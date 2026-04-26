#!/usr/bin/env bash
# Runs inside the container as root. Base image already has apt packages,
# mise, node LTS, and claude. This script handles the per-project bits:
# ssh setup, cloning, and starting the devserver + remote-control + claude.
# Safe to re-run — /root is a persistent podman volume.
set -euo pipefail

: "${PROJECT_NAME:?}"
: "${REPO_URL:?}"
: "${WEBAPP_CMD:?}"
: "${WEBAPP_PORT:?}"
: "${RC_PORT:?}"
: "${CANARY_BLOCKED_IP:?}"

# HOST_OS is set by launch.sh on the host and passed in as an env var.
# It never affects container behaviour (the container is always Linux);
# it only controls which host-side instructions are printed at the end.
HOST_OS="${HOST_OS:-linux}"
EXPOSE_WEBAPP="${EXPOSE_WEBAPP:-false}"
DISABLE_NETWORK_BLOCK="${DISABLE_NETWORK_BLOCK:-false}"

WORKDIR="/root/work/${PROJECT_NAME}"

log() { printf '\n==> %s\n' "$*"; }

# Non-interactive bash (`/bin/bash /setup.sh`) does not source .bashrc,
# so we activate mise explicitly.
export PATH="/root/.local/bin:$PATH"
eval "$(/root/.local/bin/mise activate bash)"

# Egress filter self-check. Runs BEFORE any network-using step so that if
# the host's egress filter is not enforcing, we abort before the deploy key
# is used, the repo is cloned, or package managers phone home.
#
# Two probes using bash's built-in /dev/tcp (no external deps):
#   1. CANARY_BLOCKED_IP must be unreachable — proves the filter is dropping
#      non-allowlisted destinations.
#   2. GIT_HOST must be reachable — proves the allowlist is not globally
#      broken (avoids a harness that "passes" only because all egress is down).
#
# nft `drop` silently discards packets, so a working filter appears as a
# connect timeout rather than a TCP reset. 3s is enough.
DISABLE_NETWORK_BLOCK="${DISABLE_NETWORK_BLOCK:-false}"

GIT_HOST="$(echo "$REPO_URL" | sed -E 's#^(git@|ssh://git@|https://)##; s#[:/].*$##')"
# Extract an explicit SSH port from ssh:// URLs (defaults to 22). Useful when an
# ISP or firewall blocks port 22 — in that case set REPO_URL to something like
# ssh://git@ssh.github.com:443/owner/repo.git and the harness will probe and
# keyscan on the right port.
GIT_SSH_PORT="$(echo "$REPO_URL" | sed -nE 's#^ssh://git@[^:/]+:([0-9]+)/.*#\1#p')"
GIT_SSH_PORT="${GIT_SSH_PORT:-22}"

if [[ "$DISABLE_NETWORK_BLOCK" == "true" ]]; then
    log "egress self-check skipped (--disable-network-block)"
else
    log "egress self-check (block: $CANARY_BLOCKED_IP, allow: $GIT_HOST:$GIT_SSH_PORT)"
    if timeout 3 bash -c "echo > /dev/tcp/${CANARY_BLOCKED_IP}/80" 2>/dev/null; then
        cat >&2 <<EOF

