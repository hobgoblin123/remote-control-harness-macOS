# TODO

## Persistence vs containment — known tradeoff

`/root` is a named podman volume per project, so uncommitted work and
tool caches survive launches. The cost: a session that writes malicious
content into `~/.bashrc`, shims a mise-managed binary, or plants code
in `node_modules/.bin` carries into the next launch. The `--cap-drop=ALL`
posture limits in-session damage; it doesn't prevent persisted artifacts
from executing next time. Use `./launch.sh --reset` to wipe the volume
when you want fresh state.

## Network hardening — known limitations

Two egress-filter implementations, one per launch mode. Both enforce a
hostname-resolved IP allowlist on the host; neither filters on DNS names
at the application layer.

### Rootless mode (default): nftables + cgroup v2

The container (and its pasta helper) runs inside a transient systemd user
slice. A single `nft` rule on the `inet output` chain matches packets
whose socket's cgroupv2 path contains the slice name at a known depth, and
drops anything not going to an allowlisted IP.

- **CDN / IP rotation.** Hostnames are resolved to IPs once, at launch
  time. If a CDN-backed host returns a different IP later, the container
  can't reach it — relaunch, or add the CDN's known egress range. Same
  failure mode as rootful.
- **Loopback is trusted.** Traffic to `127.0.0.0/8` is accepted
  unconditionally so the container can reach the host's DNS stub (e.g.
  `127.0.0.53` with systemd-resolved). This means a process in the container
  can still exfiltrate data via DNS labels sent to the local resolver, which
  forwards upstream. Closing this would require either a stub that only
  answers for the allowlist, or filtering resolver egress separately.
- **Slice-scope coupling.** The nft rule matches the slice cgroup, so
  *anything* launched into the same slice shares the allowlist — that's
  the whole container, fine — but if you `systemd-run --slice=rcode_*`
  something else yourself, it'll inherit the filter too. Document-only,
  no real bug.
- **Rule-load ordering.** `nft` resolves the cgroupv2 argument via a literal
  `stat("/sys/fs/cgroup/" + string)` at rule-load time, captures the inode,
  and hands that inode to the kernel for the actual match
  (`src/datatype.c:cgroupv2_type_parse` in nftables). So the string has to
  be the **full path relative to `/sys/fs/cgroup`** (not a basename), and
  the cgroup must exist when the rule loads. `launch.sh` pre-creates the
  slice via a `sleep infinity` warmup service before installing the rule,
  so there's no race between container start and rule enforcement.

### Rootful mode (`--rootful`): iptables FORWARD

Inherits the original harness design: a dedicated bridge with a
deterministic `/24`, and a `sudo iptables` chain hooked into `FORWARD`
filtering on the subnet.

- **CDN / IP rotation.** Same limitation as rootless.
- **DNS exfiltration.** `aardvark-dns` on the bridge gateway forwards
  queries upstream. A process in the container can encode data into DNS
  labels and leak it via the host resolver. Close this by running a stub
  resolver on the gateway that only answers for the allowlist.
- **Socket = root.** VSCode attach requires enabling
  `/run/podman/podman.sock`, which is root-owned. The socket is never
  mounted into the container, so it's not a container→host escalation
  path — but any host-side process that can read it is root-equivalent.
  Don't loosen its permissions; don't add your SSH user to a `podman`
  group without understanding that membership = root.
- **Container escape = root.** A process that escapes the container
  (requires an additional kernel bug given `--cap-drop=ALL` and
  `no-new-privileges`) lands as uid 0 on the host. Rootless mode reduces
  this blast radius to your own uid.

### Allowlist coverage

`sample.env` lists the hosts this project's defaults need (ubuntu apt,
npm registry, anthropic api, github, mise, VSCode server + marketplace).
Projects with their own package registries or telemetry endpoints need
those added before launch or network calls will fail.
