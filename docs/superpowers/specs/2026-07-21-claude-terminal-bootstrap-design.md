# claude-terminal Bootstrap — Design Spec

**Date:** 2026-07-21
**Status:** Approved (maintainer), implemented same day

## Purpose

Turn a stock **Ubuntu 24.04 LTS Desktop** install (typically a Hyper-V VM)
into a "Claude Code terminal": a machine whose primary job is running Claude
Code sessions, with the maintainer's proven quality-of-life fixes applied.
Public repo; only the maintainer pushes; anyone may use or fork.

Derived from a field audit of two production machines (personal + work
terminals) which agreed on ~85% of their configuration. The shared portion
became the **core**; the rest became **opt-in extras** or stayed out entirely.

## Requirements

1. **Easy to run.** One command from a fresh box. Sensible defaults. Safe to
   re-run at any time (idempotent) — re-running is also the upgrade path.
2. **Core by default, extras by flag.** `./bootstrap.sh` installs the core.
   `--with-<name>` adds extras. `--all-extras` adds all *safe* extras
   (excludes `weak-passwords` and `splashtop`, which need explicit intent).
3. **Never require interactive stdin** (must work via `curl | bash`); sudo
   may prompt on the TTY. Anything that genuinely needs interaction (Claude
   login, `tailscale up`, printer names) is deferred to a printed
   **NEXT STEPS** list at the end.
4. **Degrade gracefully.** A module that can't run (not logged into Claude
   yet, no GUI session, private repo unreachable) reports SKIPPED with the
   manual fallback, and the rest continues.
5. **No secrets in the repo, ever.** No SSH keys, printer hostnames, VPN
   auth, or machine-specific identifiers. Audit output is gitignored.

## Components

| Unit | Responsibility |
|------|----------------|
| `get.sh` | curl-able entry: installs git if needed, clones/updates `~/claude-terminal`, execs `bootstrap.sh "$@"` |
| `bootstrap.sh` | arg parsing, module ordering, per-module status collection, NEXT STEPS summary |
| `lib/common.sh` | logging, `have`, root/OS guards, DBus env fixup, idempotent `append_block` marker edits, status arrays |
| `modules/core/*.sh` | one concern per file, numeric prefix = run order |
| `modules/extra/*.sh` | opt-in features, name = flag name |
| `tools/add-printer.sh` | create a permanent direct-IPP queue (`lpadmin -m everywhere`), replacing flaky cups-browsed auto-queues |
| `verify.sh` | read-only PASS/FAIL/SKIP report of expected state |
| `audit/system-audit.sh` | full read-only system snapshot for machine-to-machine diffing (the tool the core/extras split came from) |

### Core modules (run order)

| Module | What it does | Why |
|--------|--------------|-----|
| 00-base-cli | apt: git, gh, tmux, curl, wget, jq, unzip, lynx, xvfb, openssh-server | shared tooling on both reference machines |
| 05-node | NodeSource Node 20; npm prefix `~/.npm-global` (no sudo-npm) | Claude ecosystem deps; user-owned global packages |
| 10-claude-code | native installer → `~/.local/bin/claude`; `cc` + `phonecc` aliases | the point of the machine; aliases match maintainer's workflow |
| 15-bun | official bun installer → `~/.bun` | required by claude-mem v10 worker |
| 20-claude-mem | marketplace `thedotmack/claude-mem`, plugin `claude-mem@thedotmack` | persistent memory; v10 plugin needs none of the 3.x hand-fixes |
| 25-superpowers | marketplace `obra/superpowers-marketplace`, plugin `superpowers` | structured skills (planning/TDD/debugging) |
| 30-uv | astral.sh installer → `~/.local/bin/uv` | Python tooling; claude-mem's Chroma MCP uses uvx |
| 40-gnome-qol | gsettings: screen lock off, idle-blank off | terminal VM should never lock/blank |
| 45-hyperv-qol | xorg.conf.d: libinput `HighResolutionWheelScrolling off`; add user to `video` group. Gated on `systemd-detect-virt` = microsoft | fixes wildly-fast scrolling from Hyper-V/remote-desktop synthetic mice; fixes /dev/fb0 Xorg permission error |
| 50-okular-md | apt okular (+md backend); xdg-mime default for text/markdown | double-click a .md, see it rendered |

### Extra modules (flags)

| Flag | What it does |
|------|--------------|
| `--with-docker` | Docker CE from docker.com repo (engine, buildx, compose), user in `docker` group |
| `--with-xrdp` | xrdp + XFCE session; startwm.sh sources `~/.profile` so RDP sessions get user PATH |
| `--with-tailscale` | tailscale.com repo + install + enable; `tailscale up` left to NEXT STEPS |
| `--with-printing-direct` | disable `cups-browsed` (source of duplicate/broken auto-queues); queues added per-printer via `tools/add-printer.sh` |
| `--with-buildtools` | build-essential, maven, JDK, msitools, wixl, osslsigncode, mdbtools |
| `--with-usagemeter` | adnettech/usagemeter tray meter (best-effort clone + install) |
| `--with-weak-passwords` | zero out pwquality requirements (lab VMs only; never in `--all-extras`; prints the optional GDM PAM step rather than editing PAM) |
| `--with-splashtop` | **stub**: prints manual install instructions. Real automation is a planned follow-up ("revisit once the bones are up") |

### Explicitly out of scope (stay manual/private)

SSH keys and host configs, printer hostnames/queues themselves (tool provided,
data not), VPN/Tailscale auth, RustDesk custom builds, personal containers and
cron jobs, MFA enrollment, GNOME PAM root-guard edits, any machine hostnames.

## Error handling

- `set -u` everywhere; modules run in subshells so one failure can't abort the run.
- Every module ends in exactly one recorded state: OK / SKIPPED(reason) / FAILED(reason).
- Guards: refuse to run as root; refuse non-Ubuntu-24.04 unless `--force-os`.
- apt runs with `-y` and `DEBIAN_FRONTEND=noninteractive`; retries left to re-runs.

## Testing

- `bash -n` + shellcheck (dockerized) on every script.
- `bootstrap.sh --list` / `--help` smoke tests.
- First end-to-end run happens on the maintainer's fresh 24.04 test VM;
  `verify.sh` then `audit/system-audit.sh` diff against a reference box.

## Maintenance discipline

Every future OS change that is generic goes into a module + `CHANGELOG.md`
entry; machines converge by `git pull && ./bootstrap.sh` (plus flags).
Personal-only changes stay in each machine's private os-changes log.
