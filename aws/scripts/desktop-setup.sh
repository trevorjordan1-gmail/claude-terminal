#!/bin/bash
# ASP terminal desktop setup — idempotent, re-runnable via SSM.
# Expects /etc/asp-terminal.env with: ASP_BROKER_HOST ASP_LOCAL_USER ASP_OWNER_UPN
#                                     ASP_CUSTOMER ASP_REGION ASP_BUCKET
set -uxo pipefail
source /etc/asp-terminal.env
export DEBIAN_FRONTEND=noninteractive
[ -f /opt/asp/progress.sh ] && . /opt/asp/progress.sh || prog() { :; }

# ---- 1. local users (no passwords — DCV auth is broker tokens only) ----
# The owner gets sudo; every other tenant user exists too, because DCV session
# permissions only apply to existing OS users (collab guests connect as them).
for u in $(echo "${ASP_ALL_USERS:-$ASP_LOCAL_USER}" | tr ',' ' '); do
  if ! id -u "$u" &>/dev/null; then
    adduser --disabled-password --gecos "ASP terminal user" "$u"
  fi
done
# Passwordless sudo for the owner (workbench + in-session installs). Use the
# exact filename claude-terminal's verify.sh checks for.
echo "$ASP_LOCAL_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/010-$ASP_LOCAL_USER-nopasswd"
chmod 440 "/etc/sudoers.d/010-$ASP_LOCAL_USER-nopasswd"
# cloud AMI ships /etc/sudoers.d as 750; desktop ISO uses 755 — verify.sh
# stats the rule as the user and needs directory traversal
chmod 755 /etc/sudoers.d

prog 12 "Installing the desktop (GNOME)" 21

# ---- 2. desktop environment: GNOME (matches the stock Ubuntu 24.04 Desktop
#         that claude-terminal targets). Virtual sessions bring their own X
#         server (Xdcv), so no greeter: gdm stays off, boot to multi-user ----

# CRITICAL, must precede the GNOME install: ubuntu-desktop pulls in
# NetworkManager, which grabs the cloud ENI and kills the instance's network
# mid-provision (both PoC terminals died at minute ~5 to exactly this).
# Pre-seed NM to leave ethernet alone; systemd-networkd keeps managing it.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-asp-cloud.conf <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:en*;interface-name:eth*
NMEOF
# ...AND the network-manager package ships /usr/lib/netplan/00-network-manager-all.yaml
# which flips the netplan renderer to NM for ALL interfaces: networkd releases the
# ENI while NM (per the guard above) won't take it — NOBODY owns the interface and
# the instance goes dark (PoC round 3 autopsy). Shadow the file so the renderer
# stays networkd forever.
printf 'network:\n  version: 2\n' > /etc/netplan/00-network-manager-all.yaml
chmod 600 /etc/netplan/00-network-manager-all.yaml

apt-get update -y
apt-get install -y ubuntu-desktop-minimal gnome-terminal dbus-x11 xdg-utils
# the left dock + tray icons are extensions ubuntu-desktop-minimal doesn't pull
apt-get install -y gnome-shell-extension-ubuntu-dock gnome-shell-extension-appindicator
apt-get install -y firefox
# noble's firefox deb is transitional to the snap; make the snap certain
snap list firefox >/dev/null 2>&1 || snap install firefox
systemctl set-default multi-user.target
systemctl disable --now gdm3 2>/dev/null || true

# stock Ubuntu Desktop suppresses the first-login language/keyboard wizard via
# the OS installer; our builds must purge it or every user gets interrogated
apt-get remove -y --purge gnome-initial-setup 2>/dev/null || true

# CCTs don't print (TJ 2026-08-15): GNOME drags in cups, and DCV printer
# redirection was mounting every client printer as a session queue. The portal
# disallows the DCV printer feature; this kills the local print stack so no
# queue ever shows up (masks cover cups.socket/path activation too).
systemctl disable --now cups.service cups.socket cups.path cups-browsed 2>/dev/null || true
systemctl mask cups.service cups.socket cups.path cups-browsed 2>/dev/null || true
rm -f /etc/cups/printers.conf /etc/cups/printers.conf.O   # drop already-redirected queues

# client-local time (terminal timestamps match the user)
timedatectl set-timezone America/Chicago || true

