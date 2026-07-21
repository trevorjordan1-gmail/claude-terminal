# shellcheck shell=bash
# ct-desc: uv Python package manager (claude-mem's Chroma MCP runs via uvx)

if have uv || [ -x "$HOME/.local/bin/uv" ]; then
    ok "already installed"
fi

log "installing uv (astral.sh installer)"
curl -LsSf https://astral.sh/uv/install.sh | sh || fail "uv installer failed"
[ -x "$HOME/.local/bin/uv" ] || have uv || fail "uv missing after install"

ok "uv installed to ~/.local/bin"
