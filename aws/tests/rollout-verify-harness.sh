#!/bin/bash
# rollout-verify-harness.sh — `rollout.sh verify` against a stubbed aws CLI and a fake
# tenant registry: proves the layer fetches cp-verify.sh from the bucket, runs it over
# SSM, prints the box's report, and fails the rollout when the report has a FAIL.
#
#   bash aws/tests/rollout-verify-harness.sh        # ~2 s, exit 0 = all pass
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
# shellcheck disable=SC2015 # pass/fail always return 0
has()   { grep -qE -- "$2" "$1" && pass "has /$2/" || fail "lacks /$2/  ($(tr '\n' '|' <"$1" | cut -c1-300))"; }
mkdir -p "$T/bin"
cat >"$T/bin/aws" <<'A'
#!/bin/bash
echo "aws $*" >>"$AWSLOG"
case "$*" in
  *"ssm send-command"*) echo cmd-42 ;;
  *"get-command-invocation"*"--query Status"*) echo Success ;;
  *"get-command-invocation"*"StandardOutputContent"*) cat "$REPORT" ;;
  *) exit 0 ;;
esac
A
chmod +x "$T/bin/aws"
printf '[{"name":"t1","aws_profile":"p","region":"us-east-2","artifacts_bucket":"bkt","controlplane_id":"i-cp1","portal_url":"https://portal.t1"}]\n' >"$T/tenants.json"
run() { ( export PATH="$T/bin:$PATH" AWSLOG="$T/aws.log" REPORT="$1" ASP_TENANTS="$T/tenants.json"; : >"$T/aws.log"; bash "$REPO/aws/scripts/rollout.sh" verify; echo "exit=$?" ) >"$T/out" 2>&1; }

echo "1. a green report: fetched from the bucket, run via SSM, printed, rollout OK"
printf -- '- PASS — cp-tls steady state\n- PASS — renewal dry-run\nverdict: 2 pass · 0 fail · 0 skip\n' >"$T/r1"
run "$T/r1"
has "$T/out" 'PASS — cp-tls steady state'
has "$T/out" 'verdict: 2 pass'
has "$T/out" 'exit=0'
has "$T/aws.log" 'ssm send-command --instance-ids i-cp1 .*s3://bkt/scripts/cp-verify.sh'
has "$T/aws.log" 's3 cp .*cp-verify.sh s3://bkt/scripts/cp-verify.sh'

echo "2. a report with a FAIL → the tenant is FAILED and rollout exits 1"
printf -- '- PASS — cp-tls steady state\n- FAIL — renewal dry-run failed\nverdict: 1 pass · 1 fail · 0 skip\n' >"$T/r2"
run "$T/r2"
has "$T/out" 'FAIL — renewal dry-run failed'
has "$T/out" 'FAILED'
has "$T/out" 'exit=1'

echo "3. usage names the layer"
# shellcheck disable=SC2015
( bash "$REPO/aws/scripts/rollout.sh" 2>&1 || true ) | grep -q 'portal.scripts.workbench.all.verify' && pass "usage mentions verify" || fail "usage lacks verify"
echo
# shellcheck disable=SC2015
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
