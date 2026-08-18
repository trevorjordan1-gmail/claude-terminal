"""AI Terminals portal.

Entra OIDC login -> your desktops -> power controls + native-DCV connect via
broker tokens. Session sharing: owners/admins grant view or control to other
tenant users; guests join the same session through the gateway.
"""

import socket
import time
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor

import msal
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from itsdangerous import BadSignature, URLSafeTimedSerializer
from jinja2 import Environment, FileSystemLoader, select_autoescape
import os

import aws_ec2
import broker
import config
import downloads as dcv_downloads
import idle_settings
import viewers as viewer_list

app = FastAPI(title="AI Terminals", docs_url=None, redoc_url=None)

_signer = URLSafeTimedSerializer(config.SESSION_SECRET, salt="asp-portal-session")
_jinja = Environment(
    loader=FileSystemLoader(os.path.join(os.path.dirname(__file__), "templates")),
    autoescape=select_autoescape(["html"]),
)

# In-memory share grants per DCV session: {session_id: {guest_local_user: level}}
# PoC scope: single-process portal; move to a table when the portal scales out.
_grants: dict[str, dict[str, str]] = {}

SESSION_COOKIE = "asp_session"
SESSION_TTL = 8 * 3600


# ---------- auth plumbing ----------

def _msal_app() -> msal.ConfidentialClientApplication:
    return msal.ConfidentialClientApplication(
        config.CLIENT_ID,
        authority=config.AUTHORITY,
        client_credential=config.CLIENT_SECRET,
    )


def _current_user(request: Request) -> dict | None:
    raw = request.cookies.get(SESSION_COOKIE)
    if not raw:
        return None
    try:
        return _signer.loads(raw, max_age=SESSION_TTL)
    except BadSignature:
        return None


def _require_user(request: Request) -> dict:
    user = _current_user(request)
    if not user:
        raise HTTPException(status_code=307, headers={"Location": "/login"})
    return user


def _is_admin(user: dict) -> bool:
    return config.GROUP_ADMINS in user.get("groups", [])


def _is_desktop_user(user: dict) -> bool:
    return config.GROUP_DESKTOP_USERS in user.get("groups", [])


def _is_build_engineer(user: dict) -> bool:
    """Build boxes are an operator capability, dormant unless configured."""
    if not config.GROUP_BUILD_ENGINEERS:
        return False
    return (config.GROUP_BUILD_ENGINEERS in user.get("groups", [])
            or _is_admin(user))


def _may_use_machine(user: dict, m: dict) -> bool:
    """Owner always; a machine's OwnerGroup extends full use to that group's
    members — but only where the build-box feature is configured at all."""
    if m["owner"].lower() == user["upn"].lower():
        return True
    return bool(
        config.GROUP_BUILD_ENGINEERS
        and m.get("owner_group")
        and m["owner_group"] in user.get("groups", [])
    )


def _may_view(user: dict) -> bool:
    return (
        _is_admin(user)
        or _is_desktop_user(user)
        or (config.GROUP_VIEWERS and config.GROUP_VIEWERS in user.get("groups", []))
        or viewer_list.is_viewer(user.get("upn", ""))
    )


def _render(name: str, **ctx) -> HTMLResponse:
    return HTMLResponse(_jinja.get_template(name).render(**ctx))


@app.get("/login")
def login():
    auth_url = _msal_app().get_authorization_request_url(
        scopes=["User.Read"],
        redirect_uri=f"https://{config.PORTAL_HOST}/auth/callback",
        state=str(uuid.uuid4()),
    )
    return RedirectResponse(auth_url)


