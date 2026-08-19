# shellcheck shell=bash
# ct-desc: passwordless sudo for the invoking user — asks once at first setup, never again

# A Claude terminal is a single-user box; sudo password prompts stall Claude
# sessions mid-task (and stall users who don't manage the box's password).
# Never install unvalidated content into /etc/sudoers.d — a syntax error
# there disables sudo box-wide, so visudo -cf gates every write.
user="$(id -un)"
# verifypw=any: `sudo -v` must also be prompt-free. sudoers' default is
# verifypw=all — every matching rule must be NOPASSWD — so a user who is ALSO
# in the sudo group (stock desktop first user; DCV terminal owners) got a
# password prompt from `sudo -v` (bootstrap's own check) despite this grant,
# while plain `sudo cmd` worked. Same two lines as aws/scripts/desktop-setup.sh
# writes at build, byte-for-byte, so the two never rewrite each other.
rule="Defaults:$user verifypw=any
$user ALL=(ALL) NOPASSWD:ALL"
# sudo silently ignores sudoers.d file names containing a dot.
target="/etc/sudoers.d/010-${user//./_}-nopasswd"

tmp="$CT_TMP/sudoers-nopasswd"
printf '%s\n' "$rule" > "$tmp" || fail "could not write $tmp"

if sudo cmp -s "$tmp" "$target" 2>/dev/null; then
    ok "already configured ($target)"
fi

visudo -cf "$tmp" >/dev/null \
    || fail "generated rule failed visudo validation — system untouched"

sudo install -o root -g root -m 0440 "$tmp" "$target" \
    || fail "could not install $target"
ok "passwordless sudo for $user ($target)"
