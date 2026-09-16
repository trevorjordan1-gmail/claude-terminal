#!/usr/bin/env python3
"""Self-test for provision-terminal-groups.py — stdlib only, no network, no tenant.

    python3 templates/entra-sso/test-provision-terminal-groups.py

Stubs Graph so everything that does not need Microsoft is exercised: the group shape the
portal actually requires (assigned security, no M365, no dynamic), idempotent adoption of
groups that already exist, matching on mailNickname rather than displayName, membership,
the groupMembershipClaims patch whose absence is silent, and dry-run purity.

It canNOT validate the Graph request shapes themselves — only a real --apply against a
tenant we control does that, the same caveat provision-sso.py carries.
"""
import importlib.util
import io
import contextlib
import os
import sys

SP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "provision-terminal-groups.py")
spec = importlib.util.spec_from_file_location("ptg", SP)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

PASS = []


def ok(msg):
    PASS.append(msg)
    print("PASS " + msg)


class FakeGraph:
    """Records every write; answers reads from `state`."""

    def __init__(self, state=None, apply=True):
        self.state = state or {"groups": [], "users": [], "apps": [], "members": {}}
        self.apply = apply
        self.writes = []

    def call(self, method, path, body=None, soft=False):
        if method != "GET" and not self.apply:
            self.writes.append(("DRYRUN", method, path, body))
            return {"dryRun": True}
        if method != "GET":
            self.writes.append((method, path, body))
        if method == "POST" and path == "groups":
            gid = "id-" + body["mailNickname"]
            self.state["groups"].append(dict(body, id=gid))
            return {"id": gid}
        if method == "POST" and path.endswith("/members/$ref"):
            gid = path.split("/")[1]
            self.state["members"].setdefault(gid, []).append(body["@odata.id"].rsplit("/", 1)[1])
            return {}
        if method == "PATCH" and path.startswith("applications/"):
            for a in self.state["apps"]:
                if a["id"] == path.split("/")[1]:
                    a.update(body)
            return {}
        return {}

    def get(self, path, soft=False):
        if path.startswith("groups?$filter=mailNickname eq '"):
            nick = path.split("'")[1]
            return {"value": [g for g in self.state["groups"] if g.get("mailNickname") == nick]}
        if path.startswith("users/"):
            upn = path.split("/")[1].split("?")[0].replace("%40", "@")
            for u in self.state["users"]:
                if u["userPrincipalName"] == upn:
                    return u
            return None
        if path.startswith("groups/") and "/members" in path:
            gid = path.split("/")[1]
            return {"value": [{"id": i} for i in self.state["members"].get(gid, [])]}
        if path.startswith("applications?$filter=appId eq '"):
            appid = path.split("'")[1]
            return {"value": [a for a in self.state["apps"] if a.get("appId") == appid]}
        return {}


def run_main(g, argv):
    """Drive main() with a stubbed token + Graph, capturing stdout."""
    real_token, real_graph, real_argv = m.device_token, m.Graph, sys.argv
    m.device_token = lambda tenant: "fake-token"
    m.Graph = lambda tok, apply: g
    sys.argv = ["provision-terminal-groups.py"] + argv
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            m.main()
    finally:
        m.device_token, m.Graph, sys.argv = real_token, real_graph, real_argv
    return buf.getvalue()


# ---------- the group shape the portal requires ----------
g = FakeGraph()
out = run_main(g, ["--tenant", "t-guid", "--apply"])
created = [w for w in g.writes if w[1] == "POST" or w[0] == "POST"]
bodies = [w[-1] for w in g.writes if w[0] == "POST" and w[1] == "groups"]
assert len(bodies) == 4, f"expected 4 groups, got {len(bodies)}"
for b in bodies:
    assert b["securityEnabled"] is True, b
    assert b["mailEnabled"] is False, b
    assert "groupTypes" not in b, f"groupTypes would make it M365/dynamic: {b}"
ok("creates four ASSIGNED SECURITY groups (securityEnabled, not mail-enabled, no groupTypes)")

names = [b["displayName"] for b in bodies]
assert names == ["Ai_Terminals_Admins", "Ai_Terminals_Users",
                 "Ai_Terminals_Viewers", "Ai_Build_Engineers"], names
ok("uses the names real tenants run — not the runbook's drifted ASP-* ones")

assert "GROUP_BUILD_ENGINEERS" in out and "Ai_Build_Engineers" in out
ok("includes the fourth group the runbook forgot (GROUP_BUILD_ENGINEERS)")

