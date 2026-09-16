#!/usr/bin/env python3
"""provision-terminal-groups.py — the four portal groups, agent-runnable on a build box.

WHY THIS EXISTS (operator question, 2026-09-16): "if I have the build box look at the repo,
can it create all these groups correctly?" It could not. `build-tenant.md` §3 created them
with `az ad group create`, and the same runbook says twice that a build terminal has no `az`
("every directory step is a device-code Graph sitting"). `provision-sso.py` never touched
groups — it owns the `<code>-sso` registration. So the groups were documented but not
executable, the documented NAMES had drifted from every real tenant, and the fourth group
was missing from the doc entirely.

What one --apply run ensures, idempotently (re-run it; it adopts what already exists):
  * four ASSIGNED SECURITY groups — not M365, not mail-enabled, not dynamic, matching what
    real tenants run:
        Ai_Terminals_Admins      may join ANY session, full control (see below)
        Ai_Terminals_Users       gets a 1:1 terminal desktop
        Ai_Terminals_Viewers     portal login + session-join rights only
        Ai_Build_Engineers       shared per-engagement build terminals
  * --admin UPN added to Ai_Terminals_Admins (and --user UPN to Ai_Terminals_Users), because a
    tenant whose admin group is empty has nobody who can administer the portal.
  * groupMembershipClaims = SecurityGroup on the `<code>-terminals` registration when
    --app-id is given. THE STEP WHOSE ABSENCE IS SILENT: without it the id_token carries no
    `groups` claim, so _is_admin() is false for everyone, forever, with no error anywhere.
  * prints the object IDs and the exact `aws ssm put-parameter` line for /asp/portal/config,
    which is where the portal actually reads them from (it matches on OBJECT ID, never name —
    so renaming a group is safe and RECREATING one silently breaks access).

ADMIN IS A REAL CAPABILITY, NOT A LABEL. A member of Ai_Terminals_Admins sees every active
session on the tenant in "Sessions you can join" and joining SELF-GRANTS control — keyboard,
mouse, clipboard both ways, file upload/download — with no consent prompt and no notification
to the session owner, including on an unattended session. Put people in it deliberately.

Auth is the same device-code relay provision-sso.py uses: az-cli first-party client, .default
scope, tenant-pinned. One sign-in link, opened in a private window as a Global Administrator.
Needs Group.ReadWrite.All + (for --app-id) Application.ReadWrite.All from that sign-in.

    python3 provision-terminal-groups.py --tenant <guid>                      # dry run
    python3 provision-terminal-groups.py --tenant <guid> --admin you@x.com \
        --app-id <terminals-app-id> --apply
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

AZCLI = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # az-cli first-party public client

# displayName, mailNickname, description, and the /asp/portal/config key it fills.
GROUPS = [
    ("Ai_Terminals_Admins", "ai-terminals-admins",
     "adNET engineers - may join any session", "GROUP_ADMINS"),
    ("Ai_Terminals_Users", "ai-terminals-users",
     "Gets a 1:1 Claude Code terminal desktop", "GROUP_DESKTOP_USERS"),
    ("Ai_Terminals_Viewers", "ai-terminals-viewers",
     "Portal login + session-join rights only", "GROUP_VIEWERS"),
    ("Ai_Build_Engineers", "ai-build-engineers",
     "Members can create and access shared per-engagement build terminals", "GROUP_BUILD_ENGINEERS"),
]


def device_token(tenant):
    """One sign-in link, tenant-pinned. Same relay as provision-sso.py — `common` degrades to
    AADSTS50059 after repeated mints, and explicit scopes trip AADSTS65002."""
    base = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"
    d = json.load(urllib.request.urlopen(urllib.request.Request(
        base + "/devicecode", data=urllib.parse.urlencode(
            {"client_id": AZCLI,
             "scope": "https://graph.microsoft.com/.default offline_access openid profile"}).encode())))
    print(f"\n>>> Sign in as a Global Administrator of the client tenant:\n"
          f">>>   https://login.microsoftonline.com/common/oauth2/deviceauth?otc={d['user_code']}\n"
          f">>> Open it in a private window, sign in, close the window. Any device, this one included.\n"
          f">>>   (no link? {d['verification_uri']} → code {d['user_code']})\n"
          f">>> Single-use, expires in {d['expires_in'] // 60} min. Waiting…\n", flush=True)
    deadline = time.time() + d["expires_in"]
    while time.time() < deadline:
        time.sleep(d.get("interval", 5))
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(
                base + "/token", data=urllib.parse.urlencode(
                    {"grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                     "client_id": AZCLI, "device_code": d["device_code"]}).encode())))["access_token"]
        except urllib.error.HTTPError as e:
            err = json.loads(e.read()).get("error")
            if err not in ("authorization_pending", "slow_down"):
                sys.exit(f"sign-in failed: {err} (wrong tenant/role? fresh run = fresh code, never reuse one)")
    sys.exit("device code expired unused — re-run for a fresh one")


class Graph:
    def __init__(self, tok, apply):
        self.tok, self.apply = tok, apply

    def call(self, method, path, body=None, soft=False):
        if method != "GET" and not self.apply:
            print(f"    DRY-RUN {method} {path} {json.dumps(body) if body else ''}")
            return {"dryRun": True}
        req = urllib.request.Request(
            "https://graph.microsoft.com/v1.0/" + urllib.parse.quote(path, safe="/?=&$',()"),
            data=json.dumps(body).encode() if body is not None else None, method=method,
            headers={"Authorization": "Bearer " + self.tok, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if soft:
                return None
            sys.exit(f"FAILED {method} {path}: HTTP {e.code} {e.read()[:300].decode(errors='replace')}")

    def get(self, path, soft=False):
        return self.call("GET", path, soft=soft)


def ensure_group(g, display, nick, desc):
    """Adopt an existing group, or create it. Matched on mailNickname: it is the stable handle,
    and matching on displayName would create a duplicate the day someone renames one."""
    found = g.get(f"groups?$filter=mailNickname eq '{nick}'&$select=id,displayName,securityEnabled,groupTypes")
    vals = (found or {}).get("value", [])
    if vals:
        existing = vals[0]
        warn = ""
        if not existing.get("securityEnabled") or existing.get("groupTypes"):
            warn = "  !! NOT a plain security group — the portal needs securityEnabled, no groupTypes"
        print(f"  = {display:24} exists  {existing['id']}{warn}")
        return existing["id"]
    made = g.call("POST", "groups", {
        "displayName": display, "mailNickname": nick, "description": desc,
        "securityEnabled": True, "mailEnabled": False,   # assigned security group, no M365, no dynamic
    })
    gid = made.get("id", "(dry-run)")
    print(f"  + {display:24} created {gid}")
    return gid


def ensure_member(g, gid, upn, label):
    if not upn or gid == "(dry-run)":
        return
    u = g.get(f"users/{urllib.parse.quote(upn)}?$select=id,userPrincipalName", soft=True)
    if not u or "id" not in u:
        print(f"  ! {upn} not found in this tenant — add to {label} by hand")
        return
    members = g.get(f"groups/{gid}/members?$select=id", soft=True) or {}
    if any(m.get("id") == u["id"] for m in members.get("value", [])):
        print(f"  = {upn} already in {label}")
        return
    g.call("POST", f"groups/{gid}/members/$ref",
           {"@odata.id": f"https://graph.microsoft.com/v1.0/directoryObjects/{u['id']}"})
    print(f"  + {upn} added to {label}")


def ensure_group_claims(g, app_id):
    """Without this the id_token has no `groups` claim and NOBODY is an admin — silently."""
    apps = g.get(f"applications?$filter=appId eq '{app_id}'&$select=id,displayName,groupMembershipClaims")
    vals = (apps or {}).get("value", [])
    if not vals:
        print(f"  ! app {app_id} not found — set groupMembershipClaims=SecurityGroup by hand")
        return
    app = vals[0]
    if (app.get("groupMembershipClaims") or "").find("SecurityGroup") >= 0:
        print(f"  = {app.get('displayName')}: groupMembershipClaims already {app['groupMembershipClaims']}")
        return
    g.call("PATCH", f"applications/{app['id']}", {"groupMembershipClaims": "SecurityGroup"})
    print(f"  + {app.get('displayName')}: groupMembershipClaims -> SecurityGroup"
          f" (was {app.get('groupMembershipClaims') or 'None'})")


def main():
    p = argparse.ArgumentParser(description="Create the four AI Terminals portal groups via device-code Graph.")
    p.add_argument("--tenant", required=True, help="client tenant GUID (pinned; never 'common')")
    p.add_argument("--admin", help="UPN to add to Ai_Terminals_Admins — may join ANY session")
    p.add_argument("--user", help="UPN to add to Ai_Terminals_Users")
    p.add_argument("--app-id", help="the <code>-terminals app registration, to set groupMembershipClaims")
    p.add_argument("--apply", action="store_true", help="without this, every write is a dry run")
    a = p.parse_args()

    g = Graph(device_token(a.tenant), a.apply)
    print(f"\n== groups ({'APPLY' if a.apply else 'DRY RUN'}) ==")
    ids = {key: ensure_group(g, disp, nick, desc) for disp, nick, desc, key in GROUPS}

    if a.admin or a.user:
        print("\n== membership ==")
        if a.admin:
            ensure_member(g, ids["GROUP_ADMINS"], a.admin, "Ai_Terminals_Admins")
        if a.user:
            ensure_member(g, ids["GROUP_DESKTOP_USERS"], a.user, "Ai_Terminals_Users")
    if not a.admin:
        print("\n  ! no --admin given: an empty admin group means nobody can administer the portal")

    if a.app_id:
        print("\n== token configuration ==")
        ensure_group_claims(g, a.app_id)
    else:
        print("\n  ! no --app-id given: verify groupMembershipClaims=SecurityGroup on <code>-terminals"
              "\n    by hand — without it the groups claim is absent and no one is an admin")

    print("\n== put these in /asp/portal/config (the portal matches on OBJECT ID, never name) ==")
    print("aws ssm put-parameter --name /asp/portal/config --type String --overwrite --value '<merge into the existing JSON>'")
    for _, _, _, key in GROUPS:
        print(f'    "{key}": "{ids[key]}",')
    print("\nthen: rollout.sh portal   (portal-deploy rewrites /etc/asp-portal.env from SSM)")
    print("and:  anyone already signed in must sign out and back in — group membership is read"
          "\n      from the token at sign-in and cached in the session cookie for 8 hours.")


if __name__ == "__main__":
    main()
