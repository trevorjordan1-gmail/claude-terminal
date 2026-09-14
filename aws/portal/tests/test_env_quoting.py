"""#38: portal-deploy.sh shell-quotes every value it writes to /etc/asp-portal.env (a bare
multi-word ASP_BRAND is a prefix assignment to anything that `source`s the file — #12's
portal-side twin). config must read quoted values back exactly, and keep reading the
unquoted lines a pre-fix control plane wrote."""
import config


def test_load_reads_shell_quoted_values_exactly(tmp_path, monkeypatch):
    f = tmp_path / "portal.env"
    f.write_text(
        "TQ_SINGLE='Acme Terminals'\n"
        "TQ_APOS='Bob'\"'\"'s Terminals'\n"          # shlex.quote's splice for an apostrophe
        "TQ_SPLICE='Bob'\\''s Terminals'\n"          # bash's own splice (asp-terminal.env, #12)
        "TQ_DOUBLE=\"a \\\"b\\\" c\"\n"
        "TQ_PLAIN=abc-123~x\n"
        "TQ_LEGACY=Acme Terminals\n"                 # written by a pre-fix portal-deploy
        "TQ_EMPTY=''\n"
        "TQ_HASH='secret#not-a-comment'\n"
        "TQ_BS=Acme\\ Terminals\n"                   # printf %q's form, should anyone write it
    )
    monkeypatch.setattr(config, "ENV_FILE", str(f))
    cfg = config._load()
    assert cfg["TQ_SINGLE"] == "Acme Terminals"
    assert cfg["TQ_APOS"] == "Bob's Terminals"
    assert cfg["TQ_SPLICE"] == "Bob's Terminals"
    assert cfg["TQ_DOUBLE"] == 'a "b" c'
    assert cfg["TQ_PLAIN"] == "abc-123~x"
    assert cfg["TQ_LEGACY"] == "Acme Terminals"
    assert cfg["TQ_EMPTY"] == ""
    assert cfg["TQ_HASH"] == "secret#not-a-comment"
    assert cfg["TQ_BS"] == "Acme Terminals"


def test_unbalanced_quote_falls_back_to_the_raw_value(tmp_path, monkeypatch):
    f = tmp_path / "portal.env"
    f.write_text("TQ_RAW=Bob's Terminals\n")         # legacy line no shell could parse
    monkeypatch.setattr(config, "ENV_FILE", str(f))
    assert config._load()["TQ_RAW"] == "Bob's Terminals"
