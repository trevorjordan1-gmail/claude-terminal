"""ASP_BRAND (issue #1): portal title/header come from config, neutral default."""
import app
import config


def test_brand_default_and_global():
    assert config.BRAND == "Claude Code Terminals"
    assert app._jinja.globals["brand"] == config.BRAND


def test_base_renders_brand_with_accent_on_last_word():
    html = app._render("downloads.html", downloads=[]).body.decode()
    assert "<title>Claude Code Terminals</title>" in html
    assert "Claude Code <span>Terminals</span>" in html


def test_single_word_brand_renders_without_span():
    app._jinja.globals["brand"] = "Terminals"
    try:
        html = app._render("downloads.html", downloads=[]).body.decode()
        assert "<h1>Terminals</h1>" in html
    finally:
        app._jinja.globals["brand"] = config.BRAND
