# shellcheck shell=bash
# ct-desc: Compilers & packaging toolchain (build-essential, maven, JDK, msitools/wixl, osslsigncode, mdbtools)

PKGS=(build-essential gcc g++ maven default-jdk default-jre msitools wixl osslsigncode mdbtools)

apt_update_once
want=()
for p in "${PKGS[@]}"; do
    if pkg_installed "$p"; then
        continue
    elif apt-cache show "$p" >/dev/null 2>&1; then
        want+=("$p")
    else
        warn "no apt candidate for $p — skipping it"
    fi
done

if [ ${#want[@]} -eq 0 ]; then
    ok "all present"
fi

apt_install "${want[@]}" || fail "apt install failed for: ${want[*]}"
ok "installed: ${want[*]}"
