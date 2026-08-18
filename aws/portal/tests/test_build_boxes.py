"""Operator build boxes — gating, naming, and authz.

The load-bearing property is DORMANCY: on customer tenants
GROUP_BUILD_ENGINEERS is never set, and every new code path must be
unreachable there. Tests assert the negative cases as hard as the positives.
"""
import app
import config

BUILD_GROUP = "33333333-3333-3333-3333-333333333333"


def _mk(name, owner="", owner_group="", build_for=""):
    return {"id": "i-" + name, "name": name, "owner": owner,
            "owner_group": owner_group, "build_for": build_for,
            "local_user": "x", "state": "running", "reason_code": "",
            "private_ip": "", "type": "t3.large",
            "idle_policy": "", "idle_minutes": ""}


# ---------- gate ----------

def test_dormant_when_unset():
    """No config value -> predicate is False for everyone (customer tenants)."""
    assert config.GROUP_BUILD_ENGINEERS == ""
    user = {"upn": "eng@example.com", "groups": [BUILD_GROUP, config.GROUP_ADMINS]}
    assert app._is_build_engineer(user) is False


def test_enabled_by_group_membership(monkeypatch):
    monkeypatch.setattr(config, "GROUP_BUILD_ENGINEERS", BUILD_GROUP)
    member = {"upn": "eng@example.com", "groups": [BUILD_GROUP]}
    admin = {"upn": "adm@example.com", "groups": [config.GROUP_ADMINS]}
    outsider = {"upn": "who@example.com", "groups": [config.GROUP_DESKTOP_USERS]}
    assert app._is_build_engineer(member) is True
    assert app._is_build_engineer(admin) is True     # admins may provision too
    assert app._is_build_engineer(outsider) is False


# ---------- naming ----------

def test_next_build_name(monkeypatch):
    import aws_ec2
    boxes = [_mk("acme-build01", build_for="acme"), _mk("acme-cct01"),
             _mk("zeta-build03", build_for="zeta")]
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: boxes)
    assert aws_ec2.next_build_name("acme") == "acme-build02"
    assert aws_ec2.next_build_name("zeta") == "zeta-build04"
    assert aws_ec2.next_build_name("newco") == "newco-build01"


def test_build_names_never_shift_cct_numbering(monkeypatch):
    import aws_ec2
    boxes = [_mk("acme-build07", build_for="acme"), _mk("acme-cct02")]
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: boxes)
    assert aws_ec2.next_cct_name() == "acme-cct03"


def test_valid_build_code():
    import aws_ec2
    assert aws_ec2.valid_build_code("acme")
    assert aws_ec2.valid_build_code("acme2")
    assert not aws_ec2.valid_build_code("Acme")     # lowercase only
    assert not aws_ec2.valid_build_code("a b")
    assert not aws_ec2.valid_build_code("")


# ---------- authz ----------

def test_may_use_machine(monkeypatch):
    monkeypatch.setattr(config, "GROUP_BUILD_ENGINEERS", BUILD_GROUP)
    box = _mk("acme-build01", owner="tech1@example.com",
              owner_group=BUILD_GROUP, build_for="acme")
    owner = {"upn": "tech1@example.com", "groups": []}
    teammate = {"upn": "tech2@example.com", "groups": [BUILD_GROUP]}
    outsider = {"upn": "other@example.com", "groups": [config.GROUP_DESKTOP_USERS]}
    assert app._may_use_machine(owner, box)
    assert app._may_use_machine(teammate, box)
    assert not app._may_use_machine(outsider, box)
    plain = _mk("acme-cct01", owner="alice@example.com")
    assert not app._may_use_machine(teammate, plain)   # group grants nothing on 1:1 boxes


def test_group_access_dormant_without_config():
    """OwnerGroup tag present but config unset -> no group access (customer tenant)."""
    box = _mk("acme-build01", owner="tech1@example.com",
              owner_group=BUILD_GROUP, build_for="acme")
    teammate = {"upn": "tech2@example.com", "groups": [BUILD_GROUP]}
    assert config.GROUP_BUILD_ENGINEERS == ""
    assert not app._may_use_machine(teammate, box)


# ---------- UI + route dormancy ----------

def _page_ctx(**over):
    ctx = dict(user={"upn": "u@example.com", "name": "U"}, mine=[], others=[],
               joinable=[], my_shares=[], is_admin=False, banner=None,
               is_build_engineer=False, auto_refresh=False, suppress_actions=False)
    ctx.update(over)
    return ctx


def test_machines_template_gates_form():
    tpl = app._jinja.get_template("machines.html")
    assert "/build-boxes/new" not in tpl.render(**_page_ctx())
    assert "/build-boxes/new" in tpl.render(**_page_ctx(is_build_engineer=True))


def test_build_badge_on_cards():
    tpl = app._jinja.get_template("machines.html")
    box = _mk("acme-build01", owner="tech1@example.com",
              owner_group=BUILD_GROUP, build_for="acme")
    box.update(css="running", label="Running", creator="tech1@example.com")
    html = tpl.render(**_page_ctx(mine=[box]))
    assert "build box · acme" in html


def test_build_box_route_dormant():
    """Route 403s even for group members when the feature is unconfigured —
    a customer tenant cannot reach provisioning no matter the token claims."""
    from fastapi.testclient import TestClient
    client = TestClient(app.app)
    cookie = app._signer.dumps({"upn": "eng@example.com", "name": "E",
                                "groups": [BUILD_GROUP]})
    client.cookies.set(app.SESSION_COOKIE, cookie)
    r = client.post("/build-boxes/new", data={"build_for": "acme"},
                    follow_redirects=False)
    assert r.status_code == 403
