#!/usr/bin/env bash
set -euo pipefail

RESET=false
REBUILD_BASE=false
ENV_FILE=".env"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset) RESET=true; shift ;;
        --rebuild-base) REBUILD_BASE=true; shift ;;
        -h|--help)
            echo "usage: $0 [--reset] [--rebuild-base] [env-file]"
            echo "  --reset         wipe the persistent volume for this project before launch"
            echo "  --rebuild-base  force rebuild of the base image"
            echo "  env-file        path to env file (default: .env)"
            exit 0
            ;;
        -*) echo "error: unknown flag $1" >&2; exit 1 ;;
        *)  ENV_FILE="$1"; shift ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: $ENV_FILE not found. copy sample.env to .env and edit it." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PROJECT_NAME:?PROJECT_NAME must be set}"
: "${REPO_URL:?REPO_URL must be set}"
: "${DEPLOY_KEY_PATH:?DEPLOY_KEY_PATH must be set}"
: "${WEBAPP_CMD:?WEBAPP_CMD must be set}"
: "${WEBAPP_PORT:?WEBAPP_PORT must be set}"
: "${RC_PORT:?RC_PORT must be set}"
: "${WHITELIST_HOSTS:?WHITELIST_HOSTS must be set}"

if [[ ! -f "$DEPLOY_KEY_PATH" ]]; then
    echo "error: DEPLOY_KEY_PATH does not exist: $DEPLOY_KEY_PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"

if [[ ! -f "$SETUP_SCRIPT" ]]; then
    echo "error: setup.sh not found at $SETUP_SCRIPT" >&2
    exit 1
fi

if [[ ! -f "$DOCKERFILE" ]]; then
    echo "error: Dockerfile not found at $DOCKERFILE" >&2
    exit 1
fi

IMAGE_NAME="remote-code-base:latest"

# ---- identifiers derived from project name ---------------------------------

CONTAINER_NAME="remote-code-${PROJECT_NAME}"
NET_NAME="remote-code-net-${PROJECT_NAME}"
VOLUME_NAME="remote-code-vol-${PROJECT_NAME}"
# iptables chain names max 28 chars; keep it slug-safe.
SLUG=$(printf '%s' "$PROJECT_NAME" | tr -c 'A-Za-z0-9' _ | cut -c1-14)
CHAIN_NAME="REMOTE-CODE-${SLUG}"
# Deterministic /24 from project-name hash, in the 10.89.X.0/24 block.
SUBNET_HEX=$(printf '%s' "$PROJECT_NAME" | md5sum | cut -c1-2)
SUBNET_OCTET=$(( 16#${SUBNET_HEX} % 200 + 40 ))
SUBNET="10.89.${SUBNET_OCTET}.0/24"
GATEWAY="10.89.${SUBNET_OCTET}.1"

GIT_HOST="$(echo "$REPO_URL" | sed -E 's#^(git@|ssh://git@|https://)##; s#[:/].*$##')"
ALL_HOSTS="$GIT_HOST $WHITELIST_HOSTS"

# ---- pre-flight checks -----------------------------------------------------

echo "==> pre-flight"

# Host iptables rules require root.
if ! sudo -n true 2>/dev/null; then
    echo "    this script needs sudo to install host iptables rules"
    sudo -v || { echo "error: sudo required" >&2; exit 1; }
fi

if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qi true; then
    NET_BACKEND=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo unknown)
    cat >&2 <<EOF
    WARNING: rootless podman detected (backend: $NET_BACKEND).
    host iptables rules apply to FORWARD-chain traffic. rootless traffic
    via slirp4netns bypasses FORWARD entirely; via pasta it does not.
    if unsure, use rootful podman to guarantee enforcement.
EOF
fi

# ---- base image ------------------------------------------------------------

# Build before installing the egress filter — `podman build` runs on the
# default network and needs unrestricted apt access.
if $REBUILD_BASE || ! podman image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "==> building base image $IMAGE_NAME"
    podman build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
else
    echo "==> using cached base image $IMAGE_NAME"
fi

# ---- resolve allowlist -----------------------------------------------------

echo "==> resolving allowlist"
declare -a ALLOWED_IPS=()
declare -a ADD_HOST_ARGS=()
declare -A SEEN_IPS=()

for h in $ALL_HOSTS; do
    ips=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true)
    if [[ -z "$ips" ]]; then
        echo "    warn: $h did not resolve — skipping"
        continue
    fi
    first_ip=$(echo "$ips" | head -n1)
    ADD_HOST_ARGS+=(--add-host "${h}:${first_ip}")
    while IFS= read -r ip; do
        if [[ -z "${SEEN_IPS[$ip]:-}" ]]; then
            ALLOWED_IPS+=("$ip")
            SEEN_IPS[$ip]=1
        fi
    done <<< "$ips"
    printf '    %-40s -> %s\n' "$h" "$(echo $ips | tr '\n' ' ')"
