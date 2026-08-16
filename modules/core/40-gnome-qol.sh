# shellcheck shell=bash
# ct-desc: GNOME QoL — screen lock/blanking off; dock = Firefox, Files, Terminal (no App Center/Help)

have gsettings || skip "gsettings not available (no GNOME here?)"
gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.shell$' \
    || skip "GNOME Shell schemas not installed (no GNOME desktop here?)"
gui_conf_ready || skip "no D-Bus session and no dbus-run-session — install dbus-daemon (or log into the desktop once), then re-run ./bootstrap.sh"

gui_conf gsettings set org.gnome.desktop.screensaver lock-enabled false \
    || fail "could not set screensaver lock-enabled"
gui_conf gsettings set org.gnome.desktop.session idle-delay 0 \
    || fail "could not set session idle-delay"

# Dock favorites, converged from the reference machines: Terminal pinned,
# App Center (snap-store) and Help (yelp) gone. Re-runs re-converge — if you
# want another permanent pin, add it here.
FAVS="['firefox_firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']"
if [ "$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)" != "$FAVS" ]; then
    gui_conf gsettings set org.gnome.shell favorite-apps "$FAVS" \
        || fail "could not set dock favorites"
fi

ok "lock/blanking off; dock = Firefox, Files, Terminal"
