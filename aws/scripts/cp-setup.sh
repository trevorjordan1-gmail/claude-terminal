#!/bin/bash
# ASP control-plane setup — idempotent, re-runnable via SSM.
# Expects /etc/asp-terminal.env with: ASP_PORTAL_HOST ASP_GW_HOST ASP_CUSTOMER
#   ASP_REGION ASP_BUCKET ASP_CERT_EMAIL (cp-tls.sh) ASP_PROFILE (portal-deploy.sh)
#   [ASP_DNS_ZONE is written too but unused here]
set -uxo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y --no-install-recommends \
  openjdk-17-jre-headless nginx python3-venv python3-pip \
  certbot unzip jq

systemctl enable --now nginx

# ---- TLS (needs the portal/gw A records live at the DNS provider before certbot can validate) ----
if aws s3 ls "s3://$ASP_BUCKET/scripts/cp-tls.sh" >/dev/null 2>&1; then
  aws s3 cp "s3://$ASP_BUCKET/scripts/cp-tls.sh" /opt/asp/cp-tls.sh
  chmod +x /opt/asp/cp-tls.sh
  /opt/asp/cp-tls.sh || echo "WARN: TLS issuance failed (DNS records live yet?) — re-run via SSM"
fi

# ---- broker + gateway (layered script; iterated separately) ----
if aws s3 ls "s3://$ASP_BUCKET/scripts/dcv-cp-install.sh" >/dev/null 2>&1; then
  aws s3 cp "s3://$ASP_BUCKET/scripts/dcv-cp-install.sh" /opt/asp/dcv-cp-install.sh
  chmod +x /opt/asp/dcv-cp-install.sh
  /opt/asp/dcv-cp-install.sh
else
  echo "dcv-cp-install.sh not in bucket yet — base only"
fi

# ---- portal (layered script; deploys from artifacts bucket) ----
if aws s3 ls "s3://$ASP_BUCKET/scripts/portal-deploy.sh" >/dev/null 2>&1; then
  aws s3 cp "s3://$ASP_BUCKET/scripts/portal-deploy.sh" /opt/asp/portal-deploy.sh
  chmod +x /opt/asp/portal-deploy.sh
  /opt/asp/portal-deploy.sh || echo "WARN: portal deploy failed — re-run via SSM"
fi

echo "cp-setup complete"
