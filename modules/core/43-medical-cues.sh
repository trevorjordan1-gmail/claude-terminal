# shellcheck shell=bash
# ct-desc: Medical mode — PHI-approved identity cues (wallpaper, shell banner, motd)

# Users must not mistake this box for an ordinary terminal: PHI is allowed
# here and nowhere else. On DCV the terminal opens at sign-in and MOTD never
# shows (non-login shells), so the shell banner and wallpaper are what people
# actually see; motd is kept for SSH/console completeness.
is_medical_terminal || skip "not a medical terminal"
is_dcv_terminal || skip "medical mode is DCV-only for now"

WP=/usr/share/backgrounds/claude-terminal-medical.svg
if ! sudo cmp -s "$SCRIPT_DIR/assets/medical-wallpaper.svg" "$WP" 2>/dev/null; then
    sudo install -D -m 0644 "$SCRIPT_DIR/assets/medical-wallpaper.svg" "$WP" || fail "could not install $WP"
fi

# GNOME renders SVG backgrounds through gdk-pixbuf's librsvg loader.
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.desktop\.background$' && gui_conf_ready; then
    pkg_installed librsvg2-common || apt_install librsvg2-common || warn "librsvg2-common not installed — SVG wallpaper may not render"
    URI="file://$WP"
    for k in picture-uri picture-uri-dark; do
        if [ "$(gsettings get org.gnome.desktop.background "$k" 2>/dev/null)" != "'$URI'" ]; then
            gui_conf gsettings set org.gnome.desktop.background "$k" "$URI" || fail "could not set $k"
        fi
    done
else
    warn "no GNOME here — wallpaper installed but not selected"
fi

append_block "$HOME/.bashrc" "claude-terminal medical banner" <<'EOF'
case $- in *i*) printf '\033[1;35m[Ai Build Medical]\033[0m PHI-approved environment — Claude runs on Amazon Bedrock in this tenant only.\n' ;; esac
EOF

MOTD_LINE="Ai Build Medical — PHI-approved environment. Claude runs on Amazon Bedrock in this tenant only."
if ! sudo grep -qxF "$MOTD_LINE" /etc/motd 2>/dev/null; then
    printf '%s\n' "$MOTD_LINE" | sudo tee -a /etc/motd >/dev/null || fail "could not update /etc/motd"
fi

ok "wallpaper, shell banner, motd"
