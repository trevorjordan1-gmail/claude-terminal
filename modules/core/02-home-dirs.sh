# shellcheck shell=bash
# ct-desc: Standard home layout — create the ~/Projects workspace folder

if [ -d "$HOME/Projects" ]; then
    ok "~/Projects already exists"
fi

mkdir -p "$HOME/Projects" || fail "could not create ~/Projects"
ok "created ~/Projects"
