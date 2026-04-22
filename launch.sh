#!/usr/bin/env bash
set -euo pipefail

# ---- arg parsing -----------------------------------------------------------

MODE=rootless
RESET=false
REBUILD_BASE=false
VERIFY=false
DISABLE_NETWORK_BLOCK=false
ENV_FILE=".env"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootful)                MODE=rootful; shift ;;
        --reset)                  RESET=true; shift ;;
        --rebuild-base)           REBUILD_BASE=true; shift ;;
        --verify)                 VERIFY=true; shift ;;
        --disable-network-block)  DISABLE_NETWORK_BLOCK=true; shift ;;
        -h|--help)
            cat <<EOF
usage: $0 [--rootful] [--reset] [--rebuild-base] [--verify]
          [--disable-network-block] [env-file]

default mode: rootless podman + --network=pasta + nftables cgroup-v2 match
on OUTPUT for egress filtering. prereqs: pasta, nftables, systemd --user
session (loginctl enable-linger <you> if not logged in).

  --rootful                 fallback to rootful podman + netavark bridge +
                            iptables FORWARD egress filter. requires sudo
                            for the podman invocation itself; volume/image
                            live in root's store, so the first --rootful
                            launch rebuilds both.
  --reset                   remove the container and wipe the persistent
                            volume for the current mode (forces a fresh
                            create on next launch, picking up any config
                            edits in this script)
  --rebuild-base            force rebuild of the base image from scratch
                            (passes --no-cache so every layer re-runs;
                            use this when a step's inputs changed
                            semantically without the RUN line changing)
  --verify                  after launch, run a short egress check and exit
  --disable-network-block   run the container without egress restrictions.
                            skips nft/iptables setup and the WHITELIST_HOSTS
                            allowlist; all outbound traffic is permitted.
                            mutually exclusive with --verify.
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
if ! $DISABLE_NETWORK_BLOCK; then
    : "${WHITELIST_HOSTS:?WHITELIST_HOSTS must be set}"
fi

# Canary IP the container tries to reach at startup to prove the egress
# filter is enforcing. Must be reachable on the open internet (so its
# unreachability is attributable to OUR filter, not a routing dead-end) and
# must NOT appear in the resolved allowlist. example.com is the default.
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
[[ -f "$SETUP_SCRIPT" ]] || { echo "error: setup.sh not found at $SETUP_SCRIPT" >&2; exit 1; }
[[ -f "$DOCKERFILE"    ]] || { echo "error: Dockerfile not found at $DOCKERFILE" >&2; exit 1; }

IMAGE_NAME="remote-code-base:latest"

# ---- identifiers derived from project name ---------------------------------

CONTAINER_NAME="remote-code-${PROJECT_NAME}"
VOLUME_NAME="remote-code-vol-${PROJECT_NAME}"

