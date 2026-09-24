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
#      certbot holds one lock per box and certbot.timer fires twice a day at a random
#      offset (#52): a collision is retried for ~CP_VERIFY_LOCK_WAIT×4 s, then reported as
#      SKIP (certbot busy) — never as the allowlist FAIL, which sends someone into Cloudflare.
#   3. the egress IP the allowlist must contain (informational)
#   4. the expiry alarm's own verdict + its timer (cert-expiry-check.sh pings Healthchecks
#      exactly as the daily timer would — the state it reports is the true state), and
#      whether it has a ping URL at all (#50 — an alarm with nowhere to report is mute)
#      4c. the BACKUP alarms have a key too (#53): backup-arm.sh runs on every terminal, not
#      here, so this is the tenant-level view — backups enabled (/asp/backup/config exists)
#      and a Healthchecks key somewhere backup-arm.sh looks. Key values are never printed.
#   5. the portal answers /healthz, and with which release
#   6. /etc/asp-portal.env sources safely (#38 — a bare value with a space was a prefix
#      assignment when sourced). portal-deploy.sh writes through shlex.quote, which leaves a
#      value BARE when it needs no quoting (#51), so the test is "bare AND carries a character
#      a shell would act on", not "has quote marks".
#   7. solo tenant only (ASP_SOLO=1, #64): forwarding for the private subnets is on and
#      survives a boot, zram + swap are active, and free memory is not in thrash territory
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
  # The lock is certbot's own (fcntl on /var/lib/letsencrypt/.certbot.lock — not testable with
  # flock from here), so the probe is the run itself: its "Another instance" line is the
  # signal. Up to 4 tries, CP_VERIFY_LOCK_WAIT s apart (default 15; the harness sets 0).
  BUSY=0; DRY=1
  for _try in 1 2 3 4; do
    if OUT=$(certbot renew --dry-run --cert-name "$HOST" 2>&1); then DRY=0; BUSY=0; break; fi
    if printf '%s\n' "$OUT" | grep -qi 'another instance of certbot is already running'; then
      BUSY=1; sleep "${CP_VERIFY_LOCK_WAIT:-15}"; continue
    fi
    BUSY=0; break
  done
  if [ "$DRY" -eq 0 ]; then
    ok "renewal dry-run succeeded — DNS-01 ran from this box, so the Cloudflare token's IP allowlist covers this egress"
  elif [ "$BUSY" -eq 1 ]; then
    skip "renewal dry-run not run — certbot busy (its own certbot.timer, or another verify, holds the lock); re-run rollout.sh verify in a minute (#52)"
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

# ── 4b. the alarm has somewhere to report (#50) ─────────────────────────────────────────
# shellcheck source=/dev/null  # written by cp-tls.sh
HCU=$( [ -r /etc/asp-cert.env ] && . /etc/asp-cert.env; printf '%s' "${CERT_HEALTHCHECK_URL:-}" )
if [ -n "$HCU" ]; then
  ok "expiry alarm pings Healthchecks (CERT_HEALTHCHECK_URL set in /etc/asp-cert.env)"
else
  bad "expiry alarm is MUTE — armed with no ping URL, it only writes to a journal nobody reads: put SSM SecureString /asp/healthchecks/api-key (build-tenant §4), rollout.sh cp, re-run cp-tls.sh (#50)"
fi

# ── 4c. the backup alarms have a key to register with (#53) ────────────────────────────
# One key, every alarm: /asp/healthchecks/api-key (what cp-tls.sh reads) is the standard;
# HEALTHCHECKS_API_KEY inside /asp/backup/config is the pre-#53 place and still works.
# Neither value is echoed — this report lands in the SSM command log.
R=(); [ -n "${ASP_REGION:-}" ] && R=(--region "$ASP_REGION")
if ! command -v aws >/dev/null 2>&1; then
  skip "backup alarm — aws CLI unavailable here; cannot read the tenant's SSM parameters"
elif ! BC=$(aws ssm get-parameter "${R[@]}" --name /asp/backup/config --with-decryption --query Parameter.Value --output text 2>/dev/null) \
     || [ -z "$BC" ] || [ "$BC" = None ]; then
  skip "backup alarm — no /asp/backup/config in this tenant (backups not enabled; nothing to alarm)"
