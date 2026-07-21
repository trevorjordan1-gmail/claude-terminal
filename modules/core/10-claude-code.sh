# shellcheck shell=bash
# ct-desc: Claude Code (official native installer) + cc/phonecc aliases

if ! have claude; then
    log "installing Claude Code (native installer)"
    curl -fsSL https://claude.ai/install.sh | bash || fail "Claude Code installer failed"
    have claude || fail "claude not on PATH after install — open a new shell and re-run"
fi

append_block "$HOME/.bashrc" "claude-terminal aliases" <<'EOF'
alias cc='claude --dangerously-skip-permissions'
alias phonecc='tmux new-session -A -s claude claude --dangerously-skip-permissions'
EOF

# (No next_step here when logged out — the dispatcher already queues the
# login reminder, and two differently-worded copies survive the dedup.)
if claude_ready; then
    ok "$(claude --version 2>/dev/null | head -1)"
else
    ok "installed; not logged in yet"
fi
