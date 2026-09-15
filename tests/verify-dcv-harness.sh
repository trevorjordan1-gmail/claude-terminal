#!/bin/bash
# verify-dcv-harness.sh — run verify.sh's DCV section in a throwaway container (fake
# /etc/asp-terminal.env, stubbed pgrep) and assert only the lines under test. The rest of
# verify.sh is expected to FAIL noisily in a bare container; this ignores it.
#
#   bash tests/verify-dcv-harness.sh        # ~5 s, exit 0 = all pass
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
IMG=claude-terminal-harness:2
docker image inspect "$IMG" >/dev/null 2>&1 || docker build -q -t "$IMG" - <<'DF' >/dev/null
FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends openssl ca-certificates python3 >/dev/null && rm -rf /var/lib/apt/lists/*
DF
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
# shellcheck disable=SC2015 # pass/fail always return 0
has() { grep -qE -- "$2" "$1" && pass "has /$2/" || fail "lacks /$2/  ($(grep -iE 'chrome|xdg-terminals' "$1" | tr '\n' '|'))"; }
# run_case OUT CHROME(0|1) XTL(gnome|none) DISPLAY(:0|"")
run_case() {
  local out=$1
  docker run --rm -v "$REPO:/kit:ro" -e "CHROME=$2" -e "XTL=$3" -e "DISP=$4" "$IMG" bash -c '
mkdir -p /usr/local/bin /root/.config
printf "ASP_PORTAL_HOST=portal.zone.test\n" >/etc/asp-terminal.env
printf "#!/bin/bash\n[ \"$CHROME\" = 1 ] && { echo 3; exit 0; }; echo 0; exit 1\n" >/usr/local/bin/pgrep; chmod +x /usr/local/bin/pgrep
[ "$XTL" = gnome ] && printf "org.gnome.Terminal.desktop\n" >/root/.config/xdg-terminals.list
[ -n "$DISP" ] && export DISPLAY="$DISP"
HOME=/root bash /kit/verify.sh 2>&1 | sed "s/\x1b\[[0-9;]*m//g"' >"$out" 2>&1
}
echo "1. Chrome resident + GNOME Terminal recorded → both PASS"
run_case "$PWD/.v1" 1 gnome :0
has .v1 'PASS.*Chrome warm start resident'
has .v1 'PASS.*xdg-terminals\.list.*org\.gnome\.Terminal\.desktop'
echo "2. Chrome gone + no list → SKIP with the #27 reason, FAIL for the missing list"
run_case "$PWD/.v2" 0 none :0
has .v2 'SKIP.*Chrome not resident.*--no-startup-window'
has .v2 'FAIL.*xdg-terminals\.list missing'
echo "3. no DISPLAY → Chrome check is a SKIP, not a verdict"
run_case "$PWD/.v3" 1 gnome ""
has .v3 'SKIP.*Chrome.*no DISPLAY'
rm -f .v1 .v2 .v3
echo
# shellcheck disable=SC2015
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
