# remote-code-harness

Spins up a network-hardened Linux container for working on a single
project from somewhere else — a phone, a tablet, another laptop.
You run `./launch.sh` on a host machine, and you end up with:

- A local base image (`remote-code-base:latest`) built once from the
  checked-in [Dockerfile](Dockerfile) and reused across all projects.
  The image bakes in apt packages (`git`, `curl`, `openssh-client`,
  `ca-certificates`), `mise`, Node LTS, and Claude Code — nothing in the
  install chain needs to run at container start.
- The repo cloned inside the resulting container, on a per-project
  persistent volume so uncommitted work, branches, and `node_modules`
  survive across launches. The volume is seeded from the image's `/root`
  on first mount, so mise/node/pnpm/claude come along for free.
- The project's dev webapp running under `nohup`, forwarded to
  `127.0.0.1:$WEBAPP_PORT` on the host.
- A Claude Code remote-control server on `127.0.0.1:$RC_PORT`, which you
  connect to from your phone.
- A per-project iptables allowlist on the host that drops every outbound
  connection except to hostnames you named in `WHITELIST_HOSTS`.

Container posture: `--cap-drop=ALL`, `no-new-privileges`, 4G RAM / 2 CPU /
256 pids cap. The deploy key is mounted read-only and scoped to the one
repo by whoever issued it.

## Prerequisites

- `podman` (rootful recommended — see the rootless note in [TODO.md](TODO.md))
- `iptables` and `sudo` on the host (launch script installs host-side rules)
- A deploy key with commit + pull access to the repo you want to work on

## Usage

```bash
cp sample.env .env
$EDITOR .env      # set PROJECT_NAME, REPO_URL, DEPLOY_KEY_PATH, etc.
./launch.sh       # prompts for sudo once, then drops you into `claude`
```

When you exit `claude` (or the container otherwise stops), `launch.sh`
tears down the iptables chain and the podman network automatically.

To point `launch.sh` at a different env file:

```bash
./launch.sh path/to/other.env
```

The base image is built automatically on first run. To force a rebuild
(e.g. after editing [Dockerfile](Dockerfile) to add a system package, or
to refresh the pinned mise / node LTS / claude versions):

```bash
./launch.sh --rebuild-base
```

## Persistence

Each project gets a named podman volume `remote-code-vol-$PROJECT_NAME`
mounted at `/root` in the container. Across launches this preserves:

- the repo working tree (including uncommitted changes and feature branches)
- `node_modules`, pnpm store (`~/.local/share/pnpm`), and other caches
- mise-installed toolchains (`~/.local/share/mise`)
- claude config and login state (`~/.claude`)

The container OS layer (apt packages, `/var`, `/etc`) stays ephemeral
and rebuilds on each launch.

**Tradeoff worth knowing:** persistent state means a compromised session
— a bad dep's postinstall, an agent going off the rails, a modified
`~/.bashrc` — can carry effects into your next launch. The throw-away
containment you'd get from `--rm` alone is weaker here. Use `--reset`
to wipe the volume back to empty:

```bash
./launch.sh --reset
```

The first launch after a `--reset` just re-seeds `/root` from the base
image (near-instant). `pnpm install` for the project's own dependencies
runs on demand inside the container, not at launch.

## What goes where

- [sample.env](sample.env) — config template; copy to `.env`.
- [Dockerfile](Dockerfile) — base image. Holds everything shared across
  projects: apt packages, mise, Node LTS, claude code. Built once by
  `launch.sh`, reused for every project, rebuilt with `--rebuild-base`.
- [launch.sh](launch.sh) — host side. Validates env, builds the base
  image if missing, resolves the allowlist, creates a dedicated bridge
  network on a deterministic `/24`, installs an iptables chain hooked
  into `FORWARD`, runs the container, cleans up on exit.
- [setup.sh](setup.sh) — runs inside the container as the entrypoint.
  Installs the deploy key, clones the repo (or reuses an existing
  checkout), then starts three tmux sessions: `devserver`,
  `remote-control`, and `claude` (the interactive one, which is attached
  in the foreground). Every step is idempotent.
- [TODO.md](TODO.md) — known limitations of the current hardening.

## Connecting from your phone

Both published ports bind to `127.0.0.1` on the host, not `0.0.0.0`. To
reach them from a phone you need your own secure tunnel to the host
(Tailscale, SSH port forward, etc.) — this repo deliberately doesn't
expose anything on your LAN.

## Adjusting the allowlist

If a package manager or tool inside the container hangs on a network
call, it's almost always a missing host in `WHITELIST_HOSTS`. Add the
hostname, relaunch. IPs are re-resolved on each launch, so a stale
allowlist only costs you a container restart.

## Claude remote-control

[setup.sh](setup.sh) starts `claude remote-control` inside a detached
tmux session named `remote-control` on container boot. Two ways to see
what it's doing:

```bash
# Attach to the live tmux session (Ctrl-b d to detach without killing it)
podman exec -it remote-code-<project> tmux attach -t remote-control

# Or just tail the mirrored log
podman exec -it remote-code-<project> tail -f /var/log/remote-code/remote-control.log
```

The first time you connect, grab the pairing URL/code from there and
hand it to your phone. Auth persists in the volume, so subsequent
launches don't need re-pairing.

If the server isn't reachable from the host on `127.0.0.1:$RC_PORT`,
check what interface it bound to — `claude remote-control` needs to
bind to `0.0.0.0` inside the container for podman's port publish to
forward correctly (same gotcha as the webapp).
