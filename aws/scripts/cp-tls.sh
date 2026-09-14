#!/bin/bash
# Issue/renew Let's Encrypt certs for portal + gateway via Cloudflare DNS-01.
# Requires SSM SecureString /asp/cloudflare/token (zone-scoped DNS-edit token).
# Re-runnable via SSM. (Client tenants on other DNS: swap the certbot plugin.)
set -uxo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env

CERT_DIR="/etc/letsencrypt/live/$ASP_PORTAL_HOST"

apt-get install -y --no-install-recommends python3-certbot-dns-cloudflare >/dev/null

# certbot credentials file from SSM (never in git / user-data).
# The control plane runs this at first boot, BEFORE /asp/cloudflare/token can exist on a
# fresh tenant (runbook §4 comes after the apply). An absent parameter used to be cached as
# an EMPTY token, and every later run then skipped the fetch and failed inside certbot with
# "Either dns_cloudflare_api_token ... are required" — two layers away from the cause (#38).
# So: a cached file only counts if it actually carries a token, and a missing/empty
# parameter is FATAL here, by name, with the fix.
INI=/root/.secrets/cloudflare.ini
if ! grep -qE '^dns_cloudflare_api_token = .+' "$INI" 2>/dev/null; then
  mkdir -p /root/.secrets && chmod 700 /root/.secrets
  set +x   # the token must not land in the SSM command log via xtrace
  TOKEN=$(aws ssm get-parameter --region "$ASP_REGION" --name /asp/cloudflare/token \
    --with-decryption --query Parameter.Value --output text 2>/dev/null) || TOKEN=""
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ]; then
    echo "cp-tls: FATAL — SSM parameter /asp/cloudflare/token is missing or empty; create it (runbook §4," >&2
    echo "        account-foundations.md §7) and re-run cp-tls.sh via SSM. Nothing was cached." >&2
    rm -f "$INI"
    exit 1
  fi
  ( umask 077 && printf 'dns_cloudflare_api_token = %s\n' "$TOKEN" > "$INI" )
  set -x
fi

# ONE wildcard covers portal, gw AND every per-terminal vanity alias: the native
# DCV client titles its window by connect host (the .dcv format has no title
# key), so the portal hands out <terminal>.<zone> names that all resolve to the
# gateway, and the title bar names the terminal instead of 'gw'.
#
# It must be requested ALONE. Boulder rejects an order that mixes *.<zone> with
# any name that wildcard already covers ("Domain name X is redundant with a
# wildcard domain in the same request") — and both ASP_PORTAL_HOST and
# ASP_GW_HOST live under <zone>. --cert-name pins the lineage so live/ and
# renewal/ paths stay stable no matter which names are on the cert.
WILDCARD="*.${ASP_PORTAL_HOST#*.}"
RENEWAL_CONF="/etc/letsencrypt/renewal/$ASP_PORTAL_HOST.conf"

# A cert DIRECTORY is not a managed cert. Found in the field: a hand-placed cert
# left plain files under live/ with no renewal/*.conf, so certbot would never
# touch it and expiry was a scheduled silent outage. The lineage is the real
# test — never `[ ! -d "$CERT_DIR" ]` alone.
NEED=""
if [ ! -s "$RENEWAL_CONF" ]; then
  NEED="no certbot lineage — nothing would ever renew this cert"
elif [ ! -d "$CERT_DIR" ]; then
  NEED="lineage exists but $CERT_DIR is missing"
elif ! openssl x509 -in "$CERT_DIR/cert.pem" -noout -text | grep -qF "DNS:$WILDCARD"; then
  NEED="cert carries no $WILDCARD SAN (pre-vanity tenant)"
fi

if [ -n "$NEED" ]; then
  echo "cp-tls: (re)issuing — $NEED"
  EXPAND=()
  if [ -s "$RENEWAL_CONF" ]; then
    EXPAND=(--expand)          # name set is changing on an existing lineage
  elif [ -d "$CERT_DIR" ]; then
    # an unmanaged live/ dir blocks a fresh lineage of the same name. The
    # gateway and nginx serve their own copies (deploy hook), so moving it
    # aside costs no downtime, and it stays on disk as a fallback.
    mv "$CERT_DIR" "$CERT_DIR.unmanaged.$(date +%s)"
  fi
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
    -d "$WILDCARD" --cert-name "$ASP_PORTAL_HOST" "${EXPAND[@]}" \
    --non-interactive --agree-tos -m "${ASP_CERT_EMAIL:?ASP_CERT_EMAIL missing from /etc/asp-terminal.env}" || exit 1
