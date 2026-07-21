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
    pkg_installed "$pkg" && p "apt: $pkg" || f "apt: $pkg missing"
done

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
    claude_ready && p "claude logged in" || s "claude not logged in yet (run 'claude')"
else
    f "claude not on PATH"
fi

[ -x "$HOME/.bun/bin/bun" ] && p "bun $("$HOME/.bun/bin/bun" --version)" || f "bun missing"
{ have uv || [ -x "$HOME/.local/bin/uv" ]; } && p "uv installed" || f "uv missing"

[ -d "$HOME/.claude/plugins/cache/thedotmack" ] \
    && p "claude-mem plugin (thedotmack) present" \
    || s "claude-mem plugin not installed yet (needs claude login + re-run bootstrap)"
[ -d "$HOME/.claude/plugins/cache/superpowers-marketplace" ] \
    && p "superpowers plugin present" \
    || s "superpowers plugin not installed yet (needs claude login + re-run bootstrap)"

if have gsettings && ensure_user_dbus; then
    [ "$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)" = "false" ] \
        && p "screen lock disabled" || f "screen lock still enabled"
    [ "$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null)" = "uint32 0" ] \
        && p "idle blanking disabled" || f "idle-delay not 0"
else
    s "gsettings unavailable (no GUI session bus) — GNOME checks skipped"
fi

if [ "$(systemd-detect-virt 2>/dev/null)" = "microsoft" ]; then
    [ -f /etc/X11/xorg.conf.d/99-libinput-no-hires-scroll.conf ] \
        && p "hi-res scroll fix present" || f "hi-res scroll fix missing"
    id -nG | grep -qw video && p "user in video group" || f "user not in video group"
else
    s "not Hyper-V — VM QoL checks skipped"
fi

pkg_installed okular && p "okular installed" || f "okular missing"
[ "$(xdg-mime query default text/markdown 2>/dev/null)" = "okularApplication_md.desktop" ] \
    && p "markdown opens in okular" || s "text/markdown default is '$(xdg-mime query default text/markdown 2>/dev/null)'"

log "extras (reported only when artifacts exist)"
pkg_installed docker-ce   && { systemctl is-active docker >/dev/null 2>&1 && p "docker active" || f "docker installed but not active"; }
pkg_installed xrdp        && { systemctl is-active xrdp   >/dev/null 2>&1 && p "xrdp active"   || f "xrdp installed but not active"; }
have tailscale            && { systemctl is-active tailscaled >/dev/null 2>&1 && p "tailscaled active" || f "tailscale installed but daemon inactive"; }
if pkg_installed cups-browsed && systemctl is-enabled cups-browsed >/dev/null 2>&1; then
    s "cups-browsed still enabled (run --with-printing-direct to disable auto-queues)"
fi

echo
if [ "$FAILED" = 1 ]; then
    warn "verify finished with failures"
    exit 1
fi
log "verify finished — no failures"
