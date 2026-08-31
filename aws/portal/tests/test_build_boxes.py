"""Operator build boxes — gating, naming, and authz.

The load-bearing property is DORMANCY: on customer tenants
GROUP_BUILD_ENGINEERS is never set, and every new code path must be
unreachable there. Tests assert the negative cases as hard as the positives.
"""
import app
import pytest
from fastapi import HTTPException
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


# ---------- session routing (two build boxes, one shared 'build' owner) ----------

def _sess(sid, ip, state="READY", owner="build"):
    return {"Id": sid, "Owner": owner, "State": state,
            "Server": {"Ip": ip, "Hostname": "ip-" + ip.replace(".", "-")}}


def test_session_on_host():
    s = _sess("s1", "10.0.1.5")
    assert app._session_on_host(s, "10.0.1.5")
    assert not app._session_on_host(s, "10.0.1.6")
    assert not app._session_on_host(s, "")            # stopped machine: no ip
    assert app._session_on_host({"Id": "s2", "Server": {"Hostname": "ip-10-0-1-7"}},
                                "10.0.1.7")           # hostname-only broker row


def test_ensure_session_picks_this_machine_not_sibling(monkeypatch):
    """Two build boxes both run as 'build'. Connect on <clientB>'s box must return
    <clientB>'s session even when <clientA>'s session was created first (the bug: an
    owner-only lookup sent every Connect to <clientA>)."""
    import broker
    clienta = _sess("sess-clienta", "10.0.1.10")
    clientb = _sess("sess-clientb", "10.0.1.20")
    monkeypatch.setattr(broker, "describe_sessions", lambda owner=None: [clienta, clientb])
    machine = {"id": "i-clientb", "private_ip": "10.0.1.20"}
    assert app._ensure_session("build", machine)["Id"] == "sess-clientb"


def test_ensure_session_creates_pinned_to_instance(monkeypatch):
    """No session on the clicked box yet (sibling has one): create one pinned
    to this instance via Requirements, and keep waiting for THIS host's
    session — never return the sibling's."""
    import broker
    clienta = _sess("sess-clienta", "10.0.1.10")
    clientb = _sess("sess-clientb", "10.0.1.20")
    created = {}

    def fake_create(name, owner, permissions=None, requirements=None):
        created["requirements"] = requirements
        return {}

    calls = {"n": 0}

    def fake_describe(owner=None):
        # <clientB>'s session only appears after the create call
        return [clienta, clientb] if created else [clienta]

    monkeypatch.setattr(broker, "describe_sessions", fake_describe)
    monkeypatch.setattr(broker, "create_session", fake_create)
    monkeypatch.setattr(app.time, "sleep", lambda s: None)
    machine = {"id": "i-clientb", "private_ip": "10.0.1.20"}
    session = app._ensure_session("build", machine)
    assert session["Id"] == "sess-clientb"
    assert created["requirements"] == "server:Host.Aws.Ec2InstanceId = 'i-clientb'"


def test_ensure_session_without_host_ip_fails_fast(monkeypatch):
    """A machine with no private IP cannot be matched to a session. Fail fast
    and honestly rather than spinning the 90s wait loop and then blaming the
    DCV service — and never fall back to a same-owner session on another box."""
    import broker
    polls = {"n": 0}

    def counting(owner=None):
        polls["n"] += 1
        return [_sess("sess-sibling", "10.0.1.10")]

    monkeypatch.setattr(broker, "describe_sessions", counting)
    monkeypatch.setattr(app.time, "sleep", lambda s: None)
    with pytest.raises(HTTPException) as e:
        app._ensure_session("build", {"id": "i-x", "private_ip": ""})
    assert e.value.status_code == 409
    assert "still coming up" in e.value.detail
    assert polls["n"] == 0, "polled the broker despite having no way to match a session"


def test_admin_remove_spares_sibling_build_box_sessions(monkeypatch):
    """Removing one build box must not delete its siblings' sessions. Every
    build box is owned by 'build', so the pre-fix owner-only sweep tore down
    live sessions on machines that were not being removed."""
    import broker
    victim = {"id": "i-victim", "local_user": "build", "private_ip": "10.0.1.20"}
    sibling_sess = _sess("sess-sibling", "10.0.1.10")
    victim_sess = _sess("sess-victim", "10.0.1.20")
    deleted = []

    monkeypatch.setattr(app, "_require_admin", lambda r: {"upn": "adm@example.com"})
    monkeypatch.setattr(app.aws_ec2, "list_desktops",
                        lambda: [victim, {"id": "i-sibling", "local_user": "build",
                                          "private_ip": "10.0.1.10"}])
    monkeypatch.setattr(app.aws_ec2, "terminate", lambda i: None)
    monkeypatch.setattr(broker, "describe_sessions",
                        lambda owner=None: [sibling_sess, victim_sess])
    monkeypatch.setattr(broker, "delete_session", lambda sid, owner: deleted.append(sid))

    app.admin_remove(None, "i-victim")
    assert deleted == ["sess-victim"], deleted


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
