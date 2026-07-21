# shellcheck shell=bash
# ct-desc: claude-mem persistent memory, v10 plugin architecture (thedotmack marketplace)

claude_ready || skip "Claude Code not logged in yet — run 'claude', then re-run ./bootstrap.sh"

if claude plugin list 2>/dev/null | grep -qi 'claude-mem'; then
    ok "already installed"
fi

if ! claude plugin marketplace list 2>/dev/null | grep -qi 'thedotmack'; then
    claude plugin marketplace add thedotmack/claude-mem \
        || fail "marketplace add failed — inside claude, run: /plugin marketplace add thedotmack/claude-mem"
fi

claude plugin install claude-mem@thedotmack \
    || fail "plugin install failed — inside claude, run: /plugin install claude-mem@thedotmack"

next_step "claude-mem installed — restart any open claude session to activate it."
ok "installed claude-mem@thedotmack"