@app.get("/auth/callback")
def auth_callback(request: Request, code: str = "", error_description: str = ""):
    if not code:
        return PlainTextResponse(f"Login failed: {error_description}", status_code=401)
    result = _msal_app().acquire_token_by_authorization_code(
        code,
        scopes=["User.Read"],
        redirect_uri=f"https://{config.PORTAL_HOST}/auth/callback",
    )
    if "id_token_claims" not in result:
        return PlainTextResponse(f"Login failed: {result.get('error_description')}", status_code=401)
    claims = result["id_token_claims"]
    session = {
        "upn": claims.get("preferred_username", ""),
        "name": claims.get("name", ""),
        "groups": claims.get("groups", []),
    }
    resp = RedirectResponse("/")
    resp.set_cookie(
        SESSION_COOKIE, _signer.dumps(session),
        secure=True, httponly=True, samesite="lax", max_age=SESSION_TTL,
    )
    return resp


@app.get("/logout")
def logout():
    resp = RedirectResponse("/login")
    resp.delete_cookie(SESSION_COOKIE)
    return resp


# ---------- pages ----------

ACTION_BANNERS = {
    "pause": "Pause requested — saving the terminal's full state (a minute or two). "
             "Everything resumes exactly where you left off.",
    "start": "Starting — restoring a paused terminal takes 2–3 minutes; the status "
             "shows 'Waking up…' until it's truly ready to connect.",
    "stop": "Turning off — running programs will close. Use Pause next time to keep your work.",
    "reboot": "Reboot requested — status stays 'Running' during a reboot; the session "
              "drops for ~30 seconds.",
    "buildbox": "Build box launching — first boot installs the desktop + workbench "
                "(~15–20 min). Every build engineer can see and use it.",
}

HIBERNATED = "Client.UserInitiatedHibernate"


def _dcv_reachable(ip: str, timeout: float = 0.7) -> bool:
    """True when the desktop's DCV server answers on 8443 — the only honest
    "you can actually connect now" signal. During a resume-from-Pause EC2 says
    running within seconds and the broker even keeps the server AVAILABLE,
    while the OS spends ~3 min restoring its RAM image (measured 2026-08-16).
    A TCP connect from the control plane is ground truth."""
    try:
        with socket.create_connection((ip, 8443), timeout=timeout):
            return True
    except OSError:
        return False


def _broker_available_hosts() -> set | None:
    """Short hostnames the broker can place sessions on, or None if it's down."""
    try:
        return {s.get("Hostname") for s in broker.describe_servers()
                if s.get("Availability") == "AVAILABLE"}
    except Exception:
        return None  # broker unreachable: fail open on that signal


def _annotate_machines(machines: list[dict]) -> None:
    """Honest states for running instances. Connectable needs BOTH signals:
    the desktop's DCV port answers (the OS is really up — EC2 "running" lies
    for minutes during boot/RAM-restore) AND the broker lists the server
    AVAILABLE (session placement works — this lags the port by ~30–90 s).
    Ladder: "Getting ready…"+bar (true first-boot provisioning, fresh marker)
    → "Waking up…" (port down) → "Almost ready…" (port up, broker syncing)
    → Running."""
    for m in machines:
        m["label"], m["css"] = _display_state(m)
    avail = _broker_available_hosts()
    runners = [m for m in machines if m["css"] == "running" and m.get("private_ip")]
    if not runners:
        return
    with ThreadPoolExecutor(max_workers=min(8, len(runners))) as ex:
        up = list(ex.map(lambda m: _dcv_reachable(m["private_ip"]), runners))
    for m, ok in zip(runners, up):
        in_broker = (avail is None) or ("ip-" + m["private_ip"].replace(".", "-") in avail)
        if ok and in_broker:
            continue  # truly Running
        progress = aws_ec2.provision_status(m["id"]) if not in_broker else None
        if progress:
            m["label"], m["css"] = "Getting ready…", "pending"
            m["progress"] = progress
        elif not ok:
            m["label"], m["css"], m["waking"] = "Waking up…", "pending", True
        else:
            m["label"], m["css"], m["almost"] = "Almost ready…", "pending", True


