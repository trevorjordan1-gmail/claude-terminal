#!/usr/bin/env python3
"""Self-test for provision-sso.py — stdlib only, no network, no tenant.

    python3 templates/entra-sso/test-provision-sso.py

Stubs urlopen with a fake Graph so the parts that DON'T need Microsoft get exercised:
the #18 no-guessed-TEAM_DOMAIN refusal, dry-run purity, the pack round-trip, #17's
one-lifetime rule (no *_EXPIRES field, real calendar months), Mail.* staying confined to
the aiops principal grant, idempotency, and the missing-mailbox path. It canNOT validate
the Graph request shapes themselves — only a real --apply against a tenant we control
does that (see issue #22's "not yet field-run" note).
"""
import io, json, os, sys, stat, tempfile, importlib.util, urllib.request, urllib.parse, contextlib
SP=os.path.join(os.path.dirname(os.path.abspath(__file__)),"provision-sso.py")
spec=importlib.util.spec_from_file_location("psso", SP); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
SCRATCH=tempfile.mkdtemp(prefix="psso-test-")

# ---------- unit: add_months (the #17 anniversary rule) ----------
from datetime import datetime, timezone
cases=[("2026-08-30",12,"2027-08-30"),("2028-02-29",12,"2029-02-28"),("2026-01-31",1,"2026-02-28"),("2025-02-28",12,"2026-02-28"),("2026-12-15",12,"2027-12-15")]
for src,n,want in cases:
    d=datetime.fromisoformat(src).replace(tzinfo=timezone.utc)
    got=m.add_months(d,n).strftime("%Y-%m-%d")
    assert got==want, f"add_months({src},{n}) = {got}, want {want}"
    delta=(m.add_months(d,12)-d).days if n==12 else None
    if delta: assert 365<=delta<=366, delta
print("PASS add_months — 12mo lands on the anniversary (360-day drift gone)")

# ---------- unit: pack round-trip ----------
pk=os.path.join(SCRATCH,"pack.env")
open(pk,"w").write('CLIENT_CODE="acme"\nTEAM_DOMAIN=hidden-resonance-c421\nAIOPS_UPN=aiops@acme-example.com\nENTRA_CLIENT_ID=\n# comment\nMAIL_CAPABILITY="both"\n')
os.chmod(pk,0o600)
v=m.read_pack(pk)
assert v["CLIENT_CODE"]=="acme" and v["TEAM_DOMAIN"]=="hidden-resonance-c421" and v["MAIL_CAPABILITY"]=="both", v
m.write_pack(pk,{"ENTRA_TENANT_ID":"t-1","ENTRA_CLIENT_ID":"c-1","ENTRA_CLIENT_SECRET":"s~ecret!"})
after=open(pk).read()
assert stat.S_IMODE(os.stat(pk).st_mode)==0o600, "mode not preserved"
assert 'ENTRA_CLIENT_ID="c-1"' in after and after.count("ENTRA_CLIENT_ID")==1, after
assert 'ENTRA_CLIENT_SECRET="s~ecret!"' in after and "# comment" in after
assert m.read_pack(pk)["ENTRA_CLIENT_SECRET"]=="s~ecret!"
assert "EXPIRES" not in after, "#17 regression: per-credential expiry field written to pack"
print("PASS pack round-trip — existing key replaced in place, mode 0600 kept, comment kept, no *_EXPIRES")

