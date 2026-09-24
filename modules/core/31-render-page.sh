# shellcheck shell=bash
# ct-desc: render-page — one command to read a JavaScript-only web page in the box's Chrome (Playwright, own venv)

# curl/WebFetch get a 1 KB shell from a single-page app; Chrome is on every DCV terminal
# but nothing drove it (#60). render-page renders the page headless, clicks through nav
# items by text, prints the text and — with --json — the JSON/XHR calls the page made,
# which for a SPA is usually its own content API. The tool builds its venv on first use
# (uv, module 30 — the kit's standard for tool venvs; python3-venv is deliberately not in
# the image), so install here is just the launcher.

mkdir -p "$HOME/.local/bin"
install -m 0755 "$SCRIPT_DIR/tools/render-page.py" "$HOME/.local/bin/render-page" \
    || fail "could not install render-page into ~/.local/bin"

ok "render-page installed (first run builds ~/.venvs/render-page)"
