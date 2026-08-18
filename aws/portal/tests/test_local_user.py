"""local_user() (issue #5): UPN → valid Linux name; provisioning and session
mapping share it, and old-mapping terminals stay usable via _my_locals()."""
import app
import aws_ec2
import config


def test_local_user_sanitizes():
    assert config.local_user("John.Smith@example.com") == "johnsmith"
    assert config.local_user("first_last@example.com") == "firstlast"
    assert config.local_user("123abc@example.com") == "abc"
    assert config.local_user("--@example.com") == "user"
    long = "a" * 40 + "@example.com"
    assert len(config.local_user(long)) == 31
    assert aws_ec2.valid_local_user(config.local_user(long))


def test_my_locals_includes_owned_machine_tags(monkeypatch):
    user = {"upn": "john.smith@example.com", "groups": []}
    machines = [
        {"id": "i-1", "name": "acme-cct01", "owner": "john.smith@example.com", "local_user": "john.smith"},
        {"id": "i-2", "name": "acme-cct02", "owner": "someone@example.com", "local_user": "someone"},
    ]
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: machines)
    assert app._my_locals(user) == {"johnsmith", "john.smith"}


def test_my_locals_survives_aws_error(monkeypatch):
    def boom():
        raise RuntimeError("no aws")
    monkeypatch.setattr(aws_ec2, "list_desktops", boom)
    assert app._my_locals({"upn": "x.y@example.com", "groups": []}) == {"xy"}
