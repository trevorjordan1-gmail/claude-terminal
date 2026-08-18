# shellcheck shell=bash
# ct-desc: cct-finish + .bashrc hook — first shell after `claude` is usable (login, or Bedrock) completes the plugin installs

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

# "claude is usable" = an OAuth login exists, or the kit's managed settings pin
# Claude Code to Bedrock (medical boxes never log in). The repo path is baked
# in so a checkout anywhere other than ~/claude-terminal still works.
append_block "$HOME/.bashrc" "claude-terminal postlogin-finish" <<EOF
if { [ -f "\$HOME/.claude/.credentials.json" ] || grep -qs '"CLAUDE_CODE_USE_BEDROCK": *"1"' /etc/claude-code/managed-settings.json; } \\
   && [ -x "\$HOME/.local/bin/cct-finish" ] \\
   && { [ ! -d "\$HOME/.claude/plugins/cache/thedotmack" ] \\
        || [ ! -d "\$HOME/.claude/plugins/cache/superpowers-marketplace" ]; }; then
    echo "claude-terminal: claude is ready — finishing plugin setup (cct-finish)"
    CT_REPO="$SCRIPT_DIR" "\$HOME/.local/bin/cct-finish"
fi
EOF

ok "cct-finish + post-login hook installed"
