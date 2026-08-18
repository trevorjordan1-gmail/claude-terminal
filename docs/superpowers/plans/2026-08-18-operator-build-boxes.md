# Operator Build Boxes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group-owned engagement workbenches (`<code>-buildNN`) in the portal, dormant unless `GROUP_BUILD_ENGINEERS` is configured — per `docs/superpowers/specs/2026-08-18-operator-build-boxes-design.md`.

**Architecture:** A new optional config value gates everything. Machines gain
three optional tags (`OwnerGroup`, `BuildFor`, `Creator`); authz becomes
"owner UPN matches OR OwnerGroup ∈ user's group claims"; a "New build box"
form on the machines page (NOT /admin — build engineers aren't admins)
provisions from the existing launch template. Build boxes carry a fixed local
session user `build`: sessions are per-local-user, and a group box has no
single UPN to derive one from — so connect/share must use the machine's
`LocalUser` tag rather than deriving from the Owner UPN (correct for 1:1
boxes too, which set both at provision).

**Tech Stack:** FastAPI portal (`aws/portal/`), boto3, pytest via `uv run`.
No terraform changes. Tests import the app with a stub env file
(`ASP_PORTAL_ENV`), so no AWS credentials or network are needed.

**Two non-obvious correctness points (from code reading, keep them):**
1. `connect()`/`share()` currently do `config.local_user(m["owner"])`; they
   must switch to `m["local_user"]` or every group member would try to open a
   session for a *different* owner and fail.
2. `admin_add()` rejects "that user already has a terminal" by scanning Owner
   tags; build boxes set Owner = creator UPN, so the guard must skip machines
   with `build_for` or a tech with a build box can never get their own cct.

Run tests from `aws/portal/`:
`uv run --with pytest -r requirements.txt python -m pytest tests/ -v`

---

### Task 1: Config gate + predicate (dormancy first)

**Files:**
- Modify: `aws/portal/config.py:42` (after GROUP_ADMINS)
- Modify: `aws/portal/app.py:77` (after `_is_desktop_user`)
- Create: `aws/portal/tests/conftest.py`, `aws/portal/tests/test_build_boxes.py`

- [ ] **Step 1: conftest that makes the app importable with a stub env**

```python
# aws/portal/tests/conftest.py
"""Import the portal with a stub env file — no AWS, no network, no secrets."""
import os
import sys
import pathlib

STUB = """\
ENTRA_TENANT_ID=00000000-0000-0000-0000-000000000000
ENTRA_CLIENT_ID=00000000-0000-0000-0000-000000000001
ENTRA_CLIENT_SECRET=stub
ASP_PORTAL_HOST=portal.terminals.example.com
ASP_GW_HOST=gw.terminals.example.com
BROKER_CLIENT_ID=stub
BROKER_CLIENT_SECRET=stub
GROUP_DESKTOP_USERS=11111111-1111-1111-1111-111111111111
GROUP_ADMINS=22222222-2222-2222-2222-222222222222
SESSION_SECRET=stub-secret-for-tests
CLIENT_CODE=acme
"""


def pytest_configure(config):
    envfile = pathlib.Path(__file__).parent / "stub-portal.env"
    envfile.write_text(STUB)
    os.environ["ASP_PORTAL_ENV"] = str(envfile)
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
```

- [ ] **Step 2: failing tests for the gate**

```python
# aws/portal/tests/test_build_boxes.py
import config
import app


BUILD_GROUP = "33333333-3333-3333-3333-333333333333"


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
```

- [ ] **Step 3: run to verify failure** — `uv run --with pytest -r requirements.txt python -m pytest tests/ -v` from `aws/portal/`. Expected: FAIL (`config has no attribute GROUP_BUILD_ENGINEERS` / `app has no attribute _is_build_engineer`).

- [ ] **Step 4: implement**

`config.py`, after the `GROUP_ADMINS` line:
```python
# optional: enables operator build boxes (engagement workbenches); customer
# tenants never set this, so the whole feature is dormant there
GROUP_BUILD_ENGINEERS = _c.get("GROUP_BUILD_ENGINEERS", "")
```

`app.py`, after `_is_desktop_user`:
```python
def _is_build_engineer(user: dict) -> bool:
    """Build boxes are an operator capability, dormant unless configured."""
    if not config.GROUP_BUILD_ENGINEERS:
        return False
    return (config.GROUP_BUILD_ENGINEERS in user.get("groups", [])
            or _is_admin(user))
```

- [ ] **Step 5: run tests (PASS), commit** — `git add aws/portal && git commit -m "feat(portal): GROUP_BUILD_ENGINEERS gate + predicate (dormant by default)"`

### Task 2: aws_ec2 — tags, naming, provisioning

**Files:**
- Modify: `aws/portal/aws_ec2.py` (`list_desktops` dict; new functions after `provision`)
- Test: `aws/portal/tests/test_build_boxes.py` (append)

- [ ] **Step 1: failing tests**

```python
def _mk(name, owner="", owner_group="", build_for=""):
    return {"id": "i-" + name, "name": name, "owner": owner,
            "owner_group": owner_group, "build_for": build_for,
            "local_user": "x", "state": "running", "reason_code": "",
            "private_ip": "", "type": "t3.large",
            "idle_policy": "", "idle_minutes": ""}


def test_next_build_name(monkeypatch):
    import aws_ec2
    boxes = [_mk("acme-build01", build_for="acme"), _mk("acme-cct01"),
             _mk("zeta-build03", build_for="zeta")]
    monkeypatch.setattr(aws_ec2, "list_desktops", lambda: boxes)
    assert aws_ec2.next_build_name("acme") == "acme-build02"
    assert aws_ec2.next_build_name("zeta") == "zeta-build04"
    assert aws_ec2.next_build_name("newco") == "newco-build01"


def test_valid_build_code():
    import aws_ec2
    assert aws_ec2.valid_build_code("acme")
    assert aws_ec2.valid_build_code("acme2")
    assert not aws_ec2.valid_build_code("Acme")     # lowercase only
    assert not aws_ec2.valid_build_code("a b")
    assert not aws_ec2.valid_build_code("")
```

- [ ] **Step 2: run (FAIL: no attribute next_build_name), implement**

In `list_desktops()`, extend the appended dict (after `"idle_minutes"`):
```python
                "owner_group": tags.get("OwnerGroup", ""),
                "build_for": tags.get("BuildFor", ""),
                "creator": tags.get("Creator", ""),
```

After `provision()`:
```python
# ---------- operator build boxes (engagement workbenches) ----------

def valid_build_code(code: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z0-9]{1,15}", code))


def next_build_name(build_for: str) -> str:
    highest = 0
    for m in list_desktops():
        match = re.fullmatch(rf"{re.escape(build_for)}-build(\d+)", m["name"])
        if match:
            highest = max(highest, int(match.group(1)))
    return f"{build_for}-build{highest + 1:02d}"


def provision_build_box(build_for: str, creator_upn: str, owner_group: str) -> str:
    """Launch an engagement workbench. Owner = the creating engineer (their 1:1
    view still works); OwnerGroup extends access to the whole team; the local
    session user is the fixed 'build' — group boxes have no single UPN to
    derive one from, and everyone shares the one session by design."""
    name = next_build_name(build_for)
    local = "build"
    env = "\n".join([
        f"ASP_BROKER_HOST={config.BROKER_SHORT_HOST}",
        f"ASP_LOCAL_USER={local}",
        f"ASP_OWNER_UPN={creator_upn}",
        f"ASP_ALL_USERS={local}",
        f"ASP_CUSTOMER={config.CUSTOMER}",
        f"ASP_REGION={config.REGION}",
        f"ASP_BUCKET={config.ARTIFACTS_BUCKET}",
    ])
    user_data = BOOTSTRAP.format(env=env, bucket=config.ARTIFACTS_BUCKET)
    tags = [
        {"Key": "Name", "Value": name},
        {"Key": "Role", "Value": "desktop"},       # watchdog/rollout treat it normally
        {"Key": "Customer", "Value": config.CUSTOMER},
        {"Key": "Owner", "Value": creator_upn},
        {"Key": "LocalUser", "Value": local},
        {"Key": "OwnerGroup", "Value": owner_group},
        {"Key": "BuildFor", "Value": build_for},
        {"Key": "Creator", "Value": creator_upn},
    ]
    subnet = config.SUBNET_IDS[len(list_desktops()) % len(config.SUBNET_IDS)]
    _ec2.run_instances(
        LaunchTemplate={"LaunchTemplateId": config.LAUNCH_TEMPLATE_ID},
        MinCount=1, MaxCount=1,
        SubnetId=subnet,
        UserData=user_data,
        TagSpecifications=[
            {"ResourceType": "instance", "Tags": tags},
            {"ResourceType": "volume", "Tags": tags},
        ],
    )
    return name
```

- [ ] **Step 3: run tests (PASS), commit** — `git commit -m "feat(portal): build-box tags, naming, provisioning in aws_ec2"`

### Task 3: authz — group access; local_user fixes; admin_add guard

**Files:**
- Modify: `aws/portal/app.py` (`_authz_machine`, `home` mine/others split, `connect`, `share`, `admin_add`)
- Test: `aws/portal/tests/test_build_boxes.py` (append)

- [ ] **Step 1: failing tests**

```python
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
```

- [ ] **Step 2: run (FAIL), implement in `app.py`**

After `_is_build_engineer`:
```python
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
```

`_authz_machine` line `if m["owner"].lower() != ... and not _is_admin(user):` becomes:
```python
    if not _may_use_machine(user, m) and not _is_admin(user):
        raise HTTPException(403, "not your machine")
```

`home()` mine/others split becomes:
```python
    mine = [m for m in machines if _may_use_machine(user, m)]
    if not _may_view(user) and not mine:
        return _render("denied.html", user=user)
    others = [m for m in machines if m not in mine]
```

`connect()` line `owner_local = config.local_user(m["owner"])` becomes:
```python
    owner_local = m["local_user"]
```

`share()` line `owner_local = config.local_user(m["owner"])` becomes:
```python
    owner_local = m["local_user"]
```

`admin_add()` duplicate guard becomes (build boxes don't count as "a terminal"):
```python
    if any(m["owner"].lower() == owner_upn and not m.get("build_for")
           for m in aws_ec2.list_desktops()):
        raise HTTPException(409, "that user already has a terminal")
```

- [ ] **Step 3: run tests (PASS), commit** — `git commit -m "feat(portal): group-owned machine authz; session owner from LocalUser tag"`

### Task 4: route + template

**Files:**
- Modify: `aws/portal/app.py` (new route after `admin_remove`; ACTION_BANNERS entry)
- Modify: `aws/portal/templates/machines.html`

- [ ] **Step 1: route**

Add to `ACTION_BANNERS` dict:
```python
    "buildbox": "Build box launching — first boot installs the desktop + workbench "
                "(~15–20 min). Every build engineer can see and use it.",
```

New route (after `admin_remove`, before `downloads_page`):
```python
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
```

`home()` render call gains `is_build_engineer=_is_build_engineer(user),`.

- [ ] **Step 2: template.** In `machines.html`: on each machine card, show a
badge when `m.build_for` is set (`build · {{ m.build_for }}`, plus
`created by {{ m.creator }}` in the details line); after the "mine" section add:

```html
{% if is_build_engineer %}
<div class="card">
  <h3>New build box</h3>
  <p class="muted">One workbench per engagement — every build engineer can use it.</p>
  <form method="post" action="/build-boxes/new">
    <input name="build_for" placeholder="client code (e.g. acme)"
           pattern="[a-z][a-z0-9]{1,15}" required>
    <button type="submit">Create build box</button>
  </form>
</div>
{% endif %}
```
(Match the file's existing card/form markup and classes — reuse whatever the
admin provisioning form uses rather than inventing new styles.)

- [ ] **Step 3: render smoke** (jinja render of machines.html with and without
`is_build_engineer`), run all tests, commit —
`git commit -m "feat(portal): New build box form + route (machines page, gated)"`

### Task 5: runbook + docs

**Files:**
- Create: `aws/runbooks/build-boxes.md` — content per the spec's runbook
  section: conventions for engineers (identity belongs to the box; `/login`
  only per-visitor switch + `/status` check; per-engagement credential set +
  backup destination decisions; lifecycle incl. pause→off conversion; purge
  checklist; shared-session note) and the deployment checklist for the
  operator's admin agent (create Entra group → add engineers → set
  `GROUP_BUILD_ENGINEERS` in the portal env → restart portal → provision from
  the form → verify group access positive AND negative). `acme` examples only.
- Modify: `aws/README.md` — one paragraph + link under a "Build boxes" heading.
- Modify: `CHANGELOG.md` — dated entry (config-gated, dormant on customer
  tenants, the LocalUser connect fix, the admin_add guard fix).

- [ ] Write all three, then commit — `git commit -m "docs(aws): build-boxes runbook + README + changelog"`

### Task 6: validation + ship

- [ ] Full test run from `aws/portal/`: `uv run --with pytest -r requirements.txt python -m pytest tests/ -v` — all PASS.
- [ ] `python -m py_compile` every touched `.py`; `bash -n` nothing (no shell changes).
- [ ] Dormancy re-check: grep the diff — every new behavior path must be
  reachable only through `_is_build_engineer` or `_may_use_machine`, both of
  which return False when `GROUP_BUILD_ENGINEERS` is unset.
- [ ] Push to main; watch pii-guard to green.
- [ ] Report: hand the runbook's deployment section to the operator's DCV
  Manager agent; field test = operator provisions the first real box.
