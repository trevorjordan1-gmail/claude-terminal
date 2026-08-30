#!/usr/bin/env python3
"""provision-sso.py — the `<code>-sso` registration, agent-runnable end to end.

Python port of New-ClientSSO.ps1 for the terminal/build-box path: no PowerShell, no module
installs, and IDEMPOTENT — re-running extends the ONE per-client registration (adds a missing
redirect URI, grant, owner, or secret) instead of refusing. Designed so Claude Code runs it
FROM THE PACK during the platform build (PLATFORM-BUILD.md step 3) and the engineer's only
act is one sign-in.

What one --apply run ensures (same object model as New-ClientSSO.ps1):
  * `<code>-sso` app registration — single tenant, web redirect =
    https://<TEAM_DOMAIN>.cloudflareaccess.com/cdn-cgi/access/callback (the REAL team domain
    from the pack; a guessed one fails staff sign-in with AADSTS50011), IsFallbackPublicClient
    on (the aiops-mail device-code path), + service principal.
  * Delegated openid/profile/email/offline_access admin-consented for all users (Access sign-in).
  * The aiops MAIL RIDER: Mail.Read/ReadWrite/Send consented for the aiops PRINCIPAL ONLY —
    no other mailbox is reachable through this app, by construction. aiops added as owner of
    app + SP (object-scoped power, no directory roles).
  * A secret labeled `cloudflare-access` (12 months) IF none is live — printed once, and with
    --pack written straight into the pack (never transits another machine).

Auth = the field-proven device-code relay (see get-graph-token-devicecode.sh: az-cli
first-party client, `.default` scopes — explicit admin scopes trip AADSTS65002 — TENANT-PINNED
because `common` degrades to AADSTS50059 after repeated mints). The script prints ONE sign-in
link; a Global Administrator opens it FROM THEIR OWN DEVICE — admin credentials never touch
the box running this. Codes are single-use, ~15-minute expiry, one sign-in per run; the token
lives only in this process. A run that dies mid-way = fresh sign-in, never a cached token.

DRY-RUN BY DEFAULT (still requires the sign-in; all reads are real, writes are printed).
Add --apply to write.

Usage (on the terminal, from the workspace):
  python3 ~/claude-terminal/templates/entra-sso/provision-sso.py --pack ~/Projects/<code>.tools/.env [--apply]
  # or explicit, no pack:
  python3 provision-sso.py --tenant <tenant-id-or-domain> --code acme \
      --team <real-zt-team-prefix> --aiops aiops@acme-example.com [--apply]

--pack reads CLIENT_CODE, TEAM_DOMAIN, AIOPS_UPN, ENTRA_TENANT_ID (tenant fallback: the
aiops UPN's domain) and, on --apply, writes ENTRA_TENANT_ID / ENTRA_CLIENT_ID /
ENTRA_CLIENT_SECRET back into the same file (mode preserved). There is deliberately NO
per-credential expiry field (#17): the Entra secret takes the operator-standard 12-month
lifetime like every other mintable credential, so the pack's ONE `CREDENTIALS_MINTED` date
and STATE.md's single minted line already carry it.

External-IT tenants: do NOT use this — send ENTRA-SSO-REQUEST.template.md (+ New-ClientSSO.ps1).
"""
import argparse, json, os, re, stat, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

AZCLI = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # az-cli first-party public client (present in fresh tenants)
GRAPH_APPID = "00000003-0000-0000-c000-000000000000"
SIGNIN = ["openid", "profile", "email", "offline_access"]
MAIL = ["Mail.Read", "Mail.ReadWrite", "Mail.Send"]
SECRET_LABEL = "cloudflare-access"


