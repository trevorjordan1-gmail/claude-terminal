#!/usr/bin/env bash
# Field-proven device-code flow for New-ClientSSO.ps1 -UseEnvToken (see FINDINGS.md).
# Mints via the az-cli first-party client (present in fresh tenants, unlike Graph CLI
# Tools) with .default scopes (explicit admin scopes trip AADSTS65002), TENANT-PINNED
# (common/organizations degrade to AADSTS50059 after repeated mints). 15-min window.
# Usage: get-graph-token-devicecode.sh <tenant-id-or-domain>   → exports nothing; prints
# the user code on fd2, writes the token to stdout when the admin completes sign-in.
set -euo pipefail
TENANT="${1:?usage: get-graph-token-devicecode.sh <tenant>}"
AZCLI=04b07795-8ddb-461a-bbee-02f9e1bf7b46
r=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/devicecode" \
  -d "client_id=$AZCLI" --data-urlencode "scope=https://graph.microsoft.com/.default offline_access openid profile")
dc=$(echo "$r" | jq -r '.device_code // empty'); [ -n "$dc" ] || { echo "$r" >&2; exit 1; }
echo "USER CODE: $(echo "$r" | jq -r .user_code) at https://microsoft.com/devicelogin ($(echo "$r" | jq -r .expires_in)s)" >&2
deadline=$(( $(date +%s) + $(echo "$r" | jq -r .expires_in) ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  t=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" -d "client_id=$AZCLI" -d "device_code=$dc")
  case "$(echo "$t" | jq -r '.error // empty')" in
    "") echo "$t" | jq -r .access_token; exit 0 ;;
    authorization_pending|slow_down) sleep 6 ;;
    *) echo "$t" | jq -r .error_description >&2; exit 1 ;;
  esac
done
echo "device code expired unused" >&2; exit 1
