#!/usr/bin/env bash
# Apply the kit's GNOME Terminal look to the profile you are ACTUALLY using.
#
# 42-terminal-prefs seeds a pristine box by loading assets/gnome-terminal.dconf straight
# into /org/gnome/terminal/legacy/. That works exactly once, on a fresh box, because the
# asset's profile stanza is keyed to b1dcc9dd-… — GNOME Terminal's well-known default
# profile UUID. On a box whose terminal has already been customized the default profile has
# a DIFFERENT uuid, so loading the asset writes a profile nothing uses and appears to do
# nothing at all. That is why this exists: it reads your live default profile and writes
# there instead.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET="${1:-$SCRIPT_DIR/assets/gnome-terminal.dconf}"
[ -r "$ASSET" ] || { echo "seed-terminal-prefs: no asset at $ASSET" >&2; exit 1; }
command -v dconf >/dev/null || { echo "seed-terminal-prefs: dconf not installed" >&2; exit 1; }

DEF=$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'")
[ -n "$DEF" ] || { echo "seed-terminal-prefs: cannot read your default profile (is GNOME Terminal installed?)" >&2; exit 1; }

# A busless `dconf load` writes nothing while exiting 0 — the same trap as gsettings
# (43b6e27) — so go through the kit's one-shot bus helper when there is no session bus.
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

# dconf load needs a keyfile GROUP header, so re-emit one: bare key=value lines are
# rejected with "Key file does not start with a group" and nothing is written.
section() { printf '[/]\n'; awk -v want="$1" '
    /^\[/ { inside = ($0 == want); next }
    inside && NF { print }' "$ASSET"; }

section '[keybindings]' | gui_conf dconf load /org/gnome/terminal/legacy/keybindings/ \
    || { echo "seed-terminal-prefs: keybindings load failed" >&2; exit 1; }
section "[profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]" \
    | gui_conf dconf load "/org/gnome/terminal/legacy/profiles:/:$DEF/" \
    || { echo "seed-terminal-prefs: profile load failed" >&2; exit 1; }
echo "seed-terminal-prefs: applied to your default profile ($DEF) — open a NEW terminal window to see it"
