#!/bin/bash
# session-layout-guard.sh — hold the single 1920x1080 head through a session's
# first minute (field report 2026-09-11, the "4 screens then black" pair).
#
# What actually happens at session start, from the DCV server + agent logs:
#   t+0.6s  dcvsessioninit's xrandr pre-mode lands: one 1920x1080 head (#20 fix OK)
#   t+2.0s  gnome-shell/mutter starts, sees FOUR "connected" Xdcv outputs (Xdcv
#           reports every VNC-output-N as connected; max-num-heads=1 does not
#           change that) and enables them all at their only mode → 4×800x600 in
#           a row = the "4 screens" the user sees
#   t+2.3s  the portal's Connect-time set-display-layout wins for 100 ms, then the
#           layout flips once more to a single 3200x600 head at 0.00 Hz — the #20
#           dead frame clock: one flat frame, "black screen", forever
#   t+10s   the paint probe samples, sees colours (the one frame), says ok
# Every existing guard fires ONCE and too early; mutter's own startup is what
# clobbers them. This one runs as the session user (backgrounded from
# dcvsessioninit, inherits DISPLAY/XAUTHORITY), waits for gnome-shell, then for
# GUARD_SECONDS keeps checking for the Xdcv default signature and re-asserts the
# single head. It never fights a real client resize: a client can only produce a
# single primary head at some size that is not 800x600 / 3200x600.
#
# It then stays resident (#47): mutter replays the same default on EVERY
# gnome-shell start (#43 — ensure_configured never looks at the current X
# state), so a later restart — the paint probe's TERM (#21), a crash under
# Restart=always — would put the four heads back hours into a good session with
# nothing left to correct them. A cheap loop watches gnome-shell's PID and re-runs
# the correction window whenever it changes; the guard exits when the X server
# does. One instance per session (flock under XDG_RUNTIME_DIR): a re-run of
# dcvsessioninit must not stack guards.
#
# Signature of "wrong" (any one is enough):
#   - any non-primary output is active (has +x+y geometry)
#   - the X screen is 3200x600
#   - the primary output is at 800x600
set -u
TAG="asp-layout-guard"
GUARD_SECONDS="${GUARD_SECONDS:-60}"
GUARD_POLL_SECONDS="${GUARD_POLL_SECONDS:-2}"

LOCK="${XDG_RUNTIME_DIR:-/tmp}/asp-layout-guard.$(id -u).${DISPLAY//[^A-Za-z0-9]/_}.lock"
exec 9>"$LOCK"
flock -n 9 || { logger -t "$TAG" "already guarding ${DISPLAY:-?} — exiting"; exit 0; }

PRIMARY=$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$PRIMARY" ] || { logger -t "$TAG" "no RandR output visible on ${DISPLAY:-?} — not guarding"; exit 0; }

bad() {
  local q; q=$(xrandr --query 2>/dev/null) || return 1
  echo "$q" | awk -v p="$PRIMARY" '/ connected/ && $1!=p && $0 ~ /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/ {f=1} END{exit !f}' && return 0
  echo "$q" | grep -qE '^Screen 0:.*current 3200 x 600' && return 0
  echo "$q" | grep -qE "^$PRIMARY connected( primary)? 800x600\+" && return 0
  return 1
}

fix() {
  local o
  for o in $(xrandr --query 2>/dev/null | awk -v p="$PRIMARY" '/ connected/ && $1!=p {print $1}'); do
    xrandr --output "$o" --off >/dev/null 2>&1
  done
  xrandr --output "$PRIMARY" --mode 1920x1080_60 --primary >/dev/null 2>&1 \
    || xrandr --output "$PRIMARY" --mode 1920x1080 --primary >/dev/null 2>&1 \
    || { xrandr --newmode 1920x1080_60 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync >/dev/null 2>&1
         xrandr --addmode "$PRIMARY" 1920x1080_60 >/dev/null 2>&1
         xrandr --output "$PRIMARY" --mode 1920x1080_60 --primary >/dev/null 2>&1; }
}

shell_pid() { pgrep -u "$(id -u)" -x gnome-shell 2>/dev/null | head -n 1; }
current() { xrandr --query 2>/dev/null | grep -oE 'current [0-9]+ x [0-9]+'; }

# One correction window: GUARD_SECONDS of re-asserting the single head whenever
# the default signature shows up. $1 names the window in the journal.
guard_window() {
  local why=$1 n=0 end=$((SECONDS + GUARD_SECONDS)) before
  while [ "$SECONDS" -lt "$end" ]; do
    if bad; then
      before=$(current)
      fix; n=$((n + 1)); sleep 2
      logger -t "$TAG" "corrected default layout (#$n): was '$before' now '$(current)'"
    fi
    sleep 1
  done
  logger -t "$TAG" "done: window=$why corrections=$n final=$(current) display=${DISPLAY:-?} user=$(id -un)"
  # a shell that ran against 0.00 Hz for a while may have latched anyway — let the
  # paint probe judge the pixels once more after we have corrected anything
  if [ "$n" -gt 0 ] && [ -x /opt/asp/session-paint-probe.sh ]; then
    /opt/asp/session-paint-probe.sh >/dev/null 2>&1 &
  fi
}

# the clobberer is gnome-shell — wait for it (it is what we are guarding against)
for _ in $(seq 1 40); do
  shell_pid >/dev/null && break
  sleep 1
done
pid=$(shell_pid)
guard_window first

# Resident: re-arm on every gnome-shell restart; leave when the X server does.
dead=0
while :; do
  sleep "$GUARD_POLL_SECONDS"
  if xrandr --query >/dev/null 2>&1; then dead=0; else
    dead=$((dead + 1))
    [ "$dead" -lt 3 ] && continue
    logger -t "$TAG" "display gone (${DISPLAY:-?}) — exiting"; exit 0
  fi
  now=$(shell_pid)
  { [ -n "$now" ] && [ "$now" != "$pid" ]; } || continue
  if [ -n "$pid" ]; then
    logger -t "$TAG" "shell restarted (pid $pid → $now), re-arming"
  else
    logger -t "$TAG" "shell appeared late (pid $now), arming"
  fi
  pid=$now
  guard_window re-arm
done
