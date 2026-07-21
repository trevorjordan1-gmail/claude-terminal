# shellcheck shell=bash
# ct-desc: xrdp remote desktop + XFCE session; RDP logins get your ~/.profile environment

if ! pkg_installed xrdp || ! pkg_installed xfce4; then
    apt_install xrdp xfce4 xfce4-goodies || fail "xrdp/xfce4 install failed"
fi

# Reference machines add a ~/.profile source to startwm.sh so RDP sessions see
# the user's PATH (~/.local/bin etc.). Insert once, before the Xsession exec.
STARTWM=/etc/xrdp/startwm.sh
if [ -f "$STARTWM" ] && ! grep -Eq 'claude-terminal|\. ~/\.profile' "$STARTWM"; then
    sudo sed -i '/^test -x \/etc\/X11\/Xsession/i \
# >>> claude-terminal >>>\
if test -r ~/.profile; then\
    . ~/.profile\
fi\
# <<< claude-terminal <<<' "$STARTWM" || fail "could not patch $STARTWM"
fi

sudo systemctl enable --now xrdp || fail "could not enable xrdp"

next_step "RDP to this machine on port 3389 (user + password login)."
ok "xrdp active; XFCE available; startwm sources ~/.profile"
