#!/usr/bin/env bash
# pack-verify.sh — lint + write-probe the credential pack (onboarding stage 4, SETUP step).
#
#   bash pack-verify.sh [envfile] [--lint]
#
# envfile defaults to ./.env. --lint stops after the static checks (run it right after
# staging the scratch, BEFORE pointing Claude at SETUP). The full run probes a real WRITE
# on every provider — read access is not evidence of write access — and cleans up every
# probe object, confirming the deletion. Output lines are paste-ready for STATE.md's
# verified table. Exit 0 = all pass.
set -uo pipefail

ENVFILE="${1:-./.env}"
[ "${ENVFILE}" = "--lint" ] && { ENVFILE="./.env"; set -- "$ENVFILE" --lint; }
LINT_ONLY=0; [ "${2:-}" = "--lint" ] && LINT_ONLY=1
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "- **PASS** — $1${2:+ · \`$2\`}"; return 0; }
bad()  { FAIL=$((FAIL+1)); echo "- **FAIL** — $1${2:+ · \`$2\`}"; return 0; }

# ── lint: the pack must source cleanly and completely ───────────────────────
[ -f "$ENVFILE" ] || { echo "No env file at $ENVFILE"; exit 1; }
# shellcheck disable=SC1090 # the pack itself — runtime file, path from argv
if ! ( set -e; . "$ENVFILE" ) >/dev/null 2>&1; then
  bad "env does not source cleanly — unquoted spaces? (BUILDER_NAME needs quotes)"
  echo "lint failed — fix $ENVFILE before anything else."; exit 1
fi
set -a
# shellcheck disable=SC1090 # same runtime file
. "$ENVFILE"
set +a

REQUIRED=(CLIENT_CODE CLIENT_DOMAIN BUILDER_NAME BUILDER_EMAIL
  DO_API_KEY CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN GITHUB_ORG GITHUB_PAT
  WASABI_ACCESS_KEY WASABI_SECRET_KEY WASABI_REGION
  HEALTHCHECKS_API_KEY HEALTHCHECK_READONLY_API_KEY
  RESTIC_PASSWORD_CCT RESTIC_PASSWORD_DOCKER01)
MISS=0
for v in "${REQUIRED[@]}"; do
  [ -n "${!v:-}" ] || { bad "missing/empty: $v"; MISS=1; }
done
case "$GITHUB_ORG" in
  *" "*|*,*) bad "GITHUB_ORG must be the URL slug (after github.com/), not a display name" "$GITHUB_ORG"; MISS=1 ;;
esac
# CLIENT_CODE names S3 buckets (lowercase only — an uppercase code fails the Wasabi probe
# with InvalidBucketName while the keys are fine, field-hit), the droplet sudo user, repo
# and hostname prefixes. Reject rather than normalise: a silently lowercased value would
# leave the pack disagreeing with whatever the accounts pass already created under it.
case "${CLIENT_CODE:-}" in
  ""|*[!a-z0-9-]*) bad "CLIENT_CODE must be lowercase [a-z0-9-] (S3 bucket names, sudo user, repo prefix) — stage it lowercase at the accounts pass" "${CLIENT_CODE:-}"; MISS=1 ;;
esac
# Per-credential *_EXPIRES fields are gone (#17): the operating standard is ONE
# lifetime for every mintable credential (12 months — CF, DO, both GitHub PATs,
# the Entra secret), so every expiry is "≈ the engagement anniversary" by
# construction. One optional date carries the whole convention; CF_TOKEN_ID
# stays because it is a revocation identifier, not bookkeeping.
# Both are recorded AUTOMATICALLY by the Cloudflare probe below (the token's own
# verify endpoint returns its id + expiry; expiry − 12 months = the mint date), so an
# empty field here is only a note until the full run has had its chance.
[ -n "${CREDENTIALS_MINTED:-}" ] || echo "  (note: CREDENTIALS_MINTED empty — the full run derives it from the CF token's expiry and records it)"
[ -n "${CF_TOKEN_ID:-}" ] || echo "  (note: CF_TOKEN_ID empty — the full run reads it from /accounts/{id}/tokens/verify and records it)"
# Alert routing is an ACCOUNTS-PASS deliverable, not a build-time judgment call: every
# Healthchecks check and DO alert policy binds to these two addresses. Empty = alerts land
# nowhere (field-hit: a platform whose alerts reached only the machine mailbox) → FAIL.
for v in CLIENT_ALERT_EMAILS ADNET_ALERTS_MAILBOX; do
  [ -n "${!v:-}" ] || { bad "$v empty — alert routing has nowhere to land; fill it at the accounts pass" ""; MISS=1; }
