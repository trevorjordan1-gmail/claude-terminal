"""#58: an admin can reach an idle terminal from the UI, Join never 500s while a box is
still restoring from hibernate, and removing a terminal leaves no ghost broker session.

The admin path is a stronger act than Join — it starts the OWNER's session and connects
as the owner's local user — so the tests also pin the safeguards: the button says so,
only truly Running cards offer it, non-admins never see it, and the portal logs it."""
import app
import aws_ec2
import broker
import config
from fastapi.testclient import TestClient

ADMIN = {"upn": "adm@example.com", "name": "A", "groups": [config.GROUP_ADMINS]}
USER = {"upn": "bob@example.com", "name": "B", "groups": [config.GROUP_DESKTOP_USERS]}


def _mk(name, owner, css="running", ip="10.60.1.10", local_user="bob"):
    return {"id": "i-" + name, "name": name, "owner": owner, "owner_group": "",
            "build_for": "", "local_user": local_user, "state": "running",
            "reason_code": "", "private_ip": ip, "type": "t3.large",
            "idle_policy": "", "idle_minutes": "", "label": css.title(), "css": css}


def _client(user):
    c = TestClient(app.app)
    c.cookies.set(app.SESSION_COOKIE, app._signer.dumps(user))
    return c


# ---------- the button ----------

def _render_home(user, others):
    return app._render("machines.html", user=user, mine=[], others=others, joinable=[],
                       is_admin=app._is_admin(user), is_build_engineer=False, banner=None,
                       my_shares=[], auto_refresh=False, suppress_actions=False).body.decode()


def test_admin_sees_connect_as_owner_on_running_card():
    html = _render_home(ADMIN, [_mk("acme-cct01", "bob@example.com")])
    assert "Connect as owner" in html
    assert 'action="/connect/i-acme-cct01"' in html
    assert "starts one on their behalf" in html      # the confirm says what it does
    assert "This is logged" in html


def test_no_connect_as_owner_unless_truly_running():
    for css in ("paused", "stopped", "pending", "failed", "stopping"):
        html = _render_home(ADMIN, [_mk("acme-cct01", "bob@example.com", css=css)])
        assert "Connect as owner" not in html, css


def test_non_admin_never_sees_the_admin_section():
    html = _render_home(USER, [_mk("acme-cct02", "carol@example.com")])
    assert "Connect as owner" not in html
    assert "All tenant terminals" not in html


# ---------- the audit line ----------

def test_admin_connect_to_someone_elses_terminal_is_logged(monkeypatch):
    m = _mk("acme-cct01", "bob@example.com")
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: [m])
    monkeypatch.setattr(app, "_dcv_reachable", lambda ip, timeout=0.7: True)
    monkeypatch.setattr(app, "_broker_available_hosts", lambda: None)
    monkeypatch.setattr(app, "_ensure_session", lambda owner, mach: {"Id": "sess-1"})
    monkeypatch.setattr(aws_ec2, "force_display_layout", lambda *a, **k: None)
    monkeypatch.setattr(app, "_connect_response", lambda sid, u, label="": ("dcv://x", "file"))
    lines = []
    monkeypatch.setattr(app.audit, "info", lambda msg, *a: lines.append(msg % a))
    r = _client(ADMIN).post("/connect/i-acme-cct01")
    assert r.status_code == 200
    assert lines and "adm@example.com" in lines[0] and "as owner bob" in lines[0]


def test_owner_connect_is_not_an_audit_event(monkeypatch):
    m = _mk("acme-cct01", "bob@example.com")
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: [m])
    monkeypatch.setattr(app, "_dcv_reachable", lambda ip, timeout=0.7: True)
    monkeypatch.setattr(app, "_broker_available_hosts", lambda: None)
    monkeypatch.setattr(app, "_ensure_session", lambda owner, mach: {"Id": "sess-1"})
    monkeypatch.setattr(aws_ec2, "force_display_layout", lambda *a, **k: None)
    monkeypatch.setattr(app, "_connect_response", lambda sid, u, label="": ("dcv://x", "file"))
    lines = []
    monkeypatch.setattr(app.audit, "info", lambda msg, *a: lines.append(msg % a))
    assert _client(USER).post("/connect/i-acme-cct01").status_code == 200
    assert lines == []


