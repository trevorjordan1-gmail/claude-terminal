# shellcheck shell=bash
# ct-desc: Splashtop Streamer — install + register this machine with your deployment code
# ct-suggest: splashtop-streamer|Remote access (Splashtop): ./bootstrap.sh --with-splashtop

# Pinned on purpose. Splashtop publishes no "latest" URL: the download host
# answers 403 for directory listings, unversioned names, and versions that
# don't exist alike, and the downloads page doesn't carry the Linux link. Their
# Linux builds are rare (3.8.0.0 dates from Jan 2026) and the streamer keeps
# itself current through -auto_update below, so this pin only has to be good
# enough to get the package onto the box once. Bump it here when it 403s.
STB_URL="https://download.splashtop.com/linux/STB_CSRS_Ubuntu_v3.8.0.0_amd64.tar.gz"

# Re-running bootstrap must stay unattended, so an installed streamer is left
# alone rather than re-prompting for a code.
if pkg_installed splashtop-streamer; then
    ok "already installed (re-register with: sudo splashtop-streamer deploy <code>)"
fi

# Ask before downloading 11MB we might not be able to use.
CODE="${CT_SPLASHTOP_CODE:-}"
if [ -z "$CODE" ]; then
    # Under `curl | bash` stdin is the pipe, so `[ -t 0 ]` is false even in a
    # real console, and a bare `read` would silently consume this script's own
    # next line instead of prompting. /dev/tty is the only reliable route to
    # the operator, and failing to open it is what "not interactive" means.
    if ( : </dev/tty ) 2>/dev/null; then
        read -r -p "Splashtop deployment code (12 digits): " CODE </dev/tty
    else
        next_step "Splashtop: re-run './bootstrap.sh --with-splashtop' from a terminal, or set CT_SPLASHTOP_CODE=<code> first."
        skip "no deployment code, and no terminal to ask on"
    fi
fi

CODE="${CODE//[^A-Za-z0-9]/}"
[ -n "$CODE" ] || fail "no deployment code entered"

D="$CT_TMP/splashtop"
mkdir -p "$D"

log "downloading Splashtop Streamer"
curl -fsSL -o "$D/stb.tar.gz" "$STB_URL" \
    || fail "download failed — if Splashtop shipped a new build, update STB_URL in modules/extra/splashtop.sh"

tar xzf "$D/stb.tar.gz" -C "$D" || fail "could not unpack the download"
DEB="$(find "$D" -name '*.deb' -print -quit)"
[ -n "$DEB" ] || fail "no .deb inside the download — the package layout changed"

# The .deb's postinst symlinks /usr/bin/splashtop-streamer and starts the service.
apt_install "$DEB" || fail "apt could not install the streamer"
have splashtop-streamer || fail "installed, but splashtop-streamer is not on PATH"

# Deploy as root: the polkit action for these is auth_admin_keep, which would
# pop an authentication dialog at a normal user instead of just running.
sudo splashtop-streamer deploy "$CODE" \
    || fail "Splashtop rejected the deployment code — retry with: sudo splashtop-streamer deploy <code>"

# There is no latest-version URL to chase, so let the streamer update itself.
sudo splashtop-streamer config -auto_update=1 >/dev/null 2>&1 \
    || warn "could not enable Splashtop auto-update"

if ! systemctl is-active --quiet SRStreamer.service; then
    next_step "Splashtop registered, but its service isn't running: sudo systemctl start SRStreamer"
    ok "registered; service not yet active"
fi

ok "installed and registered"
