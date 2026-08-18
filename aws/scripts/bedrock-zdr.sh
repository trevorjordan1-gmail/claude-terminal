#!/bin/bash
# Bedrock zero-data-retention lock + medical-tenant acceptance checks.
# Run from the operator workstation with the TENANT's AWS credentials (same
# profile terraform uses). No Terraform resource exists for account data
# retention (provider issue #49201), so this is the one imperative step.
#
#   bedrock-zdr.sh --apply [--region R]           set account data retention = none (idempotent, per Region)
#   bedrock-zdr.sh --check [--region R] [--fable-id ID]
#       retention mode is none; EBS encryption-by-default on; model-invocation
#       logging off; a Fable-tier request is refused (proves the mode bites)
set -uo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"; ACTION=""; FABLE_ID="us.anthropic.claude-fable-5"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply|--check) ACTION="$1" ;;
    --region) REGION="$2"; shift ;;
    --fable-id) FABLE_ID="$2"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done
[ -n "$ACTION" ] || usage 2
[ -n "$REGION" ] || { echo "region unknown — pass --region or set AWS_REGION" >&2; exit 2; }

ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=1; }
FAIL=0

case "$ACTION" in
  --apply)
    aws bedrock put-account-data-retention --region "$REGION" --mode none >/dev/null \
      || { echo "put-account-data-retention failed (need bedrock:PutAccountDataRetention; is Bedrock enabled in $REGION?)" >&2; exit 1; }
    echo "applied: Bedrock account data retention = none in $REGION"
    aws bedrock get-account-data-retention --region "$REGION" --output table
    ;;
  --check)
    echo "medical tenant checks — $REGION"
    MODE="$(aws bedrock get-account-data-retention --region "$REGION" --query mode --output text 2>/dev/null)"
    if [ "$MODE" = "none" ]; then ok "Bedrock account data retention: none"
    else bad "Bedrock account data retention: ${MODE:-unreadable} (want none — run: $0 --apply --region $REGION)"; fi

    EBS="$(aws ec2 get-ebs-encryption-by-default --region "$REGION" --query EbsEncryptionByDefault --output text 2>/dev/null)"
    if [ "$EBS" = "True" ]; then ok "EBS encryption by default: on"
    else bad "EBS encryption by default: ${EBS:-unreadable} (terraform apply sets it)"; fi

    LOGCFG="$(aws bedrock get-model-invocation-logging-configuration --region "$REGION" --query loggingConfig --output json 2>/dev/null)"
    if [ -z "$LOGCFG" ] || [ "$LOGCFG" = "null" ]; then ok "Bedrock model-invocation logging: off"
    else bad "Bedrock model-invocation logging is CONFIGURED — prompts would persist to S3/CloudWatch: $LOGCFG"; fi

    # Under mode=none, models that require provider data sharing (Fable/Mythos)
    # are unavailable — an invoke must be refused. A "not found" answer means
    # the ID is wrong for this Region, which proves nothing: say so.
    ERR="$(mktemp)"
    if aws bedrock-runtime invoke-model --region "$REGION" --model-id "$FABLE_ID" \
         --cli-binary-format raw-in-base64-out \
         --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
         /dev/null >/dev/null 2>"$ERR"; then
      bad "a $FABLE_ID request SUCCEEDED — the retention mode is not excluding Fable-tier models"
    elif grep -qiE "not found|invalid|does not exist|ValidationException" "$ERR" && ! grep -qiE "retention|unavailable|not available" "$ERR"; then
      printf '  SKIP  %s\n' "could not prove the Fable exclusion: $FABLE_ID is unknown here (pass --fable-id with the Region's ID). Error: $(head -c 160 "$ERR" | tr '\n' ' ')"
    else
      ok "Fable-tier request refused: $(head -c 120 "$ERR" | tr '\n' ' ')"
    fi
    rm -f "$ERR"
    if [ "$FAIL" = 0 ]; then echo "all checks passed"; else echo "checks FAILED"; exit 1; fi
    ;;
esac
