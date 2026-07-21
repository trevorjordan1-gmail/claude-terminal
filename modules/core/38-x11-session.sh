# shellcheck shell=bash
# ct-desc: Force X11 (disable Wayland at GDM) — RustDesk/Splashtop remote control needs X11

# Remote-control tools (RustDesk, Splashtop) cannot capture/inject input on
# Wayland, and the Hyper-V scroll fix is an Xorg InputClass. Both reference
# machines run with WaylandEnable=false.

CONF=/etc/gdm3/custom.conf
[ -d /etc/gdm3 ] || skip "no GDM here (/etc/gdm3 missing)"

changed=0
if [ ! -f "$CONF" ]; then
    printf '[daemon]\nWaylandEnable=false\n' | sudo tee "$CONF" >/dev/null \
        || fail "could not create $CONF"
    changed=1
elif grep -qE '^WaylandEnable=false' "$CONF"; then
    :   # already forced
elif grep -qE '^[[:space:]]*#[[:space:]]*WaylandEnable=false' "$CONF"; then
    sudo sed -i 's/^[[:space:]]*#[[:space:]]*WaylandEnable=false/WaylandEnable=false/' "$CONF" \
        || fail "could not uncomment WaylandEnable in $CONF"
    changed=1
elif grep -qE '^WaylandEnable=' "$CONF"; then
    sudo sed -i 's/^WaylandEnable=.*/WaylandEnable=false/' "$CONF" \
        || fail "could not rewrite WaylandEnable in $CONF"
    changed=1
elif grep -q '^\[daemon\]' "$CONF"; then
    sudo sed -i '/^\[daemon\]/a WaylandEnable=false' "$CONF" \
        || fail "could not insert WaylandEnable into $CONF"
    changed=1
else
    printf '\n[daemon]\nWaylandEnable=false\n' | sudo tee -a "$CONF" >/dev/null \
        || fail "could not append to $CONF"
    changed=1
fi

if [ "$changed" = 1 ]; then
    next_step "Reboot (or log out to the GDM greeter) so the session switches from Wayland to X11 — remote control won't work until then."
fi
ok "Wayland disabled at GDM (X11 forced)"
