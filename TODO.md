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

Egress is enforced by a per-project iptables chain on the host, hooked into
`FORWARD` and filtering on the container's dedicated `/24`. The container
itself stays capability-free (`--cap-drop=ALL`). Limitations worth knowing:

- **CDN / IP rotation.** Allowlisted hostnames are resolved to IPs once, at
  launch time. If a CDN-backed host returns a different IP later, the
  container can't reach it — symptom is a hang or "connection refused" on
  TLS connect. Fix is to relaunch, or add the CDN's known egress range.
  Long-term: periodic re-resolve + rule refresh, or switch to an
  application-layer allowlist (MITM proxy with hostname matching).

- **DNS exfiltration.** `aardvark-dns` on the bridge gateway forwards
  queries upstream. A process in the container can encode data into DNS
  labels and leak it via the host resolver. TCP/UDP egress to arbitrary IPs
  is blocked, but DNS is not content-filtered. Close this by running a
  stub resolver on the gateway that only answers for the allowlist.

- **Rootless podman with slirp4netns.** Host `FORWARD` rules don't apply
  to slirp4netns-routed traffic — the rules silently no-op and the
  container has full egress. `launch.sh` warns on rootless but doesn't
  refuse. Use rootful podman or pasta backend for real enforcement.

- **Allowlist coverage.** `sample.env` lists the hosts this project's
  defaults need (ubuntu apt, npm registry, anthropic api, github, mise).
  Projects with their own package registries or telemetry endpoints need
  those added before launch or network calls will fail.
