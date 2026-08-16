#!/bin/bash
# Roll a change out to EVERY tenant (or --tenant NAME for one).
# Usage: rollout.sh portal|scripts|workbench|all [--tenant NAME]
# The tenants.json registry IS the "did we get everywhere" checklist.
set -uo pipefail
cd "$(dirname "$0")/.."
LAYER="${1:?usage: rollout.sh portal|scripts|workbench|all [--tenant NAME]}"
ONLY="${3:-}"; [ "${2:-}" = "--tenant" ] && ONLY="$3"
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)
# tenant registry is PRIVATE — keep it out of this public repo
# (default: git-ignored aws/tenants.json; see tenants.example.json)
TENANTS_FILE="${ASP_TENANTS:-tenants.json}"
echo "== rollout $LAYER @ $VERSION =="
FAIL=0
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
  if [ "$LAYER" = "portal" ] || [ "$LAYER" = "all" ]; then
    echo "$VERSION" > portal/VERSION
    (cd portal && zip -qr /tmp/portal-rollout.zip . -x "__pycache__/*")
    aws s3 cp /tmp/portal-rollout.zip "s3://$BUCKET/portal/portal.zip" >/dev/null || ok=0
    CMD=$(aws ssm send-command --instance-ids "$CPID" --document-name AWS-RunShellScript \
      --timeout-seconds 300 --parameters 'commands=["bash /opt/asp/portal-deploy.sh >/dev/null 2>&1; sleep 3; curl -s http://127.0.0.1:8080/healthz"]' \
      --query Command.CommandId --output text) || ok=0
    sleep 25
    OUT=$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$CPID" \
      --query StandardOutputContent --output text 2>/dev/null)
    echo "   portal healthz: $OUT"
    echo "$OUT" | grep -q "\"version\":\"$VERSION\"" || { echo "   VERSION MISMATCH"; ok=0; }
  fi
  if [ "$LAYER" = "workbench" ] || [ "$LAYER" = "all" ]; then
    IDS=$(aws ec2 describe-instances --filters Name=tag:Role,Values=desktop Name=instance-state-name,Values=running \
      --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')
    for I in $IDS; do
      U=$(aws ec2 describe-instances --instance-ids "$I" --query 'Reservations[0].Instances[0].Tags[?Key==`LocalUser`]|[0].Value' --output text)
      aws ssm send-command --instance-ids "$I" --document-name AWS-RunShellScript --timeout-seconds 900 \
        --parameters "commands=[\"su - $U -c 'curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash' >> /var/log/asp-workbench.log 2>&1 && echo workbench-updated\"]" \
        --query Command.CommandId --output text >/dev/null && echo "   workbench rerun queued: $I ($U)" || ok=0
    done
    [ -z "$IDS" ] && echo "   no running desktops (paused ones update on next natural wake via SSM rerun, or start them first)"
  fi
  [ $ok = 1 ] && echo "   OK" || { echo "   FAILED"; FAIL=1; }
done < <(python3 -c "
import json
for t in json.load(open('$TENANTS_FILE')):
    print('\t'.join([t['name'], t['aws_profile'], t['region'], t['artifacts_bucket'], t['controlplane_id'], t['portal_url']]))")
exit $FAIL