def _display_state(m: dict) -> tuple[str, str]:
    """(label, css_class) from EC2 state + hibernate reason code."""
    state, reason = m["state"], m.get("reason_code", "")
    if state == "running":
        return "Running", "running"
    if state == "pending":
        return "Starting…", "pending"
    if state == "stopping":
        return ("Pausing…", "stopping") if reason == HIBERNATED else ("Shutting down…", "stopping")
    if state == "stopped":
        return ("Paused", "paused") if reason == HIBERNATED else ("Powered off", "stopped")
    return state, state


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    user = _require_user(request)
    banner = ACTION_BANNERS.get(request.query_params.get("did", ""))

    machines = aws_ec2.list_desktops()
    _annotate_machines(machines)
    mine = [m for m in machines if _may_use_machine(user, m)]
    if not _may_view(user) and not mine:
        return _render("denied.html", user=user)
    others = [m for m in machines if m not in mine]

    # joinable sessions: any active session where I'm admin or have a grant
    my_local = config.local_user(user["upn"])
    joinable = []
    try:
        for s in broker.describe_sessions():
            if s.get("State") not in ("READY", "CREATING"):
                continue
            owner = s.get("Owner", "")
            if owner == my_local:
                continue
            granted = _grants.get(s.get("Id", ""), {}).get(my_local)
            if _is_admin(user) or granted:
                joinable.append({
                    "id": s.get("Id"),
                    "owner": owner,
                    "level": granted or "control",
                })
    except Exception:
        pass  # broker down -> page still renders machines

    # active share grants on my sessions, so owners can revoke
    my_shares = []
    try:
        if mine:
            my_locals = {m["local_user"] for m in mine}
            for s in broker.describe_sessions():
                if s.get("Owner") in my_locals and s.get("State") == "READY":
                    for guest, level in (_grants.get(s.get("Id"), {}) or {}).items():
                        my_shares.append({"session_id": s["Id"], "guest": guest, "level": level})
    except Exception:
        pass

    transitional = any(m["css"] in ("pending", "stopping") for m in machines)
    return _render(
        "machines.html",
        user=user, mine=mine, others=others, joinable=joinable,
        is_admin=_is_admin(user), is_build_engineer=_is_build_engineer(user),
        banner=banner, my_shares=my_shares,
        auto_refresh=bool(banner) or transitional,
        suppress_actions=bool(banner),
    )


# ---------- power ----------

def _authz_machine(user: dict, instance_id: str) -> dict:
    machines = {m["id"]: m for m in aws_ec2.list_desktops()}
    m = machines.get(instance_id)
    if not m:
        raise HTTPException(404, "unknown machine")
    if not _may_use_machine(user, m) and not _is_admin(user):
        raise HTTPException(403, "not your machine")
    return m


@app.post("/machines/{instance_id}/{action}")
def power(request: Request, instance_id: str, action: str):
    user = _require_user(request)
    _authz_machine(user, instance_id)
    if action == "start":
        aws_ec2.start(instance_id)
    elif action == "pause":
        aws_ec2.hibernate(instance_id)
    elif action == "stop":
        aws_ec2.stop(instance_id)
    elif action == "reboot":
        aws_ec2.reboot(instance_id)
    else:
        raise HTTPException(400, "unknown action")
    return RedirectResponse(f"/?did={action}", status_code=303)


# ---------- connect (owner) ----------

def _ensure_session(owner_local: str) -> dict:
    sessions = broker.describe_sessions(owner=owner_local)
    for s in sessions:
        if s.get("State") == "READY":
            return s
    # don't double-create while one is still being born
    if not any(s.get("State") == "CREATING" for s in sessions):
        # the broker's availability view can lag the desktop by ~30-90s after
        # a boot/close — absorb that window instead of erroring at the user
        for attempt in range(6):
            try:
                broker.create_session(name=f"{owner_local}-desktop", owner=owner_local)
                break
            except RuntimeError as e:
                if "No DCV server found" not in str(e) or attempt == 5:
                    raise
                time.sleep(5)
    for _ in range(45):
        time.sleep(2)
        for s in broker.describe_sessions(owner=owner_local):
            if s.get("State") == "READY":
                return s
    raise HTTPException(
        504,
        "The terminal accepted the request but the session never became ready — "
        "its DCV service may need attention. Try again in a minute; if it "
        "persists, tell your admin contact.")


