# Medical mode (Ai Build Medical, regulated data) — design

**Status:** approved 2026-08-18 (brainstormed with the operator 2026-08-17→18).
**Scope:** kit (`bootstrap.sh`, `lib/common.sh`, three core modules, `verify.sh`,
one asset) + `aws/` (terraform, portal, scripts, runbook). Ships in three
steps, each its own plan; main stays production the whole way.

## Problem

Some engagements are HIPAA-adjacent. The client gets no Claude seats (a seat
also grants claude.ai/desktop/mobile from any device — ungovernable). The
terminal is the ONLY place Claude exists, and every AI call goes through
**Amazon Bedrock in the client's own AWS account** with zero data retention.
PHI may appear on the box; the box is the compliance boundary. This is an
opt-in profile — the default fleet is unchanged.

## Decisions (with the reasoning that matters)

- **State-driven, not flag-driven.** The DCV updater re-runs plain
  `get.sh | bash` daily with no flags, so the medical signal must live on the
  box. `is_medical_terminal()` = `ASP_PROFILE=medical` in
  `/etc/asp-terminal.env` **or** `/etc/claude-terminal/medical` marker.
  `bootstrap.sh --medical` only writes the marker (so an existing DCV box can
  be flipped without reprovisioning). One source of truth per platform.
- **Core modules gated on state**, not `modules/extra/`. Extras run after
  core, but the Bedrock env must exist before `10-claude-code` /
  `20-claude-mem` / `25-superpowers`; the existing skip-on-platform pattern
  (`38-x11-session`, `41-splashtop-cursorfix`) fits exactly.
- **DCV-only for now.** A marker on a non-DCV box → clean
  `skip "medical mode is DCV-only for now"`. Region comes from `ASP_REGION`.
- **No OAuth login on medical boxes.** Claude Code on Bedrock takes creds
  from the instance role (docs: "no browser login is needed"). `claude_ready()`
  becomes "installed AND (logged in OR Bedrock configured)", so the plugin
  modules run during bootstrap itself and the "run claude to log in" reminder
  disappears. `27-postlogin-finish` stays; its hook never fires (harmless).
- **Model IDs live in one place** (`08-medical-bedrock.sh` env); claude-mem
  uses the CLI's `sonnet`/`haiku` aliases which resolve through
  `ANTHROPIC_DEFAULT_*_MODEL`. Sonnet is the default model (spec), Opus
  reachable via `/model`, Haiku for the small/fast slot.
- **Fable/Mythos exclusion is enforced by ZDR mode `none`**, not by IAM
  allow-lists (AWS: those models require provider data sharing; HIPAA-eligible
  list excludes them). The IAM allow covers `anthropic.claude-*` broadly.
- **DCV lockdown = `file-download` + `printer` denied** (owner and guests;
  `deny` is final). Upload and clipboard stay on for usability.
- **Standalone tenant accounts, no Org**: ZDR lock = script (`put`+verify) +
  IAM deny on the terraform-managed roles + an SCP JSON output for the
  client's own Org admin. Runbook says plainly that account admins can still
  flip it without an SCP.
- **EBS encryption by default for ALL tenants** (not medical-gated), with
  `prevent_destroy` — an account/Region-wide setting must not silently switch
  off on tenant teardown.
- **Egress trimming**: `DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`
  (Claude Code metrics/Sentry — no prompt content, but less egress);
  `CLAUDE_MEM_TELEMETRY=0` + `telemetry.json {"enabled":false}` (claude-mem's
  PostHog is on by default); claude-mem cloud-sync keys emptied. Chroma stays
  on (embeddings are local ONNX; one model tarball fetch on first use).

## Facts established during design (verified 2026-08-18)

- Claude Code Bedrock env: `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`,
  `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`; model IDs
  are cross-region inference profiles (`us.anthropic.claude-…`); transport is
  `InvokeModelWithResponseStream`. IAM: `bedrock:InvokeModel`,
  `bedrock:InvokeModelWithResponseStream`, `bedrock:ListInferenceProfiles`,
  `bedrock:GetInferenceProfile` (+ marketplace view). Managed settings:
  `/etc/claude-code/managed-settings.json` (`env`, `hooks`, `permissions`);
  precedence over user settings; server-managed settings do NOT reach
  Bedrock sessions (irrelevant — we use the file).
