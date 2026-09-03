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

# Cloud AMIs can ship /etc/sudoers.d closed to non-root (0750), so fall back
# to a prompt-free sudo read — NOPASSWD working is itself the thing checked.
sudoers_rule="/etc/sudoers.d/010-$(id -un | tr '.' '_')-nopasswd"
if [ -s "$sudoers_rule" ] || sudo -n test -s "$sudoers_rule" 2>/dev/null; then
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
    if claude_bedrock_ready; then p "claude → Amazon Bedrock (managed settings; no login needed)"
    elif claude_ready; then p "claude logged in"
    else s "claude not logged in yet (run 'claude')"; fi
else
    f "claude not on PATH"
fi

if grep -qE 'PATH=.*\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    p ".bashrc puts ~/.local/bin on PATH (claude reachable without a login shell)"
else
    f ".bashrc does not export ~/.local/bin — claude off PATH in DCV/cloud sessions"
fi

if is_dcv_terminal; then
    if [ -x "$HOME/.local/bin/cc-launcher" ] && grep -q "^alias cc='cc-launcher'" "$HOME/.bashrc" 2>/dev/null; then
        p "cc is menu-first (cc-launcher) on this DCV terminal"
    else
        f "cc-launcher missing or cc alias not pointing at it (10-claude-code, DCV branch)"
    fi
fi

if [ -x "$HOME/.local/bin/cct-finish" ] && grep -q 'claude-terminal postlogin-finish' "$HOME/.bashrc" 2>/dev/null; then
    p "cct-finish + post-login hook installed"
else
    f "cct-finish or its .bashrc hook missing (re-run ./bootstrap.sh)"
fi

if [ -x "$HOME/.bun/bin/bun" ]; then p "bun $("$HOME/.bun/bin/bun" --version)"; else f "bun missing"; fi
if have uv || [ -x "$HOME/.local/bin/uv" ]; then p "uv installed"; else f "uv missing"; fi

if [ -d "$HOME/.claude/plugins/cache/thedotmack" ]; then
    p "claude-mem plugin (thedotmack) present"
else
    if claude_bedrock_ready; then s "claude-mem plugin not installed yet (re-run ./bootstrap.sh or cct-finish)"
    else s "claude-mem plugin not installed yet (needs claude login + re-run bootstrap)"; fi
fi
if [ -d "$HOME/.claude/plugins/cache/superpowers-marketplace" ]; then
    p "superpowers plugin present"
else
    if claude_bedrock_ready; then s "superpowers plugin not installed yet (re-run ./bootstrap.sh or cct-finish)"
    else s "superpowers plugin not installed yet (needs claude login + re-run bootstrap)"; fi
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

# A root-owned XDG dir silently defeats dconf/xdg-mime writes (gsettings still
# exits 0), so check ownership before trusting any GNOME state below.
_xdg_bad=""
for _d in .config .local .cache; do
    [ -e "$HOME/$_d" ] || continue
    [ "$(stat -c %u "$HOME/$_d" 2>/dev/null)" = "$(id -u)" ] || _xdg_bad="$_xdg_bad ~/$_d"
done
if [ -n "$_xdg_bad" ]; then
    f "not owned by $(id -un):$_xdg_bad — user-level writes (dconf, xdg-mime) fail silently; re-run ./bootstrap.sh to repair"
else
    p "XDG dirs owned by $(id -un)"
fi

# GNOME state reads straight from the dconf database — no session or bus
# needed, so these run on headless boxes too (cloud/DCV, unattended builds).
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.shell$'; then
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
    # DCV hosts lock the dock to Chrome (no Firefox snap there); everywhere
    # else the kit pins Firefox. Same three-slot dock, different browser.
    if is_dcv_terminal; then
        FAVS="['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"
        FAVS_LABEL="Chrome, Files, Terminal (host-managed)"
    else
        FAVS="['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"
        FAVS_LABEL="Firefox, Files, Terminal"
    fi
    if [ "$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)" = "$FAVS" ]; then
        p "dock favorites converged ($FAVS_LABEL)"
    else
        f "dock favorites are $(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo unreadable) — expected $FAVS_LABEL"
    fi
    if have dconf && [ -n "$(dconf dump /org/gnome/terminal/legacy/ 2>/dev/null)" ]; then
        p "terminal prefs present (seeded or user-customized)"
    else
        f "GNOME Terminal prefs tree empty — 42-terminal-prefs never seeded"
    fi
else
    s "no GNOME desktop on this box — GNOME checks skipped"
fi

if is_dcv_terminal; then
    s "DCV terminal — host owns session config (GDM not in use) — Wayland check n/a"
