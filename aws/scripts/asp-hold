#!/bin/bash
# asp-hold — keep this terminal awake for a bounded time (#55).
#
# For work the idle watchdog cannot see as work: a long-running Claude monitor,
# an overnight job, a soak test. The watchdog hibernates a box once no viewer
# has connected for an hour, and hibernation stops the wall clock — so a
# monitor that sleeps between ticks does NOT survive it. This is the explicit,
# visible, EXPIRING way to say "leave this one alone".
#
#   asp-hold 4h "nightly monitor"   arm/renew a lease
#   asp-hold status                       what is held, and for how long
#   asp-release                           drop it now (symlink to this script)
#
# The lease is capped (max_hold_hours in /asp/idle/config, 12h by default), so
# a forgotten hold cannot keep a box running for ever — renew it if the work
# genuinely outlives the cap. The watchdog logs the lease and the admin page
# shows it, so a held box is visible rather than mysterious.
set -uo pipefail
LEASE=/var/lib/asp/keep-awake.json
MAX_H_DEFAULT=12

need_root() {
  [ "$(id -u)" = 0 ] && return 0
  command -v sudo >/dev/null && exec sudo -n "$0" "$@" 2>/dev/null
  echo "asp-hold: need root to write $LEASE (try: sudo $0 $*)" >&2; exit 1
}

show() {
  if [ ! -s "$LEASE" ]; then echo "no hold — this terminal follows the normal idle policy"; return 0; fi
  python3 - "$LEASE" <<'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("no readable hold"); raise SystemExit(0)
left = int(d.get("until", 0)) - time.time()
if left <= 0:
    print(f"hold EXPIRED {-left/3600:.1f}h ago ({d.get('why','')}) — normal idle policy applies")
else:
    print(f"held {left/3600:.1f}h more: {d.get('why','(no reason)')} — set by {d.get('who','?')}")
PY
}

case "${1:-status}" in
  status) show; exit 0 ;;
  release) need_root "$@"; rm -f "$LEASE"; echo "hold released — normal idle policy applies"; exit 0 ;;
esac
case "$(basename "$0")" in
  asp-release) need_root "$@"; rm -f "$LEASE"; echo "hold released — normal idle policy applies"; exit 0 ;;
esac

DUR="$1"; WHY="${2:-}"
[ -n "$WHY" ] || { echo "usage: asp-hold <duration, e.g. 90m or 4h> \"why\"" >&2; exit 2; }
case "$DUR" in
  *h) SECS=$(( ${DUR%h} * 3600 )) ;;
  *m) SECS=$(( ${DUR%m} * 60 )) ;;
  *)  echo "asp-hold: duration must end in h or m (e.g. 4h, 90m)" >&2; exit 2 ;;
esac

MAX_H=$(aws ssm get-parameter --name /asp/idle/config --query Parameter.Value --output text 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("max_hold_hours",""))' 2>/dev/null)
[ -n "$MAX_H" ] || MAX_H=$MAX_H_DEFAULT
if [ "$SECS" -gt $(( MAX_H * 3600 )) ]; then
  echo "asp-hold: capped at ${MAX_H}h (max_hold_hours) — renew if the work outlives it" >&2
  SECS=$(( MAX_H * 3600 ))
fi

need_root "$@"
install -d /var/lib/asp
WHO="${SUDO_USER:-$(id -un)}"
UNTIL=$(( $(date +%s) + SECS ))
UNTIL="$UNTIL" WHY="$WHY" WHO="$WHO" python3 -c '
import json, os
json.dump({"until": int(os.environ["UNTIL"]), "why": os.environ["WHY"], "who": os.environ["WHO"]},
          open("/var/lib/asp/keep-awake.json", "w"))'
show
