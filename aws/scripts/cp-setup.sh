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

# ---- solo tenant (#64): this box is also the NAT, on a 512 MB-1 GB instance ----
# ASP_SOLO=1 is written by terraform only when `solo = true`; a fleet tenant never enters.
if [ "${ASP_SOLO:-0}" = "1" ]; then
  # 1. forward for the private subnets. Same three facts fck-nat runs on: ip_forward,
  #    a masquerade on the egress interface, and source/dest check off (terraform).
  #    A oneshot unit re-applies it on every boot; nftables is stock on 24.04.
  apt-get install -y --no-install-recommends nftables zram-tools
  cat > /opt/asp/solo-nat.sh <<'NAT'
#!/bin/bash
# solo control plane: forward + masquerade the VPC's egress (#64). Idempotent.
set -uo pipefail
sysctl -qw net.ipv4.ip_forward=1
DEV=$(ip -o route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ -n "$DEV" ] || { echo "solo-nat: no default route device" >&2; exit 1; }
nft list table ip asp-nat >/dev/null 2>&1 || nft add table ip asp-nat
nft list chain ip asp-nat postrouting >/dev/null 2>&1 || \
  nft add chain ip asp-nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
nft list chain ip asp-nat postrouting | grep -q "oifname \"$DEV\" masquerade" || \
  nft add rule ip asp-nat postrouting oifname "$DEV" masquerade
echo "solo-nat: forwarding via $DEV"
NAT
  chmod 755 /opt/asp/solo-nat.sh
  cat > /etc/systemd/system/asp-solo-nat.service <<'UNIT'
[Unit]
Description=ASP solo control plane: NAT for the private subnets (#64)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/asp/solo-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now asp-solo-nat.service
  # 2. memory: zram (compressed swap IN RAM, tried first) in front of the disk swapfile
  #    dcv-cp-install.sh creates. zram-tools sizes it as a percent of RAM; zstd compresses
  #    the portal's and the JVM's cold pages ~3:1. swappiness high on purpose: with zram the
  #    kernel should page early and cheaply rather than hold the cache. The broker heap
  #    (dcv-cp-install.sh) is sized to stay resident — GC walks all of it.
  cat > /etc/default/zramswap <<'ZRAM'
ALGO=zstd
PERCENT=60
PRIORITY=100
ZRAM
  systemctl enable --now zramswap.service || echo "WARN: zramswap did not start" >&2
  systemctl restart zramswap.service || true
  printf 'vm.swappiness=150\nvm.vfs_cache_pressure=200\n' > /etc/sysctl.d/90-asp-solo.conf
  sysctl -q --system
fi

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


# ---- tenant extension hook (issue #1): sanctioned per-tenant customization ----
# If the tenant bucket carries scripts/tenant-custom-cp.sh, run it LAST. Contract: the
# operator owns the file, it is idempotent (re-runs on every release), failure
# is logged + surfaced but non-fatal, and upstream never edits it. Same trust
# boundary as this script — the same bucket writers control both.
if aws s3 cp "s3://$ASP_BUCKET/scripts/tenant-custom-cp.sh" "/opt/asp/tenant-custom-cp.sh" >/dev/null 2>&1; then
  chmod +x "/opt/asp/tenant-custom-cp.sh"
  if bash "/opt/asp/tenant-custom-cp.sh" >> /var/log/asp-tenant-custom.log 2>&1; then
    echo "tenant-custom-cp.sh: ok"
  else
    rc=$?
    echo "WARN: tenant-custom-cp.sh failed (rc=$rc) — see /var/log/asp-tenant-custom.log" >&2
  fi
fi

echo "cp-setup complete"
