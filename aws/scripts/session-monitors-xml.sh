#!/bin/bash
# session-monitors-xml.sh — write the session user's stored monitor layout from the live
# RandR state, before gnome-session starts (#43; run synchronously by dcvsessioninit).
#
# Why: mutter's startup (meta_monitor_manager_ensure_configured, gnome-46) picks a stored
# monitors.xml, else "suggested", else "linear" — it NEVER looks at what the X server already
# has. Linear enables every output whose RandR state is not Disconnected at its FIRST listed
# mode; Xdcv reports all four VNC-output-N as connected with 800x600 first, so every
# gnome-shell start — first session, paint-probe TERM, crash — replays 4x800x600 and undoes
# the #20 pre-mode, the --off collapse and the portal's Connect-time layout. A stored config
# with the extras in <disabled> is mutter's own "never enable these" mechanism. Proven on a
# real Xdcv box 2026-09-15 (issue #43): guard-off A/B reproduces the four heads with the file
# moved aside and one head with it present; a fresh session logs corrections=0; a client
# resize still moves the head (mutter does not re-apply the stored config over it).
#
# Generated from `xrandr --query` here rather than shipped as a fixed file because the lookup
# key is the FULL output set: a box with a different head count would silently fall through
# to linear. The session-layout-guard stays as the backstop for exactly that case.
#
# Rules mutter applies to the file (meta-monitor-config-store.c): no-EDID outputs match on
# connector + vendor/product/serial all literally "unknown"; <rate> is mandatory and must be
# within 0.001 of dotclock/(htotal*vtotal); the mode must exist on the output; a malformed
# file drops EVERY stored config. Never blocks session start: exit 0 on every path.
set -u
TAG="asp-monitors-xml"
# The #20 modeline dcvsessioninit adds just before this runs — same numbers, so the rate
# below is derived, not transcribed: 173.00 MHz / (2576 x 1120) = 59.963.
MODE_NAME="1920x1080_60"; MODE_W=1920; MODE_H=1080
RATE=$(awk 'BEGIN{printf "%.3f", 173.00*1000000/(2576*1120)}')

Q=$(xrandr --query 2>/dev/null) || Q=""
mapfile -t OUTS < <(printf '%s\n' "$Q" | awk '/ connected/{print $1}')
if [ "${#OUTS[@]}" -eq 0 ]; then
  logger -t "$TAG" "no RandR output visible on ${DISPLAY:-?} — nothing to store"; exit 0
fi
PRIMARY=${OUTS[0]}
# A config naming a mode the output does not have is rejected whole ("Failed to use stored
# monitor configuration") and mutter falls to linear anyway — so do not write one.
if ! printf '%s\n' "$Q" | awk -v p="$PRIMARY" -v m="$MODE_NAME" \
      '$1==p{f=1; next} / connected/{f=0} f && $1==m{found=1} END{exit !found}'; then
  logger -t "$TAG" "$PRIMARY has no $MODE_NAME mode (the #20 pre-mode did not land) — not storing a layout mutter would reject"; exit 0
fi

spec() { printf '<monitorspec><connector>%s</connector><vendor>unknown</vendor><product>unknown</product><serial>unknown</serial></monitorspec>' "$1"; }
XML="<monitors version=\"2\">
  <configuration>
    <logicalmonitor>
      <x>0</x><y>0</y><scale>1</scale><primary>yes</primary>
      <monitor>
        $(spec "$PRIMARY")
        <mode><width>$MODE_W</width><height>$MODE_H</height><rate>$RATE</rate></mode>
      </monitor>
    </logicalmonitor>"
if [ "${#OUTS[@]}" -gt 1 ]; then
  XML="$XML
    <disabled>"
  for o in "${OUTS[@]:1}"; do XML="$XML
      $(spec "$o")"; done
  XML="$XML
    </disabled>"
fi
XML="$XML
  </configuration>
</monitors>"

DIR="${XDG_CONFIG_HOME:-$HOME/.config}"; FILE="$DIR/monitors.xml"
if [ -f "$FILE" ] && [ "$(cat "$FILE" 2>/dev/null)" = "$XML" ]; then
  logger -t "$TAG" "unchanged: $FILE already stores $PRIMARY ${MODE_W}x${MODE_H}@$RATE with ${#OUTS[@]} outputs"; exit 0
fi
# World-readable like every other session file; atomic so a half-written file can never be
# the one mutter reads (that would drop every stored config).
if mkdir -p "$DIR" && TMP=$(mktemp "$DIR/.monitors.xml.XXXXXX") \
   && printf '%s\n' "$XML" >"$TMP" && chmod 644 "$TMP" && mv -f "$TMP" "$FILE"; then
  logger -t "$TAG" "wrote $FILE: $PRIMARY ${MODE_W}x${MODE_H}@$RATE primary, ${#OUTS[@]} outputs (disabled: ${OUTS[*]:1})"
else
  logger -t "$TAG" "could not write $FILE — the layout guard is the only protection this session"
fi
exit 0