done
for v in CLIENT_LOCATION CLIENT_STAFF_DOMAIN \
         ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_ADMIN_DOMAIN \
         GITHUB_CLASSIC AIOPS_UPN; do
  [ -n "${!v:-}" ] || echo "  (note: $v empty — the platform build will need a judgment call or fallback)"
done
# Zero-question builds: each of these pre-answers a question PLATFORM-BUILD otherwise has
# to ask (droplet spend, SSO-now-or-OTP, which engagement shape this is). Notes, not
# failures — the build asks exactly once when a field is absent.
[ -n "${DROPLET_SIZE:-}" ] || echo "  (note: DROPLET_SIZE empty — the build will ask once to confirm droplet spend; set e.g. DROPLET_SIZE=s-2vcpu-4gb to pre-authorise it)"
case "${SSO_AT_BUILD:-}" in
  "") echo "  (note: SSO_AT_BUILD empty — the build will ask once: mint Entra SSO now (yes) or ship email-OTP policies and flip later (otp))" ;;
  yes|otp) : ;;
  *) bad "SSO_AT_BUILD must be yes or otp" "${SSO_AT_BUILD}"; MISS=1 ;;
esac
case "${ENGAGEMENT:-}" in
  "") echo "  (note: ENGAGEMENT empty — build|adopt; BUILDER_NAME='Ai Ops' is read as adopt (no human builder, no seat swap))" ;;
  build|adopt) : ;;
  *) bad "ENGAGEMENT must be build or adopt" "${ENGAGEMENT}"; MISS=1 ;;
esac
command -v doctl >/dev/null 2>&1 || echo "  (note: doctl not installed — PLATFORM-BUILD step 1 is doctl-driven; the kit's base module installs it, re-run get.sh or install it before the build)"
# AIOPS_TOTP_SEED (#24): the aiops second factor lives in the pack because the
# exporter runs UNATTENDED and the alternative — a Conditional Access policy
# exempting the account by IP — was weighed and declined. Hudu stays root of
# trust; the pack copy is a working copy, and it is credential-grade: rotating
# it means re-enrolling the authenticator, so it belongs in the same rotation
# story as the secrets beside it.
[ -n "${AIOPS_TOTP_SEED:-}" ] || echo "  (note: AIOPS_TOTP_SEED empty — unattended aiops sign-in needs it; vault it in Hudu too)"
[ -n "${APPLIANCE_HOST:-}" ] || echo "  (note: APPLIANCE_HOST empty — no appliance /settings redirect URI will be registered; NEVER derive it from a staff domain, #18)"
# TEAM_DOMAIN gets its own louder note (#18): Cloudflare AUTO-GENERATES the ZT
# team domain, so a missing value cannot be guessed — deriving it from
# CLIENT_CODE is exactly the AADSTS50011 field failure.
[ -n "${TEAM_DOMAIN:-}" ] || echo "  (note: TEAM_DOMAIN empty — record the REAL Zero Trust auth_domain (GET /accounts/{id}/access/organizations) before any Entra SSO step; NEVER derived from CLIENT_CODE — AADSTS50011, #18)"
# MAIL_CAPABILITY gates SETUP step 6 (#13): outbound = platform mails users;
# inbound = a machine must receive time-limited mail (e.g. Team admin-export
# links); none = no aiops identity gets provisioned, recorded in STATE.md.
# Absent → SETUP asks the engineer the one capability question.
case "${MAIL_CAPABILITY:-}" in
  ""|outbound|inbound|both|none) : ;;
  *) bad "MAIL_CAPABILITY must be outbound/inbound/both/none" "${MAIL_CAPABILITY}"; MISS=1 ;;