FATAL: egress filter is NOT enforcing.
  ${CANARY_BLOCKED_IP} was reachable on TCP/80, but it is not in the
  allowlist. The nft table is either missing, not matching this container's
  traffic, or installed against a stale cgroup/network. Aborting before
  this container touches the network.

  On the host, check:
    Linux rootless:  sudo nft list table inet rcode_\${PROJECT_NAME//-/_}
    Linux rootful:   sudo iptables -nvL REMOTE-CODE-<project-slug>
    macOS:           podman machine ssh -- sudo nft list table inet rcode_\${PROJECT_NAME//-/_}
EOF
        exit 1
    fi
    if ! timeout 5 bash -c "echo > /dev/tcp/${GIT_HOST}/${GIT_SSH_PORT}" 2>/dev/null \
       && ! timeout 5 bash -c "echo > /dev/tcp/${GIT_HOST}/443" 2>/dev/null; then
        cat >&2 <<EOF

FATAL: allowlisted host ${GIT_HOST} is unreachable on ${GIT_SSH_PORT} or 443.
  Either the allowlist is misconfigured (is ${GIT_HOST} in WHITELIST_HOSTS
  or resolved via GIT_HOST auto-add?) or host networking is down. Aborting
  before the repo clone.
EOF
        exit 1
    fi
    echo "  ok: egress filter enforcing (${CANARY_BLOCKED_IP} dropped, ${GIT_HOST}:${GIT_SSH_PORT} reachable)"
fi

log "installing deploy key"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /tmp/deploy_key /root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
if ! ssh-keygen -F "$GIT_HOST" -f /root/.ssh/known_hosts >/dev/null 2>&1; then
    ssh-keyscan -p "$GIT_SSH_PORT" -H "$GIT_HOST" >> /root/.ssh/known_hosts 2>/dev/null
fi

if [[ -d "$WORKDIR/.git" ]]; then
    log "repo already present at $WORKDIR — skipping clone"
else
    log "cloning $REPO_URL"
    mkdir -p "$(dirname "$WORKDIR")"
    git clone "$REPO_URL" "$WORKDIR"
fi
cd "$WORKDIR"

log "starting devserver in tmux session 'devserver': $WEBAPP_CMD"
mkdir -p /root/.logs
tmux new-session -d -s devserver -c "$WORKDIR" "$WEBAPP_CMD; echo '[devserver exited]'; exec bash"
tmux pipe-pane -t devserver -o 'cat >>/root/.logs/devserver.log'
echo "  attach: podman exec -it remote-code-$PROJECT_NAME tmux attach -t devserver"
echo "  tail:   podman exec -it remote-code-$PROJECT_NAME tail -f /root/.logs/devserver.log"

if [[ "$EXPOSE_WEBAPP" == "true" ]]; then
    log "starting cloudflared quick tunnel in tmux session 'tunnel' (-> port $WEBAPP_PORT)"
    : > /root/.logs/tunnel.log
    rm -f /root/.logs/tunnel-url.txt
    tmux new-session -d -s tunnel "cloudflared tunnel --url http://localhost:$WEBAPP_PORT 2>&1; echo '[cloudflared exited]'; exec bash"
    tmux pipe-pane -t tunnel -o 'cat >>/root/.logs/tunnel.log'
    echo "  attach: podman exec -it remote-code-$PROJECT_NAME tmux attach -t tunnel"
    echo "  tail:   podman exec -it remote-code-$PROJECT_NAME tail -f /root/.logs/tunnel.log"
fi

log "starting claude remote-control in tmux session 'remote-control'"
tmux new-session -d -s remote-control 'claude remote-control; echo "[claude remote-control exited]"; exec bash'
tmux pipe-pane -t remote-control -o 'cat >>/root/.logs/remote-control.log'
echo "  attach: podman exec -it remote-code-$PROJECT_NAME tmux attach -t remote-control"
echo "  tail:   podman exec -it remote-code-$PROJECT_NAME tail -f /root/.logs/remote-control.log"

CNAME="remote-code-$PROJECT_NAME"

# Build OS-specific VSCode socket instructions.
if [[ "$HOST_OS" == "macos" ]]; then
    VSCODE_SOCKET_INSTRUCTIONS="  1. Find your podman socket path on macOS:
       podman machine inspect | python3 -c \"
import sys, json
d = json.load(sys.stdin)
print(d[0]['ConnectionInfo']['PodmanSocket']['Path'])
\"
       (typically ~/.local/share/containers/podman/machine/.../podman.sock)"
else
    VSCODE_SOCKET_INSTRUCTIONS="  1. On THIS host, enable podman's docker-compat socket so VSCode can
     see the container:
       systemctl --user enable --now podman.socket     # rootless mode
       sudo systemctl enable --now podman.socket       # --rootful mode"
fi

TUNNEL_BANNER=""
if [[ "$EXPOSE_WEBAPP" == "true" ]]; then
    log "waiting for cloudflared tunnel URL (up to 30s)"
    TUNNEL_URL=""
    for _ in $(seq 1 60); do
        TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /root/.logs/tunnel.log 2>/dev/null | head -1 || true)
        [[ -n "$TUNNEL_URL" ]] && break
        sleep 0.5
    done
    if [[ -n "$TUNNEL_URL" ]]; then
        echo "$TUNNEL_URL" > /root/.logs/tunnel-url.txt
        TUNNEL_BANNER=$(cat <<TBEOF

============================================================
  PUBLIC TUNNEL ACTIVE — webapp exposed to the internet
============================================================

  $TUNNEL_URL

  Anyone with this URL can reach your webapp; the URL is the
  only access control. Stable until the next ./launch.sh.
  Cached at /root/.logs/tunnel-url.txt inside the container.

  attach: podman exec -it $CNAME tmux attach -t tunnel
  log:    podman exec -it $CNAME tail -f /root/.logs/tunnel.log

============================================================
TBEOF
)
    else
        TUNNEL_BANNER=$(cat <<TBEOF

============================================================
  PUBLIC TUNNEL — URL not detected after 30s
============================================================

  Check the tunnel session:
    podman exec -it $CNAME tmux attach -t tunnel
    podman exec -it $CNAME tail -f /root/.logs/tunnel.log

============================================================
TBEOF
)
    fi
fi

cat <<EOF

============================================================
  Dev container '$CNAME' is up and running.
============================================================

Shell into the container:
  podman exec -it $CNAME bash

Running tmux sessions (sessions persist across attach/detach;
Ctrl-b d to detach without killing them):

  devserver        — your webapp ($WEBAPP_CMD), bound to port $WEBAPP_PORT
    attach: podman exec -it $CNAME tmux attach -t devserver
    log:    podman exec -it $CNAME tail -f /root/.logs/devserver.log

  remote-control   — 'claude remote-control' on port $RC_PORT;
                     pairing URL/code shows up here on first connect
    attach: podman exec -it $CNAME tmux attach -t remote-control
    log:    podman exec -it $CNAME tail -f /root/.logs/remote-control.log

Connect with VSCode (Dev Containers):

${VSCODE_SOCKET_INSTRUCTIONS}

  2. On your local machine, install the 'Dev Containers' extension
     (ms-vscode-remote.remote-containers) and add to settings.json:
       "dev.containers.dockerPath": "podman",
       "docker.host": "ssh://user@<this-host>"   # omit if local

  3. Command Palette -> 'Dev Containers: Attach to Running Container...'
     -> pick '$CNAME'.

  4. In the new VSCode window, install the 'Claude Code' extension —
     it lands on the persistent volume and survives relaunches. The
     extension spawns its own claude; it does NOT share state with the
     'remote-control' tmux session above.

To stop the container:
  podman stop $CNAME
  or: press Ctrl+C / Ctrl+D in this terminal

============================================================
$TUNNEL_BANNER

EOF

trap 'echo; echo "shutting down..."; exit 0' INT TERM
cat >/dev/null || true
echo
echo "stdin closed, shutting down..."
