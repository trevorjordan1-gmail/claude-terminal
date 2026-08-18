# Development Guide

For anyone (human or agent) changing this repo. The README covers *using* the
bootstrap; this covers *maintaining* it.

## Status

**v1 complete and field-validated** (2026-07-22); since then the DCV/AWS
platform moved into `aws/`, the medical profile landed (2026-08-18), and the
`templates/` Ai Build methodology ships alongside — see `CHANGELOG.md` for
the current state. As of 2026-07-22, every code path —
core modules, post-login plugin modules (claude-mem, superpowers), extras
plumbing, `get.sh` one-liner, `verify.sh` — has run successfully on freshly
built Ubuntu 24.04 Hyper-V VMs. The module set was distilled from a
file-by-file audit of two long-lived production machines (see
`audit/system-audit.sh`, the tool that produced the split).

## Repo map

| Path | Role |
|---|---|
| `get.sh` | curl-able entrypoint: clone/update `~/claude-terminal`, exec bootstrap |
| `bootstrap.sh` | arg parsing, module dispatch, summary + NEXT STEPS output |
| `lib/common.sh` | helpers every module can use (see contract below) |
| `modules/core/NN-*.sh` | always run, lexical order |
| `modules/extra/<flag>.sh` | run when `--with-<flag>` given |
| `assets/` | data files modules load (`gnome-terminal.dconf`, `medical-wallpaper.svg`) |
| `tools/` | standalone user-facing helpers (`add-printer.sh`, `cct-finish.sh` — installed to `~/.local/bin` by module 27) |
| `windows/get.ps1` | Windows counterpart of `get.sh`: `irm … \| iex` on a Hyper-V host |
| `windows/cctemp.ps1` | temporary Claude Code install on a Windows box for a troubleshooting engagement, with dead-man cleanup (README) |
| `aws/` | the DCV-on-AWS platform: terraform tenant substrate, Entra portal, provisioning/ops scripts, runbooks (`aws/README.md`) |
| `templates/` | Ai Build methodology templates the kit ships to every terminal (`CHANGELOG.md` 2026-08-13/14) |
| `windows/New-UbuntuHyperVVM.ps1` | interactive Gen-2 Ubuntu VM builder (host-side) |
| `verify.sh` | read-only PASS/FAIL/SKIP state check |
| `modules/core/08-medical-bedrock.sh`, `21-medical-claude-mem.sh`, `43-medical-cues.sh` | medical-profile modules; skip unless `is_medical_terminal` (README "Medical mode") |
| `audit/system-audit.sh` | full machine snapshot for diffing two boxes |
| `docs/superpowers/` | original design spec + implementation plan (historical) |

`windows/` and `aws/` don't run on the target box — `windows/` runs on the
Hyper-V host that *builds* a box, `aws/` on the operator workstation and the
tenant's control plane. `windows/` in particular
runs on the Windows Hyper-V host that *builds* the box. It's standalone
tooling in the spirit of `tools/`, outside `bootstrap.sh` dispatch, so the
module contract below does not apply to it.

## Module contract

Modules are **sourced inside a subshell** by `bootstrap.sh`. Rules:

1. First lines: `# shellcheck shell=bash` and `# ct-desc: <one-liner>`
   (the ct-desc line is what `--list` prints). An extra may also carry
   `# ct-suggest: <command>|<hint>`: bootstrap prints `<hint>` under NEXT STEPS
   when that extra didn't run *and* `<command>` isn't on PATH. That's how an
   opt-in product advertises itself without the dispatcher knowing it exists.
2. Terminate through exactly one of `ok "msg"` / `skip "why"` / `fail "why"`.
   These `exit` the subshell — code after them does not run. A module that
   falls off the end counts as OK.
3. Queue user-visible follow-ups with `next_step "…"` (deduped, printed once
   at the end of the run). Don't print the same instruction the dispatcher
   already adds (e.g. the claude-login reminder).
4. Available helpers: `have`, `pkg_installed`, `apt_install` (auto
   `apt-get update` once per run), `append_block FILE MARKER <<'EOF'`
   (idempotent marker-delimited config blocks; `sudo_append_block` is the
   same for root-owned files), `claude_ready` (installed *and* logged in —
   or pinned to Bedrock: `claude_bedrock_ready`), `is_dcv_terminal` /
   `is_medical_terminal` / `asp_env KEY` (platform facts from
   `/etc/asp-terminal.env`), `log/warn`. After adding an apt repo,
   `rm -f "$CT_TMP/apt-updated"` to force a re-update.
   **gsettings/dconf writes go through `gui_conf`** (gate with
   `gui_conf_ready || skip`): it uses the live user bus when one exists and
   falls back to a private one-shot bus (`dbus-run-session`) so headless
   provisioning works — a busless `gsettings set` otherwise exits 0 while
   writing nothing. Reads (`gsettings get`, `dconf dump`) hit the database
   file directly and need no bus or wrapper. (`ensure_user_dbus` remains the
   lower-level SSH-session helper `gui_conf` builds on.)
   **Platform gates:** `is_dcv_terminal` is true on DCV/cloud fleet boxes
   (`/etc/asp-terminal.env` or the DCV server package) — gate anything
   GDM/lock/login-shaped behind it; the host owns session config there.
   Hyper-V stays `systemd-detect-virt` = `microsoft`, Splashtop stays
   `pkg_installed splashtop-streamer`.
5. **Idempotency is non-negotiable.** Re-running bootstrap is the upgrade
   path. Guard every mutation (`grep -q` before sed-insert, `pkg_installed`
   before apt, compare-before-set for gsettings).
