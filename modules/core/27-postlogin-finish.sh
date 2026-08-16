# shellcheck shell=bash
# ct-desc: cct-finish + .bashrc hook — first shell after `claude` login completes the plugin installs

# Headless provisions (cloud/DCV, unattended Hyper-V) end before `claude`
# login, and cloud users never see bootstrap's "re-run after login" reminder.
# So the box finishes itself: cct-finish runs only the login-gated modules
# (claude-mem, superpowers — no sudo, no apt), and the .bashrc hook fires it
# on the first interactive shell where claude is logged in but the plugins are
# missing. The hook stays installed and simply stops matching once the plugin
# caches exist. Re-runs refresh the installed copy from the repo.

mkdir -p "$HOME/.local/bin"
install -m 0755 "$SCRIPT_DIR/tools/cct-finish.sh" "$HOME/.local/bin/cct-finish" \
    || fail "could not install cct-finish into ~/.local/bin"

append_block "$HOME/.bashrc" "claude-terminal postlogin-finish" <<'EOF'
if [ -f "$HOME/.claude/.credentials.json" ] && [ -x "$HOME/.local/bin/cct-finish" ] \
   && { [ ! -d "$HOME/.claude/plugins/cache/thedotmack" ] \
        || [ ! -d "$HOME/.claude/plugins/cache/superpowers-marketplace" ]; }; then
    echo "claude-terminal: claude login detected — finishing plugin setup (cct-finish)"
    "$HOME/.local/bin/cct-finish"
fi
EOF

ok "cct-finish + post-login hook installed"
