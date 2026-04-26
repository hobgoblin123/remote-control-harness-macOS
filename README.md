# remote-code-harness

## Overview

- Spins up a network-hardened Linux container for dev environments.
0 Theoretically, this can also be configured to run on a remote instance running on Hetzner/AWS/Digital Ocean.
- Primary benefits are
  - Your host environment/machine is more insulated from supply chain attacks
    - Which are becoming increasingly common
  - Even if compromised, the blast radius of the compromise is restricted to the dev container

## Highlights

- Runs in rootless mode using podman. It clones your code into the container.
- Persists the container data across restarts
- Enforces egress rules that prevents accessing/sending data to any non-whitelisted IPs
  - Does a self-check at startup to ensure enforecement for egress rules
- Sets up a podman socket on local that lets you connect to it via VSCode's 'Attach to Running Container' feature
- Comes built in with Lazyvim so that you have a fully capable terminal editor you can on terminal
  - Useful when you have to `podman exec -it <container> /bin/bash` terminal
- Has mise installed to setup any other dev environments you may need
- Claude Code pre-installed (along with NodeJS and pnpm that Claude Code needs)
- Optionally, it can mount a directory on host that you can configure as a read-only mount
- Optionally exposes the webapp to the public internet via a Cloudflare quick tunnel (opt-in via `EXPOSE_WEBAPP` in `.env`)
- When doing teardown, it checks git directories for any uncommitted files/commits before taking it down
- Dev container to host notification via Unix domain socket comes built in

## Prerequisites

- **rootless mode:** `podman` 4.4+, `passt` (provides `pasta`), `nftables`,
  a working systemd `--user` session (`loginctl enable-linger $USER` if
  you're not always logged in), kernel ≥ 5.x with cgroup v2.
- **`--rootful` mode:** `podman`, `iptables` (legacy or nft-backed), `sudo`.
- A deploy key with commit + pull access to the repo you want to work on.

## Usage

```bash
cp sample.env .env
$EDITOR .env      # set PROJECT_NAME, REPO_URL, DEPLOY_KEY_PATH, etc.
./launch.sh       # rootless mode; prompts for sudo once to install nft rules
./launch.sh --rootful                 # fallback mode (see Modes above)
./launch.sh path/to/other.env         # use a different env file
./launch.sh --rebuild-base            # rebuild the base image
./launch.sh --reset                   # wipe the persistent volume
./launch.sh --verify                  # rootless only: run an egress smoke test
./launch.sh --update                  # in-container refresh (see Updates below)
```

When you exit `claude` (or the container otherwise stops), `launch.sh`
tears down the egress filter (nft table or iptables chain, depending on
mode), plus the warmup slice / podman network it installed.

**Note on mode switching:** volumes and images are stored per-mode
(rootless uses your user's podman store, `--rootful` uses root's). Switching
modes means a first-launch rebuild of the base image and an empty volume;
it does not destroy data in the other mode's store.

## More docs

### [Technical details](docs/Technical%20details.md)

- [Overview](docs/Technical%20details.md#overview) — the end-state that `./launch.sh` produces (base image, volume, ports, egress allowlist, container posture).
- [Container capabilities](docs/Technical%20details.md#container-capabilities) — which caps are added back, why, and why it's safe.
- [Usage Modes](docs/Technical%20details.md#usage-modes) — rootless (default) vs. `--rootful` fallback.
- [Persistence](docs/Technical%20details.md#persistence) — what survives restarts, how config edits propagate, `--reset` semantics.
- [Updates](docs/Technical%20details.md#updates) — what `--update` refreshes and what it deliberately won't touch.
- [Sharing host data (read-only)](docs/Technical%20details.md#sharing-host-data-read-only) — `SHARED_DATA_PATH`.
- [Adjusting the allowlist](docs/Technical%20details.md#adjusting-the-allowlist) — when a tool hangs on network.
- [What goes where](docs/Technical%20details.md#what-goes-where) — file-by-file map of the harness.
- [Best practices](docs/Technical%20details.md#best-practices) — deploy-key scoping.

### [How to connect to container](docs/How%20to%20connect%20to%20container.md)

- [Connecting from your phone](docs/How%20to%20connect%20to%20container.md#connecting-from-your-phone) — tunneling the 127.0.0.1-bound ports.
- [Connecting from VSCode](docs/How%20to%20connect%20to%20container.md#connecting-from-vscode) — Dev Containers extension + the podman socket.
- [Claude remote-control](docs/How%20to%20connect%20to%20container.md#claude-remote-control) — attaching to the tmux session, pairing, log tail.

### [Running on a remote host](docs/Running%20on%20a%20remote%20host.md)

- Launching the harness on a remote Linux box (Hetzner/AWS/DO, x86_64 or aarch64) and attaching to it from your laptop's VSCode over SSH.
