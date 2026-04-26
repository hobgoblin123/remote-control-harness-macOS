#!/usr/bin/env bash
# Host-side notifier: plays notification_sound.wav and shows a desktop
# notification. Invoked by the host-side listener when the container signals
# a notification event via the UDS.
#
# Supports Linux (libnotify + PulseAudio/PipeWire/ALSA) and macOS
# (osascript + afplay). On macOS, osascript's display notification does not
# require any extra packages and respects Do Not Disturb settings.
#
# Arg 1 is an event-type keyword that maps to a preset body; anything
# else is rejected. Arg 2 optionally overrides the title.
#
# Standalone test:
#   ./host_notify.sh                         # "Task complete"
#   ./host_notify.sh done                    # "Task complete"
#   ./host_notify.sh waiting                 # "Awaiting your input"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOUND_FILE="${SOUND_FILE:-$SCRIPT_DIR/notification_sound.wav}"

EVENT="${1:-done}"
TITLE="Claude Code"

# Whitelist of valid events. Refuse to display arbitrary body text because
# the notification appears under the trusted "Claude Code" brand —
# a compromised process in the container could otherwise spoof prompts.
# The upstream listener daemon also rejects unknown events; this is
# cheap defence-in-depth.
case "$EVENT" in
    done)       BODY="Task complete" ;;
    waiting)    BODY="Awaiting your input" ;;
    *)          echo "host_notify: unknown event '$EVENT'" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
    # Audio: afplay is built into macOS (no install required).
    if [[ -r "$SOUND_FILE" ]]; then
        afplay "$SOUND_FILE" &
        disown 2>/dev/null || true
    fi

    # Notification: osascript is always available on macOS. The 'display
    # notification' command routes through Notification Centre and respects
    # per-app and focus/DND settings. We do not force critical urgency here
    # because macOS manages that at the system level.
    osascript -e "display notification \"$BODY\" with title \"$TITLE\"" 2>/dev/null || {
        # Fallback if osascript is somehow unavailable.
        echo "$TITLE: $BODY" >&2
    }
    exit 0
fi

# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------

# Play the sound in the background so the notification pops immediately.
# Try common players in order: paplay (PulseAudio/PipeWire), pw-play
# (native PipeWire), aplay (bare ALSA), ffplay (last-ditch fallback).
play_sound() {
    if [[ ! -r "$SOUND_FILE" ]]; then
        echo "notify: sound file not readable at $SOUND_FILE" >&2
        return 0
    fi
    if command -v paplay >/dev/null 2>&1; then
        paplay "$SOUND_FILE" &
    elif command -v pw-play >/dev/null 2>&1; then
        pw-play "$SOUND_FILE" &
    elif command -v aplay >/dev/null 2>&1; then
        aplay -q "$SOUND_FILE" &
    elif command -v ffplay >/dev/null 2>&1; then
        ffplay -nodisp -autoexit -loglevel quiet "$SOUND_FILE" &
    else
        echo "notify: no audio player found (install one of: paplay, pw-play, aplay, ffplay)" >&2
        return 0
    fi
    disown 2>/dev/null || true
}

# --urgency=critical + --expire-time=0 = persistent until dismissed on every
# freedesktop-compliant notification daemon (GNOME Shell, KDE Plasma, dunst,
# mako, xfce4-notifyd, ...). Critical notifications typically bypass DND.
show_notification() {
    if ! command -v notify-send >/dev/null 2>&1; then
        echo "notify: notify-send not installed (try 'apt install libnotify-bin')" >&2
        echo "$TITLE: $BODY" >&2
        return 1
    fi
    notify-send \
        --urgency=critical \
        --expire-time=0 \
        --app-name="claude-code" \
        --icon=dialog-information \
        "$TITLE" \
        "$BODY"
}

play_sound
show_notification