def add_months(dt, months):
    """Calendar-month add. The operator standard is a 12-MONTH lifetime (#17), not 360 days —
    every mintable credential must land on ≈ the same engagement anniversary."""
    y, m = divmod(dt.month - 1 + months, 12)
    y, m = dt.year + y, m + 1
    leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)
    return dt.replace(year=y, month=m,
                      day=min(dt.day, [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]))


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--pack", help="path to the workspace .env — reads CLIENT_CODE/TEAM_DOMAIN/AIOPS_UPN, writes ENTRA_* back on --apply")
    p.add_argument("--tenant", help="tenant id or a verified domain (default: pack ENTRA_TENANT_ID, else the aiops UPN domain)")
    p.add_argument("--code", help="client code (default: pack CLIENT_CODE)")
    p.add_argument("--team", help="REAL Zero Trust team prefix (default: pack TEAM_DOMAIN). No safe default — see ENTRA-SSO.md")
    p.add_argument("--aiops", help="aiops UPN for the mail rider + owner (default: pack AIOPS_UPN; omit with --no-aiops)")
    p.add_argument("--no-aiops", action="store_true", help="skip the mail rider/owner (retrofit later with Grant-AiopsMail.ps1)")
    p.add_argument("--defer-redirect", action="store_true", help="EXPLICIT opt-in to create with no redirect URI (Zero Trust not bootstrapped yet); re-run later with --team")
    p.add_argument("--secret-months", type=int, default=12)
    p.add_argument("--no-secret", action="store_true")
    p.add_argument("--apply", action="store_true", help="write; default is dry-run")
    return p.parse_args()


def read_pack(path):
    vals = {}
    for line in open(path):
        m = re.match(r'^([A-Z][A-Z0-9_]*)=(.*)$', line.strip())
        if m:
            vals[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return vals


def write_pack(path, updates):
    lines = open(path).read().splitlines()
    seen = set()
    for i, line in enumerate(lines):
        m = re.match(r'^([A-Z][A-Z0-9_]*)=', line)
        if m and m.group(1) in updates:
            lines[i] = f'{m.group(1)}="{updates[m.group(1)]}"'
            seen.add(m.group(1))
    for k, v in updates.items():
        if k not in seen:
            lines.append(f'{k}="{v}"')
    mode = stat.S_IMODE(os.stat(path).st_mode)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, mode)