else
  TK=$(aws ssm get-parameter "${R[@]}" --name /asp/healthchecks/api-key --with-decryption --query Parameter.Value --output text 2>/dev/null) || TK=""
  [ "$TK" = None ] && TK=""
  CK=$(printf '%s' "$BC" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("HEALTHCHECKS_API_KEY",""))' 2>/dev/null)
  if [ -n "$TK" ]; then
    ok "backup alarm — terminals mint their check with /asp/healthchecks/api-key (one key, every alarm — #53)"
  elif [ -n "$CK" ]; then
    ok "backup alarm — terminals mint their check with the legacy HEALTHCHECKS_API_KEY in /asp/backup/config (works; /asp/healthchecks/api-key is the standard, #53)"
  else
    bad "backup alarm is MUTE on every terminal — backups enabled but no Healthchecks key anywhere: put SSM SecureString /asp/healthchecks/api-key (build-tenant §4); terminals re-arm on their next auto-update (#53)"
  fi
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
  # A value is safe when it is built only from: '…' segments (sq() / shlex when quoting was
  # needed), an escaped apostrophe \' (sq()'s splice: 'Bob'\''s'), a "…" segment with no
  # $ ` or \ inside (shlex's splice: 'Bob'"'"'s' — no expansion possible), and bare characters
  # from shlex's safe set [A-Za-z0-9_@%+=:,./-] — exactly what shlex.quote leaves bare.
  # Anything else (space, $, backtick, ;, &, |, <, >, *, ?, a stray quote…) is a value the
  # shell would act on when the file is sourced. KEY= (empty) is safe.
  BADL=$(grep -vE '^[[:space:]]*(#|$)' /etc/asp-portal.env \
    | grep -vE "^[A-Za-z_][A-Za-z0-9_]*=('[^']*'|\\\\'|\"[^\"\$\`\\\\]*\"|[A-Za-z0-9_@%+=:,./-])*$" | cut -d= -f1 | tr '\n' ' ')
  if [ -z "$BADL" ]; then
    ok "/etc/asp-portal.env — sources safely: every value quoted or shell-safe bare (#38, #51)"
  else
    bad "/etc/asp-portal.env — bare value(s) a shell would act on when sourced: ${BADL% } — re-run portal-deploy.sh (#38 quotes them; a value still listed after that was edited by hand)"
  fi
else
  skip "/etc/asp-portal.env absent — portal not deployed here"
fi
# ---- 7. solo tenant (#64): this box is the NAT and runs on a 512 MB-1 GB instance ----
if [ "${ASP_SOLO:-0}" = "1" ]; then
  echo; echo "solo control plane (#64)"
  if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then ok "ip_forward=1 (terminals' egress runs through this box)"; else bad "ip_forward is off — terminals have no egress; systemctl start asp-solo-nat"; fi
  if nft list chain ip asp-nat postrouting 2>/dev/null | grep -q masquerade; then ok "nft masquerade rule present"; else bad "no masquerade rule in nft table asp-nat — run /opt/asp/solo-nat.sh"; fi
  if systemctl is-enabled asp-solo-nat.service >/dev/null 2>&1; then ok "asp-solo-nat.service enabled (re-applies at boot)"; else bad "asp-solo-nat.service not enabled — forwarding dies at next boot"; fi
  if grep -q zram /proc/swaps 2>/dev/null; then ok "zram swap active"; else bad "no zram swap — the broker's cold pages have nowhere cheap to go; systemctl start zramswap"; fi
  if grep -q '^/swapfile' /proc/swaps 2>/dev/null; then ok "disk swapfile active (overflow)"; else bad "/swapfile not active"; fi
  AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null); SWAPUSED=$(free -m 2>/dev/null | awk '/Swap:/{print $3}')
  if [ -n "$AVAIL" ] && [ "$AVAIL" -lt 48 ]; then bad "MemAvailable ${AVAIL} MB (< 48) — thrash territory; set control_plane_type = t4g.micro"; else ok "MemAvailable ${AVAIL:-?} MB, swap used ${SWAPUSED:-?} MB (informational: steady state after 24 h is the number that matters)"; fi
  if [ -f /proc/pressure/memory ]; then echo "  memory pressure: $(head -1 /proc/pressure/memory)"; fi
fi

verdict
