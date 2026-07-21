# shellcheck shell=bash
# ct-desc: Node.js 20 (NodeSource repo) + user-level npm prefix (~/.npm-global, no sudo-npm)

node_major=0
if have node; then
    node_major="$(node -v | sed 's/^v//; s/\..*//')"
fi

if [ "$node_major" != "20" ]; then
    log "adding NodeSource repo and installing Node 20"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null \
        || fail "NodeSource repo setup failed"
    apt_install nodejs || fail "nodejs install failed"
fi

# Global npm packages belong to the user, not root.
npm config set prefix "$HOME/.npm-global" || fail "npm config set prefix failed"
mkdir -p "$HOME/.npm-global/bin"
append_block "$HOME/.bashrc" "claude-terminal npm prefix" <<'EOF'
export PATH="$HOME/.npm-global/bin:$PATH"
EOF

ok "node $(node -v), npm prefix ~/.npm-global"
