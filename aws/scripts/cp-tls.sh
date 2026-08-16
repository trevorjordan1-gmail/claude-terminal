#!/bin/bash
# Issue/renew Let's Encrypt certs for portal + gateway via Cloudflare DNS-01.
# Requires SSM SecureString /asp/cloudflare/token (zone-scoped DNS-edit token).
# Re-runnable via SSM. (Client tenants on other DNS: swap the certbot plugin.)
set -uxo pipefail
source /etc/asp-terminal.env

CERT_DIR="/etc/letsencrypt/live/$ASP_PORTAL_HOST"

apt-get install -y --no-install-recommends python3-certbot-dns-cloudflare >/dev/null

# certbot credentials file from SSM (never in git / user-data)
if [ ! -f /root/.secrets/cloudflare.ini ]; then
  mkdir -p /root/.secrets && chmod 700 /root/.secrets
  TOKEN=$(aws ssm get-parameter --region "$ASP_REGION" --name /asp/cloudflare/token \
    --with-decryption --query Parameter.Value --output text)
  ( umask 077 && printf 'dns_cloudflare_api_token = %s\n' "$TOKEN" > /root/.secrets/cloudflare.ini )
fi

if [ ! -d "$CERT_DIR" ]; then
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
    -d "$ASP_PORTAL_HOST" -d "$ASP_GW_HOST" \
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

echo "TLS ready"
