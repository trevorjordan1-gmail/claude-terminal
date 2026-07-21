# shellcheck shell=bash
# ct-desc: Okular as the double-click viewer for Markdown files (renders .md instead of raw text)

if ! pkg_installed okular || ! pkg_installed okular-extra-backends; then
    apt_install okular okular-extra-backends || fail "apt install okular failed"
fi

if have xdg-mime; then
    xdg-mime default okularApplication_md.desktop text/markdown \
        || warn "xdg-mime default failed (no desktop session?) — run it manually later"
fi

ok "okular installed; text/markdown opens rendered"
