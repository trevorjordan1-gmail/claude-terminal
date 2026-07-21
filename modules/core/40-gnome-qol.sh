# shellcheck shell=bash
# ct-desc: GNOME QoL — screen lock/blanking off; dock = Firefox, Files, Terminal (no App Center/Help)

have gsettings || skip "gsettings not available (no GNOME here?)"
ensure_user_dbus || skip "no user D-Bus session — log into the desktop once, then re-run ./bootstrap.sh"

gsettings set org.gnome.desktop.screensaver lock-enabled false \
    || fail "could not set screensaver lock-enabled"
gsettings set org.gnome.desktop.session idle-delay 0 \
    || fail "could not set session idle-delay"

# Dock favorites, converged from the reference machines: Terminal pinned,
# App Center (snap-store) and Help (yelp) gone. Re-runs re-converge — if you
# want another permanent pin, add it here.
FAVS="['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"
if [ "$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)" != "$FAVS" ]; then
    gsettings set org.gnome.shell favorite-apps "$FAVS" \
        || fail "could not set dock favorites"
fi

ok "lock/blanking off; dock = Firefox, Files, Terminal"
