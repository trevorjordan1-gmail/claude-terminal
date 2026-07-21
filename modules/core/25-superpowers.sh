# shellcheck shell=bash
# ct-desc: superpowers plugin — structured skills for Claude Code (planning, TDD, debugging)

claude_ready || skip "Claude Code not logged in yet — run 'claude', then re-run ./bootstrap.sh"

if claude plugin list 2>/dev/null | grep -qi 'superpowers'; then
    ok "already installed"
fi

if ! claude plugin marketplace list 2>/dev/null | grep -qi 'superpowers-marketplace'; then
    claude plugin marketplace add obra/superpowers-marketplace \
        || fail "marketplace add failed — inside claude, run: /plugin marketplace add obra/superpowers-marketplace"
fi

claude plugin install superpowers@superpowers-marketplace \
    || fail "plugin install failed — inside claude, run: /plugin install superpowers@superpowers-marketplace"

next_step "superpowers installed — restart any open claude session to activate it."
ok "installed superpowers@superpowers-marketplace"
