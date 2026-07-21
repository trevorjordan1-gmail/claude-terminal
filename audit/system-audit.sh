#!/usr/bin/env bash
# system-audit.sh — Snapshot an Ubuntu 24.04 "Claude Code terminal" box for comparison.
#
# Captures OS/package/service/desktop/tool state into a folder of sorted text
# files (one per category) plus a tarball, so two machines can be diffed
# file-by-file.
#
#   Usage:  bash system-audit.sh [output-parent-dir]      (default: $HOME/os-audit)
#           bash system-audit.sh --quick [output-parent-dir]   (skip slow dpkg -V scan)
#
# Safety: read-only, no sudo, no network. Never reads private keys or
# ~/.claude/.credentials.json. Values that look like passwords/tokens/keys in
# captured config files are replaced with [REDACTED]. Output still contains
# hostnames, printer names, project names, etc. — fine for personal
# comparison, but review before sharing publicly.

# shellcheck disable=SC2088  # tildes below appear inside display labels, not paths
set -u
VERSION="1.0.0"

QUICK=0
if [ "${1:-}" = "--quick" ]; then QUICK=1; shift; fi
PARENT="${1:-$HOME/os-audit}"
HOSTN="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$PARENT/$HOSTN-$STAMP"
mkdir -p "$OUT"

have() { command -v "$1" >/dev/null 2>&1; }

# Make dconf/gsettings/systemctl --user work when run from a non-login shell
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

redact() {
    sed -E 's/((password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential)[^=:]{0,20}[=:][[:space:]"'"'"']*)[^[:space:]",'"'"']+/\1[REDACTED]/Ig'
}

hdr() { printf '### %s\n' "$*"; }

catfile() {  # catfile <path> [maxlines]  — print file with header, redacted
    local f="$1" max="${2:-400}"
    hdr "FILE: $f"
    if [ -r "$f" ]; then
        head -n "$max" "$f" | redact
        local total; total=$(wc -l < "$f")
        [ "$total" -gt "$max" ] && printf '... [truncated: %s of %s lines shown]\n' "$max" "$total"
    else
        echo "(missing or unreadable)"
    fi
    echo
}

