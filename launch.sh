#!/usr/bin/env bash
set -euo pipefail

# ---- OS detection ----------------------------------------------------------
# Detected once here; used throughout to gate macOS-specific paths.
# Linux behaviour is preserved exactly; macOS paths are purely additive.
OS="linux"
[[ "$(uname -s)" == "Darwin" ]] && OS="macos"

# ---- arg parsing -----------------------------------------------------------

MODE=rootless
RESET=false
REBUILD_BASE=false
VERIFY=false
DISABLE_NETWORK_BLOCK=false
UPDATE=false
ENV_FILE=".env"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootful)
            if [[ $OS == "macos" ]]; then
                echo "error: --rootful is not supported on macOS." >&2
                echo "       The podman machine VM already provides equivalent isolation." >&2
                echo "       Run without --rootful (rootless is the only mode on macOS)." >&2
                exit 1
            fi
            MODE=rootful; shift ;;
        --reset)                  RESET=true; shift ;;
        --rebuild-base)           REBUILD_BASE=true; shift ;;
        --verify)                 VERIFY=true; shift ;;
        --disable-network-block)  DISABLE_NETWORK_BLOCK=true; shift ;;
        --update)                 UPDATE=true; shift ;;
        -h|--help)
            cat <<'EOF'
usage: $0 [--rootful] [--reset] [--rebuild-base] [--verify]
          [--disable-network-block] [--update] [env-file]

Linux default mode: rootless podman + --network=pasta + nftables cgroup-v2
match on OUTPUT for egress filtering. prereqs: pasta, nftables, systemd --user
session (loginctl enable-linger <you> if not logged in).

macOS mode: rootless podman (via podman machine / Apple VZ) + bridge network
inside the VM + nftables FORWARD filter installed in the VM via
'podman machine ssh'. No host-level firewall changes are made on macOS.
prereqs: podman (brew install podman), a running podman machine
(podman machine init && podman machine start).

  --rootful                 (Linux only) fallback to rootful podman + netavark
                            bridge + iptables FORWARD egress filter. requires
                            sudo. not supported on macOS.
  --reset                   remove the container and wipe the persistent
                            volume for the current mode (forces a fresh create
                            on next launch, picking up any config edits).
  --rebuild-base            force rebuild of the base image (--no-cache).
  --verify                  after launch, run a short egress check and exit.
  --disable-network-block   run without egress restrictions (all outbound
                            traffic permitted). mutually exclusive with --verify.
  --update                  in-container refresh (apt upgrade, mise, claude
                            code, lazyvim). requires a container already running
                            in another terminal. mutually exclusive with
                            --reset, --rebuild-base, --verify.
  env-file                  path to env file (default: .env)
EOF
            exit 0
            ;;
        -*) echo "error: unknown flag $1" >&2; exit 1 ;;
        *)  ENV_FILE="$1"; shift ;;
    esac
done

if $VERIFY && $DISABLE_NETWORK_BLOCK; then
    echo "error: --verify and --disable-network-block are mutually exclusive." >&2
    exit 1
fi

if $UPDATE && ( $RESET || $REBUILD_BASE || $VERIFY ); then
    echo "error: --update is mutually exclusive with --reset, --rebuild-base, --verify." >&2
    exit 1
fi

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

MEM_LIMIT="${MEM_LIMIT:-8g}"
CPU_LIMIT="${CPU_LIMIT:-8}"
PIDS_LIMIT="${PIDS_LIMIT:-16384}"
if ! $DISABLE_NETWORK_BLOCK; then
    : "${WHITELIST_HOSTS:?WHITELIST_HOSTS must be set}"
fi

# Canary IP the container tries to reach at startup to prove the egress
# filter is enforcing. Must be reachable on the open internet and must NOT
# appear in the resolved allowlist. example.com is the default.
CANARY_BLOCKED_IP="${CANARY_BLOCKED_IP:-93.184.216.34}"

if [[ ! -f "$DEPLOY_KEY_PATH" ]]; then
    echo "error: DEPLOY_KEY_PATH does not exist: $DEPLOY_KEY_PATH" >&2
    exit 1
fi

SHARED_DATA_PATH="${SHARED_DATA_PATH:-}"
declare -a SHARED_DATA_VOLUME_ARGS=()
if [[ -n "$SHARED_DATA_PATH" ]]; then
    if [[ ! -d "$SHARED_DATA_PATH" ]]; then
        echo "error: SHARED_DATA_PATH is not a directory: $SHARED_DATA_PATH" >&2
        exit 1
    fi
    SHARED_DATA_PATH="$(cd "$SHARED_DATA_PATH" && pwd)"
    SHARED_DATA_VOLUME_ARGS=(--volume "${SHARED_DATA_PATH}:/root/shared_data:ro")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"
