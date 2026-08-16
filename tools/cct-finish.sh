#!/usr/bin/env bash
# cct-finish — finish the login-gated bootstrap steps (claude-mem + superpowers
# plugins) without a full ./bootstrap.sh. No sudo, no apt — safe to run any
# time. Installed to ~/.local/bin by modules/core/27-postlogin-finish.sh, which
# also adds a .bashrc hook that runs this automatically on the first
# interactive shell where claude is logged in but the plugins are missing —
# cloud/DCV provisions run headless, so nobody sees bootstrap's "re-run after
# login" reminder.
set -u

REPO="${CT_REPO:-$HOME/claude-terminal}"
[ -f "$REPO/lib/common.sh" ] || { printf 'cct-finish: repo not found at %s\n' "$REPO" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"

if ! claude_ready; then
    log "claude is not logged in yet — run 'claude', sign in, then open a new shell."
    exit 0
fi

CT_TMP="$(mktemp -d)"
CT_NEXT="$CT_TMP/next-steps"
: > "$CT_NEXT"
trap 'rm -rf "$CT_TMP"' EXIT
# shellcheck disable=SC2034  # consumed by the sourced modules (asset paths etc.)
SCRIPT_DIR="$REPO"

rc=0
for m in 20-claude-mem 25-superpowers; do
    CT_STATUS="$CT_TMP/status"
    : > "$CT_STATUS"
    (
        # Same contract as bootstrap.sh's dispatcher: the module is sourced in
        # a subshell and ends via ok/skip/fail.
        # shellcheck disable=SC1090
        . "$REPO/modules/core/$m.sh"
        printf 'OK\t\n' > "$CT_STATUS"
    )
    status=""; reason=""
    IFS=$'\t' read -r status reason < "$CT_STATUS" || true
    printf '  %-16s %s %s\n' "$m" "${status:-FAIL}" "${reason:-}"
    if [ "${status:-FAIL}" = "FAIL" ]; then rc=1; fi
done

if [ -s "$CT_NEXT" ]; then
    log "NEXT STEPS"
    awk '!seen[$0]++ { printf "  - %s\n", $0 }' "$CT_NEXT"
fi
exit "$rc"
