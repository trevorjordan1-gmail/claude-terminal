# Step 3 — Medical mode, aws/ side

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tenant built with `profile = "medical"` gives every terminal `ASP_PROFILE=medical` (so the kit's medical modules run), an instance role that can invoke Claude on Bedrock and nothing more, DCV sessions that deny file-download + printer, a Bedrock zero-data-retention lock that admins can apply/verify with one script, EBS encryption-by-default for ALL tenants, and a runbook that says exactly how to build, verify and offboard one.

**Architecture:** One terraform variable is the source of truth: `var.profile` → control-plane env `ASP_PROFILE` → `portal-deploy.sh` → `/etc/asp-portal.env` → `config.PROFILE` → a single `_terminal_env()` helper in `aws_ec2.py` (used by both provisioners) → each terminal's `/etc/asp-terminal.env`. Portal `broker.py` builds permissions from the profile; `desktop-setup.sh` writes the host default.perm in medical; terraform adds medical-only IAM (`count`) plus an ungated `aws_ebs_encryption_by_default`; a `bedrock-zdr.sh` script does what no terraform resource can. Spec: `docs/superpowers/specs/2026-08-18-medical-mode-design.md` §aws/ side.

**Tech Stack:** Terraform (hashicorp/aws v6), Python/FastAPI portal + pytest, bash, AWS CLI v2, DCV permissions files.

**Worktree:** `~/.config/superpowers/worktrees/claude-terminal/step3-medical-aws` (branch `step3-medical-aws`, from main `5c571e9`).

---

### Task 1: Terraform — `profile` variable, control-plane env, medical IAM, EBS default, SCP output

**Files:**
- Modify: `aws/terraform/variables.tf` (append)
- Modify: `aws/terraform/ec2.tf` (control-plane `env` map)
- Modify: `aws/terraform/iam.tf` (append)
- Create: `aws/terraform/ebs.tf`
- Modify: `aws/terraform/outputs.tf` (append)

- [ ] **Step 1: variables.tf** — append:

```hcl

variable "profile" {
  description = "Terminal profile for this tenant: standard, or medical (Ai Build Medical — Claude Code pinned to Bedrock, DCV file-download denied, ZDR guard). Reaches every terminal as ASP_PROFILE."
  default     = "standard"
  validation {
    condition     = contains(["standard", "medical"], var.profile)
    error_message = "profile must be \"standard\" or \"medical\"."
  }
}
```

- [ ] **Step 2: ec2.tf** — in the control-plane `user_data` `env = { … }` add `ASP_PROFILE = var.profile` after `ASP_CERT_EMAIL`.

- [ ] **Step 3: iam.tf** — append:

```hcl

# ---------- medical profile (count-gated; standard tenants get none of this) ----------
# Terminals call Claude on Bedrock with the instance role. Allow-list is
# "any Anthropic Claude model": which models are USABLE is decided by the
# account's Bedrock data-retention mode (none → Fable/Mythos unavailable),
# not by IAM — see aws/scripts/bedrock-zdr.sh.
data "aws_iam_policy_document" "desktop_bedrock" {
  statement {
    sid     = "InvokeClaudeOnBedrock"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
      "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.claude-*",
    ]
  }
  statement {
    sid       = "ResolveInferenceProfiles"
    actions   = ["bedrock:ListInferenceProfiles", "bedrock:GetInferenceProfile"]
    resources = ["*"]
  }
  statement {
    sid       = "SeeModelSubscriptions"
    actions   = ["aws-marketplace:ViewSubscriptions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "desktop_bedrock" {
  count  = var.profile == "medical" ? 1 : 0
  name   = "asp-desktop-bedrock"
  role   = aws_iam_role.desktop.id
  policy = data.aws_iam_policy_document.desktop_bedrock.json
}

# Guard: nothing running under these roles may weaken zero-data-retention or
# switch on model-invocation logging (which would persist prompts — PHI — to
# S3/CloudWatch). Account admins are outside these roles; the SCP output
# below is for the client's Organization, if they have one.
data "aws_iam_policy_document" "bedrock_zdr_guard" {
  statement {
    sid       = "LockBedrockZeroDataRetention"
    effect    = "Deny"
    actions   = ["bedrock:PutAccountDataRetention"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "bedrock:DataRetentionMode"
      values   = ["none"]
    }
  }
  statement {
    sid       = "NoBedrockInvocationLogging"
    effect    = "Deny"
    actions   = ["bedrock:PutModelInvocationLoggingConfiguration"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "desktop_zdr_guard" {
  count  = var.profile == "medical" ? 1 : 0
  name   = "asp-desktop-bedrock-zdr-guard"
  role   = aws_iam_role.desktop.id
  policy = data.aws_iam_policy_document.bedrock_zdr_guard.json
}

resource "aws_iam_role_policy" "controlplane_zdr_guard" {
  count  = var.profile == "medical" ? 1 : 0
  name   = "asp-controlplane-bedrock-zdr-guard"
  role   = aws_iam_role.controlplane.id
  policy = data.aws_iam_policy_document.bedrock_zdr_guard.json
}
```

- [ ] **Step 4: ebs.tf** (new):

```hcl
# EBS encryption by default — ALL tenants, not just medical. The launch
# template already encrypts roots (hibernation needs it); this makes the
# account/Region default catch anything created outside it (hand-restored
# snapshots, extra data disks). Account/Region-wide, so a tenant teardown must
# not switch it off: prevent_destroy — `terraform state rm
# aws_ebs_encryption_by_default.this` before `destroy` (runbook §12).
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
  lifecycle {
    prevent_destroy = true
  }
}
```

- [ ] **Step 5: outputs.tf** — append:

```hcl

