# shellcheck shell=bash
# ct-desc: Claude Code (official native installer) + cc/phonecc aliases (menu-first cc-launcher on DCV)

if ! have claude; then
    log "installing Claude Code (native installer)"
    curl -fsSL https://claude.ai/install.sh | bash || fail "Claude Code installer failed"
    have claude || fail "claude not on PATH after install — open a new shell and re-run"
fi

# `cc` opens the workspace picker (templates/cc-launcher.sh) so every session
# starts in the right folder with the right CLAUDE.md. Same file + alias shape
# SETUP.md step 3 uses, so a SETUP run and this module converge instead of
# fighting.
#
# This was DCV-only when the launcher was just a menu (issue #3). Since #26 it
# is a session-recall TUI with context-fill warnings and the hand-off loop,
# none of which is DCV-specific -- it reads ~/Projects and ~/.claude/projects
# and nothing else. A Hyper-V box with three terminals open needs it just as
# much. The launcher's SETUP entry stays gated on the pack env file inside the
# launcher, so a box without one simply never sees that item.
# (Body left indented: it is fine in bash, and re-indenting would disturb the
# python heredoc below, where indentation is load-bearing.)
    mkdir -p "$HOME/.local/bin"
    if ! cmp -s "$SCRIPT_DIR/templates/cc-launcher.sh" "$HOME/.local/bin/cc-launcher"; then
        install -m 0755 "$SCRIPT_DIR/templates/cc-launcher.sh" "$HOME/.local/bin/cc-launcher" \
            || fail "could not install cc-launcher into ~/.local/bin"
    fi
    # statusline: live context-fill readout in every session — the visible
    # teaching tool for session hygiene (wrap up before the window fills)
    if ! cmp -s "$SCRIPT_DIR/templates/cc-statusline.sh" "$HOME/.local/bin/cc-statusline"; then
        install -m 0755 "$SCRIPT_DIR/templates/cc-statusline.sh" "$HOME/.local/bin/cc-statusline" \
            || fail "could not install cc-statusline"
    fi
    python3 - <<'PY' || fail "could not wire statusLine into ~/.claude/settings.json"
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
p.parent.mkdir(exist_ok=True)
try:
    cfg = json.loads(p.read_text())
except Exception:
    cfg = {}
if "statusLine" not in cfg:  # never clobber a user's own statusline
    cfg["statusLine"] = {"type": "command",
                         "command": str(pathlib.Path.home() / ".local/bin/cc-statusline")}
    p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
    CC_CMD='cc-launcher'
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