done

if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
    echo "error: no hosts resolved. check DNS and WHITELIST_HOSTS." >&2
    exit 1
fi

# ---- cleanup trap (registered BEFORE any mutation) -------------------------

cleanup() {
    echo
    echo "==> tearing down network hardening"
    sudo iptables -w -D FORWARD -s "$SUBNET" -j "$CHAIN_NAME" 2>/dev/null || true
    sudo iptables -w -F "$CHAIN_NAME" 2>/dev/null || true
    sudo iptables -w -X "$CHAIN_NAME" 2>/dev/null || true
    podman network rm -f "$NET_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ---- create network + install firewall -------------------------------------

# Rebuild fresh in case a prior run crashed without cleanup.
podman network rm -f "$NET_NAME" >/dev/null 2>&1 || true
podman network create \
    --subnet "$SUBNET" \
    --gateway "$GATEWAY" \
    --driver bridge \
    "$NET_NAME" >/dev/null
echo "==> created network $NET_NAME ($SUBNET)"

# Wipe any stale chain, then build fresh.
sudo iptables -w -D FORWARD -s "$SUBNET" -j "$CHAIN_NAME" 2>/dev/null || true
sudo iptables -w -F "$CHAIN_NAME" 2>/dev/null || true
sudo iptables -w -X "$CHAIN_NAME" 2>/dev/null || true

sudo iptables -w -N "$CHAIN_NAME"
sudo iptables -w -A "$CHAIN_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for ip in "${ALLOWED_IPS[@]}"; do
    sudo iptables -w -A "$CHAIN_NAME" -d "$ip" -j ACCEPT
done
sudo iptables -w -A "$CHAIN_NAME" -j DROP

# Insert at FORWARD position 1 so we win over netavark's bridge-ACCEPT rules.
sudo iptables -w -I FORWARD 1 -s "$SUBNET" -j "$CHAIN_NAME"
echo "==> installed egress filter: chain $CHAIN_NAME, ${#ALLOWED_IPS[@]} allowed IPs"

# ---- persistent volume -----------------------------------------------------

if $RESET; then
    echo "==> --reset: wiping volume $VOLUME_NAME"
    podman volume rm -f "$VOLUME_NAME" >/dev/null 2>&1 || true
fi
if ! podman volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    podman volume create "$VOLUME_NAME" >/dev/null
    echo "==> created volume $VOLUME_NAME (first launch)"
else
    echo "==> reusing volume $VOLUME_NAME"
fi

# ---- launch ----------------------------------------------------------------

echo
echo "==> launching container $CONTAINER_NAME"
echo "    repo:    $REPO_URL"
echo "    webapp:  $WEBAPP_CMD (port $WEBAPP_PORT)"
echo "    rc:      port $RC_PORT"
echo

# NOTE: no `exec` — we need the trap to fire on container exit.
podman run --rm -it \
    --name "$CONTAINER_NAME" \
    --hostname remote-code \
    --network "$NET_NAME" \
    "${ADD_HOST_ARGS[@]}" \
    --memory=4g \
    --cpus=2 \
    --pids-limit=256 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --volume "$VOLUME_NAME:/root" \
    --volume "$DEPLOY_KEY_PATH:/tmp/deploy_key:ro" \
    --volume "$SETUP_SCRIPT:/setup.sh:ro" \
    --env PROJECT_NAME="$PROJECT_NAME" \
    --env REPO_URL="$REPO_URL" \
    --env WEBAPP_CMD="$WEBAPP_CMD" \
    --env WEBAPP_PORT="$WEBAPP_PORT" \
    --env RC_PORT="$RC_PORT" \
    --publish "127.0.0.1:${WEBAPP_PORT}:${WEBAPP_PORT}" \
    --publish "127.0.0.1:${RC_PORT}:${RC_PORT}" \
    "$IMAGE_NAME" \
    /bin/bash /setup.sh