def _connect_response(session_id: str, connect_user: str):
    data = broker.get_connection_data(session_id, connect_user)
    token = data.get("ConnectionToken", "")
    # format per userguide/using-connecting-uri.html: dcv://host:port/?authToken=...#sessionId
    dcv_url = (
        f"dcv://{config.GATEWAY_HOST}:{config.GATEWAY_PORT}/"
        f"?authToken={urllib.parse.quote(token, safe='')}#{session_id}"
    )
    dcv_file = "\n".join([
        "[version]", "format=1.0",
        "[connect]",
        f"host={config.GATEWAY_HOST}",
        f"port={config.GATEWAY_PORT}",
        f"sessionid={session_id}",
        f"authtoken={token}",
        "transport=auto",
        "",
    ])
    return dcv_url, dcv_file


@app.post("/connect/{instance_id}")
def connect(request: Request, instance_id: str):
    user = _require_user(request)
    m = _authz_machine(user, instance_id)
    if m["state"] == "stopped":
        aws_ec2.start(instance_id)
        return _render("starting.html", user=user, machine=m)
    if m["state"] != "running":
        return _render("starting.html", user=user, machine=m)
    if m.get("private_ip"):
        # EC2 "running" isn't connectable: the OS may still be booting or
        # restoring RAM (port closed), and the broker can't place a session
        # until it re-lists the server — gate Connect on both signals
        avail = _broker_available_hosts()
        in_broker = (avail is None) or ("ip-" + m["private_ip"].replace(".", "-") in avail)
        if not (_dcv_reachable(m["private_ip"]) and in_broker):
            return _render("starting.html", user=user, machine=m)

    # the machine's LocalUser tag, NOT derived from the Owner UPN: build boxes
    # have a fixed shared session user that no UPN maps to
    owner_local = m["local_user"]
    try:
        session = _ensure_session(owner_local)
        aws_ec2.force_display_layout(m["id"], session["Id"])
        dcv_url, dcv_file = _connect_response(session["Id"], owner_local)
    except HTTPException as e:
        return _render("error.html", user=user, message=e.detail)
    except Exception as e:
        return _render("error.html", user=user, message=str(e))
    return _render(
        "connect.html",
        user=user, dcv_url=dcv_url, session_id=session["Id"],
        connect_user=owner_local,
    )


# ---------- share / join ----------

@app.post("/share/{instance_id}")
def share(request: Request, instance_id: str,
          guest_upn: str = Form(...), level: str = Form("view")):
    user = _require_user(request)
    m = _authz_machine(user, instance_id)  # owner, group member, or admin
    owner_local = m["local_user"]
    sessions = [s for s in broker.describe_sessions(owner=owner_local)
                if s.get("State") == "READY"]
    if not sessions:
        raise HTTPException(409, "no active session to share — connect first")
    sid = sessions[0]["Id"]
    guest_local = config.local_user(guest_upn)
    aws_ec2.ensure_os_user(m["id"], guest_local)
    grants = _grants.setdefault(sid, {})
    grants[guest_local] = "control" if level == "control" else "view"
    broker.update_permissions(sid, sessions[0].get("Owner", owner_local), broker.build_permissions(grants))
    return RedirectResponse("/", status_code=303)


@app.post("/revoke/{session_id}/{guest_local}")
def revoke(request: Request, session_id: str, guest_local: str):
    user = _require_user(request)
    session = next((s for s in broker.describe_sessions() if s.get("Id") == session_id), None)
    if not session:
        return RedirectResponse("/", status_code=303)
    if session.get("Owner") != config.local_user(user["upn"]) and not _is_admin(user):
        raise HTTPException(403, "not your session")
    grants = _grants.get(session_id, {})
    grants.pop(guest_local, None)
    broker.update_permissions(session_id, session.get("Owner", ""), broker.build_permissions(grants))
    return RedirectResponse("/", status_code=303)


