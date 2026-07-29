# shellcheck shell=bash
# ct-desc: Standard home layout — create the ~/Projects workspace folder

if [ -d "$HOME/Projects" ]; then
    # shellcheck disable=SC2088  # tilde is display text; the test above uses $HOME
    ok "~/Projects already exists"
fi

mkdir -p "$HOME/Projects" || fail "could not create ~/Projects"
ok "created ~/Projects"
