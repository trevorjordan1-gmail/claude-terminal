# shellcheck shell=bash
# ct-desc: Bun runtime (required by the claude-mem v10 background worker)

if [ -x "$HOME/.bun/bin/bun" ] || have bun; then
    ok "bun $("$HOME/.bun/bin/bun" --version 2>/dev/null || bun --version 2>/dev/null)"
fi

log "installing bun (official installer)"
curl -fsSL https://bun.sh/install | bash || fail "bun installer failed"
[ -x "$HOME/.bun/bin/bun" ] || fail "bun missing after install"

ok "bun $("$HOME/.bun/bin/bun" --version)"
