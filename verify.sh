#!/usr/bin/env bash
# Read-only state check for a claude-terminal box. Prints PASS/FAIL/SKIP per
# item; exits 1 if anything FAILs. Safe to run any time.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

FAILED=0
p() { printf '  %sPASS%s  %s\n' "$C_GREEN"  "$C_OFF" "$*"; }
f() { printf '  %sFAIL%s  %s\n' "$C_RED"    "$C_OFF" "$*"; FAILED=1; }
s() { printf '  %sSKIP%s  %s\n' "$C_YELLOW" "$C_OFF" "$*"; }

log "claude-terminal verify — core"

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    p "Ubuntu 24.04 (${PRETTY_NAME:-})"
else
    f "OS is ${PRETTY_NAME:-unknown}, expected Ubuntu 24.04"
fi

for pkg in git gh tmux curl jq unzip lynx xvfb openssh-server; do
    if pkg_installed "$pkg"; then p "apt: $pkg"; else f "apt: $pkg missing"; fi
done

sudoers_rule="/etc/sudoers.d/010-$(id -un | tr '.' '_')-nopasswd"
if [ -s "$sudoers_rule" ]; then
    p "passwordless sudo rule present"
else
    f "passwordless sudo rule missing or empty ($sudoers_rule)"
fi

# shellcheck disable=SC2088  # tilde is display text; the test itself uses $HOME
if [ -d "$HOME/Projects" ]; then p "~/Projects exists"; else f "~/Projects missing"; fi

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"

if have node && [ "$(node -v | sed 's/^v//; s/\..*//')" = "20" ]; then
    p "node $(node -v)"
else
    f "node 20 not found ($(node -v 2>/dev/null || echo none))"
fi

if [ "$(npm config get prefix 2>/dev/null)" = "$HOME/.npm-global" ]; then
    p "npm prefix ~/.npm-global"
else
    f "npm prefix is '$(npm config get prefix 2>/dev/null)', expected ~/.npm-global"
fi

if have claude; then
    p "claude $(claude --version 2>/dev/null | head -1)"
    if claude_ready; then p "claude logged in"; else s "claude not logged in yet (run 'claude')"; fi
else
    f "claude not on PATH"
fi

if [ -x "$HOME/.bun/bin/bun" ]; then p "bun $("$HOME/.bun/bin/bun" --version)"; else f "bun missing"; fi
if have uv || [ -x "$HOME/.local/bin/uv" ]; then p "uv installed"; else f "uv missing"; fi

if [ -d "$HOME/.claude/plugins/cache/thedotmack" ]; then
    p "claude-mem plugin (thedotmack) present"
else
    s "claude-mem plugin not installed yet (needs claude login + re-run bootstrap)"
fi
if [ -d "$HOME/.claude/plugins/cache/superpowers-marketplace" ]; then
    p "superpowers plugin present"
else
    s "superpowers plugin not installed yet (needs claude login + re-run bootstrap)"
fi

# claude-mem runtime artifacts only exist after the first claude session
# post-install, so absence right after bootstrap is expected (SKIP, not FAIL).
if [ -d "$HOME/.claude-mem" ]; then
    if [ -f "$HOME/.claude-mem/claude-mem.db" ]; then
        p "claude-mem database present"
    else
        s "claude-mem db not created yet (appears after first claude session)"
    fi
    if [ -f "$HOME/.claude-mem/supervisor.json" ] || [ -f "$HOME/.claude-mem/worker.pid" ]; then
        p "claude-mem worker state present"
    else
        s "claude-mem worker not started yet (starts with first session)"
    fi
else
    # shellcheck disable=SC2088  # tilde is display text
    s "~/.claude-mem not present yet (created on first claude session after install)"
fi

if have gsettings && ensure_user_dbus; then
    if [ "$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)" = "false" ]; then
        p "screen lock disabled"
    else
        f "screen lock still enabled"
    fi
    if [ "$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null)" = "uint32 0" ]; then
        p "idle blanking disabled"
    else
        f "idle-delay not 0"
    fi
else
    s "gsettings unavailable (no GUI session bus) — GNOME checks skipped"
fi

if grep -qE '^WaylandEnable=false' /etc/gdm3/custom.conf 2>/dev/null; then
    p "Wayland disabled at GDM (X11 forced)"
else
    f "WaylandEnable=false not set in /etc/gdm3/custom.conf (RustDesk/Splashtop need X11)"
fi

if [ "$(systemd-detect-virt 2>/dev/null)" = "microsoft" ]; then
    if [ -f /etc/X11/xorg.conf.d/99-libinput-no-hires-scroll.conf ]; then
        p "hi-res scroll fix present"
    else
        f "hi-res scroll fix missing"
    fi
    if id -nG | grep -qw video; then p "user in video group"; else f "user not in video group"; fi
