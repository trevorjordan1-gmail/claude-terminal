"""Medical profile — the tenant's profile reaches every terminal and shapes
DCV permissions. Default is standard: nothing medical leaks into ordinary
tenants."""
import aws_ec2
import broker
import config


def test_profile_defaults_to_standard():
    assert config.PROFILE == "standard"


def test_terminal_env_carries_profile_default():
    env = aws_ec2._terminal_env("alice", "alice@example.com")
    assert "ASP_PROFILE=standard" in env.splitlines()
    assert "ASP_LOCAL_USER=alice" in env.splitlines()
    assert "ASP_OWNER_UPN=alice@example.com" in env.splitlines()


def test_terminal_env_carries_medical(monkeypatch):
    monkeypatch.setattr(config, "PROFILE", "medical")
    assert "ASP_PROFILE=medical" in aws_ec2._terminal_env("bob", "bob@example.com").splitlines()


def test_default_permissions_standard():
    perms = broker.default_permissions()
    assert "%owner% allow builtin" in perms
    assert "%any% disallow printer" in perms
    assert "deny" not in perms


def test_default_permissions_medical(monkeypatch):
    monkeypatch.setattr(config, "PROFILE", "medical")
    perms = broker.default_permissions()
    assert perms.splitlines()[-1] == broker.MEDICAL_DENY   # last rule wins; deny is final
    assert "file-download" in perms and "printer" in perms


def test_build_permissions_medical_guests(monkeypatch):
    monkeypatch.setattr(config, "PROFILE", "medical")
    perms = broker.build_permissions({"guest": "control"})
    lines = perms.splitlines()
    assert any(l.startswith("guest allow") and "file-download" in l for l in lines)  # granted…
    assert lines[-1] == broker.MEDICAL_DENY                                           # …then denied for %any%


def test_build_permissions_standard_has_no_deny():
    assert "deny" not in broker.build_permissions({"guest": "control"})
