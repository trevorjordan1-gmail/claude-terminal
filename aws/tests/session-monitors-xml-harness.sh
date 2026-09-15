#!/bin/bash
# session-monitors-xml-harness.sh — exercise aws/scripts/session-monitors-xml.sh with a
# stubbed xrandr and a captured logger. No X, no DCV, no box. The fixture is the real
# `xrandr --query` from an Xdcv session (#43, 2026-09-15): four VNC-output-N outputs all
# "connected", 800x600 first on every one, the #20-added 1920x1080_60 on output-0 only.
#
#   bash aws/tests/session-monitors-xml-harness.sh        # ~2 s, exit 0 = all pass
# shellcheck disable=SC2015 # pass/fail always return 0, so `A && pass || fail` is an if/else here
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GEN="$HERE/../scripts/session-monitors-xml.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STUB="$T/bin"; mkdir -p "$STUB"
export XR_OUT="$T/xrandr.txt" LOG="$T/log"; : >"$LOG"
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
assert_log()   { grep -qF -- "$1" "$LOG" && pass "log has: $1" || fail "log lacks: $1  (log: $(tr '\n' '|' <"$LOG"))"; }
assert_nolog() { grep -qF -- "$1" "$LOG" && fail "log unexpectedly has: $1" || pass "log has no: $1"; }

cat >"$STUB/xrandr" <<'XR'
#!/bin/bash
[ -s "$XR_OUT" ] || exit 1
cat "$XR_OUT"
XR
cat >"$STUB/logger" <<'LG'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; *) break;; esac; done
echo "$*" >>"$LOG"
LG
chmod +x "$STUB"/*

four_outputs() { cat >"$XR_OUT" <<'X'
Screen 0: minimum 1 x 1, current 1920 x 1080, maximum 32767 x 32767
VNC-output-0 connected primary 1920x1080+0+0 0mm x 0mm
   800x600        0.00
   1920x1080_60  59.96*
VNC-output-1 connected
   800x600        0.00
VNC-output-2 connected
   800x600        0.00
VNC-output-3 connected
   800x600        0.00
X
}
run_gen() { HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" env PATH="$STUB:$PATH" DISPLAY=:9 bash "$GEN"; }
XML="$T/home/.config/monitors.xml"
mkdir -p "$T/home"

echo "1. four Xdcv outputs → one 1920x1080 primary on the REAL connector name, the other three disabled, rate 59.963"
four_outputs; run_gen; rc=$?
[ "$rc" = 0 ] && pass "exit 0" || fail "exit $rc"
[ -s "$XML" ] && pass "wrote $XML" || fail "no monitors.xml written"
python3 - "$XML" <<'PY' && pass "XML shape matches mutter's store" || fail "XML shape wrong"
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert r.tag == "monitors" and r.get("version") == "2"
c = r.find("configuration")
lm = c.findall("logicalmonitor"); assert len(lm) == 1
m = lm[0]
assert m.findtext("primary") == "yes" and m.findtext("x") == "0" and m.findtext("y") == "0" and m.findtext("scale") == "1"
spec = m.find("monitor/monitorspec")
assert spec.findtext("connector") == "VNC-output-0"
assert [spec.findtext(k) for k in ("vendor", "product", "serial")] == ["unknown"] * 3
mode = m.find("monitor/mode")
assert (mode.findtext("width"), mode.findtext("height"), mode.findtext("rate")) == ("1920", "1080", "59.963")
dis = [s.findtext("connector") for s in c.findall("disabled/monitorspec")]
assert dis == ["VNC-output-1", "VNC-output-2", "VNC-output-3"], dis
for s in c.findall("disabled/monitorspec"):
    assert [s.findtext(k) for k in ("vendor", "product", "serial")] == ["unknown"] * 3
PY
grep -q 'VNC-0<' "$XML" && fail "guessed connector name VNC-0 present" || pass "no guessed VNC-0 names"
assert_log "wrote"
[ "$(stat -c %a "$XML")" = 644 ] && pass "mode 0644" || fail "mode $(stat -c %a "$XML")"

echo "2. second run with the same layout → unchanged, file not rewritten"
m1=$(stat -c %Y "$XML"); sleep 1.1; : >"$LOG"
run_gen
assert_log "unchanged"
assert_nolog "wrote"
[ "$(stat -c %Y "$XML")" = "$m1" ] && pass "mtime untouched" || fail "file rewritten"

echo "3. a single output → no <disabled> block, still the primary at 1920x1080"
cat >"$XR_OUT" <<'X'
Screen 0: minimum 1 x 1, current 1920 x 1080, maximum 32767 x 32767
VNC-output-0 connected primary 1920x1080+0+0 0mm x 0mm
   800x600        0.00
   1920x1080_60  59.96*
X
: >"$LOG"; run_gen
python3 - "$XML" <<'PY' && pass "single output: primary only, no disabled" || fail "single-output XML wrong"
import sys, xml.etree.ElementTree as ET
c = ET.parse(sys.argv[1]).getroot().find("configuration")
assert c.find("disabled") is None
assert c.find("logicalmonitor/monitor/monitorspec").findtext("connector") == "VNC-output-0"
PY
assert_log "wrote"

echo "4. the primary has no 1920x1080_60 mode (the #20 pre-mode did not land) → nothing written, said in the log"
cat >"$XR_OUT" <<'X'
Screen 0: minimum 1 x 1, current 800 x 600, maximum 32767 x 32767
VNC-output-0 connected primary 800x600+0+0 0mm x 0mm
   800x600        0.00
VNC-output-1 connected
   800x600        0.00
X
rm -f "$XML"; : >"$LOG"; run_gen; rc=$?
[ "$rc" = 0 ] && pass "exit 0 (never blocks session start)" || fail "exit $rc"
[ -e "$XML" ] && fail "wrote a config naming a mode the output does not have" || pass "no file written"
assert_log "1920x1080_60"

echo "5. xrandr fails (no X) → exit 0, nothing written, one log line"
: >"$XR_OUT"; : >"$LOG"; run_gen; rc=$?
[ "$rc" = 0 ] && pass "exit 0" || fail "exit $rc"
[ -e "$XML" ] && fail "wrote without an X server" || pass "no file written"
assert_log "no RandR output"

echo "6. a stale user file for a DIFFERENT output set is replaced (the lookup key is the full set)"
four_outputs
printf '<monitors version="2"><configuration><logicalmonitor><x>0</x><y>0</y><scale>1</scale><primary>yes</primary><monitor><monitorspec><connector>VNC-0</connector><vendor>unknown</vendor><product>unknown</product><serial>unknown</serial></monitorspec><mode><width>1920</width><height>1080</height><rate>59.963</rate></mode></monitor></logicalmonitor></configuration></monitors>\n' >"$XML"
: >"$LOG"; run_gen
grep -q 'VNC-output-3' "$XML" && pass "replaced with the live set" || fail "stale file kept"
assert_log "wrote"

echo
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
