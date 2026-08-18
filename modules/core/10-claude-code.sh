# shellcheck shell=bash
# ct-desc: Claude Code (official native installer) + cc/phonecc aliases (menu-first cc-launcher on DCV)

if ! have claude; then
    log "installing Claude Code (native installer)"
    curl -fsSL https://claude.ai/install.sh | bash || fail "Claude Code installer failed"
    have claude || fail "claude not on PATH after install — open a new shell and re-run"
fi

# DCV terminals are menu-first (issue #3): `cc` opens the workspace picker
# (templates/cc-launcher.sh) so every session starts in the right folder with
# the right CLAUDE.md. Same file + alias shape SETUP.md step 3 uses, so a
# SETUP run and this module converge instead of fighting. Hyper-V keeps the
# plain alias.
if is_dcv_terminal; then
    mkdir -p "$HOME/.local/bin"
    if ! cmp -s "$SCRIPT_DIR/templates/cc-launcher.sh" "$HOME/.local/bin/cc-launcher"; then
        install -m 0755 "$SCRIPT_DIR/templates/cc-launcher.sh" "$HOME/.local/bin/cc-launcher" \
            || fail "could not install cc-launcher into ~/.local/bin"
    fi
    CC_CMD='cc-launcher'
else
    CC_CMD='claude --dangerously-skip-permissions'
fi
append_block "$HOME/.bashrc" "claude-terminal aliases" <<EOF
# DCV/cloud sessions skip the login-shell pass through ~/.profile, so the
# claude install dir must go on PATH here in .bashrc.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH" ;; esac
alias cc='$CC_CMD'
alias phonecc='tmux new-session -A -s claude $CC_CMD'
EOF

# (No next_step here when logged out — the dispatcher already queues the
# login reminder, and two differently-worded copies survive the dedup.)
if claude_ready; then
    ok "$(claude --version 2>/dev/null | head -1)"
else
    ok "installed; not logged in yet"
fi