output "bedrock_zdr_scp_json" {
  description = "Service control policy for the CLIENT's AWS Organization admin (if the tenant account sits in one): denies weakening Bedrock zero-data-retention and enabling model-invocation logging account-wide. Standalone accounts have no SCP; the role-level guard in iam.tf plus bedrock-zdr.sh --check is what applies there."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "LockBedrockZeroDataRetention"
        Effect    = "Deny"
        Action    = ["bedrock:PutAccountDataRetention"]
        Resource  = "*"
        Condition = { StringNotEquals = { "bedrock:DataRetentionMode" = "none" } }
      },
      {
        Sid      = "NoBedrockInvocationLogging"
        Effect   = "Deny"
        Action   = ["bedrock:PutModelInvocationLoggingConfiguration"]
        Resource = "*"
      },
    ]
  })
}
```

- [ ] **Step 6: fmt + validate (docker; no backend, no creds)**

```bash
docker run --rm -v "$PWD/aws/terraform:/tf" -w /tf hashicorp/terraform:latest fmt -check -recursive && echo fmt-ok
docker run --rm -v "$PWD/aws/terraform:/tf" -w /tf -e TF_IN_AUTOMATION=1 hashicorp/terraform:latest init -backend=false -input=false >/dev/null && docker run --rm -v "$PWD/aws/terraform:/tf" -w /tf hashicorp/terraform:latest validate && echo validate-ok
rm -rf aws/terraform/.terraform aws/terraform/.terraform.lock.hcl   # both gitignored, but keep the tree clean
```
Expected: `fmt-ok`, `Success! The configuration is valid.`, `validate-ok`. (`init` downloads the aws provider once — needs network.)

- [ ] **Step 7: Commit**

```bash
git add aws/terraform && git commit -q -m "feat(aws/terraform): profile variable, medical Bedrock IAM + ZDR guard, EBS encryption by default for all tenants, SCP output

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 2: Portal — profile plumbing, `_terminal_env()`, medical permissions, tests

**Files:**
- Modify: `aws/scripts/portal-deploy.sh` (env block)
- Modify: `aws/portal/config.py`
- Modify: `aws/portal/aws_ec2.py` (helper; both provisioners)
- Modify: `aws/portal/broker.py`
- Create: `aws/portal/tests/test_medical.py`

- [ ] **Step 1: Write the failing tests first** — `aws/portal/tests/test_medical.py`:

```python
"""Medical profile — the tenant's profile reaches every terminal and shapes
DCV permissions. Default is standard: nothing medical leaks into ordinary
tenants."""
import aws_ec2
import broker
import config


def test_profile_defaults_to_standard():
    assert config.PROFILE == "standard"


def test_terminal_env_carries_profile_default():
    env = aws_ec2._terminal_env("alice", "alice@example.com")
    assert "ASP_PROFILE=standard" in env.splitlines()
    assert "ASP_LOCAL_USER=alice" in env.splitlines()
    assert "ASP_OWNER_UPN=alice@example.com" in env.splitlines()


def test_terminal_env_carries_medical(monkeypatch):
    monkeypatch.setattr(config, "PROFILE", "medical")
    assert "ASP_PROFILE=medical" in aws_ec2._terminal_env("bob", "bob@example.com").splitlines()


def test_default_permissions_standard():
    perms = broker.default_permissions()
    assert "%owner% allow builtin" in perms
    assert "%any% disallow printer" in perms
    assert "deny" not in perms


def test_default_permissions_medical(monkeypatch):
    monkeypatch.setattr(config, "PROFILE", "medical")
    perms = broker.default_permissions()
    assert perms.splitlines()[-1] == broker.MEDICAL_DENY   # last rule wins; deny is final
    assert "file-download" in perms and "printer" in perms


def test_build_permissions_medical_guests(monkeypatch):
    monkeypatch.setattr(config, "PROFILE", "medical")
    perms = broker.build_permissions({"guest": "control"})
    lines = perms.splitlines()
    assert any(l.startswith("guest allow") and "file-download" in l for l in lines)  # granted…
    assert lines[-1] == broker.MEDICAL_DENY                                           # …then denied for %any%


def test_build_permissions_standard_has_no_deny():
    assert "deny" not in broker.build_permissions({"guest": "control"})
```

