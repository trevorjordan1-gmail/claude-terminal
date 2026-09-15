#!/bin/bash
# Roll a change out to EVERY tenant (or --tenant NAME for one).
# Usage: rollout.sh portal|scripts|cp|workbench|all|verify [--tenant NAME]
# The tenants.json registry IS the "did we get everywhere" checklist.
# `cp` refreshes /opt/asp on every control plane from the bucket (#49): a CP stages its scripts
# ONCE at first boot and nothing else ever updates them, so `/opt/asp` is a cache of the bucket
# and this layer is the only thing allowed to refresh it. `all` runs it after `scripts` and
# before `portal`, so the portal layer's `portal-deploy.sh` is the current one by construction.
# `verify` is a READ, not a layer of `all`: it runs cp-verify.sh on every control plane over
# SSM and prints each box's report (#27) — run it after a rollout, or any time.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
LAYER="${1:?usage: rollout.sh portal|scripts|cp|workbench|all|verify [--tenant NAME]}"
case "$LAYER" in portal|scripts|cp|workbench|all|verify) ;; *) echo "usage: rollout.sh portal|scripts|cp|workbench|all|verify [--tenant NAME]" >&2; exit 2 ;; esac
# the control plane's script set — what cp-setup.sh staged at first boot, plus what later
# releases added (the expiry checker cp-tls.sh now depends on, and the verifier)
CP_SCRIPTS="cp-tls.sh dcv-cp-install.sh portal-deploy.sh cert-expiry-check.sh cp-verify.sh"
ONLY="${3:-}"; [ "${2:-}" = "--tenant" ] && ONLY="$3"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)
# tenant registry is PRIVATE — keep it out of this public repo
# (default: git-ignored aws/tenants.json; see tenants.example.json)
TENANTS_FILE="${ASP_TENANTS:-tenants.json}"
echo "== rollout $LAYER @ $VERSION =="
FAIL=0
# ssm_run INSTANCE TIMEOUT_S COMMAND — run one shell command on a box and wait for the
# invocation to finish (up to TIMEOUT_S) instead of a fixed sleep. Prints the box's stdout;
# returns 0 only when the invocation ended Success. (Callers use it inside $(...), so the
# status has to travel in the return code — a variable set here never reaches them.)
ssm_run() {
  local id=$1 tmo=$2 cmd=$3 c st
  c=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --timeout-seconds "$tmo" --parameters "commands=[\"$cmd\"]" \
    --query Command.CommandId --output text) || return 1
  st=""
  for _ in $(seq 1 $((tmo / 5 + 1))); do
    sleep 5
    st=$(aws ssm get-command-invocation --command-id "$c" --instance-id "$id" --query Status --output text 2>/dev/null)
    case "$st" in Success|Failed|TimedOut|Cancelled) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$c" --instance-id "$id" --query StandardOutputContent --output text 2>/dev/null
  [ "$st" = Success ] || { echo "   (invocation on $id ended: ${st:-unknown})" >&2; return 1; }
}
# shellcheck disable=SC2034  # PORTAL is a registry column we read for shape, not (yet) used here
while IFS=$'\t' read -r NAME PROFILE REGION BUCKET CPID PORTAL; do
  [ -n "$ONLY" ] && [ "$NAME" != "$ONLY" ] && continue
  export AWS_PROFILE=$PROFILE AWS_DEFAULT_REGION=$REGION
  echo "-- tenant: $NAME"
  ok=1
  if [ "$LAYER" = "scripts" ] || [ "$LAYER" = "all" ]; then
    aws s3 sync scripts/ "s3://$BUCKET/scripts/" --exclude "*" --include "*.sh" --include "*.py" >/dev/null || ok=0
    echo "$VERSION" | aws s3 cp - "s3://$BUCKET/release/version" >/dev/null || ok=0
    echo "   scripts synced + release channel set to $VERSION (terminals self-apply within a day, or on wake)"
  fi
  if [ "$LAYER" = "cp" ] || [ "$LAYER" = "all" ]; then
    CMD=""
    for f in $CP_SCRIPTS; do
      CMD="${CMD}aws s3 cp s3://$BUCKET/scripts/$f /opt/asp/$f >/dev/null && chmod 755 /opt/asp/$f && echo refreshed $f || { echo MISSING $f — run rollout.sh scripts first; exit 1; }; "
    done
    CMD="${CMD}aws s3 cp s3://$BUCKET/scripts/tenant-custom-cp.sh /opt/asp/tenant-custom-cp.sh >/dev/null 2>&1 && chmod 755 /opt/asp/tenant-custom-cp.sh && echo refreshed tenant-custom-cp.sh; true"
    OUT=$(ssm_run "$CPID" 120 "$CMD") || ok=0
    printf '%s\n' "${OUT:-no output}" | sed 's/^/   cp: /'
    printf '%s\n' "$OUT" | grep -q '^MISSING' && ok=0
  fi
  if [ "$LAYER" = "portal" ] || [ "$LAYER" = "all" ]; then
    # runs the CP's LOCAL /opt/asp/portal-deploy.sh — current only if the cp layer ran (#49)
    # stamp VERSION into a staging copy — never into the tracked portal/VERSION
    # (a dirty tree would make every later `git describe --dirty` lie)
    STAGE=$(mktemp -d); cp -r portal "$STAGE/portal"; echo "$VERSION" > "$STAGE/portal/VERSION"
    (cd "$STAGE/portal" && zip -qr /tmp/portal-rollout.zip . -x "*/__pycache__/*" -x "__pycache__/*")
    rm -rf "$STAGE"
    aws s3 cp /tmp/portal-rollout.zip "s3://$BUCKET/portal/portal.zip" >/dev/null || ok=0
    # portal-deploy pip-installs, so wait for the invocation to finish (up to
    # ~3 min) instead of a fixed sleep that reports a phantom VERSION MISMATCH
    OUT=$(ssm_run "$CPID" 300 "bash /opt/asp/portal-deploy.sh >/dev/null 2>&1; sleep 3; curl -s http://127.0.0.1:8080/healthz") || ok=0
    echo "   portal healthz: $OUT"
    echo "$OUT" | grep -q "\"version\":\"$VERSION\"" || { echo "   VERSION MISMATCH"; ok=0; }
  fi
  if [ "$LAYER" = "workbench" ] || [ "$LAYER" = "all" ]; then
    IDS=$(aws ec2 describe-instances --filters Name=tag:Role,Values=desktop Name=instance-state-name,Values=running \
      --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')
    for I in $IDS; do
      # A box still provisioning is "running" from the moment it boots — 20 min
      # before its setup finishes. Queueing the workbench there puts two apt
      # consumers on one dpkg lock, and whichever loses is silently broken (#7,
      # hit for real). Fresh + unfinished marker = mid-build: skip it.
      BUSY=$(aws s3 cp "s3://$BUCKET/status/$I.json" - 2>/dev/null | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if float(d.get("pct", 0)) < 100 and time.time() - float(d.get("ts", 0)) < 7200:
    print("%s — %s%%" % (d.get("label", "?"), d.get("pct", "?")))')
      if [ -n "$BUSY" ]; then
        echo "   skipped $I: still provisioning ($BUSY) — rerun 'rollout.sh workbench' once it reports Ready"
        continue
      fi
      # shellcheck disable=SC2016  # JMESPath backticks, not shell expansion
      U=$(aws ec2 describe-instances --instance-ids "$I" --query 'Reservations[0].Instances[0].Tags[?Key==`LocalUser`]|[0].Value' --output text)
      aws ssm send-command --instance-ids "$I" --document-name AWS-RunShellScript --timeout-seconds 900 \
        --parameters "commands=[\"su - $U -c 'curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash' >> /var/log/asp-workbench.log 2>&1 && echo workbench-updated\"]" \
        --query Command.CommandId --output text >/dev/null && echo "   workbench rerun queued: $I ($U)" || ok=0
    done
    [ -z "$IDS" ] && echo "   no running desktops (paused ones update on next natural wake via SSM rerun, or start them first)"
  fi
  if [ "$LAYER" = "verify" ]; then
    # stage the current checker, then run it where it lives (certbot --dry-run can take a
    # minute or two per box)
    aws s3 cp scripts/cp-verify.sh "s3://$BUCKET/scripts/cp-verify.sh" >/dev/null || ok=0
    REPORT=$(ssm_run "$CPID" 600 "aws s3 cp s3://$BUCKET/scripts/cp-verify.sh /opt/asp/cp-verify.sh >/dev/null && chmod 755 /opt/asp/cp-verify.sh && bash /opt/asp/cp-verify.sh 2>&1") || ok=0
    if [ -n "$REPORT" ]; then
      printf '%s\n' "$REPORT" | sed 's/^/   /'
      printf '%s\n' "$REPORT" | grep -q '^- FAIL' && ok=0
    else
      echo "   no report from $CPID"; ok=0
    fi
  fi
  if [ "$ok" = 1 ]; then echo "   OK"; else echo "   FAILED"; FAIL=1; fi
done < <(python3 -c "
import json
for t in json.load(open('$TENANTS_FILE')):
    print('\t'.join([t['name'], t['aws_profile'], t['region'], t['artifacts_bucket'], t['controlplane_id'], t['portal_url']]))")
exit $FAIL
