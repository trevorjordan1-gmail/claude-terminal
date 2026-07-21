# shellcheck shell=bash
# ct-desc: usagemeter — Claude subscription usage meter (tray icon + http://localhost:7777 dashboard)

DEST="$HOME/.local/share/usagemeter"

if [ -d "$DEST" ]; then
    ok "already present at $DEST"
fi

have git || fail "git missing (core 00-base-cli should have installed it)"

git clone --depth 1 https://github.com/adnettech/usagemeter "$DEST" \
    || skip "could not clone adnettech/usagemeter (private repo or offline?) — install manually"

( cd "$DEST" && bash install.sh ) || fail "usagemeter install.sh failed — see $DEST"

# Prefer the tray icon (needs no GNOME Shell reload; works with ubuntu-appindicators).
AUTOSTART="$HOME/.config/autostart/usagemeter.desktop"
if [ -f "$AUTOSTART" ] && ! grep -q -- '--tray' "$AUTOSTART"; then
    sed -i 's|^Exec=\(.*\)$|Exec=\1 --tray|' "$AUTOSTART"
fi

next_step "usagemeter: dashboard at http://localhost:7777 — tray icon appears at next login."
ok "installed with tray autostart"
