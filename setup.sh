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

WORKDIR="/root/work/${PROJECT_NAME}"

log() { printf '\n==> %s\n' "$*"; }

# Non-interactive bash (`/bin/bash /setup.sh`) does not source .bashrc,
# so we activate mise explicitly.
export PATH="/root/.local/bin:$PATH"
eval "$(/root/.local/bin/mise activate bash)"

# Egress filter self-check. Runs BEFORE any network-using step so that if
# the host's egress filter isn't enforcing, we abort before the deploy key
# is used, the repo is cloned, or package managers phone home.
#
# Two probes using bash's built-in /dev/tcp (no external deps):
#   1. CANARY_BLOCKED_IP must be unreachable — proves the filter is dropping
#      non-allowlisted destinations.
#   2. GIT_HOST must be reachable — proves the allowlist isn't globally
#      blocking (avoids a silently-broken harness that "passes" the block
#      test only because all egress is down).
#
# nft `drop` action silently discards packets, so a working filter shows up
# as a connect timeout rather than a TCP reset. 3s is enough.
GIT_HOST="$(echo "$REPO_URL" | sed -E 's#^(git@|ssh://git@|https://)##; s#[:/].*$##')"
log "egress self-check (block: $CANARY_BLOCKED_IP, allow: $GIT_HOST)"
if timeout 3 bash -c "echo > /dev/tcp/${CANARY_BLOCKED_IP}/80" 2>/dev/null; then
    cat >&2 <<EOF

FATAL: egress filter is NOT enforcing.
  ${CANARY_BLOCKED_IP} was reachable on TCP/80, but it is not in the
  allowlist. The host's nft table or iptables chain is either missing,
  not matching this container's traffic, or installed against a stale
  cgroup. Aborting before this container touches the network.

  On the host, check:
    mode=rootless: sudo nft list table inet rcode_\${PROJECT_NAME//-/_}
    mode=rootful : sudo iptables -nvL REMOTE-CODE-\${PROJECT_NAME-slug}
EOF
    exit 1
fi
if ! timeout 5 bash -c "echo > /dev/tcp/${GIT_HOST}/22" 2>/dev/null \
   && ! timeout 5 bash -c "echo > /dev/tcp/${GIT_HOST}/443" 2>/dev/null; then
    cat >&2 <<EOF

FATAL: allowlisted host ${GIT_HOST} is unreachable on 22 or 443.
  Either the allowlist is misconfigured (is ${GIT_HOST} in WHITELIST_HOSTS
  or resolved via GIT_HOST auto-add?) or host networking is down. Aborting
  before the repo clone.
EOF
    exit 1
fi
echo "  ok: egress filter enforcing (${CANARY_BLOCKED_IP} dropped, ${GIT_HOST} reachable)"

log "installing deploy key"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /tmp/deploy_key /root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
if ! ssh-keygen -F "$GIT_HOST" -f /root/.ssh/known_hosts >/dev/null 2>&1; then
    ssh-keyscan -H "$GIT_HOST" >> /root/.ssh/known_hosts 2>/dev/null
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

log "starting claude remote-control in tmux session 'remote-control'"
# tmux inherits setup.sh's PATH (mise shims are on it), so `claude` resolves.
# If claude remote-control exits for any reason, the session drops into bash
# so you can poke around instead of losing the window.
tmux new-session -d -s remote-control 'claude remote-control; echo "[claude remote-control exited]"; exec bash'
# Mirror pane output to a log file too, so you can tail without attaching.
tmux pipe-pane -t remote-control -o 'cat >>/root/.logs/remote-control.log'
echo "  attach: podman exec -it remote-code-$PROJECT_NAME tmux attach -t remote-control"
echo "  tail:   podman exec -it remote-code-$PROJECT_NAME tail -f /root/.logs/remote-control.log"

CNAME="remote-code-$PROJECT_NAME"
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

  1. On THIS host, enable podman's docker-compat socket so VSCode can
     see the container:
       systemctl --user enable --now podman.socket     # rootless mode
       sudo systemctl enable --now podman.socket       # --rootful mode

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

============================================================

EOF

exec sleep infinity
