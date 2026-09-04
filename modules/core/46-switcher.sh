# shellcheck shell=bash
# ct-desc: Switcher window picker on Alt+` — pick a terminal by title, not by app icon
# Sourced by bootstrap.sh inside a subshell; ends via ok/skip/fail.

# A Claude Code terminal is many gnome-terminal windows told apart by their TITLE.
# GNOME's Alt-Tab groups them all under one icon, so it cannot pick between them, and
# standalone pickers (rofi) ghost through the Hyper-V console and RustDesk. Switcher draws
# inside the shell, which is the only kind of popup that renders cleanly on those.

UUID="switcher@landau.fi"
EXT="$HOME/.local/share/gnome-shell/extensions/$UUID"
PATCHDIR="$HOME/.local/share/claude-terminal/switcher"

have gnome-extensions || skip "no gnome-extensions (not a GNOME desktop)"
gui_conf_ready || skip "no way to write GNOME settings (no user bus, no dbus-run-session)"

SHELL_VER=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
[ -n "$SHELL_VER" ] || skip "cannot determine the GNOME Shell version"

# Install from extensions.gnome.org, matched to THIS shell version. A fetch failure is a
# skip, never a fail: no window picker must never be the reason a bootstrap stops.
if [ ! -d "$EXT" ]; then
    URL=$(curl -fsS --max-time 20 \
        "https://extensions.gnome.org/extension-info/?uuid=$UUID&shell_version=$SHELL_VER" 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null)
    [ -n "$URL" ] || skip "no Switcher build for GNOME Shell $SHELL_VER on extensions.gnome.org"
    curl -fsSL --max-time 60 -o "$CT_TMP/switcher.zip" "https://extensions.gnome.org$URL" \
        || skip "could not download Switcher (offline?)"
    gnome-extensions install --force "$CT_TMP/switcher.zip" >/dev/null 2>&1 \
        || fail "gnome-extensions install failed"
fi
# gui_conf like every other settings write here: `gnome-extensions enable` goes through
# gsettings, and with no user bus that exits 0 while writing nothing (43b6e27).
gui_conf gnome-extensions enable "$UUID" >/dev/null 2>&1 || true

# The three local patches ship with the kit and are re-applied whenever the extension's
# files change, because an extension update overwrites them.
install -d "$PATCHDIR"
for p in "$SCRIPT_DIR"/assets/switcher/*.patch; do
    cmp -s "$p" "$PATCHDIR/$(basename "$p")" || install -m 0644 "$p" "$PATCHDIR/"
done
install -D -m 0755 "$SCRIPT_DIR/tools/switcher-patches.sh" "$HOME/.local/bin/switcher-patches"
PATCH_RC=0
"$HOME/.local/bin/switcher-patches" || PATCH_RC=1

# Re-patch on extension update: the .path unit fires when any patched file changes.
install -d "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/switcher-patches.service" <<UNIT
[Unit]
Description=Re-apply the claude-terminal Switcher patches
[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/switcher-patches
UNIT
cat > "$HOME/.config/systemd/user/switcher-patches.path" <<UNIT
[Unit]
Description=Watch the Switcher extension for updates that undo the patches
[Path]
PathChanged=$EXT/extension.js
PathChanged=$EXT/modes/launcher.js
PathChanged=$EXT/modes/switcher.js
[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable --now switcher-patches.path >/dev/null 2>&1 || true

# Settings. The extension keeps its schema in its own dir, so --schemadir is required.
# gui_conf, never a bare gsettings: with no user bus a `gsettings set` exits 0 and writes
# NOTHING (the defect behind 43b6e27), which would leave Alt+` silently unbound.
SCHEMAS="$EXT/schemas"
gui_conf gsettings --schemadir "$SCHEMAS" set org.gnome.shell.extensions.switcher show-switcher "['<Alt>grave']" \
    || fail "could not bind Alt+\` to the switcher"
gui_conf gsettings --schemadir "$SCHEMAS" set org.gnome.shell.extensions.switcher matching 1 || true
gui_conf gsettings --schemadir "$SCHEMAS" set org.gnome.shell.extensions.switcher activate-by-key 0 || true
# Free Alt+` from GNOME's own switch-group, which otherwise wins. Super+` still cycles a group.
gui_conf gsettings set org.gnome.desktop.wm.keybindings switch-group "['<Super>Above_Tab']" || true

[ "$PATCH_RC" = 0 ] || fail "Switcher installed but a patch no longer applies — upstream changed; see verify.sh"
ok "Switcher on Alt+\` (fuzzy, title-matching; reload the shell or log out/in to activate)"
