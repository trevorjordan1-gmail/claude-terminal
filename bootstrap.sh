#!/usr/bin/env bash
# claude-terminal bootstrap: turn stock Ubuntu 24.04 Desktop into a Claude Code
# terminal. Core always runs; extras are opt-in. Idempotent — re-run any time
# (re-running IS the upgrade path).
#
#   ./bootstrap.sh                         # core only
#   ./bootstrap.sh --with-docker --with-xrdp
#   ./bootstrap.sh --all-extras            # every extra except weak-passwords/splashtop
#   ./bootstrap.sh --list                  # show modules
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SAFE_EXTRAS="docker xrdp tailscale printing-direct buildtools usagemeter"

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [options]

Options:
  --with-<extra>   Add an extra module (repeatable). See --list for names.
  --all-extras     Add all safe extras (excludes weak-passwords and splashtop,
                   which require explicit intent).
  --list           Show all modules and descriptions, then exit.
  --force-os       Skip the Ubuntu 24.04 check.
  -h, --help       This help.

Examples:
  ./bootstrap.sh
  ./bootstrap.sh --with-docker --with-tailscale
  curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash -s -- --with-xrdp
EOF
}

list_modules() {
    printf 'Core modules (always run, in order):\n'
    local f
    for f in "$SCRIPT_DIR"/modules/core/*.sh; do
        printf '  %-20s %s\n' "$(basename "$f" .sh)" "$(sed -n 's/^# ct-desc: //p' "$f" | head -1)"
    done
    printf '\nExtra modules (opt-in with --with-<name>):\n'
    for f in "$SCRIPT_DIR"/modules/extra/*.sh; do
        printf '  %-20s %s\n' "$(basename "$f" .sh)" "$(sed -n 's/^# ct-desc: //p' "$f" | head -1)"
    done
}

# ---- parse args ---------------------------------------------------------------
WITH=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage; exit 0 ;;
        --list)       list_modules; exit 0 ;;
        --force-os)   CT_FORCE_OS=1 ;;
        --all-extras) for e in $SAFE_EXTRAS; do WITH+=("$e"); done ;;
        --with-*)     WITH+=("${1#--with-}") ;;
        *)            die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# Validate + dedup extras, preserving order.
EXTRAS=()
for e in ${WITH[@]+"${WITH[@]}"}; do
    [ -f "$SCRIPT_DIR/modules/extra/$e.sh" ] || die "No such extra: $e (see --list)"
    dup=0
    for x in ${EXTRAS[@]+"${EXTRAS[@]}"}; do [ "$x" = "$e" ] && dup=1; done
    [ "$dup" = 1 ] || EXTRAS+=("$e")
done

require_not_root
require_ubuntu_2404

# Tools installed earlier in this same run must resolve immediately.
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"

log "sudo is needed for apt operations — you may be prompted once."
sudo -v || die "sudo access is required."

CT_TMP="$(mktemp -d)"
CT_NEXT="$CT_TMP/next-steps"
: > "$CT_NEXT"
trap 'rm -rf "$CT_TMP"' EXIT

RESULTS=()

run_module() {
    local file="$1" name status reason rc
    name="$(basename "$file" .sh)"
    log "── ${name} ──────────────────────────────"
    CT_STATUS="$CT_TMP/status"
    : > "$CT_STATUS"
    (
        # Modules inherit everything (functions, CT_* vars) and end via
        # ok / skip / fail, which exit this subshell.
        # shellcheck disable=SC1090
        . "$file"
        # A module that falls off the end without reporting counts as OK.
        printf 'OK\t\n' > "$CT_STATUS"
    )
    rc=$?
    status=""; reason=""
    IFS=$'\t' read -r status reason < "$CT_STATUS" || true
    if [ -z "$status" ]; then
        if [ "$rc" -eq 0 ]; then
            status="OK"
        else
            status="FAIL"; reason="exited $rc without reporting"
        fi
    fi
    RESULTS+=("${name}|${status}|${reason}")
}

for f in "$SCRIPT_DIR"/modules/core/*.sh; do
    run_module "$f"
done
for e in ${EXTRAS[@]+"${EXTRAS[@]}"}; do
    run_module "$SCRIPT_DIR/modules/extra/$e.sh"
done

# ---- summary --------------------------------------------------------------------
echo
log "══ Summary ══════════════════════════════"
FAILED=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r name status reason <<< "$r"
    case "$status" in
        OK)   printf '  %s%-7s%s %-20s %s\n' "$C_GREEN"  "OK"      "$C_OFF" "$name" "$reason" ;;
        SKIP) printf '  %s%-7s%s %-20s %s\n' "$C_YELLOW" "SKIPPED" "$C_OFF" "$name" "$reason" ;;
        *)    printf '  %s%-7s%s %-20s %s\n' "$C_RED"    "FAILED"  "$C_OFF" "$name" "$reason"; FAILED=1 ;;
    esac
done

if ! claude_ready; then
    next_step "Run 'claude' once to log in to Claude Code, then re-run ./bootstrap.sh so the plugin modules (claude-mem, superpowers) can finish."
fi

if [ -s "$CT_NEXT" ]; then
    echo
    log "══ NEXT STEPS ═══════════════════════════"
    awk '!seen[$0]++ { printf "  %d. %s\n", ++n, $0 }' "$CT_NEXT"
fi

echo
if [ "$FAILED" = 1 ]; then
    warn "Some modules failed — fix the cause (or just re-run ./bootstrap.sh; it is safe to repeat)."
    exit 1
fi
log "Done. Re-run ./bootstrap.sh any time; run ./verify.sh to check state."
