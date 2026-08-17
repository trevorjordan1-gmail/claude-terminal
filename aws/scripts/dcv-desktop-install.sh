#!/bin/bash
# Desktop: DCV Server (virtual sessions) + Session Manager Agent (Ubuntu 24.04 x86_64).
# Versions + config keys per docs.aws.amazon.com/dcv, verified 2026-08-15.
# Idempotent; re-runnable via SSM.
set -uxo pipefail
source /etc/asp-terminal.env
export DEBIAN_FRONTEND=noninteractive
[ -f /opt/asp/progress.sh ] && . /opt/asp/progress.sh || prog() { :; }

SERVER_TGZ="nice-dcv-2025.0-20103-ubuntu2404-x86_64.tgz"
AGENT_DEB="nice-dcv-session-manager-agent_2025.0.902-1_amd64.ubuntu2404.deb"
CDN="https://d1uj6qtbmh3dt5.cloudfront.net/2025.0"

# ---- DCV server + Xdcv (virtual sessions, no GPU -> software rendering) ----
if ! dpkg -s nice-dcv-server >/dev/null 2>&1; then
  wget -q "$CDN/Servers/$SERVER_TGZ" -O "/tmp/$SERVER_TGZ"
  tar -xzf "/tmp/$SERVER_TGZ" -C /tmp
  cd /tmp/nice-dcv-2025.0-20103-ubuntu2404-x86_64
  apt-get install -y ./nice-dcv-server_*.deb ./nice-xdcv_*.deb
  usermod -aG video dcv
fi
apt-get install -y mesa-utils

# ---- session manager agent (server must exist first) ----
if ! dpkg -s nice-dcv-session-manager-agent >/dev/null 2>&1; then
  wget -q "$CDN/SessionManagerAgents/$AGENT_DEB" -O "/tmp/$AGENT_DEB"
  apt-get install -y "/tmp/$AGENT_DEB"
fi

# ---- broker CA (published by the control plane) ----
aws s3 cp "s3://$ASP_BUCKET/certs/dcvsmbroker_ca.pem" /etc/dcv-session-manager-agent/dcvsmbroker_ca.pem

# ---- DCV server config: broker-verified tokens, QUIC on ----
cat > /etc/dcv/dcv.conf <<CONF
[license]

[log]

[session-management]
# Without a fake vblank, mutter's frame clock stalls and GNOME renders BLACK
# until poked — the root cause of every "black screen" in the PoC. Layout is
# enforced by the portal (set-display-layout on Connect), not Xdcv args.
virtual-session-xdcv-args="-fakescreenfps 60"

[session-management/defaults]

[session-management/automatic-console-session]

[display]
# CCTs are single-display by design (TJ 2026-08-15): no client can request
# multi-head layouts — kills the 4x800x600 "tiled wallpaper" failure mode
max-num-heads=1

[connectivity]
enable-quic-frontend=true

[security]
administrators=["dcvsmagent"]
ca-file="/etc/dcv-session-manager-agent/dcvsmbroker_ca.pem"
auth-token-verifier="https://${ASP_BROKER_HOST}:8445/agent/validate-authentication-token"

[clipboard]

[windows]
CONF

# ---- agent config (top-level `version` is a required field) ----
cat > /etc/dcv-session-manager-agent/agent.conf <<CONF
version = '0.1'

[agent]
broker_host = '${ASP_BROKER_HOST}'
broker_port = 8445
tls_strict = true
ca_file = '/etc/dcv-session-manager-agent/dcvsmbroker_ca.pem'
enable_query_logged_in_users = true
# default 30s makes the broker take 30-90s to re-list a booted/resumed server
# ("Almost ready…" limbo); 10s is documented-safe and cuts that ~2/3
broker_update_interval = 10

[log]
level = 'info'
CONF

# ---- session init: land in the REAL Ubuntu session (dock, Yaru, indicators) ----
# The init dcvserver actually runs for broker-created virtual sessions is
# /etc/dcv/dcvsessioninit — no InitFilePath is ever passed, so the SM agent's
# init/ dir is NOT in the code path (a day-one misbelief; scripts there never
# ran). The stock file execs /etc/X11/Xsession with no desktop identity, so
# gnome-shell came up as unbranded "GNOME": no ubuntu-dock (the "no sidebar"
# bug), no appindicators, light gnome-terminal. Exporting the identity here
# fixes all of it — verified live on cct01 2026-08-15.
cat > /etc/dcv/dcvsessioninit <<'INIT'
#!/bin/sh
# ASP-owned (rewritten by dcv-desktop-install.sh). A nice-dcv-server package
# update may restore the stock desktop-autodetect version — re-run the script.
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export GNOME_SHELL_SESSION_MODE=ubuntu
# snap apps (Firefox) are invisible without this: login shells get it from
# /etc/profile.d, the DCV Xsession path does not — the dock can't show a
# favorite whose .desktop file isn't on XDG_DATA_DIRS
[ -f /etc/profile.d/apps-bin-path.sh ] && . /etc/profile.d/apps-bin-path.sh
exec /etc/X11/Xsession
INIT
chmod 755 /etc/dcv/dcvsessioninit
# remove the dead-end init attempts (nothing ever executed these)
rm -f /var/lib/dcv-session-manager-agent/init/default.sh \
      /usr/share/gnome-session/sessions/ubuntu-dcv.session
rm -rf /etc/systemd/user/gnome-session@ubuntu-dcv.target.d

# dcvserver exits when its last session is deleted and the packaged unit
# doesn't restart it — a dead dcvserver breaks Connect silently
mkdir -p /etc/systemd/system/dcvserver.service.d
printf '[Service]\nRestart=always\nRestartSec=3\n' > /etc/systemd/system/dcvserver.service.d/override.conf
# the agent pairs with the running dcvserver; restart it whenever dcvserver
# restarts or the broker reports "No DCV server found" for a healthy host
mkdir -p /etc/systemd/system/dcv-session-manager-agent.service.d
printf '[Unit]\nPartOf=dcvserver.service\nAfter=dcvserver.service\n' > /etc/systemd/system/dcv-session-manager-agent.service.d/override.conf
systemctl daemon-reload

prog 95 "Connecting to the session broker" 1

# the nice-dcv-server package does NOT enable its unit — without this the
# first clean reboot leaves dcvserver dead and the broker has no server
# ("No DCV server found"); hibernate/resume masked it for a whole day
systemctl enable dcvserver
systemctl restart dcvserver
systemctl enable --now dcv-session-manager-agent
systemctl restart dcv-session-manager-agent

sleep 10
grep -o 'sessionsUpdateResponse.*' /var/log/dcv-session-manager-agent/agent.log | tail -2 || true
prog 100 "Ready" 0
echo "dcv-desktop-install complete"
