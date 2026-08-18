#!/usr/bin/env bash
# claude-terminal bootstrap: turn stock Ubuntu 24.04 Desktop into a Claude Code
# terminal. Core always runs; extras are opt-in. Idempotent — re-run any time
# (re-running IS the upgrade path).
#
#   ./bootstrap.sh                         # core only
#   ./bootstrap.sh --with-docker --with-xrdp
#   ./bootstrap.sh --all-extras            # every extra except weak-passwords/splashtop
#   ./bootstrap.sh --list                  # show modules
#   ./bootstrap.sh --medical               # DCV terminals only: mark the box Ai Build Medical
#   ./bootstrap.sh --force-os              # skip the Ubuntu 24.04 check
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
  --medical        DCV terminals only: mark this box as an Ai Build Medical
                   (PHI-approved) terminal — writes /etc/claude-terminal/medical so
                   the medical modules run on this and every later run (Claude Code
                   → Amazon Bedrock only). The platform normally sets this itself
                   (ASP_PROFILE=medical); refused on non-DCV boxes.
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
        --medical)    CT_MEDICAL=1 ;;
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

# --medical is state, not a per-run switch: the marker persists so unattended
# re-runs (the DCV updater passes no flags) keep the box medical.
if [ "${CT_MEDICAL:-0}" = 1 ]; then
    is_dcv_terminal || die "--medical is DCV-only for now: this box has no /etc/asp-terminal.env and no DCV server (marker not written)."
    { sudo install -d -m 0755 /etc/claude-terminal && sudo touch /etc/claude-terminal/medical; } \
        || die "could not write /etc/claude-terminal/medical"
    log "medical mode marker written — the medical modules run on this and every later run"
fi

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

DEFERRED=()
for f in "$SCRIPT_DIR"/modules/core/*.sh; do
    # "# ct-after-extras" defers a core module to the end of the run — see below.
    if grep -q '^# ct-after-extras' "$f"; then DEFERRED+=("$f"); continue; fi
    run_module "$f"
done
for e in ${EXTRAS[@]+"${EXTRAS[@]}"}; do
    run_module "$SCRIPT_DIR/modules/extra/$e.sh"
done
# A core module that acts on something an *extra* installs has to wait for it.
# 41-splashtop-cursorfix needs the streamer that --with-splashtop provides, and
# extras run after core — so without this, a fresh box's crash guard would skip
# on the run that installed Splashtop and only land on the next one.
for f in ${DEFERRED[@]+"${DEFERRED[@]}"}; do
    run_module "$f"
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

# Advertise opt-in extras that didn't run and aren't already on the box. A module
# opts in with "# ct-suggest: <command>|<hint>"; <command> is what proves it's
# already installed. Adding another (rustdesk, say) is a module file only —
# nothing here changes.
for f in "$SCRIPT_DIR"/modules/extra/*.sh; do
    suggest="$(sed -n 's/^# ct-suggest: //p' "$f" | head -1)"
    [ -n "$suggest" ] || continue
    probe="${suggest%%|*}"
    hint="${suggest#*|}"
    [ "$probe" = "$suggest" ] && probe=""   # no '|' present: always suggest
    if [ -n "$probe" ] && have "$probe"; then continue; fi
    name="$(basename "$f" .sh)"
    ran=0
    for x in ${EXTRAS[@]+"${EXTRAS[@]}"}; do [ "$x" = "$name" ] && ran=1; done
    [ "$ran" = 1 ] || next_step "$hint"
done

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
