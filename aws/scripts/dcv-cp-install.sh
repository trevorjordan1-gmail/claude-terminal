#!/bin/bash
# Control plane: Session Manager Broker + Connection Gateway (Ubuntu 24.04 arm64).
# Config keys per docs.aws.amazon.com/dcv (sm-admin, gw-admin), verified 2026-08-15.
# Idempotent; re-runnable via SSM.
set -uxo pipefail
source /etc/asp-terminal.env
export DEBIAN_FRONTEND=noninteractive

# Always-latest: the CDN root serves unversioned aliases for every component
# (verified 2026-08-18: HTTP 200 for these, while a hand-pinned versioned name
# had already 404'd once — the "-1" packaging suffix moved under us). The
# install is guarded by dpkg, so a newer alias only matters on fresh builds.
CDN="https://d1uj6qtbmh3dt5.cloudfront.net"
BROKER_DEB="nice-dcv-session-manager-broker_all.ubuntu2404.deb"
GATEWAY_DEB="nice-dcv-connection-gateway_arm64.ubuntu2404.deb"
fetch() {  # fetch <name> — download an alias to /tmp, or stop the build loudly
  wget -q "$CDN/$1" -O "/tmp/$1" || { echo "FATAL: download failed: $CDN/$1" >&2; exit 1; }
}
PROPS=/etc/dcv-session-manager-broker/session-manager-broker.properties
CA_SRC=/var/lib/dcvsmbroker/security/dcvsmbroker_ca.pem

# ---- swap: broker docs want 8GB; we run -Xmx1g on a 2GB Graviton + swap headroom ----
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---- broker ----
if ! dpkg -s nice-dcv-session-manager-broker >/dev/null 2>&1; then
  fetch "$BROKER_DEB"
  apt-get install -y "/tmp/$BROKER_DEB" || { echo "FATAL: broker install failed" >&2; exit 1; }
fi

# 2GB host: shrink the hardcoded JVM heap (-Xmx2g) and the off-heap cache
sed -i 's/-Xmx2g/-Xmx1g/' /usr/share/dcv-session-manager-broker/bin/common.sh

for kv in \
  "client-to-broker-connector-https-port = 8446" \
  "agent-to-broker-connector-https-port = 8445" \
  "enable-gateway = true" \
  "gateway-to-broker-connector-https-port = 8447" \
  "broker-to-broker-distributed-memory-max-size-mb = 256" \
; do
  key="${kv%% =*}"
  sed -i "/^[# ]*${key} *=/d" "$PROPS"
  echo "$kv" >> "$PROPS"
done

systemctl enable dcv-session-manager-broker
systemctl restart dcv-session-manager-broker

# wait for the broker's self-signed CA, publish it for desktops + gateway
for i in $(seq 1 60); do [ -f "$CA_SRC" ] && break; sleep 5; done
test -f "$CA_SRC"
aws s3 cp "$CA_SRC" "s3://$ASP_BUCKET/certs/dcvsmbroker_ca.pem"
mkdir -p /etc/dcv-connection-gateway
cp "$CA_SRC" /etc/dcv-connection-gateway/dcvsmbroker_ca.pem

# wait for the broker API to answer before registering the portal client
for i in $(seq 1 60); do
  curl -sk "https://localhost:8446/sessionConnectionData/aSession/aOwner" | grep -q authorization && break
  sleep 5
done

# ---- portal API client (credentials can't be recovered later — persist once) ----
if [ ! -f /etc/asp-broker-client.env ]; then
  OUT=$(dcv-session-manager-broker register-api-client --client-name asp-portal)
  CID=$(echo "$OUT" | grep -oP 'client-id:\s*\K\S+')
  CPW=$(echo "$OUT" | grep -oP 'client-password:\s*\K\S+')
  # subshell so the tight umask doesn't leak into later config writes
  ( umask 077 && printf 'BROKER_CLIENT_ID=%s\nBROKER_CLIENT_SECRET=%s\n' "$CID" "$CPW" > /etc/asp-broker-client.env )
fi

# ---- gateway ----
if ! dpkg -s nice-dcv-connection-gateway >/dev/null 2>&1; then
  fetch "$GATEWAY_DEB"
  apt-get install -y "/tmp/$GATEWAY_DEB" || { echo "FATAL: gateway install failed" >&2; exit 1; }
fi

CERT_LINES=""
if [ -f /etc/dcv-connection-gateway/certs/cert.pem ]; then
  CERT_LINES=$'cert-file = "/etc/dcv-connection-gateway/certs/cert.pem"\ncert-key-file = "/etc/dcv-connection-gateway/certs/key.pem"'
fi

cat > /etc/dcv-connection-gateway/dcv-connection-gateway.conf <<CONF
[gateway]
web-listen-endpoints = ["0.0.0.0:8443"]
quic-listen-endpoints = ["0.0.0.0:8443"]
$CERT_LINES

[resolver]
# must be a DNS name, not an IP (gw-admin/config-reference); short name because
# the broker cert's SAN only covers the short hostname
url = "https://$(hostname -s):8447"
ca-file = "/etc/dcv-connection-gateway/dcvsmbroker_ca.pem"

[dcv]
# desktops run DCV's auto-generated self-signed certs
tls-strict = false
CONF

systemctl enable dcv-connection-gateway
systemctl restart dcv-connection-gateway

sleep 5
systemctl --no-pager --lines=0 status dcv-session-manager-broker dcv-connection-gateway || true
curl -sk "https://localhost:8446/sessionConnectionData/aSession/aOwner" || true
echo "dcv-cp-install complete"