esac
# GITHUB_CLASSIC = classic PAT, read:packages ONLY — ghcr.io refuses fine-grained PATs;
# without it every deploy takes the build-on-droplet fallback instead of the CI image.
[ "$MISS" -eq 0 ] && ok "pack lints clean ($ENVFILE: ${#REQUIRED[@]} names, sources cleanly)"
if [ "$LINT_ONLY" -eq 1 ] || [ "$MISS" -eq 1 ]; then
  echo "verdict: $PASS pass · $FAIL fail (lint only)"; exit "$((FAIL>0))"
fi

STAMP="$$-$(date +%s)"
# Probe stderr is CAPTURED, not discarded (field-hit: a FAIL with no reason needed a manual
# re-run to root-cause). `why` prints the last stderr line under a FAIL.
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
why() { [ -s "$ERR" ] && echo "  ↳ $(tail -n 1 "$ERR" | cut -c1-220)"; return 0; }
# Fill an EMPTY pack field from an API answer — never overwrite a value the engineer set.
# Preserves a trailing inline comment on the line.
pack_record() {
  # `\` and `&` are special in a sed REPLACEMENT and `|` is the delimiter here, so a value
  # containing any of them broke the substitution while the success line still printed —
  # the function claiming to have recorded something it had not. Today's callers pass a hex
  # token id and a date, but this is generic and the next caller will not.
  local esc; esc=$(printf '%s' "$2" | sed -e 's/[\\&|]/\\&/g')
  if grep -qE "^$1=([\"']{2})?[[:space:]]*(#.*)?\$" "$ENVFILE"; then
    sed -i -E "s|^($1=)([\"']{2})?([[:space:]]*#.*)?\$|\1\"$esc\"\3|" "$ENVFILE" \
      || { echo "  (could NOT record $1 into $ENVFILE — record it by hand)"; return 1; }
  elif ! grep -qE "^$1=" "$ENVFILE"; then
    printf '%s="%s"\n' "$1" "$2" >> "$ENVFILE"
  else
    return 0   # already set by a human — theirs wins
  fi
  echo "  (recorded $1=$2 into $ENVFILE — from the API, not transcription)"
}