- [ ] **Step 2: Run — expect failures** (`config.PROFILE`, `_terminal_env`, `default_permissions`, `MEDICAL_DENY` don't exist yet):

```bash
( cd aws/portal && uv run -q --with pytest --with httpx --with-requirements requirements.txt python -m pytest -q tests/test_medical.py 2>&1 | tail -3 )
```

- [ ] **Step 3: config.py** — after `GROUP_BUILD_ENGINEERS`:

```python
# tenant profile — "medical" (Ai Build Medical) reaches every terminal as
# ASP_PROFILE and shapes DCV session permissions; default standard
PROFILE = _c.get("ASP_PROFILE", "standard")
```

- [ ] **Step 4: aws_ec2.py** — add above `provision_build_box`, and make BOTH provisioners call it:

```python
def _terminal_env(local_user: str, owner_upn: str) -> str:
    """The /etc/asp-terminal.env every terminal boots with — one place, so the
    tenant profile (medical or standard) reaches every kind of desktop."""
    return "\n".join([
        f"ASP_BROKER_HOST={config.BROKER_SHORT_HOST}",
        f"ASP_LOCAL_USER={local_user}",
        f"ASP_OWNER_UPN={owner_upn}",
        f"ASP_ALL_USERS={local_user}",  # collab guests are added at share time
        f"ASP_CUSTOMER={config.CUSTOMER}",
        f"ASP_REGION={config.REGION}",
        f"ASP_BUCKET={config.ARTIFACTS_BUCKET}",
        f"ASP_PROFILE={config.PROFILE}",
    ])
```
In `provision_build_box`: replace the `env = "\n".join([...])` block with `env = _terminal_env(local, creator_upn)`. In `provision`: replace with `env = _terminal_env(local_user, owner_upn)`.

- [ ] **Step 5: broker.py** — replace the `NO_PRINTER`/`DEFAULT_PERMISSIONS` block and `build_permissions`:

```python
# CCTs never print (TJ 2026-08-15): disallow DCV printer redirection so the
# client's local printers stop mounting as cups queues in the session. Rules
# are last-match-wins, so this strips printer back out of `allow builtin`.
NO_PRINTER = "%any% disallow printer"
# Medical tenants: nothing leaves the session as a file, and `deny` (unlike
# `disallow`) cannot be re-allowed by any later rule — owner and guests alike.
MEDICAL_DENY = "%any% deny file-download printer"


def _profile_rules() -> list[str]:
    rules = [NO_PRINTER]
    if config.PROFILE == "medical":
        rules.append(MEDICAL_DENY)
    return rules


def default_permissions() -> str:
    return "[permissions]\n%owner% allow builtin\n" + "\n".join(_profile_rules()) + "\n"
```
In `create_session` use `(permissions or default_permissions())`. In `build_permissions`, replace `lines.append(NO_PRINTER)` with `lines.extend(_profile_rules())`.

- [ ] **Step 6: portal-deploy.sh** — in the `/etc/asp-portal.env` block add after `ASP_BUCKET`:

```bash
  echo "ASP_PROFILE=${ASP_PROFILE:-standard}"
```

- [ ] **Step 7: Run all portal tests + compile**

```bash
python3 -m py_compile aws/portal/*.py 2>/dev/null && echo compile-ok
( cd aws/portal && uv run -q --with pytest --with httpx --with-requirements requirements.txt python -m pytest -q tests 2>&1 | tail -1 )
```
Expected: `17 passed`.

- [ ] **Step 8: Commit**

```bash
git add aws/portal aws/scripts/portal-deploy.sh && git commit -q -m "feat(portal): tenant profile plumbing — ASP_PROFILE on every terminal via _terminal_env(); medical DCV permissions deny file-download + printer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 3: `desktop-setup.sh` — host default.perm in medical

**Files:**
- Modify: `aws/scripts/desktop-setup.sh` (after section 4, before the auto-update block)

- [ ] **Step 1: Insert** before `# WU-style self-update`:

```bash
# ---- 5. medical profile: host-side belt-and-braces (the kit does the rest) ----
# The broker's per-session permissions already deny these on medical tenants;
# the server default catches any session created outside the portal. Stock
# default.perm is "[permissions] / %owner% allow builtin" — rewrite it whole.
if [ "${ASP_PROFILE:-standard}" = "medical" ] && [ -d /etc/dcv ]; then
  MEDPERM='[permissions]
%owner% allow builtin
%any% deny file-download printer'
  [ "$(cat /etc/dcv/default.perm 2>/dev/null)" = "$MEDPERM" ] || printf '%s\n' "$MEDPERM" > /etc/dcv/default.perm
fi

```

- [ ] **Step 2: Syntax + commit**

```bash
bash -n aws/scripts/desktop-setup.sh && git add aws/scripts/desktop-setup.sh && git commit -q -m "feat(aws): desktop-setup writes the medical DCV default.perm (deny file-download + printer)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 4: `aws/scripts/bedrock-zdr.sh`

**Files:**
- Create: `aws/scripts/bedrock-zdr.sh` (mode 0755)

- [ ] **Step 1: Write it**

```bash
#!/bin/bash
# Bedrock zero-data-retention lock + medical-tenant acceptance checks.
# Run from the operator workstation with the TENANT's AWS credentials (same
# profile terraform uses). No Terraform resource exists for account data
# retention (provider issue #49201), so this is the one imperative step.
#
#   bedrock-zdr.sh --apply [--region R]           set account data retention = none (idempotent, per Region)
#   bedrock-zdr.sh --check [--region R] [--fable-id ID]
#       retention mode is none; EBS encryption-by-default on; model-invocation
#       logging off; a Fable-tier request is refused (proves the mode bites)
set -uo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"; ACTION=""; FABLE_ID="us.anthropic.claude-fable-5"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply|--check) ACTION="$1" ;;
    --region) REGION="$2"; shift ;;
    --fable-id) FABLE_ID="$2"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done
[ -n "$ACTION" ] || usage 2
[ -n "$REGION" ] || { echo "region unknown — pass --region or set AWS_REGION" >&2; exit 2; }

ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=1; }
FAIL=0

