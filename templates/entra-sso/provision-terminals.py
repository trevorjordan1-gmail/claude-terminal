#!/usr/bin/env python3
"""provision-terminals.py — the DCV portal's `<code>-terminals` registration + the four portal
groups in ONE device-code sitting (build-tenant.md §3, #39/#69). Stdlib only, no `az`.

  python3 provision-terminals.py --code acme --portal-host portal.terminals.example.com          # dry run
  python3 provision-terminals.py --code acme --portal-host ... --admin you@client --apply --out /secure/dir

Tenant: --tenant pins it; without it the sign-in runs against `organizations` and the tenant id
is READ from the token's /organization (a test-tenant convenience — a client build pins it).
--admin/--user default to the signed-in account. On --apply writes two 0600 files in --out:
portal-config.json (the /asp/portal/config value) and portal-secrets.json (ENTRA_CLIENT_SECRET
+ a fresh SESSION_SECRET) — the secret is never printed. Idempotent: re-runs adopt the app and
groups; a new secret is minted only with --new-secret.
"""
import argparse, importlib.util, json, os, secrets, sys
from datetime import datetime, timezone, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ptg", os.path.join(HERE, "provision-terminal-groups.py"))
ptg = importlib.util.module_from_spec(spec); spec.loader.exec_module(ptg)   # device_token, Graph, ensure_group, ensure_member, GROUPS

