#!/bin/bash
# cp-verify.sh — read-only health report for a control plane (#27). Prints paste-ready
# PASS/FAIL/SKIP lines and a verdict; exit 1 if anything FAILs. Runs on the CP itself,
# normally via `rollout.sh verify` (SSM) from the operator box, or by hand:
#   sudo bash /opt/asp/cp-verify.sh
#
# What it answers, in order of consequence:
#   1. would cp-tls.sh (re)issue on its next run?  — the same lineage/live/SAN ladder
#      cp-tls.sh uses, evaluated WITHOUT running it (steady state = no certbot call)
#   2. does renewal work FROM THIS BOX?  — `certbot renew --dry-run` performs a real DNS-01
#      challenge with the Cloudflare token, so a green dry-run IS the proof that the
#      token's IP allowlist covers this box's egress (the CP uses its own EIP, not the
#      NAT's). Dry-run touches Let's Encrypt staging only; the live cert is never changed.
#   3. the egress IP the allowlist must contain (informational)
#   4. the expiry alarm's own verdict + its timer (cert-expiry-check.sh pings Healthchecks
#      exactly as the daily timer would — the state it reports is the true state)
#   5. the portal answers /healthz, and with which release
#   6. /etc/asp-portal.env values are single-quoted (#38 — a bare value with a space was a
#      prefix assignment when sourced)
set -uo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
[ -r /etc/asp-terminal.env ] && . /etc/asp-terminal.env
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "- PASS — $1"; return 0; }
bad()  { FAIL=$((FAIL+1)); echo "- FAIL — $1"; return 0; }
skip() { SKIP=$((SKIP+1)); echo "- SKIP — $1"; return 0; }
verdict() { echo; echo "verdict: $PASS pass · $FAIL fail · $SKIP skip — $(hostname) $(date -Is)"; exit "$((FAIL>0))"; }

HOST="${ASP_PORTAL_HOST:-}"
[ -n "$HOST" ] || { bad "ASP_PORTAL_HOST missing from /etc/asp-terminal.env — is this a control plane?"; verdict; }
CERT_DIR="/etc/letsencrypt/live/$HOST"
RENEWAL_CONF="/etc/letsencrypt/renewal/$HOST.conf"
WILDCARD="*.${HOST#*.}"

# ── 1. cp-tls steady state (mirror of cp-tls.sh's NEED ladder, read-only) ──────────────
NEED=""
if [ ! -s "$RENEWAL_CONF" ]; then
  NEED="no certbot lineage — nothing would ever renew this cert"
elif [ ! -d "$CERT_DIR" ]; then
  NEED="lineage exists but $CERT_DIR is missing"
elif ! openssl x509 -in "$CERT_DIR/cert.pem" -noout -text 2>/dev/null | grep -qF "DNS:$WILDCARD"; then
  NEED="cert carries no $WILDCARD SAN (pre-vanity tenant)"
fi
if [ -z "$NEED" ]; then
  ok "cp-tls steady state — lineage, live dir and $WILDCARD SAN present; a cp-tls.sh re-run makes no certbot call"
else
  bad "cp-tls would (re)issue on its next run — $NEED"
fi

# ── 2. renewal dry-run = the Cloudflare allowlist test ─────────────────────────────────
if [ -s "$RENEWAL_CONF" ]; then
  if OUT=$(certbot renew --dry-run --cert-name "$HOST" 2>&1); then
    ok "renewal dry-run succeeded — DNS-01 ran from this box, so the Cloudflare token's IP allowlist covers this egress"
  else
    bad "renewal dry-run FAILED — check the Cloudflare token's IP allowlist against the egress below, then certbot.timer and the deploy hook"
    echo "  ↳ $(printf '%s\n' "$OUT" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-220)"
  fi
else
  skip "renewal dry-run — no lineage to renew (fix the line above first: re-run cp-tls.sh)"
fi

# ── 3. egress ───────────────────────────────────────────────────────────────────────────
EG=$(curl -fsS -m 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
echo "  (egress IP: ${EG:-unknown} — the address the Cloudflare token's allowlist must contain)"

# ── 4. expiry alarm + timer ─────────────────────────────────────────────────────────────
if [ -x /opt/asp/cert-expiry-check.sh ]; then
  L=$(/opt/asp/cert-expiry-check.sh 2>/dev/null | head -n 1)
  case "$L" in
    OK*) ok "cert expiry — $L" ;;
    *)   bad "cert expiry — ${L:-no output from cert-expiry-check.sh}" ;;
  esac
else
  bad "/opt/asp/cert-expiry-check.sh missing — cp-tls.sh installs it (#38); rollout.sh scripts, then re-run cp-tls.sh"
fi
if systemctl is-active --quiet asp-cert-check.timer 2>/dev/null; then
  ok "asp-cert-check.timer active (daily expiry check)"
else
  bad "asp-cert-check.timer not active — re-run cp-tls.sh (it installs and enables the timer)"
fi

# ── 5. portal ───────────────────────────────────────────────────────────────────────────
H=$(curl -fsS -m 10 http://127.0.0.1:8080/healthz 2>/dev/null || true)
V=$(printf '%s' "$H" | grep -oE '"version":"[^"]*"' | cut -d'"' -f4)
if [ -n "$V" ]; then
  ok "portal /healthz answers — release $V"
else
  bad "portal /healthz unreachable on 127.0.0.1:8080 (portal-deploy.sh, or the service is down)"
fi

# ── 6. portal env quoting (#38) ─────────────────────────────────────────────────────────
if [ -r /etc/asp-portal.env ]; then
  BADL=$(grep -vE '^[[:space:]]*(#|$)' /etc/asp-portal.env | grep -vE "^[A-Za-z_][A-Za-z0-9_]*='.*'$" | cut -d= -f1 | tr '\n' ' ')
  if [ -z "$BADL" ]; then
    ok "/etc/asp-portal.env — every value single-quoted (#38)"
  else
    bad "/etc/asp-portal.env — unquoted value(s): ${BADL% }— re-run portal-deploy.sh (#38 quotes them)"
  fi
else
  skip "/etc/asp-portal.env absent — portal not deployed here"
fi
verdict