elif [ -d /etc/gdm3 ]; then
    if grep -qE '^WaylandEnable=false' /etc/gdm3/custom.conf 2>/dev/null; then
        p "Wayland disabled at GDM (X11 forced)"
    else
        f "WaylandEnable=false not set in /etc/gdm3/custom.conf (RustDesk/Splashtop need X11)"
    fi
else
    s "no GDM on this box (session comes from xrdp/etc.) — Wayland check n/a"
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

# ---- medical mode ----------------------------------------------------------------
# Only on Ai Build Medical terminals; the bar is zero FAILs on a fresh provision.
# DCV-only, like the modules: a marker on a non-DCV box is a SKIP, not 15 FAILs.
if is_medical_terminal && ! is_dcv_terminal; then
    s "medical marker present but this is not a DCV terminal — medical mode is DCV-only, checks skipped"
elif is_medical_terminal; then
    log "medical mode (Ai Build Medical)"
    M=/etc/claude-code/managed-settings.json
    if [ -r "$M" ] && [ "$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // empty' "$M" 2>/dev/null)" = "1" ]; then
        p "managed settings pin Claude Code to Bedrock"
        for k in AWS_REGION ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; do
            v="$(jq -r ".env.$k // empty" "$M" 2>/dev/null)"
            if [ -n "$v" ]; then p "managed env $k=$v"; else f "managed env $k missing"; fi
        done
    else
        f "$M missing or does not set CLAUDE_CODE_USE_BEDROCK=1 (08-medical-bedrock)"
    fi
    if grep -q '^# >>> claude-terminal medical env >>>' /etc/bash.bashrc 2>/dev/null; then
        p "/etc/bash.bashrc exports the Bedrock env (DCV shells are non-login)"
    else
        f "/etc/bash.bashrc lacks the medical env block"
    fi
    if [ -f /etc/profile.d/claude-terminal-medical.sh ]; then p "profile.d medical env present"; else f "/etc/profile.d/claude-terminal-medical.sh missing"; fi

    KEYRE='^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|GEMINI_API_KEY|OPENROUTER_API_KEY)='
    keyhit=0
    for kf in /etc/environment /etc/profile.d/*.sh "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.claude-mem/.env"; do
        [ -f "$kf" ] || continue
        if grep -qE "$KEYRE" "$kf" 2>/dev/null; then f "provider credential line in $kf"; keyhit=1; fi
    done
    if [ -s "$HOME/.claude/settings.json" ] && jq -e '(.env.ANTHROPIC_API_KEY // .env.ANTHROPIC_AUTH_TOKEN // .apiKeyHelper) != null' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
        f "API-key settings in ~/.claude/settings.json"; keyhit=1
    fi
    [ "$keyhit" = 0 ] && p "no provider API keys on the box"
    [ -f "$HOME/.claude/.credentials.json" ] && s "OAuth login present in ~/.claude (unused — Bedrock forced; a medical box should not carry one)"

    CMS="$HOME/.claude-mem/settings.json"
    if [ -s "$CMS" ] && [ "$(jq -r '.CLAUDE_MEM_MODEL // empty' "$CMS" 2>/dev/null)" = "sonnet" ] \
       && [ "$(jq -r '.CLAUDE_MEM_TELEMETRY // empty' "$CMS" 2>/dev/null)" = "0" ]; then
        p "claude-mem pinned (sonnet via CLI, telemetry off)"
    else
        f "claude-mem settings not pinned (21-medical-claude-mem)"
    fi

    if [ -f /usr/share/backgrounds/claude-terminal-medical.svg ]; then p "medical wallpaper installed"; else f "medical wallpaper missing"; fi
    if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.desktop\.background$'; then
        if [ "$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)" = "'file:///usr/share/backgrounds/claude-terminal-medical.svg'" ]; then
            p "medical wallpaper selected"
        else
            f "wallpaper is $(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null || echo unreadable)"
        fi
    fi
    if grep -q '^# >>> claude-terminal medical banner >>>' "$HOME/.bashrc" 2>/dev/null; then p "shell banner installed"; else f "shell banner missing from ~/.bashrc"; fi
    if grep -q 'Ai Build Medical' /etc/motd 2>/dev/null; then p "motd line present"; else f "motd line missing"; fi

    # Host-side belt-and-braces: the enforced permissions come from the broker
    # per session; desktop-setup.sh also writes the deny into default.perm —
    # after the DCV server is installed, which is later than the provision-time
    # verify run, so "no DCV yet" is a SKIP.
    if [ ! -d /etc/dcv ]; then
        s "DCV server not installed yet — default.perm check n/a"
    elif grep -qE '^[[:space:]]*%any%[[:space:]]+deny[[:space:]]+.*file-download' /etc/dcv/default.perm 2>/dev/null; then
        p "DCV default.perm denies file-download"
    else
        f "/etc/dcv/default.perm does not deny file-download (host: desktop-setup.sh medical branch)"
    fi
fi

# ---- scheduling hygiene (#16) ------------------------------------------------
# Terminal boxes sleep more than they run. A timed crontab entry has no
# catch-up — it silently skips every night the box is off at that minute —
# and a calendar timer only survives downtime with Persistent=true. anacron
# covers /etc/cron.daily|weekly|monthly, so run-parts jobs are fine. Only
# local units (files in /etc/systemd/system) are policed: stock distro timers
# are Ubuntu's problem, jobs added on an engagement are ours.
if systemctl list-units >/dev/null 2>&1; then
    BADT=""
    while read -r t _; do
        [ -f "/etc/systemd/system/$t" ] || continue
        [ -n "$(systemctl show "$t" -p TimersCalendar --value 2>/dev/null)" ] || continue
        [ "$(systemctl show "$t" -p Persistent --value 2>/dev/null)" = "yes" ] || BADT="$BADT $t"
    done < <(systemctl list-unit-files --type=timer --state=enabled --no-legend 2>/dev/null)
    if [ -n "$BADT" ]; then
        f "calendar timer(s) without Persistent=true:$BADT — they silently skip while the box sleeps"
    else
        p "local calendar timers all have Persistent=true (missed runs fire on wake)"
    fi
    CRONS=$({ crontab -l 2>/dev/null; sudo -n crontab -l 2>/dev/null; } \
        | grep -cE '^[[:space:]]*([0-9*]|@(hourly|daily|midnight|weekly|monthly|yearly|annually))')
    if [ "${CRONS:-0}" -gt 0 ]; then
        f "$CRONS timed crontab entr(y|ies) — plain cron has no catch-up on a box that sleeps; use a Persistent=true systemd timer"
    else
        p "no timed crontab entries (user/root)"
    fi
else
    s "systemd not reachable — scheduling hygiene checks skipped"
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

# ---- am I up to date? -------------------------------------------------------
# Three separate clocks, and nothing reported them together until now:
#   1. the KIT      (~/claude-terminal, pulled by get.sh)
#   2. the RELEASE  (/opt/asp/applied-version, applied by auto-update.sh)
#   3. the PORTAL   (control plane, its own version — not visible from a box)
# This answers 1 and 2 for the box you are standing on, offline by design: no
# network call, so it never hangs and never lies about what it could not reach.
echo
log "claude-terminal verify — versions"
KITV=$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)
if [ "$KITV" = unknown ]; then
    s "kit version unknown — not a git checkout, so get.sh cannot be updating it"
else
    KITD=$(git -C "$SCRIPT_DIR" log -1 --format=%cd --date=short 2>/dev/null || echo "?")
    KITT=$(git -C "$SCRIPT_DIR" log -1 --format=%ct 2>/dev/null || date +%s)
    KITAGE=$(( ( $(date +%s) - KITT ) / 86400 ))
    # get.sh pulls on every run and the fleet runs it daily, so a checkout more
    # than a week stale means the pull is not happening — not that nothing shipped.
    if [ "$KITAGE" -gt 7 ]; then
        f "kit $KITV is from $KITD (${KITAGE}d old) — get.sh is not pulling; run: git -C $SCRIPT_DIR pull && $SCRIPT_DIR/bootstrap.sh"
    else
        p "kit $KITV ($KITD)"
    fi
fi

if is_dcv_terminal; then
    APPLIED=$(cat /opt/asp/applied-version 2>/dev/null || echo none)
    if [ "$APPLIED" = none ]; then
        s "no platform release applied yet (/opt/asp/applied-version absent)"
    else
        p "platform release $APPLIED"
    fi
    # auto-update.sh writes this ONLY while it is refusing to apply something,
    # so its presence is the honest "you are behind, and here is why" signal.
    DEFER=/var/lib/asp/update-deferred.json
    if [ -r "$DEFER" ]; then
        DEFMSG=$(asp_defer_summary "$DEFER")
        DEFH=${DEFMSG%%|*}
        if [ -n "$DEFMSG" ] && [ "${DEFH:-0}" -ge 72 ]; then
            f "release ${DEFMSG#*|} — stuck past 72h; something is holding this box on the old release"
        elif [ -n "$DEFMSG" ]; then
            s "release ${DEFMSG#*|} — deferring normally, will retry"
        else
            s "a release is deferred but $DEFER could not be read"
        fi
    fi
fi
echo
if [ "$FAILED" = 1 ]; then
    warn "verify finished with failures"
    exit 1
fi
log "verify finished — no failures"
