#!/bin/bash
# backup-arm-harness.sh — aws/scripts/backup-arm.sh in a throwaway container with stubbed
# aws/curl/restic/systemctl/apt-get. What it proves (#53): which Healthchecks key arms the
# backup alarm — the tenant-wide /asp/healthchecks/api-key (the one cp-tls.sh reads, so one
# parameter arms every alarm) first, the legacy HEALTHCHECKS_API_KEY inside
# /asp/backup/config as the fallback — the check name/tags, the MUTE line when neither
# exists, and that a tenant with no backup config stays a no-op.
#
#   bash aws/tests/backup-arm-harness.sh        # ~10 s, exit 0 = all pass
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
IMG=claude-terminal-harness:2
docker image inspect "$IMG" >/dev/null 2>&1 || docker build -q -t "$IMG" - <<'DF' >/dev/null
FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends openssl ca-certificates python3 >/dev/null && rm -rf /var/lib/apt/lists/*
DF
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
# shellcheck disable=SC2015 # pass/fail always return 0
has()   { grep -qE -- "$2" "$1" && pass "has /$2/" || fail "lacks /$2/  ($(tr '\n' '|' <"$1" | cut -c1-400))"; }
# shellcheck disable=SC2015
hasnt() { grep -qE -- "$2" "$1" && fail "unexpectedly has /$2/" || pass "has no /$2/"; }

# run_case OUT then env: BACKUPCONF=1|0 (the /asp/backup/config parameter exists)
#   CFGKEY=<key>|"" (HEALTHCHECKS_API_KEY inside that config)  TENANTKEY=<key>|"" (/asp/healthchecks/api-key)
run_case() {
  local out=$1; shift; local envs=()
  for e in "$@"; do envs+=(-e "$e"); done
  docker run --rm -v "$REPO:/kit:ro" "${envs[@]}" "$IMG" bash -c '
set -u
mkdir -p /opt/asp /usr/local/bin /etc/systemd/system
printf "ASP_REGION=us-east-2\nASP_CUSTOMER=acme-poc\nASP_MACHINE_NAME=acme-cct01\nASP_BUCKET=b\n" >/etc/asp-terminal.env
printf "#!/bin/sh\nexit 0\n" >/usr/local/bin/apt-get
printf "#!/bin/sh\nexit 0\n" >/usr/local/bin/restic
printf "#!/bin/sh\necho \"systemctl \$*\" >>/tmp/calls; exit 0\n" >/usr/local/bin/systemctl
# the config JSON goes through a file — expanding it inside the stub heredoc would strip its quotes
printf "{\"BACKUP_BUCKET\":\"bk\",\"BACKUP_ENDPOINT\":\"https://s3.example.test\",\"BACKUP_ACCESS_KEY\":\"ak\",\"BACKUP_SECRET_KEY\":\"sk\",\"RESTIC_PASSWORD\":\"rp\"%s}" "${CFGKEY:+,\"HEALTHCHECKS_API_KEY\":\"$CFGKEY\"}" >/tmp/cfg.json
cat >/usr/local/bin/aws <<A
#!/bin/bash
echo "aws \$*" >>/tmp/calls
case "\$*" in
  *"/asp/backup/config"*)       [ "$BACKUPCONF" = 1 ] && cat /tmp/cfg.json || { echo "ParameterNotFound" >&2; exit 254; };;
  *"/asp/healthchecks/api-key"*) [ -n "$TENANTKEY" ] && echo "$TENANTKEY" || { echo "ParameterNotFound" >&2; exit 254; };;
  *) exit 0;;
esac
A
cat >/usr/local/bin/curl <<C
#!/bin/bash
# log the Healthchecks call with its key and body so the case can see WHICH key minted the check
key=""; body=""; while [ \$# -gt 0 ]; do case "\$1" in -H) case "\$2" in X-Api-Key:*) key="\${2#X-Api-Key: }";; esac; shift;; -d) body="\$2"; shift;; esac; shift; done
echo "curl key=[\$key] body=[\$body]" >>/tmp/calls
printf "{\"ping_url\":\"https://hc-ping.com/\$key\"}"
C
chmod +x /usr/local/bin/*
bash /kit/aws/scripts/backup-arm.sh 2>&1; echo "exit=$?"
echo "--- asp-backup.env: $(grep HEALTHCHECK_URL /etc/asp-backup.env 2>/dev/null)"
echo "--- calls:"; cat /tmp/calls 2>/dev/null
' >"$out" 2>&1
}

echo "1. key only in the tenant-wide /asp/healthchecks/api-key (the parameter cp-tls.sh reads) → mints the check with it"
run_case "$PWD/.b1" BACKUPCONF=1 CFGKEY= TENANTKEY=tenantkey
has .b1 'curl key=\[tenantkey\] body=\[.*"name":"backup-acme-acme-cct01".*"tags":"asp backup acme"'
has .b1 "HEALTHCHECK_URL='https://hc-ping.com/tenantkey'"
has .b1 'armed .*pings Healthchecks'
has .b1 'exit=0'

echo "2. legacy key only inside /asp/backup/config → still used (existing tenants keep working)"
run_case "$PWD/.b2" BACKUPCONF=1 CFGKEY=cfgkey TENANTKEY=
has .b2 'curl key=\[cfgkey\]'
has .b2 "HEALTHCHECK_URL='https://hc-ping.com/cfgkey'"
has .b2 'exit=0'

echo "3. both present → the tenant-wide key wins (one parameter arms every alarm)"
run_case "$PWD/.b3" BACKUPCONF=1 CFGKEY=cfgkey TENANTKEY=tenantkey
has .b3 'curl key=\[tenantkey\]'
hasnt .b3 'curl key=\[cfgkey\]'

echo "4. neither → armed, and the MUTE line names /asp/healthchecks/api-key on stdout"
run_case "$PWD/.b4" BACKUPCONF=1 CFGKEY= TENANTKEY=
hasnt .b4 'curl key='
has .b4 "HEALTHCHECK_URL=''"
has .b4 'MUTE.*/asp/healthchecks/api-key'
has .b4 'exit=0'

echo "5. no /asp/backup/config → no-op, nothing armed, the key parameter is never read"
run_case "$PWD/.b5" BACKUPCONF=0 CFGKEY= TENANTKEY=tenantkey
has .b5 'backups not armed \(by design\)'
hasnt .b5 'aws .*healthchecks/api-key'
hasnt .b5 'systemctl enable'
has .b5 'exit=0'
rm -f .b1 .b2 .b3 .b4 .b5
echo
# shellcheck disable=SC2015
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