@app.post("/join/{session_id}")
def join(request: Request, session_id: str):
    user = _require_user(request)
    my_local = config.local_user(user["upn"])
    granted = _grants.get(session_id, {}).get(my_local)
    if not granted and not _is_admin(user):
        raise HTTPException(403, "no grant for this session")
    if _is_admin(user) and not granted:
        # admins self-grant full control (recorded so revoke works)
        for s in broker.describe_sessions():
            if s.get("Id") == session_id:
                owner_machine = next(
                    (m for m in aws_ec2.list_desktops()
                     if m["local_user"] == s.get("Owner") and m["state"] == "running"), None)
                if owner_machine:
                    aws_ec2.ensure_os_user(owner_machine["id"], my_local)
                grants = _grants.setdefault(session_id, {})
                grants[my_local] = "control"
                broker.update_permissions(session_id, s.get("Owner", ""), broker.build_permissions(grants))
                break
    dcv_url, dcv_file = _connect_response(session_id, my_local)
    return _render(
        "connect.html",
        user=user, dcv_url=dcv_url, session_id=session_id,
        connect_user=my_local,
    )


@app.get("/dcvfile/{session_id}/{connect_user}")
def dcv_file(request: Request, session_id: str, connect_user: str):
    user = _require_user(request)
    my_local = config.local_user(user["upn"])
    if connect_user != my_local and not _is_admin(user):
        # owners fetch their own file; guests fetch theirs
        for s in broker.describe_sessions():
            if s.get("Id") == session_id and s.get("Owner") == my_local:
                break
        else:
            raise HTTPException(403, "not yours")
    _, dcv_content = _connect_response(session_id, connect_user)
    return Response(
        dcv_content, media_type="application/dcv",
        headers={"Content-Disposition": 'attachment; filename="terminal.dcv"'},
    )


ADMIN_BANNERS = {
    "viewer": "Viewer list updated — viewers can sign in and join sessions shared "
              "with them, but never get a terminal of their own.",
    "idle": "Idle settings saved — the watchdog applies them on its next 5-minute pass.",
    "add": "Terminal provisioning — the instance is launching now; first boot "
           "installs the desktop + workbench (~15–20 min). It appears below "
           "immediately and its owner can sign in once it's Running.",
    "remove": "Terminal terminated — the user's access is gone and the machine "
              "and its disk are being deleted.",
}


def _require_admin(request: Request) -> dict:
    user = _require_user(request)
    if not _is_admin(user):
        raise HTTPException(403, "admins only")
    return user


@app.get("/admin", response_class=HTMLResponse)
def admin_page(request: Request):
    user = _require_admin(request)
    banner = ADMIN_BANNERS.get(request.query_params.get("did", ""))
    machines = aws_ec2.list_desktops()
    _annotate_machines(machines)
    sessions = []
    try:
        for s in broker.describe_sessions():
            if s.get("State") in ("READY", "CREATING"):
                sessions.append({
                    "id": s.get("Id"), "owner": s.get("Owner"), "state": s.get("State"),
                    "grants": _grants.get(s.get("Id"), {}),
                })
    except Exception:
        pass
    transitional = any(m["css"] in ("pending", "stopping") for m in machines)
    return _render(
        "admin.html",
        user=user, machines=machines, sessions=sessions, banner=banner,
        next_name=aws_ec2.next_cct_name(), idle=idle_settings.get_settings(),
        viewers=viewer_list.get_viewers(),
        auto_refresh=bool(banner) or transitional,
    )


@app.post("/admin/idle-settings")
def admin_idle_settings(request: Request,
                        enabled: str = Form(""),
                        idle_minutes: int = Form(30),
                        sensitivity: str = Form("balanced"),
                        pause_to_off_hours: int = Form(48)):
    _require_admin(request)
    preset = idle_settings.SENSITIVITY_PRESETS.get(sensitivity)
    if not preset:
        raise HTTPException(400, "bad sensitivity")
    current = idle_settings.get_settings()
    idle_settings.put_settings({
        "enabled": bool(enabled),
        "idle_minutes": max(5, min(idle_minutes, 480)),
        "sensitivity": sensitivity,
        "claude_active_ticks": preset["claude_active_ticks"],
        "load_active": preset["load_active"],
        "min_uptime_secs": current["min_uptime_secs"],
        "pause_to_off_hours": max(0, min(pause_to_off_hours, 720)),
    })
    return RedirectResponse("/admin?did=idle", status_code=303)