GRAPH_APPID = "00000003-0000-0000-c000-000000000000"
ROLE_GROUPMEMBER_READ_ALL = "98830695-27a2-44f7-8c18-0c3ebc9698f6"
ROLE_USER_READ_ALL = "df021288-bdef-4463-88db-98f22de89214"
SCOPE_USER_READ = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--code", required=True, help="client code → registration '<code>-terminals'")
    p.add_argument("--portal-host", required=True, help="the portal's public hostname (redirect https://<host>/auth/callback)")
    p.add_argument("--tenant", default="organizations", help="tenant GUID/domain (default: read from the sign-in)")
    p.add_argument("--admin", help="UPN for Ai_Terminals_Admins (default: the signed-in account)")
    p.add_argument("--user", help="UPN for Ai_Terminals_Users (default: --admin)")
    p.add_argument("--out", default=".", help="where the two 0600 JSON files land on --apply")
    p.add_argument("--new-secret", action="store_true", help="mint a client secret even if the app already has a live one")
    p.add_argument("--apply", action="store_true")
    a = p.parse_args()

    tok = ptg.device_token(a.tenant)
    g = ptg.Graph(tok, a.apply)
    org = g.get("organization?$select=id,displayName,verifiedDomains")["value"][0]
    tenant_id = org["id"]
    me = g.get("me?$select=userPrincipalName,id")
    admin = a.admin or me["userPrincipalName"]
    user = a.user or admin
    print(f"tenant {tenant_id} ({org.get('displayName')}) — signed in as {me['userPrincipalName']}")

    name = f"{a.code}-terminals"
    redirect = f"https://{a.portal_host}/auth/callback"
    body = {
        "displayName": name, "signInAudience": "AzureADMyOrg",
        "web": {"redirectUris": [redirect]},
        "groupMembershipClaims": "SecurityGroup",
        "requiredResourceAccess": [{"resourceAppId": GRAPH_APPID, "resourceAccess": [
            {"id": ROLE_GROUPMEMBER_READ_ALL, "type": "Role"}, {"id": ROLE_USER_READ_ALL, "type": "Role"},
            {"id": SCOPE_USER_READ, "type": "Scope"}]}],
    }
    found = g.get(f"applications?$filter=displayName eq '{name}'&$select=id,appId,web,passwordCredentials")["value"]
    if found:
        app = found[0]
        uris = set((app.get("web") or {}).get("redirectUris") or [])
        if redirect not in uris:
            uris.add(redirect)
            body["web"] = {"redirectUris": sorted(uris)}
        g.call("PATCH", f"applications/{app['id']}", body)
        print(f"  = app {name} exists  appId {app['appId']}")
    else:
        app = g.call("POST", "applications", body)
        print(f"  + app {name} created appId {app.get('appId', '(dry-run)')}")
    app_id, obj_id = app.get("appId", "(dry-run)"), app.get("id", "(dry-run)")

    sp = g.get(f"servicePrincipals?$filter=appId eq '{app_id}'&$select=id")["value"] if app_id != "(dry-run)" else []
    sp_id = sp[0]["id"] if sp else g.call("POST", "servicePrincipals", {"appId": app_id}).get("id", "(dry-run)")
    print(f"  {'=' if sp else '+'} service principal {sp_id}")

    # admin consent, without the portal: application roles = appRoleAssignments on the Graph SP;
    # the delegated scope = an oauth2PermissionGrant for all principals
    graph_sp = g.get(f"servicePrincipals?$filter=appId eq '{GRAPH_APPID}'&$select=id")["value"][0]["id"]
    if sp_id != "(dry-run)":
        have = {r["appRoleId"] for r in g.get(f"servicePrincipals/{sp_id}/appRoleAssignments")["value"]}
        for role, label in ((ROLE_GROUPMEMBER_READ_ALL, "GroupMember.Read.All"), (ROLE_USER_READ_ALL, "User.Read.All")):
            if role in have:
                print(f"  = consent {label}")
            else:
                g.call("POST", f"servicePrincipals/{sp_id}/appRoleAssignments",
                       {"principalId": sp_id, "resourceId": graph_sp, "appRoleId": role})
                print(f"  + consent {label}")
        grants = g.get(f"oauth2PermissionGrants?$filter=clientId eq '{sp_id}' and consentType eq 'AllPrincipals'")["value"]
        if grants:
            print("  = consent User.Read (delegated)")
        else:
            g.call("POST", "oauth2PermissionGrants", {"clientId": sp_id, "consentType": "AllPrincipals",
                                                      "resourceId": graph_sp, "scope": "User.Read"})
            print("  + consent User.Read (delegated)")

    secret = None
    live = [c for c in (app.get("passwordCredentials") or [])
            if c.get("endDateTime", "") > datetime.now(timezone.utc).isoformat()]
    if a.apply and (a.new_secret or not live):
        end = (datetime.now(timezone.utc) + timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ")
        cred = g.call("POST", f"applications/{obj_id}/addPassword",
                      {"passwordCredential": {"displayName": "asp-portal", "endDateTime": end}})
        secret = cred["secretText"]
        print(f"  + client secret minted, expires {end[:10]} (value written to --out only)")
    elif live:
        print(f"  = client secret: {len(live)} live (not re-minted; --new-secret to rotate — the pack/SSM must already hold it)")

    print("groups:")
    ids = {}
    for display, nick, desc, key in ptg.GROUPS:
        ids[key] = ptg.ensure_group(g, display, nick, desc)
    ptg.ensure_member(g, ids["GROUP_ADMINS"], admin, "admin")
    ptg.ensure_member(g, ids["GROUP_DESKTOP_USERS"], user, "user")

    config = {"ENTRA_TENANT_ID": tenant_id, "ENTRA_CLIENT_ID": app_id,
              "BROKER_URL": "https://localhost:8446", "BROKER_VERIFY_TLS": "false", **ids}
    print("\n/asp/portal/config:\n" + json.dumps(config))
    if a.apply:
        os.makedirs(a.out, exist_ok=True)
        for fn, data in (("portal-config.json", config),
                         ("portal-secrets.json", {"ENTRA_CLIENT_SECRET": secret or "<already held>",
                                                  "SESSION_SECRET": secrets.token_hex(32)})):
            path = os.path.join(a.out, fn)
            with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
                json.dump(data, f)
            print(f"wrote {path} (0600)")
        if not secret:
            print("NOTE: no new secret minted — portal-secrets.json carries a placeholder; keep the existing one in SSM")


if __name__ == "__main__":
    main()
