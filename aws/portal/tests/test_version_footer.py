"""The running release is visible on the page, not only in /healthz.

Operator request 2026-09-16: when someone reports "the portal is doing X", the
first question is which build they are looking at. /healthz had the answer but
you have to know to go and ask it.
"""
import app
import config


def test_version_is_a_jinja_global():
    assert app._jinja.globals["version"] == config.VERSION


def test_footer_shows_the_build_on_a_rendered_page():
    html = app._render("downloads.html", downloads=[]).body.decode()
    assert "<footer>" in html
    assert f"build <code>{config.VERSION}</code>" in html


def test_every_user_facing_template_inherits_the_footer():
    """The footer lives in base.html, so it only reaches pages that extend it —
    including the ones people hit when something is already wrong."""
    for name, ctx in (
        ("downloads.html", {"downloads": []}),
        ("error.html", {"message": "boom"}),
        ("denied.html", {"user": {"upn": "someone@example.com", "name": "Someone"}}),
    ):
        html = app._render(name, **ctx).body.decode()
        assert f"build <code>{config.VERSION}</code>" in html, f"{name} has no build footer"


def test_version_tracks_config_not_a_hardcoded_string():
    original = app._jinja.globals["version"]
    app._jinja.globals["version"] = "v0.0.0-test"
    try:
        html = app._render("downloads.html", downloads=[]).body.decode()
        assert "build <code>v0.0.0-test</code>" in html
    finally:
        app._jinja.globals["version"] = original
