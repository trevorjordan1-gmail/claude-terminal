# shellcheck shell=bash
# ct-desc: GNOME QoL — disable screen lock and idle blanking (terminal VMs shouldn't lock)

have gsettings || skip "gsettings not available (no GNOME here?)"
ensure_user_dbus || skip "no user D-Bus session — log into the desktop once, then re-run ./bootstrap.sh"

gsettings set org.gnome.desktop.screensaver lock-enabled false \
    || fail "could not set screensaver lock-enabled"
gsettings set org.gnome.desktop.session idle-delay 0 \
    || fail "could not set session idle-delay"

ok "screen lock off, idle blanking off"
