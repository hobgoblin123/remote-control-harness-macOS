#!/usr/bin/env python3
"""Host-side UDS listener for rc-notify events.

Binds a Unix-domain socket at $XDG_RUNTIME_DIR/rc-notify.sock (or
/run/user/$UID/rc-notify.sock if unset). For each connection it reads a
single short line, validates it against a fixed whitelist, and spawns
host_notify.sh to render the desktop notification + play the sound.

The socket file is the only thing launch.sh mounts into the container,
so a process in the container can talk to exactly this listener and
nothing else on the host. The listener is the trust boundary — it
rejects anything outside the whitelist, so a compromised container
can't spoof arbitrary notification bodies under the "Claude Code"
brand.
"""

import os
import pathlib
import signal
import socket
import subprocess
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
NOTIFY_SCRIPT = SCRIPT_DIR / "host_notify.sh"

# Must stay in sync with the case branches in host_notify.sh. Adding a
# new event needs changes in both places; the asymmetry is intentional
# — this listener is the first gate, the notify script is a cheap
# defence-in-depth backstop.
ALLOWED_EVENTS = {"done", "waiting"}

# Upper bound on bytes read per connection. Events are single words, so
# this is huge overhead already — but caps the resource a misbehaving
# peer can burn.
READ_LIMIT = 128


def socket_path() -> pathlib.Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return pathlib.Path(runtime) / "rc-notify.sock"


def main() -> None:
    path = socket_path()
    if path.exists():
        path.unlink()

    # Create the socket with 0600 via umask: the socket file inherits
    # mode (0666 & ~umask). $XDG_RUNTIME_DIR is already 0700/user-only,
    # this is extra defence in depth.
    old_umask = os.umask(0o077)
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(path))
    finally:
        os.umask(old_umask)
    sock.listen(8)

    print(f"rc-notify: listening on {path}", flush=True)

    def cleanup(*_args):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while True:
        conn, _ = sock.accept()
        try:
            data = conn.recv(READ_LIMIT)
        finally:
            conn.close()

        event = data.decode("utf-8", errors="replace").strip()

        if event not in ALLOWED_EVENTS:
            # Truncate for the log so someone can't fill the journal
            # with huge junk; repr so binary noise is visible.
            print(f"rc-notify: rejecting unknown event {event[:32]!r}", file=sys.stderr, flush=True)
            continue

        # Fire-and-forget. Stdout/stderr go to the journal; we don't
        # wait for completion so a slow notification daemon can't block
        # the listener.
        subprocess.Popen(
            [str(NOTIFY_SCRIPT), event],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


if __name__ == "__main__":
    main()
