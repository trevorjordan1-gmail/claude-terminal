"""DCV Session Manager broker API client (OAuth2 client-credentials).

Paths/fields per the Session Manager OpenAPI (dcv-session-manager-api.yaml)
and sm-dev guide — PascalCase fields, sessionId as URL fragment elsewhere.
"""

import base64
import time

import httpx

import config

_token: dict = {"value": None, "exp": 0}


def _client() -> httpx.Client:
    return httpx.Client(base_url=config.BROKER_URL, verify=config.BROKER_VERIFY_TLS, timeout=20)


def _get_token() -> str:
    if _token["value"] and time.time() < _token["exp"] - 60:
        return _token["value"]
    with _client() as c:
        r = c.post(
            "/oauth2/token",
            params={"grant_type": "client_credentials"},
            auth=(config.BROKER_CLIENT_ID, config.BROKER_CLIENT_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        r.raise_for_status()
        body = r.json()
    _token["value"] = body["access_token"]
    _token["exp"] = time.time() + int(body.get("expires_in", 3600))
    return _token["value"]


def _headers() -> dict:
    return {"Authorization": f"Bearer {_get_token()}", "Content-Type": "application/json"}


def describe_sessions(owner: str | None = None) -> list[dict]:
    body: dict = {}
    if owner:
        body["Filters"] = [{"Key": "owner", "Value": owner}]
    with _client() as c:
        r = c.post("/describeSessions", json=body, headers=_headers())
        r.raise_for_status()
        return r.json().get("Sessions", []) or []


def describe_servers() -> list[dict]:
    with _client() as c:
        r = c.post("/describeServers", json={}, headers=_headers())
        r.raise_for_status()
        return r.json().get("Servers", []) or []


# CCTs never print (TJ 2026-08-15): disallow DCV printer redirection so the
# client's local printers stop mounting as cups queues in the session. Rules
# are last-match-wins, so this strips printer back out of `allow builtin`.
NO_PRINTER = "%any% disallow printer"

DEFAULT_PERMISSIONS = f"[permissions]\n%owner% allow builtin\n{NO_PRINTER}\n"


def create_session(name: str, owner: str, permissions: str | None = None) -> dict:
    req: dict = {
        "Name": name,
        "Owner": owner,
        "Type": "VIRTUAL",
        "MaxConcurrentClients": 4,  # owner + collab guests
        # without a StorageRoot the client hides file transfer entirely
        "StorageRoot": "%home%",
        "PermissionsFile": base64.b64encode((permissions or DEFAULT_PERMISSIONS).encode()).decode(),
    }
    with _client() as c:
        r = c.post("/createSessions", json=[req], headers=_headers())
        r.raise_for_status()
        body = r.json()
    fails = body.get("UnsuccessfulList") or []
    if fails:
        reason = fails[0].get("FailureReason") or fails[0].get("FailureCode") or str(fails[0])
        raise RuntimeError(f"broker refused to create the session: {reason}")
    return body


def delete_session(session_id: str, owner: str, force: bool = False) -> dict:
    body = [{"SessionId": session_id, "Owner": owner, "Force": force}]
    with _client() as c:
        r = c.post("/deleteSessions", json=body, headers=_headers())
        r.raise_for_status()
        return r.json()


def get_connection_data(session_id: str, user: str) -> dict:
    with _client() as c:
        r = c.get(f"/sessionConnectionData/{session_id}/{user}", headers=_headers())
        r.raise_for_status()
        return r.json()


def update_permissions(session_id: str, owner: str, permissions: str) -> dict:
    body = [{
        "SessionId": session_id,
        "Owner": owner,
        "PermissionsFile": base64.b64encode(permissions.encode()).decode(),
    }]
    with _client() as c:
        r = c.put("/sessionPermissions", json=body, headers=_headers())
        r.raise_for_status()
        return r.json()


VIEW_FEATURES = "display pointer audio-out"
CONTROL_FEATURES = (
    "display pointer audio-out mouse keyboard "
    "clipboard-copy clipboard-paste file-upload file-download"
)


def build_permissions(guests: dict[str, str]) -> str:
    """DCV permissions file: owner keeps everything; guests view or control."""
    lines = ["[permissions]", "%owner% allow builtin"]
    for user, level in guests.items():
        feats = CONTROL_FEATURES if level == "control" else VIEW_FEATURES
        lines.append(f"{user} allow {feats}")
    lines.append(NO_PRINTER)
    return "\n".join(lines) + "\n"
