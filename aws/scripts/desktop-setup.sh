#!/bin/bash
# ASP terminal desktop setup — idempotent, re-runnable via SSM.
# Expects /etc/asp-terminal.env with: ASP_LOCAL_USER ASP_ALL_USERS ASP_BUCKET
#   ASP_PROFILE (standard|medical); ASP_BROKER_HOST/ASP_REGION are read by the
#   chained dcv-desktop-install.sh and the kit; ASP_OWNER_UPN/ASP_CUSTOMER ride
#   along for humans debugging the box.
set -uxo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env
export DEBIAN_FRONTEND=noninteractive
# shellcheck source=/dev/null  # progress helper written by user_data at boot
if [ -f /opt/asp/progress.sh ]; then . /opt/asp/progress.sh; else prog() { :; }; fi

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
# ---- browser: Google Chrome, native deb (decision TJ 2026-08-17) ----
# The Firefox snap's cold-start unpack was the "100% CPU when I open the
# browser" complaint; Chrome's deb launches clean. Usage is light (auth,
# artifacts, app testing) — tuned for the no-GPU streamed pipeline below.
if ! dpkg -s google-chrome-stable >/dev/null 2>&1; then
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O /tmp/chrome.deb
  apt-get install -y /tmp/chrome.deb
fi
snap remove firefox 2>/dev/null || true
apt-get remove -y --purge firefox 2>/dev/null || true  # transitional snap shim

# managed policies: no autoplay video (software decode + software encode is
# the worst thing this box can do), no background mode, no session-restore
# nags, no telemetry; GPU process off — there is no GPU, Chrome's software
# raster beats GL-on-llvmpipe
mkdir -p /etc/opt/chrome/policies/managed
cat > /etc/opt/chrome/policies/managed/asp-terminal.json <<'JSON'
{
  "AutoplayAllowed": false,
  "BackgroundModeEnabled": false,
  "MetricsReportingEnabled": false,
  "PromotionalTabsEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "HardwareAccelerationModeEnabled": false,
  "RestoreOnStartup": 5
}
JSON

# launch flags: smooth scrolling off IN CHROME ONLY (each smooth-scroll frame
# is an llvmpipe composite + DCV encode; discrete jumps stream snappier —
# GNOME Terminal keeps its own smooth scrolling, this is per-app), reduced
# motion, renderer count sized for the vCPUs, and password-store=basic
# because users have no OS password and gnome-keyring would otherwise demand
# one on first launch (EBS is encrypted; profile-level storage is fine).
# /usr/local overrides /usr/share in XDG_DATA_DIRS so the dock and app grid
# pick this entry up.
mkdir -p /usr/local/share/applications
# first run: no Terms-of-Service wall. Every new terminal, and every new user
# on a shared build terminal, otherwise opens the browser into a ToS dialog
# before it will render anything — on a machine the operator already accepted
# terms for. --no-first-run alone does NOT fix this: it skips the tasks without
# dropping the sentinel, so the wall returns on the next launch. The sentinel
# file is what actually retires it; initial_preferences covers the rest of the
# first-run UI (welcome page, default-browser nag, import prompts).
cat > /opt/google/chrome/initial_preferences <<'JSON'
{
  "distribution": {
    "skip_first_run_ui": true,
    "suppress_first_run_default_browser_prompt": true,
    "import_bookmarks": false,
    "import_history": false,
    "import_search_engine": false,
    "make_chrome_default": false,
    "verbose_logging": false
  },
  "first_run_tabs": []
}
JSON
seed_chrome_first_run() {  # $1 = home dir, $2 = owner (empty for /etc/skel)
  install -d "$1/.config/google-chrome"
  : > "$1/.config/google-chrome/First Run"
  [ -n "${2:-}" ] && chown -R "$2:$2" "$1/.config/google-chrome"
}
for u in $(echo "${ASP_ALL_USERS:-$ASP_LOCAL_USER}" | tr ',' ' '); do
  h=$(getent passwd "$u" | cut -d: -f6)
  [ -n "$h" ] && [ -d "$h" ] && seed_chrome_first_run "$h" "$u"
done
seed_chrome_first_run /etc/skel ""   # collab guests added later inherit it
sed 's|Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable --disable-smooth-scrolling --force-prefers-reduced-motion --renderer-process-limit=2 --password-store=basic|g' \
  /usr/share/applications/google-chrome.desktop > /usr/local/share/applications/google-chrome.desktop

# warm start: the browser's launch burst happens during session creation,
# before the user has even connected — clicking the dock icon is instant
cat > /etc/xdg/autostart/cct-chrome-warm.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Chrome (warm start)
Comment=Opens the browser at sign-in so it is already warm
Exec=/usr/bin/google-chrome-stable --disable-smooth-scrolling --force-prefers-reduced-motion --renderer-process-limit=2 --password-store=basic --start-minimized
OnlyShowIn=GNOME;
X-GNOME-Autostart-Delay=2
DESKTOP

# paging safety (TJ 2026-08-17): hibernation's swap (ec2 hibinit, RAM-sized)
# doubles as pageout space; if it is ever absent, provide a fallback so
# memory pressure pages instead of OOM-killing
if ! swapon --noheadings --show 2>/dev/null | grep -q .; then
  if ! grep -q swap-fallback /etc/fstab; then
    fallocate -l 2G /swap-fallback && chmod 600 /swap-fallback && \
      mkswap /swap-fallback && swapon /swap-fallback && \
      echo '/swap-fallback none swap sw 0 0' >> /etc/fstab
  fi
fi
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

