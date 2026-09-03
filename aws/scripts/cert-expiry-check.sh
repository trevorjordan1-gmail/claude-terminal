#!/bin/bash
# How close is the control plane's TLS cert to expiry? Prints ONE line and pings
# Healthchecks. Runs daily on the CP (asp-cert-check.timer, installed by cp-tls.sh).
#
# This deliberately checks the CERT, not the renewal run. Renewal can fail for reasons a
# failed-unit alarm never sees: the timer disabled, the lineage missing (a hand-placed cert
# has no renewal conf at all — the #26 field case), a deploy hook broken, or the Cloudflare
# token's IP allowlist not covering this box so DNS-01 fails. Days-to-expiry catches every
# one of them with a single signal — PLATFORM-BUILD §5's rule: alert on staleness, not only
# on error.
#
# Certbot renews at 30 days remaining, so anything under WARN_DAYS (21) means at least one
# renewal window has already passed without success. That is the alert worth having: it
# fires with ~3 weeks of runway, not on the morning of the outage.
set -uo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
[ -r /etc/asp-terminal.env ] && . /etc/asp-terminal.env
# shellcheck source=/dev/null  # written by cp-tls.sh
[ -r /etc/asp-cert.env ] && . /etc/asp-cert.env

WARN_DAYS="${1:-${ASP_CERT_WARN_DAYS:-21}}"
CERT="/etc/letsencrypt/live/${ASP_PORTAL_HOST:-unset}/cert.pem"

# A failed ping must never be the reason this reports a problem.
ping_hc() { [ -n "${CERT_HEALTHCHECK_URL:-}" ] && curl -fsS -m 10 --retry 3 "${CERT_HEALTHCHECK_URL}$1" >/dev/null 2>&1 || true; }

if [ ! -r "$CERT" ]; then
  echo "MISSING — no readable cert at $CERT"; ping_hc /fail; exit 2
fi
if ! END=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2); then
  echo "MISSING — $CERT is unreadable as a certificate"; ping_hc /fail; exit 2
fi
LEFT=$(( ( $(date -d "$END" +%s) - $(date +%s) ) / 86400 ))

# No renewal lineage means nothing will ever renew this, however many days are left --
# the exact shape of the #26 field failure, where a healthy-looking cert was a dead end.
LINEAGE="/etc/letsencrypt/renewal/${ASP_PORTAL_HOST:-unset}.conf"
if [ ! -s "$LINEAGE" ]; then
  echo "UNMANAGED — ${LEFT}d left but no renewal lineage at $LINEAGE; nothing will renew it"
  ping_hc /fail; exit 1
fi

if [ "$LEFT" -lt "$WARN_DAYS" ]; then
  echo "EXPIRING — ${LEFT}d left (renewal should have run by 30d; check certbot.timer, the deploy hook, and the Cloudflare token's IP allowlist for this box's egress)"
  ping_hc /fail; exit 1
fi
echo "OK — ${LEFT}d left, renewal lineage present"
ping_hc ""
