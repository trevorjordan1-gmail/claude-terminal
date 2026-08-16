# shellcheck shell=bash
# ct-desc: Seed GNOME Terminal preferences (Ctrl+C/V copy-paste, 200x50 window) on fresh boxes

have dconf || skip "dconf not available (no GNOME here?)"
gui_conf_ready || skip "no D-Bus session and no dbus-run-session — install dbus-daemon (or log into the desktop once), then re-run ./bootstrap.sh"

ASSET="$SCRIPT_DIR/assets/gnome-terminal.dconf"
[ -f "$ASSET" ] || fail "missing $ASSET"

# Seed, don't clobber: only load when the terminal settings tree is still
# stock. Once you've customized (or we've seeded), later runs leave it alone.
# (dconf dump reads the database file directly — no bus needed.)
if [ -n "$(dconf dump /org/gnome/terminal/legacy/ 2>/dev/null)" ]; then
    skip "terminal already customized — not overwriting (manual: dconf load /org/gnome/terminal/legacy/ < $ASSET)"
fi

gui_conf dconf load /org/gnome/terminal/legacy/ < "$ASSET" || fail "dconf load failed"
ok "seeded terminal prefs (Ctrl+C/V, 200x50, bold-is-bright)"