say() { printf '  [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

echo "system-audit v$VERSION -> $OUT"

# ---------------------------------------------------------------- 00 meta
{
    echo "script_version: $VERSION"
    echo "captured: $(date -Is)"
    echo "host: $(hostname)"
    echo "user: $(id -un) ($(id -u))"
    echo "quick_mode: $QUICK"
    echo "note: secrets redacted; private keys and .credentials.json never read"
} > "$OUT/00-meta.txt"

# ---------------------------------------------------------------- 01 system
say "system info"
{
    hdr "lsb_release -a";        lsb_release -a 2>/dev/null
    hdr "uname -a";              uname -a
    hdr "virtualization";        systemd-detect-virt 2>/dev/null || echo "unknown"
    hdr "hostnamectl";           hostnamectl 2>/dev/null | grep -Ev 'Machine ID|Boot ID'
    hdr "timezone";              timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null
    hdr "locale";                localectl status 2>/dev/null || locale
    hdr "default shell";         getent passwd "$(id -un)" | cut -d: -f7
    hdr "memory (GB)";           awk '/MemTotal/{printf "%.1f\n", $2/1048576}' /proc/meminfo
    hdr "cpus";                  nproc
} > "$OUT/01-system.txt" 2>&1

# ---------------------------------------------------------------- packages
say "apt packages"
apt-mark showmanual 2>/dev/null | sort > "$OUT/02-apt-manual.txt"
dpkg-query -W -f '${Package}\n' 2>/dev/null | sort > "$OUT/03-apt-all-names.txt"
dpkg-query -W -f '${Package}\t${Version}\n' 2>/dev/null | sort > "$OUT/04-apt-all-versions.txt"

{
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
        [ -f "$f" ] && catfile "$f" 100
    done
    hdr "keyrings"; ls -1 /etc/apt/keyrings /etc/apt/trusted.gpg.d 2>/dev/null
} > "$OUT/05-apt-sources.txt"

{
    hdr "snap list"
    if have snap; then snap list 2>/dev/null; else echo "(snap not installed)"; fi
    hdr "snap names only"
    have snap && snap list 2>/dev/null | awk 'NR>1{print $1}' | sort
} > "$OUT/06-snap.txt"

{
    hdr "flatpak list"
    if have flatpak; then flatpak list 2>/dev/null; else echo "(flatpak not installed)"; fi
} > "$OUT/07-flatpak.txt"

say "python/node/other runtimes"
{
    hdr "python3 --version";  python3 --version 2>&1
    hdr "pip3 list (all)";    pip3 list 2>/dev/null | sort
    hdr "pip3 list --user";   pip3 list --user 2>/dev/null | sort
    hdr "pipx list";          have pipx && pipx list 2>/dev/null || echo "(pipx not installed)"
    hdr "uv";                 have uv && uv --version 2>/dev/null || { [ -x "$HOME/.local/bin/uv" ] && "$HOME/.local/bin/uv" --version; } || echo "(uv not installed)"
} > "$OUT/08-python.txt"

{
    hdr "node";     have node && node --version || echo "(node not installed)"
    hdr "npm";      have npm && npm --version || echo "(npm not installed)"
    hdr "npm globals"; have npm && npm ls -g --depth=0 2>/dev/null
    hdr "bun";      { have bun && bun --version; } || { [ -x "$HOME/.bun/bin/bun" ] && "$HOME/.bun/bin/bun" --version; } || echo "(bun not installed)"
} > "$OUT/09-node-npm.txt"

# ---------------------------------------------------------------- claude stack
say "claude stack"
{
    hdr "which claude";       command -v claude || echo "(claude not on PATH)"
    hdr "claude --version";   timeout 20 claude --version 2>&1 || echo "(failed/timed out)"
    hdr "claude-mem version"; timeout 20 claude-mem --version 2>&1 | head -2 || echo "(claude-mem not on PATH)"
    hdr "~/.claude top-level";        ls -1 "$HOME/.claude" 2>/dev/null
    hdr "~/.claude/plugins";          ls -1 "$HOME/.claude/plugins" 2>/dev/null
    hdr "plugin marketplaces cache";  ls -1 "$HOME/.claude/plugins/cache" 2>/dev/null
    hdr "~/.claude-mem top-level";    ls -1 "$HOME/.claude-mem" 2>/dev/null
    hdr "~/.claude-mem/hooks";        ls -1 "$HOME/.claude-mem/hooks" 2>/dev/null
    catfile "$HOME/.claude/settings.json" 200
    hdr "~/.claude/CLAUDE.md";        [ -f "$HOME/.claude/CLAUDE.md" ] && wc -l < "$HOME/.claude/CLAUDE.md" | xargs echo "exists, lines:" || echo "(none)"
} > "$OUT/10-claude.txt" 2>&1

# ---------------------------------------------------------------- services
say "systemd units"
systemctl list-unit-files --no-pager --no-legend 2>/dev/null | awk '{print $1"\t"$2}' | sort > "$OUT/11-units-system.txt"
systemctl --user list-unit-files --no-pager --no-legend 2>/dev/null | awk '{print $1"\t"$2}' | sort > "$OUT/12-units-user.txt"

{
    hdr "local unit files in /etc/systemd/system (regular files)"
    find /etc/systemd/system -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.mount' \) 2>/dev/null | sort
    echo
    find /etc/systemd/system -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) 2>/dev/null | sort | while read -r f; do
        catfile "$f" 80
    done
    hdr "drop-in dirs"; ls -1d /etc/systemd/system/*.d 2>/dev/null
} > "$OUT/13-local-units.txt"

{
    hdr "timers (unit names)"
    systemctl list-timers --all --no-pager --no-legend 2>/dev/null | awk '{print $(NF-1)}' | sort -u
    hdr "user crontab"; crontab -l 2>/dev/null || echo "(no user crontab)"
    hdr "/etc/cron.d";  ls -1 /etc/cron.d 2>/dev/null
    for d in daily weekly monthly hourly; do hdr "/etc/cron.$d"; ls -1 "/etc/cron.$d" 2>/dev/null; done
} > "$OUT/14-timers-cron.txt"

# ---------------------------------------------------------------- printing
say "printing"
{
    hdr "queues (lpstat -v)";   lpstat -v 2>&1
    hdr "printers (lpstat -p -d)"; lpstat -p -d 2>&1
    hdr "cups enabled";         systemctl is-enabled cups 2>&1
    hdr "cups-browsed enabled"; systemctl is-enabled cups-browsed 2>&1
    hdr "ppd files";            ls -1 /etc/cups/ppd 2>/dev/null || echo "(unreadable without root)"
} > "$OUT/15-printing.txt"

# ---------------------------------------------------------------- modified files
if [ "$QUICK" -eq 0 ]; then
    say "dpkg -V scan for modified package files (takes a few minutes)..."
    dpkg -V 2>/dev/null | grep -E '^(..5|missing)' | sort -k2 > "$OUT/16-modified-pkg-files.txt"
else
    echo "(skipped: --quick mode)" > "$OUT/16-modified-pkg-files.txt"
fi

say "local /etc customizations"
{
    for d in /etc/X11/xorg.conf.d /etc/udev/rules.d /etc/sysctl.d /etc/modprobe.d /etc/ssh/sshd_config.d; do
        hdr "DIR: $d"; ls -1 "$d" 2>/dev/null || echo "(empty/missing)"; echo
    done
    for f in /etc/X11/xorg.conf.d/* /etc/udev/rules.d/*; do
        [ -f "$f" ] && catfile "$f" 60
    done
    catfile /etc/environment 20
    catfile /etc/gdm3/custom.conf 40
    catfile /etc/apt/apt.conf.d/20auto-upgrades 20
    catfile /etc/default/grub 60
} > "$OUT/17-etc-local.txt"

# ---------------------------------------------------------------- ssh / network
{
    hdr "~/.ssh contents (names only)"; ls -1 "$HOME/.ssh" 2>/dev/null
    catfile "$HOME/.ssh/config" 100
    hdr "ssh server enabled"; systemctl is-enabled ssh 2>&1
    for f in /etc/ssh/sshd_config.d/*; do [ -f "$f" ] && catfile "$f" 40; done
} > "$OUT/18-ssh.txt"

{
    hdr "network connections (names/types only)"
    have nmcli && nmcli -f NAME,TYPE con show 2>/dev/null | sort || echo "(nmcli not available)"
    hdr "interfaces"; ip -brief link 2>/dev/null | awk '{print $1}'
    hdr "tailscale"; have tailscale && tailscale version 2>/dev/null | head -1 || echo "(tailscale not installed)"
    hdr "tailscaled enabled"; systemctl is-enabled tailscaled 2>&1
    hdr "ufw enabled (service)"; systemctl is-enabled ufw 2>&1
} > "$OUT/19-network.txt"

# ---------------------------------------------------------------- desktop
say "desktop / GNOME"
{
    hdr "gnome-shell version"; gnome-shell --version 2>/dev/null || echo "(n/a)"
    hdr "session type"; echo "${XDG_SESSION_TYPE:-unknown}"
    hdr "dconf dump / (all non-default settings)"
    if have dconf; then dconf dump / 2>/dev/null | redact | head -1000; else echo "(dconf not available)"; fi
} > "$OUT/20-dconf.txt"

{
    hdr "gnome-extensions list"; gnome-extensions list 2>/dev/null || echo "(n/a — no session bus?)"
    hdr "user extensions dir";   ls -1 "$HOME/.local/share/gnome-shell/extensions" 2>/dev/null
    hdr "system extensions dir"; ls -1 /usr/share/gnome-shell/extensions 2>/dev/null
    hdr "xdg-mime text/markdown";   xdg-mime query default text/markdown 2>/dev/null
    hdr "xdg-mime application/pdf"; xdg-mime query default application/pdf 2>/dev/null
    catfile "$HOME/.config/mimeapps.list" 60
    hdr "user autostart entries"
    for f in "$HOME/.config/autostart/"*.desktop; do [ -f "$f" ] && catfile "$f" 25; done
} > "$OUT/21-desktop.txt"

{
    hdr "firefox user.js files (snap profile)"
    find "$HOME/snap/firefox/common/.mozilla/firefox" -maxdepth 2 -name user.js 2>/dev/null | while read -r f; do catfile "$f" 40; done
    catfile "$HOME/.config/kcminputrc" 20
} > "$OUT/22-app-tweaks.txt"

# ---------------------------------------------------------------- docker
{
    hdr "docker version"; have docker && docker --version 2>/dev/null || echo "(docker not installed)"
    hdr "docker enabled"; systemctl is-enabled docker 2>&1
    hdr "docker networks"; docker network ls --format '{{.Name}}' 2>/dev/null | sort || echo "(daemon unreachable or no permission)"
    hdr "docker containers (name, image)"; docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | sort || true
} > "$OUT/23-docker.txt"

# ---------------------------------------------------------------- users / home
{
    hdr "id"; id
    hdr "human users"; getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1" uid="$3" shell="$7}'
    for g in sudo docker video adm; do hdr "group $g"; getent group "$g" | cut -d: -f4; done
} > "$OUT/24-users-groups.txt"

say "home & local bins"
{
    for d in /usr/local/bin /usr/local/sbin /opt "$HOME/bin" "$HOME/.local/bin" "$HOME/tools"; do
        hdr "DIR: $d"; ls -1 "$d" 2>/dev/null || echo "(empty/missing)"; echo
    done
    hdr "~/Projects (names only)"; ls -1 "$HOME/Projects" 2>/dev/null || echo "(none)"
    hdr "diff /etc/skel/.bashrc vs ~/.bashrc (additions = your customizations)"
    diff -u /etc/skel/.bashrc "$HOME/.bashrc" 2>/dev/null | redact || true
    hdr "diff /etc/skel/.profile vs ~/.profile"
    diff -u /etc/skel/.profile "$HOME/.profile" 2>/dev/null || true
} > "$OUT/25-home.txt"

# ---------------------------------------------------------------- wrap up
tar -C "$PARENT" -czf "$OUT.tar.gz" "$(basename "$OUT")"
say "done"
echo
echo "Audit written to:  $OUT"
echo "Tarball:           $OUT.tar.gz"
echo
echo "Copy the tarball to the other machine (or back to the primary one) to compare."