# GNOME defaults for remote terminals:
#  - text scaling 1.25 -> readable at 1920x1080 ("scaled so I can see everything")
#  - NEVER lock/blank/suspend: users have no OS passwords, a lock screen would
#    strand them, and GNOME suspending a cloud VM ends the session
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat > /etc/dconf/profile/user <<'DCONF'
user-db:user
system-db:local
DCONF
cat > /etc/dconf/db/local.d/01-asp-terminal <<'DCONF'
[org/gnome/desktop/interface]
text-scaling-factor=1.25

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
DCONF
dconf update

# first-login experience: real wallpaper (not void-blue) and a terminal already
# open — it's a Claude Code Terminal, greet the user with a terminal
apt-get install -y ubuntu-wallpapers 2>/dev/null || true
cat > /etc/dconf/db/local.d/02-asp-look <<'DCONF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/warty-final-ubuntu.png'
picture-uri-dark='file:///usr/share/backgrounds/warty-final-ubuntu.png'
DCONF
dconf update
cat > /etc/dconf/db/local.d/03-asp-dock <<'DCONF'
[org/gnome/shell]
favorite-apps=['firefox_firefox.desktop', 'firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']
DCONF
dconf update
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/cct-welcome-terminal.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Claude Code Terminal
Comment=Opens your terminal at sign-in
Exec=gnome-terminal --maximize
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
DESKTOP

prog 55 "Installing the Claude Code workbench" 9

# ---- 3. workbench: TJ's curated claude-terminal environment ----
# Logged + verified: a terminal without a working `claude` is not done.
if [ ! -d "/home/$ASP_LOCAL_USER/claude-terminal" ]; then
  su - "$ASP_LOCAL_USER" -c \
    'curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash' \
    > /var/log/asp-workbench.log 2>&1 || true
fi
if [ -x "/home/$ASP_LOCAL_USER/.local/bin/claude" ]; then
  prog 70 "Workbench installed (claude $(sudo -u $ASP_LOCAL_USER /home/$ASP_LOCAL_USER/.local/bin/claude --version 2>/dev/null | awk '{print $1}'))" 6
  su - "$ASP_LOCAL_USER" -c 'cd ~/claude-terminal && bash verify.sh' >> /var/log/asp-workbench.log 2>&1 || true
else
  prog 70 "WORKBENCH FAILED - claude missing, see /var/log/asp-workbench.log" 6
  echo "ERROR: workbench did not produce a working claude binary" >&2
fi

prog 80 "Installing remote display (DCV)" 4

# claude-terminal installs to ~/.local/bin, which only lands on PATH via
# ~/.profile at a GDM login — DCV virtual sessions skip that, so pin it in
# .bashrc for gnome-terminal's non-login shells
grep -q 'local/bin' "/home/$ASP_LOCAL_USER/.bashrc" 2>/dev/null ||   echo 'export PATH="$HOME/.local/bin:$PATH"' >> "/home/$ASP_LOCAL_USER/.bashrc"
chown "$ASP_LOCAL_USER:$ASP_LOCAL_USER" "/home/$ASP_LOCAL_USER/.bashrc"

# ---- 4. DCV server + Session Manager agent (layered script; iterated separately) ----
if aws s3 ls "s3://$ASP_BUCKET/scripts/dcv-desktop-install.sh" >/dev/null 2>&1; then
  aws s3 cp "s3://$ASP_BUCKET/scripts/dcv-desktop-install.sh" /opt/asp/dcv-desktop-install.sh
  chmod +x /opt/asp/dcv-desktop-install.sh
  /opt/asp/dcv-desktop-install.sh
else
  echo "dcv-desktop-install.sh not in bucket yet — base image only"
fi

# WU-style self-update: daily check + catch-up on wake (Persistent), defers in use
aws s3 cp "s3://$ASP_BUCKET/scripts/auto-update.sh" /opt/asp/auto-update.sh 2>/dev/null && chmod +x /opt/asp/auto-update.sh
cat > /etc/systemd/system/asp-auto-update.service <<'UNIT'
[Unit]
Description=ASP terminal self-update

[Service]
Type=oneshot
ExecStart=/opt/asp/auto-update.sh
UNIT
cat > /etc/systemd/system/asp-auto-update.timer <<'UNIT'
[Unit]
Description=Daily ASP terminal update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
OnBootSec=10min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now asp-auto-update.timer

echo "desktop-setup complete"