fi

# Deploy hook: give the gateway its own readable copy on issue/renew.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/asp-gateway.sh <<HOOK
#!/bin/bash
set -e
SRC="/etc/letsencrypt/live/$ASP_PORTAL_HOST"
DST="/etc/dcv-connection-gateway/certs"
mkdir -p "\$DST"
cp -L "\$SRC/fullchain.pem" "\$DST/cert.pem"
cp -L "\$SRC/privkey.pem"  "\$DST/key.pem"
GWUSER=\$(getent passwd | grep -oE '^dcv[a-z-]*gateway[a-z-]*|^dcvcgw' | head -1 | cut -d: -f1 || true)
[ -n "\$GWUSER" ] && chown -R "\$GWUSER" "\$DST"
chmod 600 "\$DST/key.pem"
systemctl try-restart dcv-connection-gateway 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/asp-gateway.sh
/etc/letsencrypt/renewal-hooks/deploy/asp-gateway.sh

# ---- expiry alarm ------------------------------------------------------------------
# Renewals now exist, which means they can now fail -- and the failure is silent by
# construction: everything keeps working until the morning it does not. #30 was the same
# shape on the backup side (snapshots fine, nobody told). Alert on staleness, not on error.
HC_URL="${CERT_HEALTHCHECK_URL:-${ASP_CERT_HC_URL:-}}"
if [ -z "$HC_URL" ] && [ -n "${HEALTHCHECKS_API_KEY:-}" ]; then
  HC_URL=$(curl -fsS -m 15 -X POST -H "X-Api-Key: $HEALTHCHECKS_API_KEY" \
    -d "{\"name\":\"cert-${ASP_CUSTOMER:-cp}\",\"tags\":\"asp tls\",\"timeout\":86400,\"grace\":86400,\"unique\":[\"name\"]}" \
    "https://healthchecks.io/api/v3/checks/" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ping_url",""))' 2>/dev/null) || HC_URL=""
fi
if [ -z "$HC_URL" ] && [ -f /etc/asp-cert.env ]; then
  # shellcheck source=/dev/null  # the file this script wrote last time
  HC_URL=$(. /etc/asp-cert.env 2>/dev/null; printf '%s' "${CERT_HEALTHCHECK_URL:-}")
fi
( umask 077; printf "CERT_HEALTHCHECK_URL='%s'\n" "$HC_URL" > /etc/asp-cert.env )

# The checker is staged like every other script: from the tenant bucket. When this script
# itself runs from /opt/asp (the SSM pattern), "alongside" IS the destination — the old
# `install` onto itself failed and printed a false "not alongside" while the timer was
# armed and running (#38). Same-file → already in place; else bucket; else alongside; else say so.
SRC="$(dirname "$0")/cert-expiry-check.sh"; DST=/opt/asp/cert-expiry-check.sh
if [ -e "$SRC" ] && [ "$SRC" -ef "$DST" ]; then
  chmod 0755 "$DST"
elif aws s3 cp "s3://$ASP_BUCKET/scripts/cert-expiry-check.sh" "$DST" >/dev/null 2>&1; then
  chmod 0755 "$DST"
elif [ -e "$SRC" ]; then
  install -m 0755 "$SRC" "$DST"
elif [ ! -x "$DST" ]; then
  echo "cp-tls: cert-expiry-check.sh is neither in the bucket nor alongside this script — the expiry timer has nothing to run; rollout.sh scripts, then re-run" >&2
fi
cat > /etc/systemd/system/asp-cert-check.service <<'UNIT'
[Unit]
Description=Check how close the control-plane TLS cert is to expiry

[Service]
Type=oneshot
ExecStart=/opt/asp/cert-expiry-check.sh
UNIT
cat > /etc/systemd/system/asp-cert-check.timer <<'UNIT'
[Unit]
Description=Daily control-plane TLS expiry check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now asp-cert-check.timer >/dev/null 2>&1
if [ -n "$HC_URL" ]; then
  echo "cp-tls: expiry alarm armed (daily; pings Healthchecks)"
else
  echo "cp-tls: expiry alarm armed WITHOUT a ping — set HEALTHCHECKS_API_KEY or CERT_HEALTHCHECK_URL; it will only log locally" >&2
fi

echo "TLS ready"
