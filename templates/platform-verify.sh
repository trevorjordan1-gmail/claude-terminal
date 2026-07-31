#!/usr/bin/env bash
# platform-verify.sh — the stage-4 checks-and-balances battery.
#
# Run from ~/Projects/<domain>/ AFTER PLATFORM-BUILD. Re-proves the platform from the
# outside in and writes PLATFORM-VERIFICATION.md (summary + raw evidence) for the
# engineer to review — the human gate on "platform build verified."
#
# Degrades honestly: a check it cannot run is reported SKIP with the reason, never PASS.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
[ -f .env ] || { echo "No ./.env — run from the platform folder."; exit 1; }
set -a; . ./.env; set +a

DOMAIN="${CLIENT_DOMAIN:?CLIENT_DOMAIN missing from .env}"
CODE="${CLIENT_CODE:?CLIENT_CODE missing from .env}"
REPORT="PLATFORM-VERIFICATION.md"
PASS=0; FAIL=0; SKIP=0
declare -a LINES

say() { LINES+=("$1"); echo "$1"; }
result() { # $1 PASS|FAIL|SKIP, $2 name, $3 evidence
  case "$1" in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; esac
  say "- **$1** — $2"
  [ -n "${3:-}" ] && say "  \`$3\`"
}

# ── locate the droplet ──────────────────────────────────────────────────────
IP=""
if command -v doctl >/dev/null 2>&1; then
  IP=$(doctl compute droplet list -t "$DO_API_KEY" --format Name,PublicIPv4 --no-header 2>/dev/null \
       | awk -v n="docker01.$DOMAIN" '$1==n{print $2}')
fi
[ -n "$IP" ] || IP="${DROPLET_IP:-}"
SSH_TARGET="${DROPLET_SSH:-$CODE@$IP}"
ssh_run() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "$1" 2>/dev/null; }

say "# Platform verification — $DOMAIN"
say ""
say "_$(date -Is) · from $(hostname -s) (egress $(curl -s --max-time 5 ifconfig.me || echo '?'))_"
say ""

# ── 1 · attack surface ──────────────────────────────────────────────────────
say "## 1 · Attack surface"
if [ -n "$IP" ]; then
  for p in 80 443 8080 5432; do
    if timeout 5 bash -c "exec 3<>/dev/tcp/$IP/$p" 2>/dev/null; then
      result FAIL "port $p on $IP is REACHABLE (must be filtered)" ""
    else
      result PASS "port $p on $IP filtered/closed" ""
    fi
  done
  if timeout 5 bash -c "exec 3<>/dev/tcp/$IP/22" 2>/dev/null; then
    result PASS "port 22 reachable from THIS build box (the one allowed source)" ""
  else
    result FAIL "port 22 unreachable from the allowed source" ""
  fi
  LISTEN=$(ssh_run "ss -tln '! src 127.0.0.0/8' '! src [::1]' | tail -n +2")
  if [ -n "$LISTEN" ] && ! echo "$LISTEN" | grep -vq ':22 '; then
    result PASS "host listens on :22 only (non-loopback)" ""
  else
    result "$([ -z "$LISTEN" ] && echo SKIP || echo FAIL)" "host listening sockets" "$(echo "$LISTEN" | tr '\n' ' | ')"
  fi
  PORTS=$(ssh_run 'for c in $(docker ps -q); do docker port "$c"; done')
  [ -z "$PORTS" ] && result PASS "no container publishes a host port" "" \
                  || result FAIL "published container ports found" "$PORTS"
else
  result SKIP "port scan — droplet IP not found (doctl/DROPLET_IP)" ""
fi
say "> Note: 80/443 have no firewall rule at all, so they time out from every vantage."
say "> A second-vantage scan (phone hotspot) makes this stronger — record it if run."

# ── 2 · edge + Access ───────────────────────────────────────────────────────
say "## 2 · Edge + Access"
HTTPCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://status.$DOMAIN" || echo 000)
case "$HTTPCODE" in
  200) result FAIL "status.$DOMAIN answered 200 UNAUTHENTICATED — Access is not gating" "" ;;
  30[0-9]|40[13]) result PASS "status.$DOMAIN challenges unauthenticated requests (HTTP $HTTPCODE)" "" ;;
  000) result FAIL "status.$DOMAIN unreachable" "" ;;
  *) result FAIL "status.$DOMAIN unexpected HTTP $HTTPCODE" "" ;;
esac
TUN=$(curl -s --max-time 15 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel?is_deleted=false" \
  | python3 -c 'import json,sys;ts=json.load(sys.stdin).get("result") or [];print(";".join(f"{t[\"name\"]}={t[\"status\"]}" for t in ts))' 2>/dev/null)
echo "$TUN" | grep -q "healthy" && result PASS "tunnel healthy" "$TUN" \
  || result FAIL "tunnel not healthy" "${TUN:-no API answer}"

# ── 3 · database isolation ──────────────────────────────────────────────────
say "## 3 · Database isolation"
ISO=$(ssh_run "cd /opt/$CODE/postgres && sudo -n ./db-verify-isolation.sh" | tail -3)
echo "$ISO" | grep -qiE 'pass|9/9' && result PASS "isolation walls proven" "$(echo "$ISO" | tail -1)" \
  || result "$([ -z "$ISO" ] && echo SKIP || echo FAIL)" "db-verify-isolation" "${ISO:-unreachable}"

# ── 4 · monitoring ──────────────────────────────────────────────────────────
say "## 4 · Monitoring"
HC=$(curl -s --max-time 15 -H "X-Api-Key: $HEALTHCHECKS_API_KEY" https://healthchecks.io/api/v3/checks/ \
  | python3 -c 'import json,sys;cs=json.load(sys.stdin).get("checks") or [];print(f"{len(cs)} checks: "+", ".join(sorted(set(c["status"] for c in cs))))' 2>/dev/null)
echo "$HC" | grep -qE 'checks: up$' && result PASS "all Healthchecks up" "$HC" \
  || result "$([ -z "$HC" ] && echo SKIP || echo FAIL)" "Healthchecks state" "${HC:-no API answer}"
say "> The silent-alarm + backup-failure drills are one-time build proofs — their dates"
say "> live in STATE.md; this battery checks the steady state."

# ── 5 · backups ─────────────────────────────────────────────────────────────
say "## 5 · Backups"
SNAP=$(ssh_run "sudo -n /opt/$CODE/backup/restic-snapshots-age.sh 2>/dev/null || echo none")
case "$SNAP" in
  none|"") result SKIP "droplet restic snapshot age (helper missing)" "" ;;
  *) echo "$SNAP" | grep -qE 'FRESH' && result PASS "droplet restic snapshot fresh (<26h)" "$SNAP" \
       || result FAIL "droplet restic snapshot stale" "$SNAP" ;;
esac

# ── 6 · nothing lingers ─────────────────────────────────────────────────────
say "## 6 · Workspace"
if bash scripts/workspace-status.sh >/dev/null 2>&1; then
  result PASS "workspace clean (nothing uncommitted/unpushed/red)" ""
else
  result FAIL "workspace-status found lingering work — resolve before sign-off" ""
fi

# ── report ──────────────────────────────────────────────────────────────────
say ""
say "## Verdict: $PASS pass · $FAIL fail · $SKIP skip"
say ""
say "_Engineer sign-off: review every FAIL/SKIP above; stage 4 is 'verified' only when_"
say "_this section is all-PASS or each SKIP has a recorded reason in STATE.md._"
printf '%s\n' "${LINES[@]}" > "$REPORT"
echo ""
echo "Report written: $REPORT"
[ "$FAIL" -eq 0 ] || exit 1