6. Pick the right convergence mode:
   - **Converge** (enforce on every run): system packages, services,
     gsettings the machines should agree on (e.g. dock favorites).
   - **Seed** (apply once, never overwrite): anything a user will personalize
     later (e.g. `42-terminal-prefs` loads its dconf only when the target
     tree is empty).
7. Anything needing interaction (logins, `tailscale up`, printer addresses)
   is a `next_step`, never a prompt. **One exception:** an extra the user
   explicitly asked for by its own `--with-` flag may prompt for input that is
   inherently per-machine and secret — a Splashtop deployment code, say. Such a
   module must read from `/dev/tty` and must `skip` when it can't, so unattended
   runs never block. Two traps: under `curl | bash` stdin is the *pipe*, so a
   bare `read` silently consumes the script's own next line instead of asking;
   and `[ -t 0 ]` is false there even in a real console, so gate on
   `( : </dev/tty ) 2>/dev/null` instead. Core modules get no exception.

Numbering: core runs in lexical order — pick a number that respects
dependencies (base-cli → runtimes → claude stack → desktop). Extras are named
exactly like their flag.

**`# ct-after-extras`** (core modules only) defers a module to the very end of
the run, after the extras pass, instead of running it in lexical position. Use
it when a core module acts on something an *extra* installs — the only case
today is `41-splashtop-cursorfix`, which is gated on `splashtop-streamer` and
would otherwise skip on the very run that `--with-splashtop` installed it, so
the fix would land only on the next bootstrap. Note the consequence: such a
module's number no longer reflects when it runs, so keep the list short and say
why in the module header.

## Adding a feature — checklist

1. Write the module (contract above). Core if both reference machines need
   it; extra if it's situational; `--all-extras` excludes anything
   consequential enough to require explicit intent (see `SAFE_EXTRAS` in
   `bootstrap.sh`).
2. Add a check to `verify.sh` (PASS/FAIL for core state, SKIP when the
   feature legitimately isn't there yet).
3. Add the README table row.
4. Add a `CHANGELOG.md` entry — this file is the project's change discipline.
5. Lint: `bash -n` every touched script, then
   `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x $(git ls-files '*.sh')`
   — keep it finding-free (scoped `# shellcheck disable=` with a reason
   comment when justified). For anything under `windows/`, the equivalent
   check is a PowerShell parse (there's no PowerShell on the dev box):
   `docker run --rm -v "$PWD:/repo:ro" mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command "…Parser]::ParseFile(…)"`
   — see the 2026-07-31 plan for the full command.
6. Smoke: `./bootstrap.sh --list` and `--help`.
7. Commit, push. Machines pick it up with
   `git -C ~/claude-terminal pull && ~/claude-terminal/bootstrap.sh`.
8. Validate on a real box before calling it done; `./verify.sh` is the
   scorecard.

## Operator loop (issues → branch → merge → tag)

The platform operator runs tenants downstream and finds fixes there; the
product lives upstream on `main`. The loop (issue #1):

1. **Issue first.** Every request or fix from an operator/agent is a GitHub
   issue on this repo (context, root cause, proposal, acceptance). Label the
   area (`area:kit` / `area:aws` / `area:docs`) and `operator`. Issues are
   public and *not* covered by pii-guard: **no client codes, hostnames,
   account IDs or people** in issue text, branch names or commit messages —
   `acme`/`example.com` placeholders only. "TJ"-style initials are fine.
2. **Branch** `<area>/<short-slug>` (e.g. `aws/polkit-aptdaemon`) from
   current `main`, referencing the issue; test against the pilot tenant from
   the branch tree (`ASP_TENANTS=… aws/scripts/rollout.sh`).
3. **Merge**: the repo admin reviews and merges to `main` (`Fixes #N` in the
   merge commit closes the issue). Main is production — validate before
   merging (shellcheck, portal tests, `terraform validate`, container runs
   for kit changes).
4. **Tag every shipping merge**: `vYYYY.MM.DD` (`-1`, `-2` for more than one
   a day). `rollout.sh` stamps tenants with `git describe`, so tags are what
   make per-tenant version records meaningful. Roll tenants forward
   tag-by-tag; the admin comments the merge sha + tag on the issue.
5. **Variance is config, not branches.** Anything a tenant needs that main
   lacks is first assumed to be a generic feature behind config
   (`profile`, `GROUP_BUILD_ENGINEERS`, `ASP_BRAND`, `ASP_TENANTS`). True
   one-offs go in the tenant's own `scripts/tenant-custom.sh` /
   `tenant-custom-cp.sh` in the artifacts bucket — run last by
   `desktop-setup.sh` / `cp-setup.sh` if present, idempotent, non-fatal,
   logged to `/var/log/asp-tenant-custom.log`, never edited upstream. Tenant
   identity (tfvars, `tenants.json`, backend, SSM config) stays in the
   operator's private overlay, never here.

## Hard rules

- **No secrets or machine identifiers, ever** — no hostnames, IPs, printer
  hosts, emails, keys. Audit snapshots (`os-audit*/`, `*.tar.gz`) are
  gitignored; keep it that way. `CLAUDE.md` in the repo root is the
  maintainer's local scratch context and is gitignored too.
- Bootstrap must keep working via `curl | bash` on a stock install — no new
  runtime assumptions (bash + apt + sudo only until a module installs more).
- Modules must degrade to SKIP with a manual fallback rather than block.

## Roadmap / candidate work

- **RustDesk extra** — some sites use RustDesk instead of Splashtop. It should
  land as `modules/extra/rustdesk.sh` with its own `ct-suggest:` line; the
  dispatcher needs no changes. Follow `splashtop.sh` for the shape.
- MFA extra (`libpam-google-authenticator` + `oathtool`) — present on one
  reference machine, not yet a module.
- Possible split of `buildtools` (compiler toolchain vs Windows-installer
  packaging tools) if either grows.