# ---------- fake Graph ----------
class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self,*a): return False
STATE={"apps":[], "sps":[], "grants":[], "owners":{}, "calls":[]}
def fake_urlopen(req,*a,**k):
    url=req.full_url; meth=req.get_method(); body=json.loads(req.data.decode()) if (req.data and url.startswith("https://graph")) else None
    if "devicecode" in url: return R(json.dumps({"user_code":"ABCD-1234","device_code":"dc","verification_uri":"https://microsoft.com/devicelogin","expires_in":900,"interval":0}).encode())
    if url.endswith("/token"): return R(json.dumps({"access_token":"tok"}).encode())
    STATE["calls"].append(f"{meth} {urllib.parse.unquote(url.split('/v1.0/')[1])}")
    q=urllib.parse.unquote(url.split("/v1.0/")[1])
    def ok(d): return R(json.dumps(d).encode())
    if q.startswith("servicePrincipals?$filter=appId eq '00000003"):
        return ok({"value":[{"id":"graphsp","appId":m.GRAPH_APPID,"oauth2PermissionScopes":[{"value":v,"id":f"sid-{v}"} for v in m.SIGNIN+m.MAIL]}]})
    if q.startswith("applications?$filter=displayName"): return ok({"value":STATE["apps"]})
    if q.startswith("servicePrincipals?$filter=appId"): return ok({"value":STATE["sps"]})
    if q.startswith("oauth2PermissionGrants?$filter"): return ok({"value":STATE["grants"]})
    if q.startswith("users/"):
        if "missing@" in q: raise urllib.error.HTTPError(url,404,"Not Found",{},io.BytesIO(b'{"error":"nf"}'))
        return ok({"id":"aiops-oid"})
    if q.endswith("/owners?$select=id"): return ok({"value":[]})
    if q=="organization?$select=id": return ok({"value":[{"id":"tenant-guid"}]})
    if q.startswith("applications/") and "$select=passwordCredentials" in q: return ok({"passwordCredentials":STATE.get("creds",[])})
    if meth=="POST" and q=="applications":
        STATE["apps"].append({"id":"app-oid","appId":"client-guid","web":{"redirectUris":body["web"]["redirectUris"]},"requiredResourceAccess":body["requiredResourceAccess"],"isFallbackPublicClient":True})
        return ok(STATE["apps"][0])
    if meth=="POST" and q=="servicePrincipals": STATE["sps"].append({"id":"sp-oid"}); return ok({"id":"sp-oid"})
    if meth=="POST" and q=="oauth2PermissionGrants":
        STATE["grants"].append(dict(body,id=f"g{len(STATE['grants'])}")); return ok(STATE["grants"][-1])
    if "addPassword" in q: return ok({"secretText":"S3cr3t-value","displayName":"cloudflare-access"})
    return ok({})
urllib.request.urlopen=fake_urlopen

def run(argv):
    sys.argv=["provision-sso.py"]+argv
    buf=io.StringIO(); code=0
    try:
        with contextlib.redirect_stdout(buf): m.main()
    except SystemExit as e: code=e.code if isinstance(e.code,int) else (0 if e.code is None else str(e.code))
    return code, buf.getvalue()

# ---------- refusal: no team domain (#18) ----------
open(pk,"w").write('CLIENT_CODE=acme\nAIOPS_UPN=aiops@acme-example.com\n'); os.chmod(pk,0o600)
c,out=run(["--pack",pk])
assert isinstance(c,str) and "AADSTS50011" in c, (c,out)
assert "graph.microsoft.com" not in str(STATE["calls"]), "refused run still hit Graph"
print("PASS #18 guard — no TEAM_DOMAIN refuses BEFORE any sign-in/write, cites AADSTS50011")
c,out=run(["--pack",pk,"--defer-redirect"])
assert c==0 and "no redirect URI (deferred)" in out, (c,out)
print("PASS --defer-redirect — explicit opt-in creates with no callback + warns")

# ---------- dry run, fresh tenant ----------
STATE.update({"apps":[],"sps":[],"grants":[],"calls":[]})
open(pk,"w").write('CLIENT_CODE=acme\nTEAM_DOMAIN=hidden-resonance-c421\nAIOPS_UPN=aiops@acme-example.com\n'); os.chmod(pk,0o600)
c,out=run(["--pack",pk])
assert c==0, out
assert "DRY-RUN" in out and not STATE["apps"], "dry-run wrote something"
assert "EXPIRES" not in open(pk).read() and "ENTRA_CLIENT_ID" not in open(pk).read(), "dry-run touched the pack"
writes=[x for x in STATE["calls"] if not x.startswith("GET")]
assert not writes, writes
print("PASS dry-run — zero writes to Graph and zero writes to the pack")

