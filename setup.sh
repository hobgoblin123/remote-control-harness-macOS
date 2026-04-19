#!/usr/bin/env bash
# Runs inside the container as root. Base image already has apt packages,
# mise, node LTS, and claude. This script handles the per-project bits:
# ssh setup, cloning, and starting the webapp + claude-rc + claude.
# Safe to re-run — /root is a persistent podman volume.
set -euo pipefail

: "${PROJECT_NAME:?}"
: "${REPO_URL:?}"
: "${WEBAPP_CMD:?}"
: "${WEBAPP_PORT:?}"
: "${RC_PORT:?}"

WORKDIR="/root/work/${PROJECT_NAME}"

log() { printf '\n==> %s\n' "$*"; }

# Non-interactive bash (`/bin/bash /setup.sh`) does not source .bashrc,
# so we activate mise explicitly.
export PATH="/root/.local/bin:$PATH"
eval "$(/root/.local/bin/mise activate bash)"

log "installing deploy key"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /tmp/deploy_key /root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519
GIT_HOST="$(echo "$REPO_URL" | sed -E 's#^(git@|ssh://git@|https://)##; s#[:/].*$##')"
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

log "starting webapp: $WEBAPP_CMD"
mkdir -p /var/log/remote-code
nohup bash -c "cd '$WORKDIR' && eval \"\$(/root/.local/bin/mise activate bash)\" && $WEBAPP_CMD" \
    >/var/log/remote-code/webapp.log 2>&1 &
echo "webapp pid: $! (logs: /var/log/remote-code/webapp.log)"

log "starting claude remote-control server on port $RC_PORT"
# Placeholder — replace with the actual start command for your claude-rc
# distribution (e.g. `claude mcp serve` or a dedicated binary).
if command -v claude-rc >/dev/null 2>&1; then
    nohup claude-rc --port "$RC_PORT" --bind 0.0.0.0 \
        >/var/log/remote-code/claude-rc.log 2>&1 &
    echo "claude-rc pid: $! (logs: /var/log/remote-code/claude-rc.log)"
else
    echo "note: claude-rc binary not found — edit setup.sh with the correct"
    echo "      remote-control invocation for your claude distribution."
fi

log "ready. dropping into claude (repo: $WORKDIR)"
cd "$WORKDIR"
exec claude
