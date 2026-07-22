# Development Guide

For anyone (human or agent) changing this repo. The README covers *using* the
bootstrap; this covers *maintaining* it.

## Status

**v1 complete and field-validated.** As of 2026-07-22, every code path —
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
| `assets/` | data files modules load (e.g. `gnome-terminal.dconf`) |
| `tools/` | standalone user-facing helpers (`add-printer.sh`) |
| `verify.sh` | read-only PASS/FAIL/SKIP state check |
| `audit/system-audit.sh` | full machine snapshot for diffing two boxes |
| `docs/superpowers/` | original design spec + implementation plan (historical) |

## Module contract

Modules are **sourced inside a subshell** by `bootstrap.sh`. Rules:

1. First lines: `# shellcheck shell=bash` and `# ct-desc: <one-liner>`
   (the ct-desc line is what `--list` prints).
2. Terminate through exactly one of `ok "msg"` / `skip "why"` / `fail "why"`.
   These `exit` the subshell — code after them does not run. A module that
   falls off the end counts as OK.
3. Queue user-visible follow-ups with `next_step "…"` (deduped, printed once
   at the end of the run). Don't print the same instruction the dispatcher
   already adds (e.g. the claude-login reminder).
4. Available helpers: `have`, `pkg_installed`, `apt_install` (auto
   `apt-get update` once per run), `append_block FILE MARKER <<'EOF'`
   (idempotent marker-delimited config blocks), `ensure_user_dbus` (makes
   gsettings/dconf work over SSH), `claude_ready` (installed *and* logged in),
   `log/warn`. After adding an apt repo, `rm -f "$CT_TMP/apt-updated"` to
   force a re-update.
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
   is a `next_step`, never a prompt — `curl | bash` has no stdin.

Numbering: core runs in lexical order — pick a number that respects
dependencies (base-cli → runtimes → claude stack → desktop). Extras are named
exactly like their flag.

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
   comment when justified).
6. Smoke: `./bootstrap.sh --list` and `--help`.
7. Commit, push. Machines pick it up with
   `git -C ~/claude-terminal pull && ~/claude-terminal/bootstrap.sh`.
8. Validate on a real box before calling it done; `./verify.sh` is the
   scorecard.

## Hard rules

- **No secrets or machine identifiers, ever** — no hostnames, IPs, printer
  hosts, emails, keys. Audit snapshots (`os-audit*/`, `*.tar.gz`) are
  gitignored; keep it that way. `CLAUDE.md` in the repo root is the
  maintainer's local scratch context and is gitignored too.
- Bootstrap must keep working via `curl | bash` on a stock install — no new
  runtime assumptions (bash + apt + sudo only until a module installs more).
- Modules must degrade to SKIP with a manual fallback rather than block.

## Roadmap / candidate work

- **Splashtop automation** (`modules/extra/splashtop.sh` is a
  manual-instructions stub today; maintainer wants it automated —
  the .deb download is version-pinned on their site, needs a stable fetch
  strategy).
- MFA extra (`libpam-google-authenticator` + `oathtool`) — present on one
  reference machine, not yet a module.
- Possible split of `buildtools` (compiler toolchain vs Windows-installer
  packaging tools) if either grows.
