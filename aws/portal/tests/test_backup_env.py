"""Backups group by engagement: a build box files under the engagement code it
was created for, an ordinary terminal under the tenant's own client code. The
box can't read its own tags, so these two values have to ride in the env."""
import aws_ec2
import config


def test_terminal_env_carries_machine_and_client():
    env = aws_ec2._terminal_env("alice", "alice@example.com", "acme-cct01", "acme").splitlines()
    assert "ASP_MACHINE_NAME=acme-cct01" in env
    assert "ASP_BACKUP_CLIENT=acme" in env


def test_build_box_files_under_its_engagement(monkeypatch):
    """A build box lives in the operator's tenant but belongs to the engagement
    — its backups must not land under the operator's own code."""
    seen = {}
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: [])
    monkeypatch.setattr(config, "CLIENT_CODE", "operator")
    monkeypatch.setattr(config, "SUBNET_IDS", ["subnet-1"])
    monkeypatch.setattr(aws_ec2._ec2, "run_instances",
                        lambda **kw: seen.update(kw) or {})
    name = aws_ec2.provision_build_box("acme", "eng@example.com", "group-id")
    assert name == "acme-build01"
    env = seen["UserData"]
    assert "ASP_BACKUP_CLIENT=acme" in env       # the engagement, not "operator"
    assert "ASP_MACHINE_NAME=acme-build01" in env
    assert "ASP_LOCAL_USER=build" in env
