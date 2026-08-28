#!/bin/bash
# Desktop: DCV Server (virtual sessions) + Session Manager Agent (Ubuntu 24.04 x86_64).
# Config keys per docs.aws.amazon.com/dcv, verified 2026-08-15.
# Idempotent; re-runnable via SSM.
set -uxo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env
export DEBIAN_FRONTEND=noninteractive
# shellcheck source=/dev/null  # progress helper written by user_data at boot
if [ -f /opt/asp/progress.sh ]; then . /opt/asp/progress.sh; else prog() { :; }; fi

# Always-latest: the CDN root serves unversioned aliases (see dcv-cp-install.sh
# for the why). Installs are dpkg-guarded, so re-runs never re-download.
CDN="https://d1uj6qtbmh3dt5.cloudfront.net"
SERVER_TGZ="nice-dcv-ubuntu2404-x86_64.tgz"
AGENT_DEB="nice-dcv-session-manager-agent_amd64.ubuntu2404.deb"
fetch() {  # fetch <name> — download an alias to /tmp, or stop the build loudly
  wget -q "$CDN/$1" -O "/tmp/$1" || { echo "FATAL: download failed: $CDN/$1" >&2; exit 1; }
}

# ---- DCV server + Xdcv (virtual sessions, no GPU -> software rendering) ----
if ! dpkg -s nice-dcv-server >/dev/null 2>&1; then
  fetch "$SERVER_TGZ"
  # the tarball unpacks into a versioned directory — read the name from it
  SERVER_DIR="$(tar -tzf "/tmp/$SERVER_TGZ" | head -1 | cut -d/ -f1)"
  tar -xzf "/tmp/$SERVER_TGZ" -C /tmp
  cd "/tmp/$SERVER_DIR" || { echo "FATAL: DCV server tarball layout changed" >&2; exit 1; }
  apt-get install -y ./nice-dcv-server_*.deb ./nice-xdcv_*.deb || { echo "FATAL: DCV server install failed" >&2; exit 1; }
  usermod -aG video dcv
fi
apt-get install -y mesa-utils

# ---- session manager agent (server must exist first) ----
if ! dpkg -s nice-dcv-session-manager-agent >/dev/null 2>&1; then
  fetch "$AGENT_DEB"
  apt-get install -y "/tmp/$AGENT_DEB" || { echo "FATAL: SM agent install failed" >&2; exit 1; }
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
# 30 fps, not 60: no GPU means every frame is composited by llvmpipe on the
# CPU and encoded by dcvagent — at 60 the render+encode loop ate most of a
# core on a busy screen (TJ 2026-08-17); 30 halves that ceiling and is fine
# for terminal work.
virtual-session-xdcv-args="-fakescreenfps 30"

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
# snap apps are invisible without this: login shells get it from
# /etc/profile.d, the DCV Xsession path does not — a snap's .desktop file must
# be on XDG_DATA_DIRS for the dock/app grid to show it (Chrome is a deb now,
# but any snap the user installs later still needs this)
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

# needrestart's apt hook (stock on noble) restarts every service linking a
# just-upgraded library — for dcvserver that tears down every live session and
# the Claude job running inside it (unattended libpam upgrade, fleet incident
# 2026-08-28, issue #19). Defer DCV restarts instead: the services pick the new
# libraries up at the next reboot / pause→off conversion, which is their
# existing restart cadence anyway. Conf.d files are Perl, evaluated by
# needrestart after its main config — keys here override the stock ones.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/asp-dcv.conf <<'NR'
# ASP: never auto-restart DCV services — a dcvserver restart kills every live
# session and running Claude job (claude-terminal#19). They converge on the
# next reboot or the 48-h pause→off conversion.
$nrconf{override_rc}{qr(^dcvserver)} = 0;
$nrconf{override_rc}{qr(^dcvsessionlauncher)} = 0;
$nrconf{override_rc}{qr(^dcv-session-manager-agent)} = 0;
NR

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
prog 97 "Remote display up — final steps" 1
echo "dcv-desktop-install complete"