case "$ACTION" in
  --apply)
    aws bedrock put-account-data-retention --region "$REGION" --mode none >/dev/null \
      || { echo "put-account-data-retention failed (need bedrock:PutAccountDataRetention; is Bedrock enabled in $REGION?)" >&2; exit 1; }
    echo "applied: Bedrock account data retention = none in $REGION"
    aws bedrock get-account-data-retention --region "$REGION" --output table
    ;;
  --check)
    echo "medical tenant checks — $REGION"
    MODE="$(aws bedrock get-account-data-retention --region "$REGION" --query mode --output text 2>/dev/null)"
    if [ "$MODE" = "none" ]; then ok "Bedrock account data retention: none"
    else bad "Bedrock account data retention: ${MODE:-unreadable} (want none — run: $0 --apply --region $REGION)"; fi

    EBS="$(aws ec2 get-ebs-encryption-by-default --region "$REGION" --query EbsEncryptionByDefault --output text 2>/dev/null)"
    if [ "$EBS" = "True" ]; then ok "EBS encryption by default: on"
    else bad "EBS encryption by default: ${EBS:-unreadable} (terraform apply sets it)"; fi

    LOGCFG="$(aws bedrock get-model-invocation-logging-configuration --region "$REGION" --query loggingConfig --output json 2>/dev/null)"
    if [ -z "$LOGCFG" ] || [ "$LOGCFG" = "null" ]; then ok "Bedrock model-invocation logging: off"
    else bad "Bedrock model-invocation logging is CONFIGURED — prompts would persist to S3/CloudWatch: $LOGCFG"; fi

    # Under mode=none, models that require provider data sharing (Fable/Mythos)
    # are unavailable — an invoke must be refused. A "not found" answer means
    # the ID is wrong for this Region, which proves nothing: say so.
    ERR="$(mktemp)"
    if aws bedrock-runtime invoke-model --region "$REGION" --model-id "$FABLE_ID" \
         --cli-binary-format raw-in-base64-out \
         --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
         /dev/null >/dev/null 2>"$ERR"; then
      bad "a $FABLE_ID request SUCCEEDED — the retention mode is not excluding Fable-tier models"
    elif grep -qiE "not found|invalid|does not exist|ValidationException" "$ERR" && ! grep -qiE "retention|unavailable|not available" "$ERR"; then
      printf '  SKIP  %s\n' "could not prove the Fable exclusion: $FABLE_ID is unknown here (pass --fable-id with the Region's ID). Error: $(head -c 160 "$ERR" | tr '\n' ' ')"
    else
      ok "Fable-tier request refused: $(head -c 120 "$ERR" | tr '\n' ' ')"
    fi
    rm -f "$ERR"
    [ "$FAIL" = 0 ] && echo "all checks passed" || { echo "checks FAILED"; exit 1; }
    ;;
esac
```

- [ ] **Step 2: Lint (this one IS held to shellcheck) + commit**

```bash
chmod 755 aws/scripts/bedrock-zdr.sh && bash -n aws/scripts/bedrock-zdr.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x aws/scripts/bedrock-zdr.sh && echo lint-ok
bash aws/scripts/bedrock-zdr.sh --help | head -3
git add aws/scripts/bedrock-zdr.sh && git commit -q -m "feat(aws): bedrock-zdr.sh — apply/verify Bedrock zero-data-retention + medical acceptance checks

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 5: Runbook + README + CHANGELOG

**Files:**
- Modify: `aws/runbooks/build-tenant.md` (new §11.6 "Medical profile"; offboarding note in §11.5; §12 teardown step)
- Modify: `aws/README.md` (one paragraph)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Runbook** — insert before `## 12. Teardown`:

```markdown
## 11.6 Medical profile (Ai Build Medical — regulated data)

Opt-in per tenant. What it changes: every terminal boots with
`ASP_PROFILE=medical` (the kit then pins Claude Code + claude-mem to Bedrock
in THIS account, sweeps API keys, brands the desktop PHI-approved — see the
repo README "Medical mode"), the desktop role may invoke Claude on Bedrock,
DCV sessions deny `file-download` + `printer` (owner and guests), and a
zero-data-retention lock keeps Fable/Mythos-tier models — the ones that
require provider data sharing — unavailable.

Build:
1. `profile = "medical"` in the tenant tfvars; `terraform apply`. (Standard
   tenants: nothing changes; `aws_ebs_encryption_by_default` is applied to
   ALL tenants from now on.)
2. **Enable Anthropic model access once** in the Bedrock console for the
   tenant Region (the instance role only gets `ViewSubscriptions`, on
   purpose).
3. `aws/scripts/bedrock-zdr.sh --apply --region <R>` (with the tenant
   profile), then `--check`: retention `none`, EBS default on, invocation
   logging off, a Fable request refused. If `--check` says it could not prove
   the Fable exclusion, pass `--fable-id` with the Region's actual ID.
4. Deploy the control plane / portal as usual — `ASP_PROFILE` flows
   automatically (`portal-deploy.sh` → `/etc/asp-portal.env`).
5. Optional: `terraform output -raw bedrock_zdr_scp_json` → hand to the
   client's AWS Organization admin. Standalone accounts have no SCP; be
   plain with the client that their own account admins could weaken the
   retention setting (the role-level guard stops the platform's roles, not
   humans) — `--check` is the audit.

Acceptance on a fresh medical terminal: `~/claude-terminal/verify.sh` zero
FAILs (medical section included), first login shows the PHI wallpaper +
shell banner and `claude` answers with no login prompt, a DCV client cannot
download a file from the session, and one claude-mem compression cycle shows
egress only to Bedrock endpoints.

Offboarding a medical user/terminal — the wipe list matters when a box is
kept or repurposed rather than terminated (termination = encrypted EBS
crypto-shred, plus the portal's Remove-user path): `~/.claude-mem/` (memory
DB + Chroma — PHI store), `~/.claude/` (project transcripts are PHI too),
`~/.cache/claude-cli-nodejs`, and the home directory in general. Never
snapshot a medical terminal on removal.
```
Also in §12 Teardown, append: "`aws_ebs_encryption_by_default.this` has `prevent_destroy` — it is account/Region-wide, so `terraform state rm aws_ebs_encryption_by_default.this` first (leaves the setting ON, which is what you want), then destroy."

