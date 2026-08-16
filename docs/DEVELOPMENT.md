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
| `windows/get.ps1` | Windows counterpart of `get.sh`: `irm … \| iex` on a Hyper-V host |
| `windows/New-UbuntuHyperVVM.ps1` | interactive Gen-2 Ubuntu VM builder (host-side) |
| `verify.sh` | read-only PASS/FAIL/SKIP state check |
| `audit/system-audit.sh` | full machine snapshot for diffing two boxes |
| `docs/superpowers/` | original design spec + implementation plan (historical) |

`windows/` is the one part of the repo that doesn't run on the target box — it
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
   (idempotent marker-delimited config blocks), `claude_ready` (installed
   *and* logged in), `log/warn`. After adding an apt repo,
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
