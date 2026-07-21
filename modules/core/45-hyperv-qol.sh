# shellcheck shell=bash
# ct-desc: Hyper-V VM fixes — disable over-amplified hi-res wheel scrolling; add user to video group

virt="$(systemd-detect-virt 2>/dev/null || echo none)"
[ "$virt" = "microsoft" ] || skip "not a Hyper-V VM (virtualization: $virt)"

CONF=/etc/X11/xorg.conf.d/99-libinput-no-hires-scroll.conf
if [ ! -f "$CONF" ]; then
    sudo mkdir -p /etc/X11/xorg.conf.d
    sudo tee "$CONF" >/dev/null <<'EOF' || fail "could not write $CONF"
# Disable high-resolution wheel scrolling for all libinput pointer devices.
#
# Hyper-V's synthetic mouse (and Splashtop/RustDesk virtual mice) advertise
# REL_WHEEL_HI_RES; on X11 the hi-res scroll path is over-amplified, producing
# wildly too-fast scrolling across all access methods. Forwarding legacy
# one-notch wheel events fixes it.
#
# Installed by claude-terminal bootstrap. Revert: delete this file, restart X.
Section "InputClass"
    Identifier  "Disable high-resolution wheel scrolling (fix over-fast VM scroll)"
    MatchDriver "libinput"
    Option      "HighResolutionWheelScrolling" "off"
EndSection
EOF
    next_step "Log out and back in (or reboot) so the scroll fix and video-group change take effect."
fi

# Xorg on hyperv_drm needs the user in the video group for /dev/fb0.
if ! id -nG | grep -qw video; then
    sudo usermod -aG video "$USER" || fail "usermod -aG video failed"
    next_step "Log out and back in (or reboot) so the scroll fix and video-group change take effect."
fi

ok "hi-res wheel scrolling disabled; $USER in video group"