# rootful-only identifiers
NET_NAME="remote-code-net-${PROJECT_NAME}"
SLUG=$(printf '%s' "$PROJECT_NAME" | tr -c 'A-Za-z0-9' _ | cut -c1-14)
CHAIN_NAME="REMOTE-CODE-${SLUG}"
SUBNET_HEX=$(printf '%s' "$PROJECT_NAME" | md5sum | cut -c1-2)
SUBNET_OCTET=$(( 16#${SUBNET_HEX} % 200 + 40 ))
SUBNET="10.89.${SUBNET_OCTET}.0/24"
GATEWAY="10.89.${SUBNET_OCTET}.1"

# rootless-only identifiers. systemd treats '-' in slice names as a path
# separator ('a-b.slice' -> 'a.slice/a-b.slice'), so normalize to '_'.
SAFE_PROJECT=$(echo "$PROJECT_NAME" | tr '-' '_')
SLICE_NAME="rcode_${SAFE_PROJECT}.slice"
WARMUP_UNIT="rcode_warmup_${SAFE_PROJECT}.service"
NFT_TABLE="rcode_${SAFE_PROJECT}"

GIT_HOST="$(echo "$REPO_URL" | sed -E 's#^(git@|ssh://git@|https://)##; s#[:/].*$##')"
ALL_HOSTS="$GIT_HOST $WHITELIST_HOSTS"

# ---- podman wrapper (sudo only in rootful mode) ----------------------------

if [[ $MODE == rootful ]]; then
    PODMAN=(sudo podman)
else
    PODMAN=(podman)
fi

# ---- pre-flight ------------------------------------------------------------

echo "==> pre-flight (mode=$MODE)"

if [[ $MODE == rootless ]]; then
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
    # rootful: sudo for both podman and iptables
    if ! sudo -n true 2>/dev/null; then
        echo "    this script needs sudo to run rootful podman + install iptables rules"
        sudo -v || { echo "error: sudo required" >&2; exit 1; }
    fi
fi

# When the egress filter is active, both modes need sudo (nft in rootless;
# podman+iptables in rootful). With --disable-network-block, rootless needs
# no sudo at all, and rootful only needs what was primed above for podman.
if ! $DISABLE_NETWORK_BLOCK && ! sudo -n true 2>/dev/null; then
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

# ---- base image ------------------------------------------------------------

# --verify uses an ephemeral alpine container, not the base image; skip the
# build to keep the smoke test fast on first run.
if $VERIFY; then
    echo "==> --verify: skipping base image build"
elif $REBUILD_BASE; then
    echo "==> rebuilding base image $IMAGE_NAME from scratch (mode=$MODE, --no-cache)"
    "${PODMAN[@]}" build --no-cache -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
    if "${PODMAN[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        echo "    note: container $CONTAINER_NAME still references the old image layers."
        echo "    run --reset (or 'podman rm -f $CONTAINER_NAME') to create a fresh one from the rebuilt image."
    fi
elif ! "${PODMAN[@]}" image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "==> building base image $IMAGE_NAME (mode=$MODE)"
    "${PODMAN[@]}" build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$SCRIPT_DIR"
else
    echo "==> using cached base image $IMAGE_NAME"
fi

# ---- resolve allowlist -----------------------------------------------------

declare -a ALLOWED_IPS=()
declare -a ADD_HOST_ARGS=()
declare -A SEEN_IPS=()

if $DISABLE_NETWORK_BLOCK; then
    echo "==> --disable-network-block: skipping allowlist resolution"
else
    echo "==> resolving allowlist"
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

    # Guard against the canary being accidentally on the allowlist — that would
    # make the container's self-check pass even when the filter is broken.
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
    echo "==> tearing down ($MODE)"
    # Stop the container but leave it (and its writable overlay) in place
    # so runtime-installed packages, state under /var, /etc edits, etc.
    # survive across launches. Use --reset to actually remove it.
    "${PODMAN[@]}" stop -t 10 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if $DISABLE_NETWORK_BLOCK; then
        return
    fi
    if [[ $MODE == rootless ]]; then
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
elif [[ $MODE == rootless ]]; then
    # Pre-create the slice via a warmup service so the cgroup exists before
    # we install the nft rule (nft resolves cgroupv2 paths to inodes at
    # rule-load time; the path must exist then). The warmup holds the slice
    # open so the cgroup survives for the container's lifetime.
    echo "==> starting slice warmup: $SLICE_NAME"
    systemctl --user stop "$WARMUP_UNIT" 2>/dev/null || true
    systemd-run --user --quiet \
        --slice="$SLICE_NAME" \
        --unit="$WARMUP_UNIT" \
        sleep infinity

    # Wait briefly for the slice cgroup to appear.
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
    # nft resolves the cgroupv2 string via a literal stat("/sys/fs/cgroup/" +
    # string) — no tree walking, not a basename match. So we feed the full
    # cgroup path stripped of its leading slash. `level N` is independent
    # metadata telling the kernel how many ancestors up from the socket's
    # cgroup to compare against; it must equal the depth of the path below.
    SLICE_CGROUP_REL="${SLICE_CGROUP#/}"
    SLICE_LEVEL=$(echo "$SLICE_CGROUP_REL" | tr / '\n' | grep -c .)
    echo "    slice cgroup: $SLICE_CGROUP"
    echo "    slice level:  $SLICE_LEVEL"

    # Install nft table. Loopback is accept-first so the container can reach
    # its own DNS stub (pasta terminates DNS in userspace and reopens a host
    # socket, typically to 127.0.0.53 on systemd-resolved hosts).
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
    # Rootful: dedicated bridge + FORWARD-chain filter on the subnet.
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

# ---- persistent volume -----------------------------------------------------

if ! $VERIFY; then
    if $RESET; then
        # Before destroying the volume, scan /root/work for any uncommitted
        # changes, unpushed commits, or stashes and prompt if found. Uses a
        # throwaway container against the volume so it works identically in
        # rootless and rootful modes — no host-side userns-path fiddling.
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
        echo "==> --reset: removing container $CONTAINER_NAME and wiping volume $VOLUME_NAME (mode=$MODE)"
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

# Containers persist across launches (no --rm): the writable overlay
# keeps runtime-installed apt packages, service state, and /etc edits.
# podman run flags (caps, volumes, env, publish ports, memory, cpus) are
# frozen at create time, so to pick up config changes you need to remove
# the container (`podman rm -f $CONTAINER_NAME`, or use --reset which
# also wipes the volume).
CONTAINER_EXISTS=false
if ! $VERIFY && "${PODMAN[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    CONTAINER_EXISTS=true
fi

# ---- launch ----------------------------------------------------------------

echo
echo "==> launching container $CONTAINER_NAME (mode=$MODE)"
echo "    repo:    $REPO_URL"
echo "    webapp:  $WEBAPP_CMD (port $WEBAPP_PORT)"
echo "    rc:      port $RC_PORT"
echo

# Shared podman args. No --rm: the container persists across launches
# (see container-existence check above). First launch uses `podman run`
# with this full arg list; subsequent launches use `podman start -ai` on
# the existing container.
PODMAN_ARGS=(
    run -it
    --name "$CONTAINER_NAME"
    --hostname remote-code
    "${ADD_HOST_ARGS[@]}"
    --memory="$MEM_LIMIT"
    --cpus="$CPU_LIMIT"
    --pids-limit=256
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
    "${SHARED_DATA_VOLUME_ARGS[@]}"
    --env "PROJECT_NAME=$PROJECT_NAME"
    --env "REPO_URL=$REPO_URL"
    --env "WEBAPP_CMD=$WEBAPP_CMD"
    --env "WEBAPP_PORT=$WEBAPP_PORT"
    --env "RC_PORT=$RC_PORT"
    --env "CANARY_BLOCKED_IP=$CANARY_BLOCKED_IP"
    --publish "127.0.0.1:${WEBAPP_PORT}:${WEBAPP_PORT}"
    --publish "127.0.0.1:${RC_PORT}:${RC_PORT}"
)

if [[ $MODE == rootless ]]; then
    # --verify runs a smoke test instead of the normal setup.sh.
    if $VERIFY; then
        echo "==> --verify: running egress smoke test in ephemeral container"
        ALLOWED_HOST="github.com"
        systemd-run --user --scope --quiet --slice="$SLICE_NAME" -- \
            podman run --rm --network=pasta "${ADD_HOST_ARGS[@]}" \
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

    # Build the podman invocation: `start -ai` for an existing container,
    # full `run ...` args for a fresh create. podman run flags are frozen
    # at create time, so `start` doesn't re-apply them.
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
    if $VERIFY; then
        echo "error: --verify is only implemented for rootless mode" >&2
        exit 1
    fi

    if $CONTAINER_EXISTS; then
        echo "==> reusing existing container $CONTAINER_NAME (use --reset to recreate)"
        sudo podman start -ai "$CONTAINER_NAME"
    elif $DISABLE_NETWORK_BLOCK; then
        # No custom bridge / iptables filter: fall back to podman's default
        # network. All outbound traffic is permitted.
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
