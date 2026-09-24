#!/usr/bin/env python3
"""render-page — one command to read a JavaScript-only web page (#60).

    render-page <url> [--click <text>]... [--json] [--json-bodies] [--html]
                      [--screenshot FILE] [--wait MS] [--browser chrome|chromium]

Renders the page in the Chrome already on the box (Playwright, headless), optionally clicks
through navigation items by their visible text, and prints the page TEXT — the thing curl
and WebFetch cannot get from a single-page app. With --json it also lists every JSON/XHR
response the page fetched while rendering: for a SPA that is usually the site's own content
API, which is cleaner than the DOM (an engineer lost 40 minutes to a vendor developer portal
before finding exactly that; the API returned the whole page and the OpenAPI file directly).

Self-contained: on first run it builds its own venv under ~/.venvs/render-page (uv if
present — the kit's standard for tool venvs; python3 -m venv otherwise) and installs
Playwright there, then re-executes itself inside it. Nothing system-wide changes. Chrome is
driven through Playwright's `channel="chrome"`, so no browser download either; --browser
chromium uses Playwright's own build (`~/.venvs/render-page/bin/playwright install chromium`
first) for a box without Chrome.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

VENV = os.path.expanduser("~/.venvs/render-page")
PY = os.path.join(VENV, "bin", "python3")


def _ensure_venv() -> None:
    """Build the tool's venv and install Playwright into it (idempotent)."""
    if not os.path.exists(PY):
        os.makedirs(os.path.dirname(VENV), exist_ok=True)
        uv = shutil.which("uv") or os.path.expanduser("~/.local/bin/uv")
        if os.path.exists(uv):
            subprocess.run([uv, "venv", "-q", VENV], check=True)
        else:
            # python3-venv is not part of the terminal image on purpose — uv is. This
            # fallback covers a box that has neither the kit's uv module nor ensurepip.
            r = subprocess.run([sys.executable, "-m", "venv", VENV])
            if r.returncode != 0:
                sys.exit("render-page: no uv and `python3 -m venv` failed — install uv "
                         "(curl -LsSf https://astral.sh/uv/install.sh | sh) and re-run")
    if subprocess.run([PY, "-c", "import playwright"], capture_output=True).returncode != 0:
        print("render-page: first run — installing Playwright into", VENV, file=sys.stderr)
        uv = shutil.which("uv") or os.path.expanduser("~/.local/bin/uv")
        if os.path.exists(uv):
            subprocess.run([uv, "pip", "install", "-q", "--python", PY, "playwright"], check=True)
        else:
            subprocess.run([PY, "-m", "pip", "install", "-q", "playwright"], check=True)


def _in_venv() -> bool:
    return os.path.realpath(sys.executable) == os.path.realpath(PY)


def render(a: argparse.Namespace) -> int:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout  # noqa: E402

    seen = []          # JSON / XHR responses, in order
    bodies = {}

    def on_response(resp):
        try:
            ctype = resp.headers.get("content-type", "")
            rtype = resp.request.resource_type
        except Exception:
            return
        if "json" in ctype or rtype in ("xhr", "fetch"):
            row = {"status": resp.status, "type": rtype, "content_type": ctype.split(";")[0],
                   "url": resp.url}
            seen.append(row)
            if a.json_bodies and "json" in ctype:
                try:
                    bodies[resp.url] = resp.json()
                except Exception:
                    pass

    with sync_playwright() as p:
        launch = {"headless": True}
        if a.browser == "chrome":
            launch["channel"] = "chrome"
        try:
            browser = p.chromium.launch(**launch)
        except Exception as e:
            hint = ("Chrome not found — this box has no google-chrome; use --browser chromium "
                    "after `%s/bin/playwright install chromium`" % VENV
                    if a.browser == "chrome" else
                    "Playwright's Chromium is not installed — run `%s/bin/playwright install chromium`" % VENV)
            sys.exit(f"render-page: could not launch the browser: {e}\n{hint}")
        page = browser.new_page()
        page.on("response", on_response)
        page.goto(a.url, wait_until="domcontentloaded", timeout=a.timeout)
        try:
            page.wait_for_load_state("networkidle", timeout=a.timeout)
        except PWTimeout:
            pass  # analytics beacons never go idle; the DOM is usually there anyway
        page.wait_for_timeout(a.wait)
        for text in a.click:
            loc = page.get_by_text(text, exact=False).first
            try:
                loc.click(timeout=a.timeout)
                try:
                    page.wait_for_load_state("networkidle", timeout=a.timeout)
                except PWTimeout:
                    pass
                page.wait_for_timeout(a.wait)
            except Exception as e:
                print(f"render-page: could not click {text!r}: {str(e).splitlines()[0]}",
                      file=sys.stderr)
            if not a.quiet:
                print(f"\n===== after click: {text!r} — {page.url}\n")
                print(page.inner_text("body"))
        if a.screenshot:
            page.screenshot(path=a.screenshot, full_page=True)
        if a.html:
            print(page.content())
        elif not a.click or a.quiet:
            print(f"===== {page.title()} — {page.url}\n")
            print(page.inner_text("body"))
        browser.close()

    if a.json or a.json_bodies:
        print("\n===== JSON / XHR responses seen (%d) — a SPA's own content API is usually in "
              "here, and cleaner than the DOM" % len(seen))
        for r in seen:
            print(f"{r['status']} {r['type']:5} {r['content_type']:24} {r['url']}")
        if a.json_bodies:
            print("\n===== bodies")
            print(json.dumps(bodies, indent=1)[:a.max_body])
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="render-page", description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url")
    ap.add_argument("--click", action="append", default=[], metavar="TEXT",
                    help="click the element with this visible text, then print the page again "
                         "(repeatable, in order)")
    ap.add_argument("--json", action="store_true", help="list JSON/XHR responses the page fetched")
    ap.add_argument("--json-bodies", action="store_true",
                    help="also dump their JSON bodies (implies --json)")
    ap.add_argument("--max-body", type=int, default=200000, help="cap on the dumped bodies (chars)")
    ap.add_argument("--html", action="store_true", help="print rendered HTML instead of text")
    ap.add_argument("--screenshot", metavar="FILE", help="full-page PNG")
    ap.add_argument("--wait", type=int, default=1500, metavar="MS",
                    help="settle time after load / each click (default 1500)")
    ap.add_argument("--timeout", type=int, default=30000, metavar="MS", help="per-step timeout")
    ap.add_argument("--browser", choices=("chrome", "chromium"), default="chrome",
                    help="chrome = the box's installed Google Chrome (default)")
    ap.add_argument("--quiet", action="store_true",
                    help="with --click: print only the final page, not every intermediate one")
    a = ap.parse_args()
    if not _in_venv():
        _ensure_venv()
        os.execv(PY, [PY, os.path.abspath(__file__)] + sys.argv[1:])
    return render(a)


if __name__ == "__main__":
    sys.exit(main())
