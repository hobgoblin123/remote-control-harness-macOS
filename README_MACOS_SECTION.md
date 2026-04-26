## macOS (Apple Silicon) support

This fork adds support for running the harness on macOS with Apple Silicon
(M1/M2/M3/M4). All existing Linux behaviour is preserved unchanged.

### How it works

On macOS, `podman machine` runs a Linux VM (Fedora CoreOS) using Apple's
Virtualization Framework. The harness:

- Creates a named bridge network inside the VM
- Installs nft FORWARD rules inside the VM via `podman machine ssh`
- Runs containers on the bridge network so all egress is filtered

No firewall changes are made on the macOS host itself.

### Prerequisites (macOS)

- Apple Silicon Mac (M1/M2/M3/M4)
- `podman` 4.4+ (`brew install podman`)
- A running podman machine in **rootful mode**:

```bash
podman machine init
podman machine set --rootful
podman machine start
```

> **Why rootful?** Rootless podman inside the VM uses `pasta` (userspace
> networking) which bypasses the kernel's netfilter — nft rules have no
> effect. Rootful mode uses real bridge networking that goes through the
> FORWARD chain. This only affects the daemon inside the VM; on the macOS
> host you still run `podman` without sudo.

For Macs with limited RAM (8 GB), configure the VM before starting:

```bash
podman machine set --memory 4096 --cpus 2
```

### Usage (macOS)

Identical to Linux — see above. The script auto-detects macOS and adjusts.

```bash
cp sample.env .env
$EDITOR .env
./launch.sh
```

### macOS-specific notes

- `--rootful` flag is not supported (and not needed) — the VM boundary
  provides equivalent isolation.
- If your ISP blocks outbound port 22, use the `ssh://` URL form:
  `REPO_URL=ssh://git@ssh.github.com:443/owner/repo.git`
- The notification socket requires virtiofs home directory sharing
  (enabled by default). If disabled, container notification hooks fail
  silently with a warning.
- `--verify` works on macOS and tests the same egress filtering as Linux.