# polkit: GUI shutdown/reboot/updates prompted for a password (TJ 2026-08-18)
# — but users have NO password by design, so those prompts are unanswerable
# dead ends, and the owner already holds passwordless sudo (full root) anyway.
# Grant the desktop-admin actions the GUI needs to sudo-group members.
# Suspend/hibernate actions are deliberately NOT granted: an in-guest suspend
# wedges an EC2 instance (Pause belongs to the portal, not the OS menu).
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-asp-terminal.rules <<'RULES'
polkit.addRule(function(action, subject) {
    if (!subject.isInGroup("sudo")) {
        return polkit.Result.NOT_HANDLED;
    }
    if (action.id == "org.freedesktop.login1.power-off" ||
        action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
        action.id == "org.freedesktop.login1.reboot" ||
        action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
        action.id.indexOf("org.freedesktop.packagekit.") == 0 ||
        action.id.indexOf("org.debian.apt.") == 0 ||
        action.id.indexOf("com.ubuntu.softwareproperties.") == 0 ||
        action.id.indexOf("io.snapcraft.snapd.") == 0) {
        return polkit.Result.YES;
    }
    return polkit.Result.NOT_HANDLED;
});
RULES
systemctl try-restart polkit 2>/dev/null || true

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
# no GPU: every animation frame is llvmpipe CPU work + a DCV encode — skip them
enable-animations=false

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
favorite-apps=['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']
DCONF
# lock favorites: the workbench kit pins Firefox per-user (40-gnome-qol) and
# would silently undo the Chrome dock on every kit re-run — the lock makes
# the system default authoritative until the kit learns DCV browser choice
mkdir -p /etc/dconf/db/local.d/locks
printf '/org/gnome/shell/favorite-apps\n' > /etc/dconf/db/local.d/locks/01-asp-dock
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
# after the browser warm start: the terminal maps last, so sign-in lands on a
# focused maximized terminal with the warm (minimized) browser one click away
X-GNOME-Autostart-Delay=6
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
  prog 70 "Workbench installed (claude $(sudo -u "$ASP_LOCAL_USER" "/home/$ASP_LOCAL_USER/.local/bin/claude" --version 2>/dev/null | awk '{print $1}'))" 6
  su - "$ASP_LOCAL_USER" -c 'cd ~/claude-terminal && bash verify.sh' >> /var/log/asp-workbench.log 2>&1 || true
else
  prog 70 "WORKBENCH FAILED - claude missing, see /var/log/asp-workbench.log" 6
  echo "ERROR: workbench did not produce a working claude binary" >&2
fi

prog 80 "Installing remote display (DCV)" 4

# claude-terminal installs to ~/.local/bin, which only lands on PATH via
# ~/.profile at a GDM login — DCV virtual sessions skip that, so pin it in
# .bashrc for gnome-terminal's non-login shells
# shellcheck disable=SC2016  # the $HOME must reach .bashrc literally
grep -q 'local/bin' "/home/$ASP_LOCAL_USER/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "/home/$ASP_LOCAL_USER/.bashrc"
chown "$ASP_LOCAL_USER:$ASP_LOCAL_USER" "/home/$ASP_LOCAL_USER/.bashrc"

# ---- 4. DCV server + Session Manager agent (layered script; iterated separately) ----
if aws s3 ls "s3://$ASP_BUCKET/scripts/dcv-desktop-install.sh" >/dev/null 2>&1; then
  aws s3 cp "s3://$ASP_BUCKET/scripts/dcv-desktop-install.sh" /opt/asp/dcv-desktop-install.sh
  chmod +x /opt/asp/dcv-desktop-install.sh
  /opt/asp/dcv-desktop-install.sh
else
  echo "dcv-desktop-install.sh not in bucket yet — base image only"
fi

# ---- 5. medical profile: host-side belt-and-braces (the kit does the rest) ----
# The broker's per-session permissions already deny these on medical tenants;
# the server default catches any session created outside the portal. Stock
# default.perm is "[permissions] / %owner% allow builtin" — rewrite it whole.
if [ "${ASP_PROFILE:-standard}" = "medical" ] && [ -d /etc/dcv ]; then
  MEDPERM='[permissions]
%owner% allow builtin
%any% deny file-download printer'
  [ "$(cat /etc/dcv/default.perm 2>/dev/null)" = "$MEDPERM" ] || printf '%s\n' "$MEDPERM" > /etc/dcv/default.perm
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


# ---- keep the broker link alive across hibernation ----
if aws s3 cp "s3://$ASP_BUCKET/scripts/dcv-relink.sh" /opt/asp/dcv-relink.sh >/dev/null 2>&1; then
  chmod +x /opt/asp/dcv-relink.sh
  bash /opt/asp/dcv-relink.sh || echo "WARN: dcv-relink.sh failed" >&2
fi

# ---- tenant extension hook (issue #1): sanctioned per-tenant customization ----
# If the tenant bucket carries scripts/tenant-custom.sh, run it LAST. Contract: the
# operator owns the file, it is idempotent (re-runs on every release), failure
# is logged + surfaced but non-fatal, and upstream never edits it. Same trust
# boundary as this script — the same bucket writers control both.
if aws s3 cp "s3://$ASP_BUCKET/scripts/tenant-custom.sh" "/opt/asp/tenant-custom.sh" >/dev/null 2>&1; then
  chmod +x "/opt/asp/tenant-custom.sh"
  if bash "/opt/asp/tenant-custom.sh" >> /var/log/asp-tenant-custom.log 2>&1; then
    echo "tenant-custom.sh: ok"
  else
    rc=$?
    echo "WARN: tenant-custom.sh failed (rc=$rc) — see /var/log/asp-tenant-custom.log" >&2
  fi
fi

prog 100 "Ready" 0
echo "desktop-setup complete"