- [ ] **Step 2: aws/README.md** — add a short paragraph pointing at §11.6 (where the README lists what the platform does).

- [ ] **Step 3: CHANGELOG** — new top section:

```markdown
## 2026-08-18 — medical mode (Ai Build Medical), aws/ side

- **`profile = "medical"` per tenant.** One terraform variable reaches every
  terminal as `ASP_PROFILE` (control plane env → `portal-deploy.sh` →
  portal `config.PROFILE` → new `_terminal_env()` used by both provisioners
  — the duplicated env block is gone). Medical-only IAM (`count`): the
  desktop role may `InvokeModel*` on Anthropic Claude models + resolve
  inference profiles; both roles carry a guard that denies weakening Bedrock
  data retention or enabling model-invocation logging. `bedrock-zdr.sh
  --apply/--check` sets and audits zero-data-retention (no Terraform resource
  exists). Output `bedrock_zdr_scp_json` for clients with an Organization.
- **DCV lockdown on medical tenants:** broker permissions append
  `%any% deny file-download printer` (owner and guests; `deny` is final);
  `desktop-setup.sh` writes the same into `/etc/dcv/default.perm` (what
  `verify.sh` asserts).
- **All tenants:** `aws_ebs_encryption_by_default` (with `prevent_destroy`;
  runbook §12 has the teardown step).
- Runbook §11.6: build, verify, offboard (wipe list incl. `~/.claude-mem/`
  and `~/.claude/`).
```

- [ ] **Step 4: Commit**

```bash
git add aws/runbooks/build-tenant.md aws/README.md CHANGELOG.md docs/superpowers/plans/2026-08-18-step3-medical-aws.md && git commit -q -m "docs(aws): medical profile runbook (build/verify/offboard), README pointer, changelog, step-3 plan

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 6: Land on main

- [ ] **Step 1: Final validation on the branch**

```bash
docker run --rm -v "$PWD/aws/terraform:/tf" -w /tf hashicorp/terraform:latest fmt -check -recursive && echo fmt-ok
python3 -m py_compile aws/portal/*.py 2>/dev/null && echo compile-ok
( cd aws/portal && uv run -q --with pytest --with httpx --with-requirements requirements.txt python -m pytest -q tests 2>&1 | tail -1 )
bash -n aws/scripts/*.sh && echo bash-n-ok
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x aws/scripts/bedrock-zdr.sh $(git ls-files '*.sh' | grep -v '^aws/') && echo lint-ok
git diff origin/main...HEAD | grep -E "^\+" | grep -nEi "@[a-z0-9.-]+\.(com|net|org)|i-0[0-9a-f]{8,}|[0-9]{12}|arn:aws:[a-z]+:[a-z0-9-]+:[0-9]|adnet|oldco-|cct0[0-9]|trevor|clientslug" | grep -viE "example\.com|acme|<account-id>|Co-Authored-By|noreply@anthropic|raw.githubusercontent.com/trevorjordan1-gmail" || echo sweep-clean
```

- [ ] **Step 2: Reconcile + merge + push from the primary checkout** (same as steps 1–2), then remove the worktree, delete the branch, update `CLAUDE.md` (gitignored) + memory.
