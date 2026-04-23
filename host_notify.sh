#!/usr/bin/env bash
# Host-side notifier: plays notification_sound.wav and shows a persistent
# libnotify notification. Meant to be invoked by the host-side listener
# when the container signals a notification event (see the UDS plumbing
# added separately).
#
# Arg 1 is an event-type keyword that maps to a preset body; anything
# else is treated as a literal body. Arg 2 optionally overrides the
# title (defaults to "Claude Code", which groups well in notification
# centers).
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

# Whitelist of valid events. Refuse to display arbitrary body text
# because the notification appears under the trusted "Claude Code"
# brand with critical urgency — an attacker-controlled process in the
# container (compromised dep, rogue agent) could otherwise spoof
# convincing prompts like "Task complete — paste the command I sent" or
# inject pango markup on daemons that render it. Add new events here
# explicitly as the need arises; the upstream listener daemon should
# reject unknown events too, but this is cheap defence-in-depth.
case "$EVENT" in
    done)       BODY="Task complete" ;;
    waiting)    BODY="Awaiting your input" ;;
    *)          echo "host_notify: unknown event '$EVENT'" >&2; exit 2 ;;
esac

# Play the sound in the background so the notification pops immediately
# and the script doesn't block on audio playback. Try the common players
# in order: paplay handles PulseAudio and PipeWire (via pipewire-pulse)
# on modern desktops; pw-play is native PipeWire; aplay is bare ALSA;
# ffplay is a last-ditch fallback.
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

# --urgency=critical + --expire-time=0 = "persistent until dismissed" on
# every freedesktop-compliant notification daemon (GNOME Shell, KDE
# Plasma, dunst, mako, xfce4-notifyd, ...). Note: critical notifications
# typically bypass Do Not Disturb, which is usually what you want for
# "Claude is awaiting input" but worth knowing.
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