def device_token(tenant):
    base = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0"
    d = json.load(urllib.request.urlopen(urllib.request.Request(
        base + "/devicecode", data=urllib.parse.urlencode(
            {"client_id": AZCLI, "scope": f"https://graph.microsoft.com/.default offline_access openid profile"}).encode())))
    print(f"\n>>> ONE sign-in, from YOUR OWN device (never this box), as a Global Administrator of the client tenant:\n"
          f">>>   https://login.microsoftonline.com/common/oauth2/deviceauth?otc={d['user_code']}\n"
          f">>>   (or {d['verification_uri']} → code {d['user_code']})\n"
          f">>> Single-use, expires in {d['expires_in']//60} min. Waiting…\n", flush=True)
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
        req = urllib.request.Request("https://graph.microsoft.com/v1.0/" + urllib.parse.quote(path, safe="/?=&$',()"),
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


def main():
    a = parse_args()
    pack = read_pack(a.pack) if a.pack else {}
    code = a.code or pack.get("CLIENT_CODE") or sys.exit("--code (or pack CLIENT_CODE) required")
    team = a.team or pack.get("TEAM_DOMAIN")
    aiops_upn = None if a.no_aiops else (a.aiops or pack.get("AIOPS_UPN"))
    tenant = a.tenant or pack.get("ENTRA_TENANT_ID") or (aiops_upn.split("@")[1] if aiops_upn else None) \
        or sys.exit("--tenant required (no pack ENTRA_TENANT_ID / AIOPS_UPN to derive it from)")
    if not team and not a.defer_redirect:
        sys.exit("--team (pack TEAM_DOMAIN) required — the REAL Zero Trust team prefix; a guessed one breaks every "
                 "staff sign-in (AADSTS50011). Zero Trust not bootstrapped yet? pass --defer-redirect and re-run later.")
    name = f"{code}-sso"
    redirect = f"https://{team}.cloudflareaccess.com/cdn-cgi/access/callback" if team else None

    g = Graph(device_token(tenant), a.apply)
    print(f"== {name} · tenant {tenant} · {'APPLY' if a.apply else 'DRY-RUN (add --apply to write)'} ==")
    graph_sp = g.get(f"servicePrincipals?$filter=appId eq '{GRAPH_APPID}'&$select=id,appId,appRoles,oauth2PermissionScopes")["value"][0]
    scope_id = {s["value"]: s["id"] for s in graph_sp["oauth2PermissionScopes"]}
    rra = [{"resourceAppId": GRAPH_APPID,
            "resourceAccess": [{"id": scope_id[v], "type": "Scope"} for v in SIGNIN + MAIL]}]

    # 1 — registration: ONE per client, ever → extend, never duplicate
    hit = g.get(f"applications?$filter=displayName eq '{name}'&$select=id,appId,web,requiredResourceAccess,isFallbackPublicClient")["value"]
    if hit:
        app = hit[0]; app_id, client_id = app["id"], app["appId"]
        print(f"EXISTS (appId {client_id}) — extending only what is missing")
        patch = {}
        uris = app.get("web", {}).get("redirectUris", [])
        if redirect and redirect not in uris:
            patch["web"] = {"redirectUris": uris + [redirect]}
        have = {x["id"] for r in app.get("requiredResourceAccess", []) for x in r.get("resourceAccess", [])}
        if any(x["id"] not in have for x in rra[0]["resourceAccess"]):
            patch["requiredResourceAccess"] = rra
        if not app.get("isFallbackPublicClient"):
            patch["isFallbackPublicClient"] = True
        if patch:
            g.call("PATCH", f"applications/{app_id}", patch)
            print(f"  patched: {', '.join(patch)}")
    else:
        r = g.call("POST", "applications",
                   {"displayName": name, "signInAudience": "AzureADMyOrg", "isFallbackPublicClient": True,
                    "web": {"redirectUris": [redirect] if redirect else []}, "requiredResourceAccess": rra})
        app_id, client_id = r.get("id", "(dry-run)"), r.get("appId", "(dry-run)")
        print(f"CREATED → appId {client_id}")
    if not redirect:
        print("  ⚠ no redirect URI (deferred) — staff sign-in cannot work until a re-run adds the real team callback")
    dry_new = "(dry-run)" in str(client_id)   # created only notionally: downstream reads impossible

    # 2 — SP + grants
    if dry_new:
        print(f"    DRY-RUN POST servicePrincipals + grants: AllPrincipals [{' '.join(SIGNIN)}]"
              + (f" · Principal {aiops_upn} [+ {' '.join(MAIL)}] · owner {aiops_upn}" if aiops_upn else ""))
        sp_id = "(dry-run)"
    else:
        spv = g.get(f"servicePrincipals?$filter=appId eq '{client_id}'&$select=id").get("value", [])
        sp_id = spv[0]["id"] if spv else g.call("POST", "servicePrincipals", {"appId": client_id}).get("id", "(dry-run)")
        grants = g.get(f"oauth2PermissionGrants?$filter=clientId eq '{sp_id}' and resourceId eq '{graph_sp['id']}'").get("value", []) if "(dry-run)" not in str(sp_id) else []

        def ensure(consent, principal, scopes, label):
            cur = [x for x in grants if x["consentType"] == consent and (consent == "AllPrincipals" or x.get("principalId") == principal)]
            if cur:
                have = set(cur[0]["scope"].split())
                if not set(scopes) <= have:
                    g.call("PATCH", f"oauth2PermissionGrants/{cur[0]['id']}", {"scope": " ".join(sorted(have | set(scopes)))})
                    print(f"GRANT {label}: widened")
                else:
                    print(f"GRANT {label}: already in place")
            else:
                body = {"clientId": sp_id, "consentType": consent, "resourceId": graph_sp["id"], "scope": " ".join(scopes)}
                if principal:
                    body["principalId"] = principal
                g.call("POST", "oauth2PermissionGrants", body)
                print(f"GRANT {label}: {' '.join(scopes)}")

        ensure("AllPrincipals", None, SIGNIN, "sign-in (all users)")
        u = g.get(f"users/{aiops_upn}?$select=id", soft=True) if aiops_upn else None
        if aiops_upn and not u:
            # The mailbox often does not exist yet at platform-build time. The registration is
            # the valuable part and is already done — do NOT abort half-finished.
            print(f"  ⚠ aiops user {aiops_upn} not found in this tenant — mail rider + owner SKIPPED.")
            print(f"    Registration itself is COMPLETE. Create the mailbox (aiops-mail.sh), then re-run")
            print(f"    this script (idempotent) or Grant-AiopsMail.ps1 to add the rider.")
        elif u:
            ensure("Principal", u["id"], SIGNIN + MAIL, f"mail rider ({aiops_upn} ONLY — its own mailbox, nothing tenant-wide)")
            for kind, oid in (("applications", app_id), ("servicePrincipals", sp_id)):
                owners = {o["id"] for o in (g.get(f"{kind}/{oid}/owners?$select=id") or {}).get("value", [])}
                if u["id"] not in owners:
                    g.call("POST", f"{kind}/{oid}/owners/$ref",
                           {"@odata.id": f"https://graph.microsoft.com/v1.0/directoryObjects/{u['id']}"})
            print(f"OWNER: {aiops_upn} on app + SP (object-scoped only)")

    # 3 — secret
    secret, expires = None, None
    if not a.no_secret:
        creds = [] if dry_new else g.get(f"applications/{app_id}?$select=passwordCredentials").get("passwordCredentials", [])
        live = [c for c in creds if c.get("displayName") == SECRET_LABEL and c.get("endDateTime", "") > datetime.now(timezone.utc).isoformat()]
        if live:
            print(f"SECRET: existing '{SECRET_LABEL}' valid to {live[0]['endDateTime'][:10]} (value unretrievable — pack already has it, or mint fresh)")
        else:
            end = add_months(datetime.now(timezone.utc), a.secret_months).strftime("%Y-%m-%dT%H:%M:%SZ")
            r = g.call("POST", f"applications/{app_id}/addPassword",
                       {"passwordCredential": {"displayName": SECRET_LABEL, "endDateTime": end}})
            if a.apply:
                secret, expires = r["secretText"], end

    # 4 — hand-back
    org_tenant = tenant if not a.apply else g.get("organization?$select=id")["value"][0]["id"]
    out = {"ENTRA_TENANT_ID": org_tenant, "ENTRA_CLIENT_ID": client_id}
    if secret:
        out["ENTRA_CLIENT_SECRET"] = secret
    if a.pack and a.apply:
        write_pack(a.pack, out)
        print(f"\nPACK UPDATED: {a.pack} ← {' '.join(out)}  (secret went straight into the pack — it is shown nowhere else;"
              f"\n  vault it per HANDOFF-TO-HUDU)")
        if expires:
            print(f"  Secret expires {expires[:10]} — the standard 12-month lifetime, so NO *_EXPIRES pack field (#17);"
                  f"\n  just confirm the pack's CREDENTIALS_MINTED is set: STATE.md's one minted date covers this too.")
    else:
        print("\n======== VALUES (secret shows ONCE — pack .env + vault, never a ticket/note/email) ========")
        for k, v in out.items():
            print(f"  {k} = {v}")
    print("Next: ENTRA-SSO.md step 2 — wire the Entra IdP into Zero Trust, flip Access policies, prove a staff sign-in.")


if __name__ == "__main__":
    main()