NOTIFY_LISTENER="$SCRIPT_DIR/host_listener.py"
[[ -f "$SETUP_SCRIPT" ]] || { echo "error: setup.sh not found at $SETUP_SCRIPT" >&2; exit 1; }
[[ -f "$DOCKERFILE"    ]] || { echo "error: Dockerfile not found at $DOCKERFILE" >&2; exit 1; }

# ---- notify socket path (OS-specific) --------------------------------------
# Linux: XDG_RUNTIME_DIR (or /run/user/$UID) — standard for user services.
# macOS: ~/.local/share/containers — this directory is shared into the podman
#        machine VM via virtiofs (Apple VZ default), so the socket file is
#        reachable as a volume mount from containers running inside the VM.
#        The path must be inside the home directory for virtiofs to see it.
if [[ $OS == "macos" ]]; then
    NOTIFY_SOCK_DIR="${HOME}/.local/share/containers"
    mkdir -p "$NOTIFY_SOCK_DIR"
    NOTIFY_SOCK="${NOTIFY_SOCK_DIR}/rc-notify.sock"
else
    NOTIFY_SOCK="${XDG_RUNTIME_DIR:-/run/user/$UID}/rc-notify.sock"
fi

IMAGE_NAME="remote-code-base:latest"

# ---- identifiers derived from project name ---------------------------------

CONTAINER_NAME="remote-code-${PROJECT_NAME}"
VOLUME_NAME="remote-code-vol-${PROJECT_NAME}"

# Used by both macOS (bridge in VM) and Linux rootful (bridge on host).
NET_NAME="remote-code-net-${PROJECT_NAME}"
SLUG=$(printf '%s' "$PROJECT_NAME" | tr -c 'A-Za-z0-9' _ | cut -c1-14)
CHAIN_NAME="REMOTE-CODE-${SLUG}"   # Linux rootful iptables chain name

# md5 differs between Linux (md5sum) and macOS (md5).
md5_hex() {
    if [[ $OS == "macos" ]]; then
        printf '%s' "$1" | md5
    else
        printf '%s' "$1" | md5sum | awk '{print $1}'
    fi
}