@app.post("/admin/idle-policy/{instance_id}")
def admin_idle_policy(request: Request, instance_id: str,
                      policy: str = Form("default"), minutes: int = Form(0)):
    _require_admin(request)
    if instance_id not in {m["id"] for m in aws_ec2.list_desktops()}:
        raise HTTPException(404, "unknown terminal")
    if policy not in ("default", "keep-awake", "custom"):
        raise HTTPException(400, "bad policy")
    aws_ec2.set_idle_policy(instance_id, policy,
                            max(5, min(minutes, 1440)) if policy == "custom" else None)
    return RedirectResponse("/admin?did=idle", status_code=303)


@app.post("/admin/viewers/add")
def admin_viewer_add(request: Request, viewer_upn: str = Form(...)):
    _require_admin(request)
    viewer_upn = viewer_upn.strip().lower()
    if "@" not in viewer_upn:
        raise HTTPException(400, "viewer must be an email/UPN")
    viewer_list.add_viewer(viewer_upn)
    return RedirectResponse("/admin?did=viewer", status_code=303)


@app.post("/admin/viewers/remove")
def admin_viewer_remove(request: Request, viewer_upn: str = Form(...)):
    _require_admin(request)
    viewer_list.remove_viewer(viewer_upn)
    return RedirectResponse("/admin?did=viewer", status_code=303)


@app.post("/admin/add")
def admin_add(request: Request, owner_upn: str = Form(...), local_user: str = Form("")):
    _require_admin(request)
    owner_upn = owner_upn.strip().lower()
    if "@" not in owner_upn:
        raise HTTPException(400, "owner must be an email/UPN")
    local_user = (local_user.strip().lower() or config.local_user(owner_upn))
    if not aws_ec2.valid_local_user(local_user):
        raise HTTPException(400, "invalid username (lowercase letters/digits/dashes)")
    # build boxes carry Owner = their creator but don't count as "a terminal"
    if any(m["owner"].lower() == owner_upn and not m.get("build_for")
           for m in aws_ec2.list_desktops()):
        raise HTTPException(409, "that user already has a terminal")
    aws_ec2.provision(owner_upn, local_user)
    return RedirectResponse("/admin?did=add", status_code=303)


@app.post("/admin/remove/{instance_id}")
def admin_remove(request: Request, instance_id: str):
    _require_admin(request)
    machines = {m["id"]: m for m in aws_ec2.list_desktops()}
    m = machines.get(instance_id)
    if not m:
        raise HTTPException(404, "unknown terminal")
    # best effort: tear down the user's broker sessions first
    try:
        for s in broker.describe_sessions(owner=m["local_user"]):
            if s.get("State") in ("READY", "CREATING"):
                broker.delete_session(s["Id"], m["local_user"])
    except Exception:
        pass
    aws_ec2.terminate(instance_id)
    return RedirectResponse("/admin?did=remove", status_code=303)


@app.post("/build-boxes/new")
def build_box_new(request: Request, build_for: str = Form(...)):
    user = _require_user(request)
    if not _is_build_engineer(user):
        raise HTTPException(403, "build engineers only")
    build_for = build_for.strip().lower()
    if not aws_ec2.valid_build_code(build_for):
        raise HTTPException(400, "client code: 2-16 lowercase letters/digits")
    aws_ec2.provision_build_box(build_for, user["upn"],
                                config.GROUP_BUILD_ENGINEERS)
    return RedirectResponse("/?did=buildbox", status_code=303)


@app.get("/downloads", response_class=HTMLResponse)
def downloads_page(request: Request):
    user = _require_user(request)
    return _render("downloads.html", user=user, downloads=dcv_downloads.get_downloads())


@app.get("/healthz")
def healthz():
    return {"ok": True, "customer": config.CUSTOMER, "version": config.VERSION}
