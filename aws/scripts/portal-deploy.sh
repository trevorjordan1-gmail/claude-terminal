#!/bin/bash
# Deploy/redeploy the portal from the artifacts bucket. Re-runnable via SSM.
# Config: /etc/asp-terminal.env (infra) + SSM params /asp/portal/{config,secrets}
#         + /etc/asp-broker-client.env (written by dcv-cp-install.sh).
set -uxo pipefail
source /etc/asp-terminal.env

# ---- code ----
aws s3 cp "s3://$ASP_BUCKET/portal/portal.zip" /tmp/portal.zip
rm -rf /opt/asp/portal
mkdir -p /opt/asp/portal
unzip -q /tmp/portal.zip -d /opt/asp/portal

python3 -m venv /opt/asp/portal-venv
/opt/asp/portal-venv/bin/pip install -q --upgrade pip
/opt/asp/portal-venv/bin/pip install -q -r /opt/asp/portal/requirements.txt

# ---- config ----
CONF=$(aws ssm get-parameter --region "$ASP_REGION" --name /asp/portal/config --query Parameter.Value --output text)
SECRETS=$(aws ssm get-parameter --region "$ASP_REGION" --name /asp/portal/secrets --with-decryption --query Parameter.Value --output text)

umask 077
{
  echo "ASP_PORTAL_HOST=$ASP_PORTAL_HOST"
  echo "ASP_GW_HOST=$ASP_GW_HOST"
  echo "ASP_REGION=$ASP_REGION"
  echo "ASP_CUSTOMER=$ASP_CUSTOMER"
  echo "ASP_BUCKET=$ASP_BUCKET"
  echo "ASP_BROKER_SHORT=$(hostname -s)"
  echo "$CONF"    | python3 -c 'import json,sys; [print(f"{k}={v}") for k,v in json.load(sys.stdin).items()]'
  echo "$SECRETS" | python3 -c 'import json,sys; [print(f"{k}={v}") for k,v in json.load(sys.stdin).items()]'
  [ -f /etc/asp-broker-client.env ] && cat /etc/asp-broker-client.env
} > /etc/asp-portal.env

# ---- systemd ----
cat > /etc/systemd/system/asp-portal.service <<'UNIT'
[Unit]
Description=AI Terminals portal
After=network.target

[Service]
WorkingDirectory=/opt/asp/portal
ExecStart=/opt/asp/portal-venv/bin/uvicorn app:app --host 127.0.0.1 --port 8080
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now asp-portal
systemctl restart asp-portal

# ---- idle watchdog (pauses idle terminals; see idle-watchdog.py) ----
aws s3 cp "s3://$ASP_BUCKET/scripts/idle-watchdog.py" /opt/asp/idle-watchdog.py
chmod +x /opt/asp/idle-watchdog.py
cat > /etc/systemd/system/asp-idle-watchdog.service <<'UNIT'
[Unit]
Description=ASP idle watchdog (pause idle terminals)

[Service]
Type=oneshot
ExecStart=/opt/asp/portal-venv/bin/python3 /opt/asp/idle-watchdog.py
UNIT
cat > /etc/systemd/system/asp-idle-watchdog.timer <<'UNIT'
[Unit]
Description=Run the ASP idle watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now asp-idle-watchdog.timer

# ---- nginx (TLS front) ----
if [ -d "/etc/letsencrypt/live/$ASP_PORTAL_HOST" ]; then
  cat > /etc/nginx/sites-available/asp-portal <<NGINX
server {
  listen 443 ssl;
  server_name $ASP_PORTAL_HOST;
  ssl_certificate     /etc/letsencrypt/live/$ASP_PORTAL_HOST/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$ASP_PORTAL_HOST/privkey.pem;
  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https;
  }
}
server {
  listen 80;
  server_name $ASP_PORTAL_HOST;
  return 301 https://\$host\$request_uri;
}
NGINX
  ln -sf /etc/nginx/sites-available/asp-portal /etc/nginx/sites-enabled/asp-portal
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
else
  echo "WARN: no TLS cert yet — portal on 127.0.0.1:8080 only (delegation pending?)"
fi

echo "portal deployed"