SUBNET_HEX=$(md5_hex "$PROJECT_NAME" | cut -c1-2)
SUBNET_OCTET=$(( 16#${SUBNET_HEX} % 200 + 40 ))
SUBNET="10.89.${SUBNET_OCTET}.0/24"
GATEWAY="10.89.${SUBNET_OCTET}.1"

# rootless Linux-only identifiers. systemd treats '-' in slice names as a
# path separator ('a-b.slice' -> 'a.slice/a-b.slice'), so normalise to '_'.
SAFE_PROJECT=$(echo "$PROJECT_NAME" | tr '-' '_')
SLICE_NAME="rcode_${SAFE_PROJECT}.slice"
WARMUP_UNIT="rcode_warmup_${SAFE_PROJECT}.service"
NFT_TABLE="rcode_${SAFE_PROJECT}"

GIT_HOST="$(echo "$REPO_URL" | sed -E 's#^(git@|ssh://git@|https://)##; s#[:/].*$##')"
ALL_HOSTS="$GIT_HOST $WHITELIST_HOSTS"

# ---- podman wrapper (sudo only in Linux rootful mode) ----------------------

if [[ $MODE == rootful ]]; then
    PODMAN=(sudo podman)
else
    PODMAN=(podman)
fi

# ---- DNS resolution (portable) ---------------------------------------------
# getent(1) is Linux-only. On macOS we use python3's socket module, which
# respects /etc/hosts and the system resolver the same way getent would.
resolve_ipv4() {
    local h="$1"
    if [[ $OS == "macos" ]]; then
        python3 - "$h" <<'PYEOF' 2>/dev/null || true
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)
    print('\n'.join(sorted({info[4][0] for info in infos})))
except Exception:
    pass
PYEOF
    else
        getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true
    fi
}

# ---- macOS: podman machine check -------------------------------------------
# On macOS, podman delegates all container operations to a Linux VM managed
# by podman machine. Ensure the VM exists and is running before proceeding.
if [[ $OS == "macos" ]]; then
    echo "==> checking podman machine (macOS)"
    if ! command -v podman >/dev/null 2>&1; then
        echo "error: podman not found. install via: brew install podman" >&2
        exit 1
    fi
    MACHINE_NAME=$(podman machine list --format "{{.Name}}" --noheading 2>/dev/null | head -n1 || true)
    if [[ -z "$MACHINE_NAME" ]]; then
        echo "error: no podman machine found." >&2
        echo "       initialise one with: podman machine init && podman machine start" >&2
        exit 1
    fi
    MACHINE_RUNNING=$(podman machine list --format "{{.Running}}" --noheading 2>/dev/null | head -n1 || true)
    if [[ "$MACHINE_RUNNING" != "true" ]]; then
        echo "==> starting podman machine: $MACHINE_NAME"
        podman machine start "$MACHINE_NAME"
    else
        echo "    podman machine '$MACHINE_NAME' is running"
    fi

    # The egress filter uses nft FORWARD rules inside the VM. Rootless podman
    # in the VM routes traffic via pasta (userspace networking) which bypasses
    # the kernel's netfilter entirely — nft rules have no effect. Rootful mode
    # uses real bridge networking that goes through the FORWARD chain.
    # This only affects the daemon inside the VM; on the macOS host you still
    # run `podman` without sudo.
    if ! $DISABLE_NETWORK_BLOCK; then
        if podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qi true; then
            echo "error: podman machine is in rootless mode." >&2
            echo "       The egress filter requires rootful mode inside the VM so that" >&2
            echo "       bridge networking goes through the kernel's nft FORWARD chain." >&2
            echo "       Run:" >&2
            echo "         podman machine stop" >&2
            echo "         podman machine set --rootful" >&2
            echo "         podman machine start" >&2
            exit 1
        fi
    fi
fi

# ---- --update: in-container refresh against running container --------------
if $UPDATE; then
    if ! "${PODMAN[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        echo "error: container $CONTAINER_NAME does not exist. run './launch.sh' first." >&2
        exit 1
    fi
    if ! "${PODMAN[@]}" container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qi true; then
        echo "error: container $CONTAINER_NAME is not running." >&2
        echo "       launch it in another terminal via './launch.sh' first, so the egress filter stays up." >&2
        exit 1
    fi
    echo "==> --update: refreshing packages inside $CONTAINER_NAME"
    "${PODMAN[@]}" exec "$CONTAINER_NAME" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
echo "--- apt upgrade"
apt-get update
apt-get -y upgrade
echo "--- mise: self-update + upgrade managed tools"
mise self-update -y || true
mise upgrade
echo "--- claude code (global pnpm)"
pnpm update -g @anthropic-ai/claude-code
node "$(pnpm root -g)/@anthropic-ai/claude-code/install.cjs"
echo "--- lazyvim plugin sync"
nvim --headless "+Lazy! sync" +qa
echo "--- done"
'
    exit 0
fi

# ---- pre-flight ------------------------------------------------------------

echo "==> pre-flight (os=$OS, mode=$MODE)"

if [[ $OS == "macos" ]]; then
    # macOS: pasta, nftables, systemd, and loginctl all live inside the podman
    # machine VM — we do not check for them on the host. No host-level sudo is
    # needed either: nft rules are applied inside the VM via
    # 'podman machine ssh -- sudo nft', which uses the VM's internal
    # passwordless sudo and does not prompt on the macOS host.
    if ! podman info >/dev/null 2>&1; then
        echo "error: 'podman info' failed. is the podman machine running?" >&2
        echo "       try: podman machine start" >&2
        exit 1
    fi
elif [[ $MODE == rootless ]]; then
    if [[ $EUID -eq 0 ]]; then
        echo "error: rootless mode must run as a regular user (no sudo). use --rootful to run rootful." >&2
        exit 1
    fi
    command -v pasta >/dev/null || { echo "error: pasta not installed. try 'apt install passt'." >&2; exit 1; }
    if ! $DISABLE_NETWORK_BLOCK; then
        command -v nft   >/dev/null || { echo "error: nft not installed. try 'apt install nftables'." >&2; exit 1; }
        command -v systemd-run >/dev/null || { echo "error: systemd-run required." >&2; exit 1; }
        if ! systemctl --user show-environment >/dev/null 2>&1; then
            echo "error: systemd --user session unavailable. run 'loginctl enable-linger $USER' and re-login." >&2
            exit 1
        fi
    fi
    if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qi true; then
        echo "error: podman is not configured for rootless operation." >&2
        exit 1
    fi
else
    # Linux rootful: sudo for both podman and iptables.
    if ! sudo -n true 2>/dev/null; then
        echo "    this script needs sudo to run rootful podman + install iptables rules"
        sudo -v || { echo "error: sudo required" >&2; exit 1; }
    fi
fi

# Linux only: prompt for sudo upfront if the egress filter will need it.
if [[ $OS == "linux" ]] && ! $DISABLE_NETWORK_BLOCK && ! sudo -n true 2>/dev/null; then
    echo
    echo "  ┌──────────────────────────────────────────────────────────────────┐"
    if [[ $MODE == rootless ]]; then
        echo "  │  sudo is required to install the host nftables egress filter.   │"
        echo "  │  This is what prevents access to unknown IPs from within the    │"
        echo "  │  container.                                                     │"
        echo "  │  The container itself will still run rootlessly — only the nft  │"
        echo "  │  table (which lives in the host network namespace) needs root.  │"
    else
        echo "  │  sudo is required to run rootful podman and install the         │"
        echo "  │  iptables FORWARD-chain egress filter on the host.              │"
    fi
    echo "  └──────────────────────────────────────────────────────────────────┘"
    echo
    sudo -v || { echo "error: sudo required" >&2; exit 1; }
fi

# ---- --reset: confirm destroy up-front -------------------------------------

if ! $VERIFY && $RESET; then
    if "${PODMAN[@]}" volume inspect "$VOLUME_NAME" >/dev/null 2>&1 \
       && "${PODMAN[@]}" image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "==> --reset: scanning /root/work for uncommitted/unpushed git state"
        DIRTY_REPORT=$(
            "${PODMAN[@]}" run --rm \
                --volume "$VOLUME_NAME:/root:ro" \
                "$IMAGE_NAME" \
                bash -c '
set +e
while IFS= read -r gitdir; do
    repo=${gitdir%/.git}
    cd "$repo" 2>/dev/null || continue
    status=$(git status --porcelain 2>/dev/null)
    unpushed=$(git rev-list --count --all --not --remotes 2>/dev/null || echo 0)
    stashes=$(git stash list 2>/dev/null)
    if [ -n "$status" ] || [ "${unpushed:-0}" -gt 0 ] || [ -n "$stashes" ]; then
        echo "--- $repo ---"
        [ -n "$status" ] && { echo "  working tree:"; echo "$status" | sed "s/^/    /"; }
        [ "${unpushed:-0}" -gt 0 ] && echo "  unpushed commits: $unpushed (not reachable from any remote)"
        [ -n "$stashes" ] && { echo "  stashes:"; echo "$stashes" | sed "s/^/    /"; }
        echo
    fi
done < <(find /root/work -maxdepth 5 -type d -name .git 2>/dev/null)
' 2>/dev/null
        )
        if [[ -n "$DIRTY_REPORT" ]]; then
            echo
            echo "$DIRTY_REPORT"
            echo "The following state in /root/work would be lost on --reset."
            read -r -p "Proceed anyway? [y/N] " REPLY
            if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
                echo "aborted"
                exit 1
            fi
        else
            echo "    /root/work is clean"
        fi
    fi
fi

# ---- base image ------------------------------------------------------------

if $VERIFY; then
    echo "==> --verify: skipping base image build"
elif $REBUILD_BASE; then
    echo "==> rebuilding base image $IMAGE_NAME from scratch (os=$OS, --no-cache)"
    "${PODMAN[@]}" build --no-cache -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
    if "${PODMAN[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        echo "    note: container $CONTAINER_NAME still references the old image layers."
        echo "    run --reset (or 'podman rm -f $CONTAINER_NAME') to create a fresh one."
    fi
elif ! "${PODMAN[@]}" image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "==> building base image $IMAGE_NAME (os=$OS)"
    "${PODMAN[@]}" build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
else
    echo "==> using cached base image $IMAGE_NAME"
fi

# ---- resolve allowlist -----------------------------------------------------

declare -a ALLOWED_IPS=()
declare -a ADD_HOST_ARGS=()
SEEN_IPS=""   # newline-separated list for dedup (bash 3.2 compatible)

if $DISABLE_NETWORK_BLOCK; then
    echo "==> --disable-network-block: skipping allowlist resolution"
else
    echo "==> resolving allowlist"
    for h in $ALL_HOSTS; do
        ips=$(resolve_ipv4 "$h")
        if [[ -z "$ips" ]]; then
            echo "    warn: $h did not resolve — skipping"
            continue
        fi
        first_ip=$(echo "$ips" | head -n1)
        ADD_HOST_ARGS+=(--add-host "${h}:${first_ip}")
        while IFS= read -r ip; do
            if ! echo "$SEEN_IPS" | grep -qxF "$ip"; then
                ALLOWED_IPS+=("$ip")
                SEEN_IPS="${SEEN_IPS}${ip}
"
            fi
        done <<< "$ips"
        printf '    %-40s -> %s\n' "$h" "$(echo "$ips" | tr '\n' ' ')"
    done

    if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
        echo "error: no hosts resolved. check DNS and WHITELIST_HOSTS." >&2
        exit 1
    fi

    for ip in "${ALLOWED_IPS[@]}"; do
        if [[ "$ip" == "$CANARY_BLOCKED_IP" ]]; then
            echo "error: CANARY_BLOCKED_IP ($CANARY_BLOCKED_IP) is in the resolved allowlist." >&2
            echo "       pick a different canary via the CANARY_BLOCKED_IP env var." >&2
            exit 1
        fi
    done
fi

# ---- cleanup trap (registered BEFORE any mutation) -------------------------

cleanup() {
    echo
    echo "==> tearing down (os=$OS, mode=$MODE)"
    "${PODMAN[@]}" stop -t 10 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if $DISABLE_NETWORK_BLOCK; then
        return
    fi
    if [[ $OS == "macos" ]]; then
        # Remove nft rules from inside the VM, then remove the podman network.
        podman machine ssh -- sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
        podman network rm -f "$NET_NAME" >/dev/null 2>&1 || true
    elif [[ $MODE == rootless ]]; then
        sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
        systemctl --user stop "$WARMUP_UNIT" 2>/dev/null || true
        systemctl --user reset-failed "$SLICE_NAME" 2>/dev/null || true
    else
        sudo iptables -w -D FORWARD -s "$SUBNET" -j "$CHAIN_NAME" 2>/dev/null || true
        sudo iptables -w -F "$CHAIN_NAME" 2>/dev/null || true
        sudo iptables -w -X "$CHAIN_NAME" 2>/dev/null || true
        "${PODMAN[@]}" network rm -f "$NET_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

# ---- install egress filter -------------------------------------------------

if $DISABLE_NETWORK_BLOCK; then
    echo "==> --disable-network-block: skipping egress filter install"

elif [[ $OS == "macos" ]]; then
    # macOS: create a bridge network inside the podman machine VM, then install
    # an nftables FORWARD filter in the VM to restrict container egress by subnet.
    # No firewall changes are made on the macOS host itself.
    #
    # The nft rule explicitly allows traffic to the bridge gateway so DNS
    # (forwarded by the VM's gateway) continues to work inside the container.
    podman network rm -f "$NET_NAME" >/dev/null 2>&1 || true
    podman network create \
        --subnet "$SUBNET" \
        --gateway "$GATEWAY" \
        --driver bridge \
        "$NET_NAME" >/dev/null
    echo "==> created podman network $NET_NAME ($SUBNET) inside VM"

    ALLOWED_SET=$(IFS=,; echo "${ALLOWED_IPS[*]}")
    echo "==> installing nft egress filter inside podman machine VM"
    podman machine ssh -- sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    podman machine ssh -- sudo nft -f - <<EOF
table inet $NFT_TABLE {
    set allowed_v4 {
        type ipv4_addr
        elements = { $ALLOWED_SET }
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
        ip saddr $SUBNET ip daddr $GATEWAY accept comment "allow gateway and DNS"
        ip saddr $SUBNET ip daddr @allowed_v4 accept
        ip saddr $SUBNET counter drop
    }
}
EOF
    echo "    installed nft table inet $NFT_TABLE: ${#ALLOWED_IPS[@]} allowed IPs"

elif [[ $MODE == rootless ]]; then
    # Linux rootless: pre-create the systemd user slice so the cgroup exists
    # before the nft rule is loaded (nft resolves cgroupv2 paths to inodes at
    # rule-load time; the path must exist then). The warmup service holds the
    # slice open for the container's lifetime.
    echo "==> starting slice warmup: $SLICE_NAME"
    systemctl --user stop "$WARMUP_UNIT" 2>/dev/null || true
    systemd-run --user --quiet \
        --slice="$SLICE_NAME" \
        --unit="$WARMUP_UNIT" \
        sleep infinity

    SLICE_CGROUP=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        SLICE_CGROUP=$(systemctl --user show "$SLICE_NAME" --property=ControlGroup --value 2>/dev/null || true)
        [[ -n "$SLICE_CGROUP" && -d "/sys/fs/cgroup${SLICE_CGROUP}" ]] && break
        sleep 0.1
    done
    if [[ -z "$SLICE_CGROUP" || ! -d "/sys/fs/cgroup${SLICE_CGROUP}" ]]; then
        echo "error: slice cgroup did not materialize: $SLICE_CGROUP" >&2
        exit 1
    fi
    SLICE_CGROUP_REL="${SLICE_CGROUP#/}"
    SLICE_LEVEL=$(echo "$SLICE_CGROUP_REL" | tr / '\n' | grep -c .)
    echo "    slice cgroup: $SLICE_CGROUP"
    echo "    slice level:  $SLICE_LEVEL"

    ALLOWED_SET=$(IFS=,; echo "${ALLOWED_IPS[*]}")
    sudo nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    sudo nft -f - <<EOF
table inet $NFT_TABLE {
    set allowed_v4 {
        type ipv4_addr
        elements = { $ALLOWED_SET }
    }
    chain output {
        type filter hook output priority 0; policy accept;
        socket cgroupv2 level $SLICE_LEVEL "$SLICE_CGROUP_REL" ip daddr 127.0.0.0/8 accept
        socket cgroupv2 level $SLICE_LEVEL "$SLICE_CGROUP_REL" ip daddr @allowed_v4 accept
        socket cgroupv2 level $SLICE_LEVEL "$SLICE_CGROUP_REL" counter drop
    }
}
EOF
    echo "==> installed nft egress filter: table inet $NFT_TABLE, ${#ALLOWED_IPS[@]} allowed IPs"

else
    # Linux rootful: dedicated bridge + FORWARD-chain iptables filter.
    "${PODMAN[@]}" network rm -f "$NET_NAME" >/dev/null 2>&1 || true
    "${PODMAN[@]}" network create \
        --subnet "$SUBNET" \
        --gateway "$GATEWAY" \
        --driver bridge \
        "$NET_NAME" >/dev/null
    echo "==> created network $NET_NAME ($SUBNET)"

    sudo iptables -w -D FORWARD -s "$SUBNET" -j "$CHAIN_NAME" 2>/dev/null || true
    sudo iptables -w -F "$CHAIN_NAME" 2>/dev/null || true
    sudo iptables -w -X "$CHAIN_NAME" 2>/dev/null || true

    sudo iptables -w -N "$CHAIN_NAME"
    sudo iptables -w -A "$CHAIN_NAME" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    for ip in "${ALLOWED_IPS[@]}"; do
        sudo iptables -w -A "$CHAIN_NAME" -d "$ip" -j ACCEPT
    done
    sudo iptables -w -A "$CHAIN_NAME" -j DROP
    sudo iptables -w -I FORWARD 1 -s "$SUBNET" -j "$CHAIN_NAME"
    echo "==> installed iptables egress filter: chain $CHAIN_NAME, ${#ALLOWED_IPS[@]} allowed IPs"
fi

# ---- host-side notification listener ---------------------------------------

if ! $VERIFY; then
    if [[ $OS == "macos" ]]; then
        # macOS: no systemd. Start the listener as a background process tracked
        # by a PID file so we do not start duplicates across launches.
        NOTIFY_PID_FILE="/tmp/rc-notify-${USER}.pid"
        LISTENER_RUNNING=false
        if [[ -f "$NOTIFY_PID_FILE" ]]; then
            OLD_PID=$(cat "$NOTIFY_PID_FILE" 2>/dev/null || echo "")
            if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null && [[ -S "$NOTIFY_SOCK" ]]; then
                LISTENER_RUNNING=true
                echo "==> rc-notify listener already running (pid $OLD_PID)"
            fi
        fi
        if ! $LISTENER_RUNNING && [[ -f "$NOTIFY_LISTENER" ]]; then
            echo "==> starting rc-notify listener on $NOTIFY_SOCK"
            rm -f "$NOTIFY_SOCK"
            nohup python3 "$NOTIFY_LISTENER" >>/tmp/rc-notify.log 2>&1 &
            echo $! > "$NOTIFY_PID_FILE"
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                [[ -S "$NOTIFY_SOCK" ]] && break
                sleep 0.1
            done
        fi
    else
        # Linux: manage via systemd user service so it persists across launches
        # independently of this shell's lifetime.
        if systemctl --user is-active --quiet rc-notify.service 2>/dev/null; then
            echo "==> rc-notify listener already running"
        elif [[ -f "$NOTIFY_LISTENER" ]] && command -v systemd-run >/dev/null 2>&1; then
            echo "==> starting rc-notify listener on $NOTIFY_SOCK"
            systemctl --user reset-failed rc-notify.service 2>/dev/null || true
            systemctl --user stop rc-notify.service 2>/dev/null || true
            systemd-run --user --quiet \
                --unit=rc-notify.service \
                --description="remote-code-harness notification listener" \
                python3 "$NOTIFY_LISTENER"
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                [[ -S "$NOTIFY_SOCK" ]] && break
                sleep 0.1
            done
        fi
    fi
fi

declare -a NOTIFY_VOLUME_ARGS=()
if [[ -S "$NOTIFY_SOCK" ]]; then
    if [[ $OS == "macos" ]]; then
        # Verify the VM can actually see the socket via virtiofs before mounting.
        # If the home directory is not shared (non-default podman machine config),
        # we skip the mount and warn rather than failing hard.
        if podman machine ssh -- "test -S '$NOTIFY_SOCK'" 2>/dev/null; then
            NOTIFY_VOLUME_ARGS=(--volume "$NOTIFY_SOCK:/run/notify.sock")
        else
            echo "    warn: VM cannot see socket at $NOTIFY_SOCK"
            echo "    warn: virtiofs may not be sharing the home directory in your podman machine config"
            echo "    warn: container notification hooks will fail silently"
        fi
    else
        NOTIFY_VOLUME_ARGS=(--volume "$NOTIFY_SOCK:/run/notify.sock")
    fi
else
    echo "    warn: rc-notify socket not present at $NOTIFY_SOCK — container hooks will fail silently"
fi

# ---- persistent volume -----------------------------------------------------

if ! $VERIFY; then
    if $RESET; then
        echo "==> --reset: removing container $CONTAINER_NAME and wiping volume $VOLUME_NAME (os=$OS)"
        "${PODMAN[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        "${PODMAN[@]}" volume rm -f "$VOLUME_NAME" >/dev/null 2>&1 || true
    fi
    if ! "${PODMAN[@]}" volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        "${PODMAN[@]}" volume create "$VOLUME_NAME" >/dev/null
        echo "==> created volume $VOLUME_NAME (first launch)"
    else
        echo "==> reusing volume $VOLUME_NAME"
    fi
fi

CONTAINER_EXISTS=false
if ! $VERIFY && "${PODMAN[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    CONTAINER_EXISTS=true
fi

# ---- launch ----------------------------------------------------------------

echo
echo "==> launching container $CONTAINER_NAME (os=$OS, mode=$MODE)"
echo "    repo:    $REPO_URL"
echo "    webapp:  $WEBAPP_CMD (port $WEBAPP_PORT)"
echo "    rc:      port $RC_PORT"
echo

# HOST_OS is passed into the container so setup.sh can tailor its instructions
# (e.g. the podman socket path for VSCode differs between Linux and macOS).
PODMAN_ARGS=(
    run -it
    --name "$CONTAINER_NAME"
    --hostname remote-code
    ${ADD_HOST_ARGS[@]:+"${ADD_HOST_ARGS[@]}"}
    --memory="$MEM_LIMIT"
    --cpus="$CPU_LIMIT"
    --pids-limit="$PIDS_LIMIT"
    --cap-drop=ALL
    --cap-add=CHOWN
    --cap-add=DAC_OVERRIDE
    --cap-add=FOWNER
    --cap-add=FSETID
    --cap-add=SETFCAP
    --cap-add=MKNOD
    --cap-add=SETUID
    --cap-add=SETGID
    --security-opt=no-new-privileges
    --volume "$VOLUME_NAME:/root"
    --volume "$DEPLOY_KEY_PATH:/tmp/deploy_key:ro"
    --volume "$SETUP_SCRIPT:/setup.sh:ro"
    ${SHARED_DATA_VOLUME_ARGS[@]:+"${SHARED_DATA_VOLUME_ARGS[@]}"}
    ${NOTIFY_VOLUME_ARGS[@]:+"${NOTIFY_VOLUME_ARGS[@]}"}
    --env "PROJECT_NAME=$PROJECT_NAME"
    --env "REPO_URL=$REPO_URL"
    --env "WEBAPP_CMD=$WEBAPP_CMD"
    --env "WEBAPP_PORT=$WEBAPP_PORT"
    --env "RC_PORT=$RC_PORT"
    --env "CANARY_BLOCKED_IP=$CANARY_BLOCKED_IP"
    --env "HOST_OS=$OS"
    --env "DISABLE_NETWORK_BLOCK=$DISABLE_NETWORK_BLOCK"
    --publish "127.0.0.1:${WEBAPP_PORT}:${WEBAPP_PORT}"
    --publish "127.0.0.1:${RC_PORT}:${RC_PORT}"
)

if [[ $OS == "macos" ]]; then
    # macOS: containers run inside the podman machine VM. No systemd-run scope
    # is needed — the VM-level nft FORWARD filter applies to all container
    # traffic on the bridge network, regardless of which process launched them.

    if $VERIFY; then
        echo "==> --verify: running egress smoke test in ephemeral container"
        ALLOWED_HOST="github.com"
        podman run --rm \
            --network "$NET_NAME" \
            ${ADD_HOST_ARGS[@]:+"${ADD_HOST_ARGS[@]}"} \
            alpine sh -c "
                set -e
                echo '--- expect OK: allowlisted host'
                wget -qO- --timeout=5 https://${ALLOWED_HOST} >/dev/null && echo '  OK: ${ALLOWED_HOST} reachable'
                echo '--- expect FAIL: blocked IP'
                if wget -qO- --timeout=5 http://${CANARY_BLOCKED_IP} >/dev/null 2>&1; then
                    echo '  FAIL: ${CANARY_BLOCKED_IP} was reachable — allowlist is not enforcing!' >&2
                    exit 1
                else
                    echo '  OK: ${CANARY_BLOCKED_IP} blocked'
                fi
            "
        echo "==> verify passed"
        exit 0
    fi

    if $CONTAINER_EXISTS; then
        echo "==> reusing existing container $CONTAINER_NAME (use --reset to recreate)"
        podman start -ai "$CONTAINER_NAME"
    else
        echo "==> creating new container $CONTAINER_NAME"
        declare -a NETWORK_ARG=()
        if ! $DISABLE_NETWORK_BLOCK; then
            NETWORK_ARG=(--network "$NET_NAME")
        fi
        podman "${PODMAN_ARGS[@]}" ${NETWORK_ARG[@]:+"${NETWORK_ARG[@]}"} "$IMAGE_NAME" /bin/bash /setup.sh
    fi

elif [[ $MODE == rootless ]]; then
    # Linux rootless: wrap in systemd-run scope so the process lands in the
    # slice whose cgroup the nft rule is matching against.
    if $VERIFY; then
        echo "==> --verify: running egress smoke test in ephemeral container"
        ALLOWED_HOST="github.com"
        systemd-run --user --scope --quiet --slice="$SLICE_NAME" -- \
            podman run --rm --network=pasta ${ADD_HOST_ARGS[@]:+"${ADD_HOST_ARGS[@]}"} \
            alpine sh -c "
                set -e
                echo '--- expect OK: allowlisted host'
                wget -qO- --timeout=5 https://${ALLOWED_HOST} >/dev/null && echo '  OK: ${ALLOWED_HOST} reachable'
                echo '--- expect FAIL: blocked IP'
                if wget -qO- --timeout=5 http://${CANARY_BLOCKED_IP} >/dev/null 2>&1; then
                    echo '  FAIL: ${CANARY_BLOCKED_IP} was reachable — allowlist is not enforcing!' >&2
                    exit 1
                else
                    echo '  OK: ${CANARY_BLOCKED_IP} blocked'
                fi
            "
        echo "==> verify passed"
        exit 0
    fi

    if $CONTAINER_EXISTS; then
        echo "==> reusing existing container $CONTAINER_NAME (use --reset to recreate)"
        PODMAN_CMD=(podman start -ai "$CONTAINER_NAME")
    else
        echo "==> creating new container $CONTAINER_NAME"
        PODMAN_CMD=(podman "${PODMAN_ARGS[@]}" --network=pasta "$IMAGE_NAME" /bin/bash /setup.sh)
    fi

    if $DISABLE_NETWORK_BLOCK; then
        "${PODMAN_CMD[@]}"
    else
        systemd-run --user --scope --quiet --slice="$SLICE_NAME" -- "${PODMAN_CMD[@]}"
    fi

else
    # Linux rootful.
    if $VERIFY; then
        echo "error: --verify is only implemented for rootless (Linux) and macOS modes" >&2
        exit 1
    fi

    if $CONTAINER_EXISTS; then
        echo "==> reusing existing container $CONTAINER_NAME (use --reset to recreate)"
        sudo podman start -ai "$CONTAINER_NAME"
    elif $DISABLE_NETWORK_BLOCK; then
        sudo podman "${PODMAN_ARGS[@]}" \
            "$IMAGE_NAME" \
            /bin/bash /setup.sh
    else
        sudo podman "${PODMAN_ARGS[@]}" \
            --network "$NET_NAME" \
            "$IMAGE_NAME" \
            /bin/bash /setup.sh
    fi
fi