else
    s "not Hyper-V — VM QoL checks skipped"
fi

if pkg_installed okular; then p "okular installed"; else f "okular missing"; fi
if [ "$(xdg-mime query default text/markdown 2>/dev/null)" = "okularApplication_md.desktop" ]; then
    p "markdown opens in okular"
else
    s "text/markdown default is '$(xdg-mime query default text/markdown 2>/dev/null)'"
fi

# ---- 41-splashtop-cursorfix ---------------------------------------------------
# Only meaningful where Splashtop is installed; RustDesk/other boxes SKIP.
cursors_static() {   # exit 0 when no animated Xcursor files live under $1/*/cursors/
    python3 - "$1" <<'PY'
import struct, glob, os, sys
bad = 0
for p in glob.glob(os.path.join(sys.argv[1], '*', 'cursors', '*')):
    if os.path.islink(p) or not os.path.isfile(p) or p.endswith('.animated'):
        continue
    d = open(p, 'rb').read()
    if d[:4] != b'Xcur':
        continue
    n = struct.unpack_from('<I', d, 12)[0]
    seen = {}
    for i in range(n):
        t, sub, _ = struct.unpack_from('<III', d, 16 + i * 12)
        if t == 0xfffd0002:
            seen[sub] = seen.get(sub, 0) + 1
    if seen and max(seen.values()) > 1:
        bad += 1
sys.exit(1 if bad else 0)
PY
}

if ! pkg_installed splashtop-streamer; then
    s "no Splashtop streamer — cursor-crash-guard checks skipped"
elif ! have python3; then
    s "no python3 — cursor-crash-guard checks skipped"
else
    if [ -d /usr/share/icons ]; then
        if cursors_static /usr/share/icons; then p "host cursor themes all static"
        else f "animated cursors remain under /usr/share/icons"; fi
    else
        s "no /usr/share/icons — host cursor check skipped"
    fi

    gct=/snap/gtk-common-themes/current/share/icons
    if [ -d "$gct" ]; then
        if cursors_static "$gct"; then p "snap theme cursors all static"
        else f "animated cursors remain in gtk-common-themes (snap apps will crash the streamer)"; fi
    else
        s "gtk-common-themes snap absent — snap cursor check skipped"
    fi

    if dpkg-divert --list 2>/dev/null | grep -q '\.animated$'; then
        p "cursor diversions in place (survive theme upgrades)"
    else
        f "no .animated dpkg diversions — theme upgrades will restore animated cursors"
    fi

    if [ -e /var/lib/snapd/desktop/applications/firefox_firefox.desktop ]; then
        if grep -q '^StartupNotify=false$' /usr/local/share/applications/firefox_firefox.desktop 2>/dev/null; then
            p "Firefox launch spinner disabled"
        else
            f "Firefox .desktop override missing or still StartupNotify=true"
        fi
    else
        s "no snap Firefox — launch-spinner check skipped"
    fi

    if systemctl cat SRStreamer.service >/dev/null 2>&1; then
        if [ -e /usr/local/lib/splashtop-pixbuf-shim.so ] &&
           systemctl show SRStreamer.service -p Environment 2>/dev/null | grep -q splashtop-pixbuf-shim; then
            p "pixbuf race shim wired into SRStreamer.service"
        else
            f "pixbuf race shim not wired into SRStreamer.service"
        fi
    else
        s "no SRStreamer.service — shim check skipped"
    fi
fi

log "extras (reported only when artifacts exist)"
if pkg_installed docker-ce; then
    if systemctl is-active docker >/dev/null 2>&1; then p "docker active"; else f "docker installed but not active"; fi
fi
if pkg_installed xrdp; then
    if systemctl is-active xrdp >/dev/null 2>&1; then p "xrdp active"; else f "xrdp installed but not active"; fi
fi
if have tailscale; then
    if systemctl is-active tailscaled >/dev/null 2>&1; then p "tailscaled active"; else f "tailscale installed but daemon inactive"; fi
fi
if pkg_installed splashtop-streamer; then
    if systemctl is-active SRStreamer.service >/dev/null 2>&1; then
        p "splashtop streamer active"
    else
        f "splashtop installed but SRStreamer.service inactive"
    fi
fi
if pkg_installed cups-browsed && systemctl is-enabled cups-browsed >/dev/null 2>&1; then
    s "cups-browsed still enabled (run --with-printing-direct to disable auto-queues)"
fi

echo
if [ "$FAILED" = 1 ]; then
    warn "verify finished with failures"
    exit 1
fi
log "verify finished — no failures"
