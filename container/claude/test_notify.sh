#!/usr/bin/env bash
# Manually send an rc-notify event over the UDS mounted in from the
# host. Use this to verify the host-side listener + notifier pipeline
# without waiting for claude to fire a Stop/Notification hook.
#
#   ./test_notify.sh           # defaults to 'done'
#   ./test_notify.sh done
#   ./test_notify.sh waiting

set -euo pipefail

SOCKET="/run/notify.sock"
EVENT="${1:-done}"

if [[ ! -S "$SOCKET" ]]; then
    echo "error: UDS not present at $SOCKET" >&2
    echo "       ensure ./launch.sh on the host started rc-notify.service and mounted the socket" >&2
    exit 1
fi

printf '%s\n' "$EVENT" | nc -U "$SOCKET"
echo "sent '$EVENT' to host"