# ---------- Join while the box is still restoring ----------

SESSION = {"Id": "sess-1", "Owner": "bob", "State": "READY", "Server": {"Ip": "10.60.1.10"}}


def _join_setup(monkeypatch, reachable, in_broker=True):
    m = _mk("acme-cct01", "bob@example.com")
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: [m])
    monkeypatch.setattr(broker, "describe_sessions", lambda owner=None: [SESSION])
    monkeypatch.setattr(app, "_dcv_reachable", lambda ip, timeout=0.7: reachable)
    monkeypatch.setattr(app, "_broker_available_hosts",
                        lambda: {"ip-10-60-1-10"} if in_broker else set())
    return m


def test_join_renders_waking_page_while_desktop_port_is_down(monkeypatch):
    _join_setup(monkeypatch, reachable=False)
    def boom(*a, **k):
        raise AssertionError("ensure_os_user must not run against a box that is not ready")
    monkeypatch.setattr(aws_ec2, "ensure_os_user", boom)
    r = _client(ADMIN).post("/join/sess-1")
    assert r.status_code == 200
    assert "waking up" in r.text


def test_join_renders_waking_page_while_broker_has_not_relisted_the_server(monkeypatch):
    _join_setup(monkeypatch, reachable=True, in_broker=False)
    r = _client(ADMIN).post("/join/sess-1")
    assert r.status_code == 200 and "waking up" in r.text


def test_join_ssm_failure_is_a_page_not_a_traceback(monkeypatch):
    _join_setup(monkeypatch, reachable=True)
    def boom(*a, **k):
        raise RuntimeError("InvalidInstanceId: Instances not in a valid state for account")
    monkeypatch.setattr(aws_ec2, "ensure_os_user", boom)
    r = _client(ADMIN).post("/join/sess-1")
    assert r.status_code == 200
    assert "InvalidInstanceId" in r.text and "Back" in r.text


def test_join_happy_path_grants_and_connects(monkeypatch):
    _join_setup(monkeypatch, reachable=True)
    monkeypatch.setattr(aws_ec2, "ensure_os_user", lambda *a, **k: None)
    perms = []
    monkeypatch.setattr(broker, "update_permissions", lambda sid, owner, p: perms.append((sid, owner)))
    monkeypatch.setattr(broker, "build_permissions", lambda g: dict(g))
    monkeypatch.setattr(app, "_connect_response", lambda sid, u, label="": ("dcv://x", "file"))
    app._grants.pop("sess-1", None)
    r = _client(ADMIN).post("/join/sess-1")
    assert r.status_code == 200 and "dcv://x" in r.text
    assert perms == [("sess-1", "bob")]
    assert app._grants["sess-1"][config.local_user(ADMIN["upn"])] == "control"


# ---------- remove leaves no ghost ----------

def test_remove_deletes_every_session_on_the_host_forced(monkeypatch):
    m = _mk("acme-cct01", "bob@example.com")
    sibling_ip = {"Id": "s-other", "Owner": "bob", "State": "UNKNOWN", "Server": {"Ip": "10.60.1.99"}}
    ghost = {"Id": "s-ghost", "Owner": "bob", "State": "UNKNOWN", "Server": {"Ip": "10.60.1.10"}}
    live = {"Id": "s-live", "Owner": "bob", "State": "READY", "Server": {"Ip": "10.60.1.10"}}
    gone = {"Id": "s-gone", "Owner": "bob", "State": "DELETED", "Server": {"Ip": "10.60.1.10"}}
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: [m])
    monkeypatch.setattr(broker, "describe_sessions", lambda owner=None: [sibling_ip, ghost, live, gone])
    deleted = []
    monkeypatch.setattr(broker, "delete_session",
                        lambda sid, owner, force=False: deleted.append((sid, force)))
    monkeypatch.setattr(aws_ec2, "terminate", lambda iid: None)
    r = _client(ADMIN).post("/admin/remove/i-acme-cct01", follow_redirects=False)
    assert r.status_code == 303
    assert sorted(deleted) == [("s-ghost", True), ("s-live", True)]
