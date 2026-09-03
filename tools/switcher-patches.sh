#!/usr/bin/env bash
# Re-apply the kit's Switcher patches. Idempotent: each patch is keyed to a marker string,
# and one already present is skipped. Run by 46-switcher.sh at bootstrap and by
# switcher-patches.path whenever the extension's files change (an extension update
# overwrites them, which is exactly when the patches need re-applying).
#
# Exit 1 means a patch NO LONGER APPLIES — upstream changed the file. That is a real
# signal, not noise: verify.sh checks the same markers, so a fleet-wide upstream bump
# shows up in the scorecard instead of only in a notify-send nobody is looking at.
set -uo pipefail
EXT="$HOME/.local/share/gnome-shell/extensions/switcher@landau.fi"
PATCHDIR="${CT_SWITCHER_PATCHES:-$HOME/.local/share/claude-terminal/switcher}"
[ -d "$EXT" ] || { echo "switcher-patches: extension not installed — nothing to do"; exit 0; }

VER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version","?"))' \
      "$EXT/metadata.json" 2>/dev/null || echo '?')
rc=0
apply_one() { # $1 = patch file, $2 = target relative to $EXT, $3 = marker string
    local p="$PATCHDIR/$1" t="$EXT/$2"
    [ -r "$p" ] || { echo "switcher-patches: missing $p"; rc=1; return; }
    [ -r "$t" ] || { echo "switcher-patches: no $2 in the extension"; rc=1; return; }
    if grep -qF "$3" "$t"; then return; fi          # already patched
    [ -f "$t.orig-v$VER" ] || cp "$t" "$t.orig-v$VER"
    if patch --silent --forward -p0 "$t" < "$p"; then
        echo "switcher-patches: applied $1"
    else
        echo "switcher-patches: $1 NO LONGER APPLIES to v$VER — upstream changed $2" >&2
        rc=1
    fi
}
apply_one switcher-focus-fix.patch       extension.js       'Activate BEFORE dropping the modal grab'
apply_one switcher-hide-apps.patch       modes/launcher.js  'hide launchable (not running) apps'
apply_one switcher-exclude-rustdesk.patch modes/switcher.js 'EXCLUDED_WM_CLASSES'
if [ "$rc" != 0 ] && command -v notify-send >/dev/null 2>&1; then
    notify-send "Switcher patches failed" "Upstream v$VER changed the extension; run verify.sh" 2>/dev/null || true
fi
exit "$rc"
