#!/usr/bin/env bash
# test-pack-verify.sh — self-test for pack-verify.sh's AWS build-identity probe (#48) and
# the BOX_ROLE pack split (#54).
# No tenant, no network: every provider probe is starved (stubbed curl, a dead proxy
# for boto3) and STS is a local fake answering GetCallerIdentity with the ARN each
# case needs. Asserts the AWS lines, the role/required-set lint lines and the SKIP accounting.
#
#   bash templates/test-pack-verify.sh        # ~10 s, exit 0 = all pass
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PV="$HERE/pack-verify.sh"
T=$(mktemp -d); trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
# shellcheck disable=SC2015 # pass/fail always return 0, so `A && pass || fail` is an if/else here
has()   { grep -qE -- "$2" "$1" && pass "output has /$2/" || fail "output lacks /$2/  (aws lines: $(grep -i aws "$1" | tr '\n' '|'))"; }
# shellcheck disable=SC2015
hasnt() { grep -qE -- "$2" "$1" && fail "output unexpectedly has /$2/" || pass "output has no /$2/"; }

# ── starve every real probe ──────────────────────────────────────────────────
STUB="$T/bin"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 7\n' >"$STUB/curl"       # DO/CF/GitHub/Healthchecks: "could not connect"
printf '#!/bin/sh\nexit 1\n' >"$STUB/restic"     # present → pack-verify never tries apt
chmod +x "$STUB"/*
uv run --quiet --with boto3 python3 -c 'import boto3' || { echo "uv/boto3 unavailable — cannot self-test"; exit 1; }
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
HITS="$T/sts-hits"; : >"$HITS"
cat >"$T/fake-sts.py" <<'PY'
import http.server, sys
PORT, ARN, ACCT, HITS = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        open(HITS, 'a').write(self.path + "\n")
        b = (f'<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">'
             f'<GetCallerIdentityResult><Arn>{ARN}</Arn><UserId>X</UserId><Account>{ACCT}</Account>'
             f'</GetCallerIdentityResult><ResponseMetadata><RequestId>r</RequestId></ResponseMetadata>'
             f'</GetCallerIdentityResponse>').encode()
        self.send_response(200); self.send_header('Content-Type', 'text/xml')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY
sts() { # $1 ARN, $2 account — (re)start the fake
  kill "${STS_PID:-}" 2>/dev/null; wait "${STS_PID:-}" 2>/dev/null
  python3 "$T/fake-sts.py" "$PORT" "$1" "$2" "$HITS" & STS_PID=$!; sleep 0.3
}
hits() { wc -l <"$HITS" | tr -d ' '; }

pack() { # $1 file, then extra lines on stdin
  cat >"$1" <<'P'
CLIENT_CODE=acme
CLIENT_DOMAIN=example.test
BUILDER_NAME="Ai Ops"
BUILDER_EMAIL=ops@example.test
DO_API_KEY=x
CLOUDFLARE_ACCOUNT_ID=x
CLOUDFLARE_API_TOKEN=x
GITHUB_ORG=acme
GITHUB_PAT=x
GITHUB_CLASSIC=x
WASABI_ACCESS_KEY=x
WASABI_SECRET_KEY=x
WASABI_REGION=us-east-1
HEALTHCHECKS_API_KEY=x
HEALTHCHECK_READONLY_API_KEY=x
RESTIC_PASSWORD_CCT=x
RESTIC_PASSWORD_DOCKER01=x
CLIENT_ALERT_EMAILS=a@example.test
ADNET_ALERTS_MAILBOX=b@example.test
P
  cat >>"$1"; chmod 600 "$1"
}
run() { # $1 pack, $2 out, rest = pack-verify args
  local p=$1 o=$2; shift 2
  ( export PATH="$STUB:$PATH" HTTPS_PROXY=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1 \
           NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 AWS_ENDPOINT_URL_STS="http://127.0.0.1:$PORT" \
           AWS_MAX_ATTEMPTS=1 AWS_RETRY_MODE=standard UV_OFFLINE=1
    unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION
    bash "$PV" "$p" "$@" ) >"$o" 2>"$o.err"
}
AWS_ROOT='arn:aws:iam::123456789012:root'
AWS_USER='arn:aws:iam::123456789012:user/aiops-terraform'

echo "1. root keys in the pack → FAIL"
sts "$AWS_ROOT" 123456789012
pack "$T/p1" <<'P'
AWS_ACCOUNT_ID=123456789012
AWS_REGION=us-east-2
AWS_BUILD_USER=aiops-terraform
AWS_ACCESS_KEY_ID=AKIATESTROOT
AWS_SECRET_ACCESS_KEY=secret
P
run "$T/p1" "$T/o1"
has "$T/o1" '\*\*FAIL\*\* — AWS.*:root'
hasnt "$T/o1" '\*\*PASS\*\* — AWS'

echo "2. IAM user keys, AWS_ACCOUNT_ID empty → PASS, account recorded, 0600 kept"
sts "$AWS_USER" 123456789012
pack "$T/p2" <<'P'
AWS_ACCOUNT_ID=
AWS_REGION=us-east-2
AWS_BUILD_USER=aiops-terraform
AWS_ACCESS_KEY_ID=AKIATESTUSER
AWS_SECRET_ACCESS_KEY=secret
P
run "$T/p2" "$T/o2"
has "$T/o2" '\*\*PASS\*\* — AWS.*:user/aiops-terraform'
hasnt "$T/o2" '\*\*FAIL\*\* — AWS'
# shellcheck disable=SC2015
grep -q '^AWS_ACCOUNT_ID="123456789012"' "$T/p2" && pass "AWS_ACCOUNT_ID recorded from STS" || fail "AWS_ACCOUNT_ID not recorded: $(grep AWS_ACCOUNT_ID "$T/p2")"
# shellcheck disable=SC2015
[ "$(stat -c %a "$T/p2")" = 600 ] && pass "pack still 0600" || fail "pack mode $(stat -c %a "$T/p2")"

echo "3. IAM user keys but the pack names a different account → FAIL"
pack "$T/p3" <<'P'
AWS_ACCOUNT_ID=999999999999
AWS_REGION=us-east-2
AWS_ACCESS_KEY_ID=AKIATESTUSER
AWS_SECRET_ACCESS_KEY=secret
P
run "$T/p3" "$T/o3"
has "$T/o3" '\*\*FAIL\*\* — AWS.*999999999999'
# shellcheck disable=SC2015
grep -q '^AWS_ACCOUNT_ID=999999999999' "$T/p3" && pass "engineer's value left alone" || fail "pack value changed: $(grep AWS_ACCOUNT_ID "$T/p3")"

echo "4. no AWS in the pack → counted SKIP with a reason, STS never called"
h0=$(hits)
pack "$T/p4" </dev/null
run "$T/p4" "$T/o4"
has "$T/o4" '\*\*SKIP\*\* — AWS.*nothing to probe'
has "$T/o4" 'verdict: .* 1 skip'
# shellcheck disable=SC2015
[ "$(hits)" = "$h0" ] && pass "STS not called" || fail "STS was called $(( $(hits) - h0 )) time(s)"

echo "5. --lint: malformed AWS_REGION is a lint FAIL and STS is never touched"
h0=$(hits)
pack "$T/p5" <<'P'
AWS_ACCOUNT_ID=123456789012
AWS_REGION=ohio
AWS_ACCESS_KEY_ID=AKIATESTUSER
AWS_SECRET_ACCESS_KEY=secret
P
run "$T/p5" "$T/o5" --lint
has "$T/o5" '\*\*FAIL\*\* — AWS_REGION'
# shellcheck disable=SC2015
[ "$(hits)" = "$h0" ] && pass "STS not called under --lint" || fail "STS called under --lint"

echo "6. GITHUB_CLASSIC missing → lint FAIL (ghcr.io refuses fine-grained PATs; #54)"
pack "$T/p6" </dev/null
sed -i '/^GITHUB_CLASSIC=/d' "$T/p6"
run "$T/p6" "$T/o6" --lint
has "$T/o6" '\*\*FAIL\*\* — missing/empty: GITHUB_CLASSIC'

echo "7. BOX_ROLE=builder carrying the DO token → FAIL (infrastructure creds on a daily workspace; #54)"
pack "$T/p7" <<'P'
BOX_ROLE=builder
P
run "$T/p7" "$T/o7" --lint
has "$T/o7" '\*\*FAIL\*\* — DO_API_KEY is set on a BUILDER terminal'

echo "8. clean builder (no DO token, no AWS) → lints clean, DO probe skipped by role, AWS counted SKIP"
h0=$(hits)
pack "$T/p8" <<'P'
BOX_ROLE=builder
P
sed -i '/^DO_API_KEY=/d' "$T/p8"
run "$T/p8" "$T/o8"
has "$T/o8" '\*\*PASS\*\* — pack lints clean'
hasnt "$T/o8" 'FAIL\*\* — missing/empty: DO_API_KEY'
has "$T/o8" 'skipped DigitalOcean.*builder'
hasnt "$T/o8" 'DigitalOcean — tag lifecycle probe'
has "$T/o8" '\*\*SKIP\*\* — AWS'
# shellcheck disable=SC2015
[ "$(hits)" = "$h0" ] && pass "STS not called for a builder" || fail "STS called for a builder"

echo "9. builder carrying AWS keys → FAIL even though the keys are an IAM user"
pack "$T/p9" <<'P'
BOX_ROLE=builder
AWS_ACCESS_KEY_ID=AKIATESTUSER
AWS_SECRET_ACCESS_KEY=secret
AWS_REGION=us-east-2
P
sed -i '/^DO_API_KEY=/d' "$T/p9"
run "$T/p9" "$T/o9" --lint
has "$T/o9" '\*\*FAIL\*\* — AWS_ACCESS_KEY_ID is set on a BUILDER terminal'

echo "10. build box, TENANT_PROFILE set but no AWS keys → the complete AWS set is REQUIRED"
pack "$T/p10" <<'P'
TENANT_PROFILE=medical
P
run "$T/p10" "$T/o10" --lint
has "$T/o10" '\*\*FAIL\*\* — missing/empty: AWS_ACCESS_KEY_ID'
has "$T/o10" '\*\*FAIL\*\* — missing/empty: AWS_REGION'
hasnt "$T/o10" 'missing/empty: AWS_ACCOUNT_ID'   # recorded from STS when empty (#48), never demanded

echo "11. half-filled AWS block (account id only) → FAIL on the rest, not a silent pass"
pack "$T/p11" <<'P'
AWS_ACCOUNT_ID=123456789012
P
run "$T/p11" "$T/o11" --lint
has "$T/o11" '\*\*FAIL\*\* — missing/empty: AWS_SECRET_ACCESS_KEY'
has "$T/o11" '\*\*FAIL\*\* — missing/empty: AWS_REGION'

echo "12. no-AWS build box (Ai Adopt shape) → lints clean; BOX_ROLE unset reads as build"
pack "$T/p12" </dev/null
run "$T/p12" "$T/o12" --lint
has "$T/o12" '\*\*PASS\*\* — pack lints clean'
hasnt "$T/o12" 'FAIL\*\* — missing/empty: AWS'

echo "13. BOX_ROLE and TENANT_PROFILE outside their vocabularies → FAIL by name"
pack "$T/p13" <<'P'
BOX_ROLE=desktop
TENANT_PROFILE=hipaa
P
run "$T/p13" "$T/o13" --lint
has "$T/o13" '\*\*FAIL\*\* — BOX_ROLE must be build or builder'
has "$T/o13" '\*\*FAIL\*\* — TENANT_PROFILE must be standard or medical'

echo
# shellcheck disable=SC2015
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