# ── DigitalOcean: tag lifecycle ─────────────────────────────────────────────
T="pack-probe-$STAMP"
if curl -sf -X POST -H "Authorization: Bearer $DO_API_KEY" -H "Content-Type: application/json" \
     -d "{\"name\":\"$T\"}" https://api.digitalocean.com/v2/tags >/dev/null \
   && curl -sf -X DELETE -H "Authorization: Bearer $DO_API_KEY" "https://api.digitalocean.com/v2/tags/$T" \
   && [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DO_API_KEY" \
          "https://api.digitalocean.com/v2/tags/$T")" = 404 ]; then
  ok "DigitalOcean — tag create/delete round-trip (deletion confirmed 404)"
else
  bad "DigitalOcean — tag lifecycle probe"
fi

# ── Cloudflare: TXT record on the live zone ─────────────────────────────────
CFAPI="https://api.cloudflare.com/client/v4"
# The token's own record, straight from the API (#41): engagement tokens are ACCOUNT-owned,
# so /user/tokens/verify answers "Invalid API Token" for them (alarming, harmless) —
# /accounts/{id}/tokens/verify is the right endpoint and returns id, status, expires_on.
# expires_on − 12 months = CREDENTIALS_MINTED by the one-lifetime convention (#17).
TV=$(curl -s -m 15 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "$CFAPI/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify" \
  | python3 -c 'import json,sys
r=json.load(sys.stdin).get("result") or {}
exp=(r.get("expires_on") or "")[:10]
minted=""
if exp:
    y,m,d=exp.split("-"); minted=f"{int(y)-1}-{m}-{d}"
print(r.get("id",""), r.get("status",""), exp, minted)' 2>>"$ERR")
read -r TV_ID TV_STATUS TV_EXP TV_MINTED <<<"${TV:-}"
if [ "${TV_STATUS:-}" = active ]; then
  ok "Cloudflare — token verified via /accounts/{id}/tokens/verify (active, expires ${TV_EXP:-never})" "id $TV_ID"
  [ -n "$TV_ID" ] && pack_record CF_TOKEN_ID "$TV_ID"
  [ -n "$TV_MINTED" ] && pack_record CREDENTIALS_MINTED "$TV_MINTED"
else
  bad "Cloudflare — /accounts/{id}/tokens/verify did not return an active token (status '${TV_STATUS:-none}')"; why
fi
ZID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "$CFAPI/zones?name=$CLIENT_DOMAIN" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r[0]["id"] if r else "")')
if [ -z "$ZID" ]; then
  bad "Cloudflare — zone $CLIENT_DOMAIN not visible to this token"
else
  RID=$(curl -s -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
    -d "{\"type\":\"TXT\",\"name\":\"_pack-probe-$STAMP.$CLIENT_DOMAIN\",\"content\":\"probe\",\"ttl\":60}" \
    "$CFAPI/zones/$ZID/dns_records" | python3 -c 'import json,sys;r=json.load(sys.stdin);print(r["result"]["id"] if r.get("success") else "")')
  if [ -n "$RID" ] && curl -sf -X DELETE -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
       "$CFAPI/zones/$ZID/dns_records/$RID" >/dev/null; then
    ok "Cloudflare — TXT record create/delete on live zone $CLIENT_DOMAIN"
  else
    bad "Cloudflare — DNS write on zone $CLIENT_DOMAIN"
  fi
fi

# ── GitHub: org visible + private repo create/delete via the machine PAT ────
GH="https://api.github.com"
AUTH=(-H "Authorization: Bearer $GITHUB_PAT" -H "Accept: application/vnd.github+json")
if ! curl -sf "${AUTH[@]}" "$GH/orgs/$GITHUB_ORG" >/dev/null; then
  bad "GitHub — org $GITHUB_ORG not reachable with this PAT (slug wrong, or org PAT policy not set)"
else
  R="$CLIENT_CODE-pack-probe-$STAMP"
  if curl -sf "${AUTH[@]}" -d "{\"name\":\"$R\",\"private\":true}" "$GH/orgs/$GITHUB_ORG/repos" >/dev/null; then
    # Issues RW joined the §4 permission set 2026-08 (field-found: the terminals work the
    # tracker, not just the code) — prove it with a real issue; it dies with the repo.
    if curl -sf "${AUTH[@]}" -d '{"title":"pack probe — deleted with this repo"}' \
         "$GH/repos/$GITHUB_ORG/$R/issues" >/dev/null; then
      ok "GitHub — issue created in the probe repo (Issues RW proven)"
    else
      bad "GitHub — issue create REFUSED (PAT minted before Issues RW joined §4 — edit the token: add Issues RW)"
    fi
    if curl -sf -X DELETE "${AUTH[@]}" "$GH/repos/$GITHUB_ORG/$R" \
       && [ "$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$GH/repos/$GITHUB_ORG/$R")" = 404 ]; then
      ok "GitHub — private repo create/delete in $GITHUB_ORG (deletion confirmed 404)"
    else
      bad "GitHub — repo delete in $GITHUB_ORG ($R may remain — delete by hand)"
      curl -s -X DELETE "${AUTH[@]}" "$GH/repos/$GITHUB_ORG/$R" >/dev/null 2>&1 || true
    fi
  else
    bad "GitHub — repo create in $GITHUB_ORG (PAT needs Contents+Administration RW)"
  fi
fi

# ── Wasabi: bucket + object round-trip, then restic init (exercises the CCT
#    passphrase — the one credential a ping can't verify) ────────────────────
if ! command -v restic >/dev/null 2>&1; then
  echo "  (installing restic — needed for the passphrase probe and this terminal's own backups; log it in os-changes)"
  sudo -n apt-get install -y restic >/dev/null 2>&1 || true
fi
B="$CLIENT_CODE-pack-probe-$STAMP"
WEP="https://s3.$WASABI_REGION.wasabisys.com"
py_s3() { uv run --quiet --with boto3 python3 - 2>"$ERR"; }
if py_s3 <<PYEOF
import boto3,os,sys
s3=boto3.client("s3",endpoint_url="$WEP",aws_access_key_id="$WASABI_ACCESS_KEY",aws_secret_access_key="$WASABI_SECRET_KEY")
s3.create_bucket(Bucket="$B")
s3.put_object(Bucket="$B",Key="probe.txt",Body=b"probe")
assert s3.get_object(Bucket="$B",Key="probe.txt")["Body"].read()==b"probe"
PYEOF
then
  ok "Wasabi — bucket + object round-trip ($B)"
  if command -v restic >/dev/null 2>&1 \
     && AWS_ACCESS_KEY_ID="$WASABI_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$WASABI_SECRET_KEY" \
        RESTIC_PASSWORD="$RESTIC_PASSWORD_CCT" restic -q init --repo "s3:$WEP/$B/probe-repo" >/dev/null 2>"$ERR"; then
    ok "restic — repo init with RESTIC_PASSWORD_CCT (passphrase exercised for real)"
  else
    bad "restic — init with RESTIC_PASSWORD_CCT (restic missing, or keys/passphrase problem)"; why
  fi
  # Cleanup: empty via the paginator (restic init leaves >1 key), then delete the bucket
  # with a short retry — object deletion is eventually consistent, and an immediate
  # delete_bucket can race it into a spurious BucketNotEmpty on an otherwise green run.
  py_s3 <<PYEOF || { bad "Wasabi — probe bucket cleanup ($B still exists — delete by hand)"; why; }
import boto3,time
s3=boto3.client("s3",endpoint_url="$WEP",aws_access_key_id="$WASABI_ACCESS_KEY",aws_secret_access_key="$WASABI_SECRET_KEY")
for page in s3.get_paginator("list_objects_v2").paginate(Bucket="$B"):
    for o in page.get("Contents",[]): s3.delete_object(Bucket="$B",Key=o["Key"])
for i in range(6):
    try:
        s3.delete_bucket(Bucket="$B"); break
    except Exception:
        if i==5: raise
        time.sleep(2*(i+1))
PYEOF
else
  bad "Wasabi — bucket/object round-trip (keys, region $WASABI_REGION, or uv/boto3 missing)"; why
fi

# ── Healthchecks: check lifecycle + the RO key must be REFUSED a write ──────
HCAPI="https://healthchecks.io/api/v3"
CU=$(curl -s -X POST -H "X-Api-Key: $HEALTHCHECKS_API_KEY" -d "{\"name\":\"pack-probe-$STAMP\"}" \
  "$HCAPI/checks/" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("update_url",""))' 2>/dev/null)
if [ -n "$CU" ] && curl -sf -X DELETE -H "X-Api-Key: $HEALTHCHECKS_API_KEY" "${CU/update/}" >/dev/null 2>&1; then
  ok "Healthchecks — check create/delete with the management key"
else
  bad "Healthchecks — check lifecycle with the management key"
fi
# The playbook binds TWO pre-created email integrations (client contact + operator alerts
# mailbox) to every check; channels cannot be API-created, so their absence is an
# accounts-pass gap the build cannot close — surface it here, before the build asks.
NCH=$(curl -s -m 15 -H "X-Api-Key: $HEALTHCHECKS_API_KEY" "$HCAPI/channels/" \
  | python3 -c 'import json,sys;print(sum(1 for c in json.load(sys.stdin).get("channels",[]) if c.get("kind")=="email"))' 2>>"$ERR")
if [ "${NCH:-0}" -ge 2 ] 2>/dev/null; then
  ok "Healthchecks — $NCH email integrations exist (client contact + operator alerts)"
else
  bad "Healthchecks — only ${NCH:-0} email integration(s); the accounts pass creates TWO (CLIENT_ALERT_EMAILS + ADNET_ALERTS_MAILBOX) — channels cannot be API-created"; why
fi
ROC=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Api-Key: $HEALTHCHECK_READONLY_API_KEY" \
  -d '{"name":"must-fail"}' "$HCAPI/checks/")
if [ "$ROC" = 401 ] || [ "$ROC" = 403 ]; then
  ok "Healthchecks — read-only key correctly REFUSED a write (HTTP $ROC)"
else
  bad "Healthchecks — read-only key was NOT refused a write (HTTP $ROC) — wrong key staged?"
fi

echo ""
echo "verdict: $PASS pass · $FAIL fail — $(date -I), probes cleaned up"
exit "$((FAIL>0))"
