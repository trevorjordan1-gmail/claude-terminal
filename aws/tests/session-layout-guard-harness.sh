#!/bin/bash
# session-layout-guard-harness.sh — exercise aws/scripts/session-layout-guard.sh
# with a stubbed xrandr, a fake pgrep and a captured logger. No X, no DCV, no
# box: the stubs replay the layouts that matter (#42) and a gnome-shell "restart"
# (#47) by changing what pgrep answers.
#
#   bash aws/tests/session-layout-guard-harness.sh        # ~25 s, exit 0 = all pass
#
# Not shipped to boxes: rollout.sh syncs aws/scripts/ only.
# shellcheck disable=SC2015 # pass/fail always return 0, so `A && pass || fail` is an if/else here
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="$HERE/../scripts/session-layout-guard.sh"
T=$(mktemp -d); trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
STUB="$T/bin"; mkdir -p "$STUB"
export STATE="$T/state" PIDFILE="$T/shell.pid" LOG="$T/log"; : >"$LOG"
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
assert_log()   { grep -qF -- "$1" "$LOG" && pass "log has: $1" || fail "log lacks: $1  (log: $(tr '\n' '|' <"$LOG"))"; }
assert_nolog() { grep -qF -- "$1" "$LOG" && fail "log unexpectedly has: $1" || pass "log has no: $1"; }
count_log()    { grep -cF -- "$1" "$LOG"; }
wait_log() { # $1 text, $2 min count, $3 timeout s
  local i; for ((i=0; i<$3*4; i++)); do [ "$(count_log "$1")" -ge "$2" ] && return 0; sleep 0.25; done; return 1
}

# ── stubs ────────────────────────────────────────────────────────────────────
# xrandr: renders/mutates $STATE. Lines: "screen W H" | "<output> WxH+X+Y" | "<output> off".
# A state of exactly "gone" = the X server is dead (every call fails).
cat >"$STUB/xrandr" <<'XR'
#!/bin/bash
[ "$(cat "$STATE")" = gone ] && exit 1
if [ "${1:-}" = --query ] || [ $# -eq 0 ]; then
  awk '$1=="screen"{printf "Screen 0: minimum 8 x 8, current %s x %s, maximum 32767 x 32767\n",$2,$3; next}
       $2=="off"{printf "%s connected (normal left inverted right x axis y axis)\n",$1; next}
       {printf "%s connected%s %s (normal left inverted right x axis y axis) 0mm x 0mm\n   800x600  60.00\n",$1,(p++?"":" primary"),$2}' "$STATE"
  exit 0
fi
case "${1:-}" in --newmode|--addmode) exit 0;; esac
out=""; mode=""; off=0
while [ $# -gt 0 ]; do case "$1" in --output) out=$2; shift;; --mode) mode=$2; shift;; --off) off=1;; esac; shift; done
[ -n "$out" ] || exit 1
if [ "$off" = 1 ]; then
  sed -i "s/^$out .*/$out off/" "$STATE"
elif [ -n "$mode" ]; then
  g=${mode%%_*}; w=${g%x*}; h=${g#*x}
  sed -i -e "s/^$out .*/$out $g+0+0/" -e "s/^screen .*/screen $w $h/" "$STATE"
fi
XR
cat >"$STUB/pgrep" <<'PG'
#!/bin/bash
p=$(cat "$PIDFILE" 2>/dev/null); [ -n "$p" ] || exit 1; echo "$p"
PG
cat >"$STUB/logger" <<'LG'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; *) break;; esac; done
echo "$*" >>"$LOG"
LG
chmod +x "$STUB"/*
four_wide() { printf 'screen 3200 600\nVNC-output-0 800x600+0+0\nVNC-output-1 800x600+800+0\nVNC-output-2 800x600+1600+0\nVNC-output-3 800x600+2400+0\n' >"$STATE"; }
is_single() { [ "$(grep -c ' off$' "$STATE")" = 3 ] && grep -q '^VNC-output-0 1920x1080+0+0' "$STATE"; }

run_guard() { env PATH="$STUB:$PATH" DISPLAY=:9 XDG_RUNTIME_DIR="$T" GUARD_SECONDS=3 GUARD_POLL_SECONDS=1 bash "$GUARD" & }

echo "1. first window corrects the 4-wide default once"
four_wide; echo 100 >"$PIDFILE"
run_guard; G1=$!
wait_log "done:" 1 15 || fail "first window never finished"
[ "$(count_log corrected)" = 1 ] && pass "exactly one correction" || fail "corrections=$(count_log corrected)"
is_single && pass "layout is the single 1920x1080 head" || fail "layout not fixed: $(tr '\n' '|' <"$STATE")"

echo "2. no re-arm while the gnome-shell PID is stable"
sleep 4
assert_nolog "re-arming"
kill -0 "$G1" 2>/dev/null && pass "guard still resident after its window" || fail "guard exited after the first window"

echo "3. gnome-shell restart (PID change) re-arms the window and corrects again"
four_wide; echo 200 >"$PIDFILE"
wait_log "done:" 2 15 || fail "second window never finished"
assert_log "shell restarted (pid 100 → 200), re-arming"
[ "$(count_log corrected)" = 2 ] && pass "second correction logged" || fail "corrections=$(count_log corrected)"
is_single && pass "layout fixed again" || fail "layout not fixed after restart: $(tr '\n' '|' <"$STATE")"

echo "4. one guard per session: a second instance exits at once"
run_guard; G2=$!
sleep 2
kill -0 "$G2" 2>/dev/null && fail "second guard still running" || pass "second guard exited"
assert_log "already guarding"
kill -0 "$G1" 2>/dev/null && pass "first guard unaffected" || fail "first guard died"

echo "5. X server gone → the resident guard exits"
echo gone >"$STATE"
for _ in $(seq 1 60); do kill -0 "$G1" 2>/dev/null || break; sleep 0.25; done
kill -0 "$G1" 2>/dev/null && fail "guard still alive 15 s after X went away" || pass "guard exited"
assert_log "display gone"

echo; [ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