# ---------- idempotency ----------
g2 = FakeGraph(state=g.state)
out2 = run_main(g2, ["--tenant", "t-guid", "--apply"])
assert not [w for w in g2.writes if w[0] == "POST" and w[1] == "groups"], g2.writes
assert out2.count("exists") == 4, out2
ok("re-run adopts all four instead of creating duplicates")

# ---------- matched on mailNickname, not displayName ----------
renamed = {"groups": [{"id": "id-ai-terminals-admins", "mailNickname": "ai-terminals-admins",
                       "displayName": "Renamed By A Client", "securityEnabled": True}],
           "users": [], "apps": [], "members": {}}
g3 = FakeGraph(state=renamed)
out3 = run_main(g3, ["--tenant", "t-guid", "--apply"])
made = [w[-1]["mailNickname"] for w in g3.writes if w[0] == "POST" and w[1] == "groups"]
assert "ai-terminals-admins" not in made, "renamed group was duplicated"
ok("a renamed group is adopted, not duplicated (match is on mailNickname)")

# ---------- a wrong-type existing group is called out ----------
m365 = {"groups": [{"id": "id-x", "mailNickname": "ai-terminals-admins", "displayName": "Ai_Terminals_Admins",
                    "securityEnabled": False, "groupTypes": ["Unified"]}],
        "users": [], "apps": [], "members": {}}
out4 = run_main(FakeGraph(state=m365), ["--tenant", "t-guid", "--apply"])
assert "NOT a plain security group" in out4, out4
ok("an existing M365/dynamic group is flagged, not silently accepted")

# ---------- membership ----------
st = {"groups": [], "users": [{"id": "u1", "userPrincipalName": "tj@example.com"}], "apps": [], "members": {}}
g5 = FakeGraph(state=st)
out5 = run_main(g5, ["--tenant", "t-guid", "--admin", "tj@example.com", "--apply"])
assert "u1" in st["members"].get("id-ai-terminals-admins", []), st["members"]
ok("--admin lands in Ai_Terminals_Admins")

g6 = FakeGraph(state=st)
out6 = run_main(g6, ["--tenant", "t-guid", "--admin", "tj@example.com", "--apply"])
assert "already in" in out6
assert not [w for w in g6.writes if "members/$ref" in str(w)], g6.writes
ok("membership is idempotent too")

out7 = run_main(FakeGraph(state={"groups": [], "users": [], "apps": [], "members": {}}),
                ["--tenant", "t-guid", "--admin", "ghost@example.com", "--apply"])
assert "not found in this tenant" in out7
ok("an unknown UPN is reported, not silently skipped")

out8 = run_main(FakeGraph(), ["--tenant", "t-guid", "--apply"])
assert "empty admin group means nobody can administer" in out8
ok("no --admin warns that the portal would have no administrator")

# ---------- groupMembershipClaims: the silent one ----------
apps = {"groups": [], "users": [], "members": {},
        "apps": [{"id": "obj1", "appId": "app-guid", "displayName": "acme-terminals",
                  "groupMembershipClaims": None}]}
g9 = FakeGraph(state=apps)
out9 = run_main(g9, ["--tenant", "t-guid", "--app-id", "app-guid", "--apply"])
assert any(w[0] == "PATCH" and w[-1] == {"groupMembershipClaims": "SecurityGroup"} for w in g9.writes), g9.writes
ok("sets groupMembershipClaims=SecurityGroup when absent")

g10 = FakeGraph(state=apps)
out10 = run_main(g10, ["--tenant", "t-guid", "--app-id", "app-guid", "--apply"])
assert not [w for w in g10.writes if w[0] == "PATCH"], g10.writes
ok("already-correct groupMembershipClaims is left alone")

out11 = run_main(FakeGraph(), ["--tenant", "t-guid", "--apply"])
assert "no --app-id given" in out11 and "no one is an admin" in out11
ok("omitting --app-id warns about the failure mode that has no symptom")

# ---------- dry-run purity ----------
g12 = FakeGraph(apply=False)
out12 = run_main(g12, ["--tenant", "t-guid", "--admin", "tj@example.com", "--app-id", "app-guid"])
assert all(w[0] == "DRYRUN" for w in g12.writes), g12.writes
assert "DRY RUN" in out12
ok("without --apply every write is a dry run")

# ---------- the operator's next steps are printed ----------
assert "put-parameter" in out and "/asp/portal/config" in out and "rollout.sh portal" in out
assert "sign out and back in" in out
ok("prints the SSM line, the redeploy, and the sign-out-and-in requirement")

print(f"\nALL {len(PASS)} TESTS PASSED")