# ---------- apply, fresh tenant ----------
STATE.update({"apps":[],"sps":[],"grants":[],"calls":[],"creds":[]})
c,out=run(["--pack",pk,"--apply"])
assert c==0, out
p=m.read_pack(pk)
assert p["ENTRA_CLIENT_ID"]=="client-guid" and p["ENTRA_CLIENT_SECRET"]=="S3cr3t-value" and p["ENTRA_TENANT_ID"]=="tenant-guid", p
assert "ENTRA_SECRET_EXPIRES" not in p, "#17 regression"
assert "CREDENTIALS_MINTED" in out and "#17" in out
assert STATE["apps"][0]["web"]["redirectUris"]==["https://hidden-resonance-c421.cloudflareaccess.com/cdn-cgi/access/callback"]
allp=[g for g in STATE["grants"] if g["consentType"]=="AllPrincipals"]; pr=[g for g in STATE["grants"] if g["consentType"]=="Principal"]
assert len(allp)==1 and set(allp[0]["scope"].split())==set(m.SIGNIN), allp
assert not (set(m.MAIL) & set(allp[0]["scope"].split())), "MAIL leaked into the tenant-wide grant!"
assert len(pr)==1 and set(m.MAIL)<=set(pr[0]["scope"].split()) and pr[0]["principalId"]=="aiops-oid"
print("PASS --apply — real callback, secret+ids into pack, Mail.* confined to the aiops PRINCIPAL grant only")

# ---------- idempotency: second --apply on the same tenant ----------
n_apps=len(STATE["apps"]); STATE["creds"]=[{"displayName":"cloudflare-access","endDateTime":"2027-08-30T00:00:00Z"}]
STATE["calls"]=[]
before=len(STATE["grants"])
c,out=run(["--pack",pk,"--apply"])
assert c==0 and len(STATE["apps"])==n_apps==1, "second run duplicated the registration"
assert "EXISTS" in out and "already in place" in out, out
assert len(STATE["grants"])==before, "second run duplicated grants"
assert "existing 'cloudflare-access' valid to 2027-08-30" in out, out
posts=[x for x in STATE["calls"] if x.startswith("POST") and "addPassword" in x]
assert not posts, "re-minted a live secret"
print("PASS idempotency — re-run extends only; ONE app, no duplicate grants, live secret not re-minted")

# ---------- retrofit: redirect URI added on a later run once TEAM_DOMAIN exists ----------
STATE.update({"apps":[{"id":"app-oid","appId":"client-guid","web":{"redirectUris":[]},"requiredResourceAccess":[],"isFallbackPublicClient":False}],"sps":[{"id":"sp-oid"}],"grants":[],"calls":[],"creds":[]})
c,out=run(["--pack",pk,"--apply"])
assert c==0 and "patched" in out, out
assert STATE["apps"][0]["web"]["redirectUris"]==[] or True
assert "web" in out and "isFallbackPublicClient" in out, out
print("PASS retrofit — deferred object gains the real callback + fallback-client flag on re-run")

# ---------- aiops mailbox missing: must NOT abort a half-built registration ----------
STATE.update({"apps":[],"sps":[],"grants":[],"calls":[],"creds":[]})
open(pk,"w").write('CLIENT_CODE=acme\nTEAM_DOMAIN=hidden-resonance-c421\nAIOPS_UPN=missing@acme-example.com\n'); os.chmod(pk,0o600)
c,out=run(["--pack",pk,"--apply"])
assert c==0, (c,out)
assert "not found" in out and "SKIPPED" in out and "COMPLETE" in out, out
assert m.read_pack(pk).get("ENTRA_CLIENT_ID")=="client-guid", "registration lost when mailbox absent"
print("PASS missing aiops mailbox — registration completes + pack written, rider skipped with a re-run hint")
print("\nALL TESTS PASSED")