- claude-mem is at **v13.15.2** (module installs latest). Config:
  `~/.claude-mem/settings.json` (process env > file > defaults) + `.env`
  holding exactly five credential keys (`ANTHROPIC_API_KEY`,
  `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `GEMINI_API_KEY`,
  `OPENROUTER_API_KEY`). Worker spawns the `claude` CLI via the Agent SDK;
  since v12.4.9 its env sanitizer preserves `CLAUDE_CODE_USE_BEDROCK`,
  `AWS_REGION`, `AWS_*` — system-wide env routes compression to Bedrock.
  Default `CLAUDE_MEM_MODEL=claude-haiku-4-5-20251001` is rejected by
  Bedrock (issue #2620) — must be an alias or inference-profile ID.
- Bedrock account data retention exists: `aws bedrock
  put-account-data-retention --mode none` / `get-account-data-retention`,
  per-Region; IAM `bedrock:PutAccountDataRetention` with condition
  `bedrock:DataRetentionMode`. No Terraform resource (provider issue #49201).
  `aws_ebs_encryption_by_default` and
  `aws_bedrock_model_invocation_logging_configuration` exist.
- DCV permissions: features `file-download`, `file-upload`, `clipboard-copy`,
  `clipboard-paste`, `printer`, …; rules `allow`/`disallow`/`deny` (final);
  default file `/etc/dcv/default.perm`; per-session `PermissionsFile` via the
  broker (what the portal already sends).

## Kit side

**`lib/common.sh`**: `is_medical_terminal()`; `claude_bedrock_ready()`
(managed-settings.json declares `CLAUDE_CODE_USE_BEDROCK=1`);
`claude_ready()` = `have claude && (creds || bedrock_ready)`.

**`bootstrap.sh`**: `--medical` → `sudo install -d /etc/claude-terminal &&
sudo touch /etc/claude-terminal/medical`, log it, continue. Nothing else.

**`modules/core/08-medical-bedrock.sh`** (skip unless medical+DCV):
- Inputs from `/etc/asp-terminal.env`: `ASP_REGION` (required → `fail` if
  missing), optional `ASP_BEDROCK_SONNET|OPUS|HAIKU` overrides. Kit defaults:
  `us.anthropic.claude-sonnet-5`, `us.anthropic.claude-opus-5`,
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`. If `aws bedrock
  list-inference-profiles` works on the box, validate the IDs and `warn` on a
  miss; never fail on a listing error.
- Env written three ways (DCV shells are non-login; claude-mem inherits
  process env): `/etc/claude-code/managed-settings.json` (kit-owned on
  medical boxes; `env` block; comment in the module marks the reserved
  `hooks` slot for a PHI-tripwire pack), `append_block` in `/etc/bash.bashrc`,
  `/etc/profile.d/claude-terminal-medical.sh`.
- API-key sweep: drop `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` lines from
  `/etc/environment`, `/etc/profile.d/*`, `~/.bashrc`, `~/.profile`,
  `~/.bash_profile`; drop `env.ANTHROPIC_*`/`apiKeyHelper` from
  `~/.claude/settings.json` (jq). `warn` per hit.

**`modules/core/21-medical-claude-mem.sh`** (after 20): merge into
`~/.claude-mem/settings.json` (create if absent): `CLAUDE_MEM_MODEL=sonnet`,
`CLAUDE_MEM_PROVIDER=claude`, `CLAUDE_MEM_TELEMETRY=0`,
`CLAUDE_MEM_CLOUD_SYNC_TOKEN|USER_ID|HUB_URL=""`; write `telemetry.json`
`{"enabled":false}`; strip the five credential keys from `.env` (warn).

**`modules/core/43-medical-cues.sh`** (after 42): `assets/medical-wallpaper.svg`
→ `/usr/share/backgrounds/claude-terminal-medical.svg`, applied via
`gui_conf` (`picture-uri` + `-dark`); `.bashrc` block printing one line at
the top of interactive shells; `/etc/motd` line.

**`verify.sh`** (medical section, only when medical): managed-settings has
`CLAUDE_CODE_USE_BEDROCK=1` + region + three model IDs; bash.bashrc block;
zero forbidden keys in the sweep set + claude-mem `.env`; claude-mem
settings pinned; wallpaper installed + selected; `/etc/dcv/default.perm`
carries `deny file-download` (host-written belt-and-braces; enforced perms
come from the broker); the "claude logged in" line reads "claude → Bedrock
(no login needed)". Zero FAILs on a fresh medical provision is the bar.

## aws/ side

**Signal plumbing:** `variable "profile"` (`standard`|`medical`, validated)
→ control-plane `user_data` env `ASP_PROFILE` → `portal-deploy.sh` copies it
into `/etc/asp-portal.env` → `config.PROFILE` → a single `_terminal_env()`
helper in `aws_ec2.py` (used by both `provision_desktop` and
`provision_build_box`, replacing today's duplicated block) puts
`ASP_PROFILE=<profile>` into every terminal's `/etc/asp-terminal.env`.
Tenants without the var stay `standard`.

**Portal `broker.py`:** `PROFILE == "medical"` → `DEFAULT_PERMISSIONS` and
`build_permissions()` append `%any% deny file-download printer`.
`StorageRoot` stays `%home%`.

**`desktop-setup.sh`:** medical → also write `/etc/dcv/default.perm` with the
same deny line. Nothing else.

**Terraform:** `aws_ebs_encryption_by_default` (all tenants, `prevent_destroy`,
runbook §12 gets the `state rm` step). Medical-only (`count`):
`aws_iam_role_policy "desktop_bedrock"` — `InvokeModel*` on
`foundation-model/anthropic.claude-*` (all Regions) + tenant
`inference-profile/*.anthropic.claude-*`; `ListInferenceProfiles`/
`GetInferenceProfile` on `*`; `aws-marketplace:ViewSubscriptions`. Guard
policy on both roles: deny `PutAccountDataRetention` unless
`bedrock:DataRetentionMode = none`; deny
`PutModelInvocationLoggingConfiguration`. Output `bedrock_zdr_scp_json`.

**`aws/scripts/bedrock-zdr.sh`:** `--apply` (put mode none, tenant Region,
idempotent) / `--check` (retention mode, EBS default, invocation logging
empty, Fable invoke refused).

**Runbook:** "Medical profile" section (set the var, enable Anthropic model
access once in the console, `bedrock-zdr.sh --apply` then `--check`, hand
the SCP to the client) + offboarding wipe list in §11/§12 (`~/.claude-mem/`,
`~/.claude/` — transcripts are PHI too —, `~/.cache/claude-cli-nodejs`, the
home dir; no snapshots on medical removals; terminated instances are
crypto-shredded by EBS encryption).

## Order of work + validation

1. **Housekeeping (prerequisite):** merge `origin/aws-dcv-platform` (only
   conflict: `MERGE-BRIEF.md`, delete wins), untrack the committed
   `aws/portal/**/__pycache__/*.pyc` + gitignore, gate `40-gnome-qol`'s
   Firefox pin and `verify.sh`'s dock expectation on `is_dcv_terminal`
   (Chrome there — the host dconf-locks favorites; Firefox elsewhere), run
   the portal tests + shellcheck, push. Must land together: after the merge
   the DCV fleet's verify would otherwise FAIL the dock check.
2. **Kit side** — container validation in `ubuntu:24.04`: fake
   `/etc/asp-terminal.env` (medical) → bootstrap writes everything, sweeps a
   planted key, verify zero FAILs; same container non-medical → modules
   SKIP, no other diff; `claude plugin …` headless with no OAuth creds under
   `CLAUDE_CODE_USE_BEDROCK=1` (if it needs auth, the plugin modules keep
   skipping with a specific reason and we revisit); idempotency (second run
   all `OK`, no duplicated blocks); shellcheck.
3. **aws side** — `terraform fmt -check`/`validate`, `py_compile`, portal
   tests, shellcheck.

**Field acceptance (via TJ, real medical provision):** `verify.sh` zero
FAILs; first login shows wallpaper + banner and `claude` answers with no
login prompt; one claude-mem compression cycle with egress only to Bedrock
endpoints; `bedrock-zdr.sh --check` all green (mode `none`, logging empty,
EBS default on, Fable refused); DCV client cannot download a file.

## Out of scope

PHI-tripwire hook pack (slot reserved), Hyper-V medical, an Org SCP
resource, clipboard/upload lockdown, Terraform for account data retention.

## Working-tree rule (new)

Two agents commit to `main` from this one checkout; that is how the `.pyc`
files got in. Feature work happens in a git worktree on a branch and lands on
main only when validated. Main remains the single production track.
