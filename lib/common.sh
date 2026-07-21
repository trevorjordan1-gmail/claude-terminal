#!/usr/bin/env bash
# Shared helpers for claude-terminal. Sourced by bootstrap.sh, verify.sh,
# and (via the dispatcher's subshell) every module.

# ---- colors / logging -------------------------------------------------------
if [ -t 1 ]; then
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
    C_BLUE=$'\033[34m'; C_OFF=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_OFF=""
fi

log()  { printf '%s[claude-terminal]%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
warn() { printf '%s[claude-terminal]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[claude-terminal] ERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---- module status protocol --------------------------------------------------
# Each module runs sourced inside a subshell and must end through exactly one of
# these. Status lands in $CT_STATUS for the dispatcher; next_step lines collect
# in $CT_NEXT and print at the end of the run.
ok()   { printf 'OK\t%s\n'   "${1:-}" > "$CT_STATUS"; exit 0; }
skip() { printf 'SKIP\t%s\n' "${1:-}" > "$CT_STATUS"; exit 0; }
fail() { printf 'FAIL\t%s\n' "${1:-}" > "$CT_STATUS"; exit 1; }

next_step() { printf '%s\n' "$*" >> "$CT_NEXT"; }

# ---- guards -------------------------------------------------------------------
require_not_root() {
    [ "$(id -u)" -ne 0 ] || die "Run as a regular user with sudo rights, not as root."
}

require_ubuntu_2404() {
    [ "${CT_FORCE_OS:-0}" = 1 ] && return 0
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
        die "This targets Ubuntu 24.04 (found: ${PRETTY_NAME:-unknown}). Re-run with --force-os to try anyway."
    fi
}

# ---- apt ----------------------------------------------------------------------
apt_update_once() {
    [ -e "$CT_TMP/apt-updated" ] && return 0
    log "apt-get update..."
    sudo apt-get update -qq && touch "$CT_TMP/apt-updated"
}

apt_install() {
    apt_update_once
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

pkg_installed() { dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# ---- idempotent config edits ----------------------------------------------------
# append_block <file> <marker>   (block content on stdin)
# Maintains a "# >>> marker >>> ... # <<< marker <<<" span: replaces it if
# present, appends it if not. Re-running with identical content is a no-op
# apart from block position after the first replacement.
append_block() {
    local file="$1" marker="$2" content tmp
    content="$(cat)"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
    awk -v m="$marker" '
        $0 == "# >>> " m " >>>" { inblock = 1; next }
        $0 == "# <<< " m " <<<" { inblock = 0; next }
        !inblock { print }
    ' "$file" > "$tmp"
    {
        cat "$tmp"
        printf '# >>> %s >>>\n%s\n# <<< %s <<<\n' "$marker" "$content" "$marker"
    } > "$file"
    rm -f "$tmp"
}

# ---- environment helpers ---------------------------------------------------------
# Make gsettings/dconf work when invoked over SSH / from a pipe, as long as the
# user has a systemd user session. Returns 1 when there is no user bus at all.
ensure_user_dbus() {
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    fi
    [ -S "$XDG_RUNTIME_DIR/bus" ]
}

# True once Claude Code is installed AND logged in (plugin operations need both).
claude_ready() {
    have claude && [ -f "$HOME/.claude/.credentials.json" ]
}
