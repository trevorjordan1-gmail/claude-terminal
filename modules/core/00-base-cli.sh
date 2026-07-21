# shellcheck shell=bash
# ct-desc: Base CLI tools (git, gh, tmux, curl, jq, unzip, lynx, xvfb, openssh-server)
# Sourced by bootstrap.sh inside a subshell; ends via ok/skip/fail.

PKGS=(git gh tmux curl wget jq unzip lynx xvfb openssh-server ca-certificates gnupg)

missing=()
for p in "${PKGS[@]}"; do
    pkg_installed "$p" || missing+=("$p")
done

if [ ${#missing[@]} -eq 0 ]; then
    ok "all present"
fi

apt_install "${missing[@]}" || fail "apt install failed for: ${missing[*]}"
ok "installed: ${missing[*]}"
