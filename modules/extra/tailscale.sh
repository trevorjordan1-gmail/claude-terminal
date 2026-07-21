# shellcheck shell=bash
# ct-desc: Tailscale mesh VPN (install + enable service; authentication stays manual)

if ! have tailscale; then
    log "installing tailscale (official script)"
    curl -fsSL https://tailscale.com/install.sh | sh || fail "tailscale installer failed"
fi

sudo systemctl enable --now tailscaled || fail "could not enable tailscaled"

if tailscale status >/dev/null 2>&1; then
    ok "installed and authenticated"
fi

next_step "Authenticate Tailscale: sudo tailscale up"
ok "installed; run 'sudo tailscale up' to join your tailnet"
