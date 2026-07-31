# Splashtop Extra Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `modules/extra/splashtop.sh` from a manual-instructions stub into a real module that installs Splashtop Streamer and registers the machine with a deployment code, and add a generic mechanism for opt-in extras to advertise themselves in NEXT STEPS.

**Architecture:** One rewritten extra module plus ~16 lines in `bootstrap.sh`. The module follows the existing contract (sourced in a subshell, ends via `ok`/`skip`/`fail`, idempotent) with one deliberate departure: it prompts, which requires a narrow amendment to hard rule 7. The suggestion mechanism reads a `# ct-suggest: <command>|<hint>` header the same way `--list` already reads `# ct-desc:`, so future products need no dispatcher changes. Spec: `docs/superpowers/specs/2026-07-31-splashtop-extra-design.md`.

**Tech Stack:** bash, apt, systemd, the vendor's `splashtop-streamer` CLI. No test framework — discipline is `bash -n`, dockerized shellcheck, `--list`/`--help` smoke runs, and isolated harness tests for anything that can't be exercised without running bootstrap. Do NOT run `./bootstrap.sh` on the dev machine.

---

### Task 1: Establish the facts before writing code

- [x] **Step 1: Verify the vendor's actual interface**

Download the tarball and inspect the package rather than trusting docs. Confirm: the CLI is `splashtop-streamer deploy CODE`; the unit is `SRStreamer.service`; `postinst` symlinks `/usr/bin/splashtop-streamer` and starts the service; `RunSplashtopDeploy` ends in `return $ret` so failure is detectable; the polkit action is `auth_admin_keep`, meaning deploy must run under `sudo` to avoid an auth dialog.

- [x] **Step 2: Verify `read` under a pipe, and the tty gate**

Demonstrate that a bare `read` in a piped script consumes the script's own next line (no prompt, following statement never runs), that `read … < /dev/tty` works under the pipe, and that `[ -t 0 ]` is false under a pipe even in a real console while `( : </dev/tty )` is true. Check the gate in three environments: piped-under-a-pty, piped-with-no-pty, detached via `setsid`.

- [x] **Step 3: Establish that no "latest" URL exists**

Probe the download host for directory listings, unversioned names, `version.txt`, `latest.json`, and adjacent version numbers. All 403. Conclusion: pin the URL and enable the streamer's own auto-update.

---

### Task 2: The module

**Files:**
- Rewrite: `modules/extra/splashtop.sh`

- [x] **Step 1: Write it**

Order matters. Return `ok` early if already installed (keeps re-runs unattended). Resolve the code from `$CT_SPLASHTOP_CODE` or prompt *before* downloading. `skip` with a `next_step` when there's neither. Then download → unpack → `apt_install` → `sudo … deploy` → `sudo … config -auto_update=1` → service check.

Carry `# ct-suggest: splashtop-streamer|Remote access (Splashtop): ./bootstrap.sh --with-splashtop`.

- [x] **Step 2: Make a stale pin diagnosable**

The download failure message must name the file and variable to bump, not just fail.

---

### Task 3: The suggestion mechanism

**Files:**
- Modify: `bootstrap.sh`

- [x] **Step 1: Add the loop after the summary, before NEXT STEPS prints**

Suggest when the extra didn't run this time AND its probe command isn't on PATH. Handle a value with no `|` by always suggesting. Must survive `set -u` with an empty `EXTRAS` array — use the existing `${EXTRAS[@]+"${EXTRAS[@]}"}` idiom.

- [x] **Step 2: Unit-test every branch in isolation**

`bootstrap.sh` can't be run on the dev box, so extract the loop with `awk '/^# Advertise opt-in extras/,/^done$/'` and drive it with fixture modules: not-run-and-absent, command-present, ran-this-time, no-suggest-line, and no-`|`. Then run it against the real modules directory with a PATH sandbox that hides `splashtop-streamer` (symlink only `sed`, `head`, `basename` into a temp bin). Note the sandbox must be invoked as `/bin/bash`, since `PATH=… bash` would look up `bash` itself in the sandbox.

---

### Task 4: verify.sh, README, DEVELOPMENT, CHANGELOG

- [x] **Step 1: verify.sh**

Follow the "reported only when artifacts exist" pattern — PASS/FAIL only when the package is installed.

- [x] **Step 2: README — keep it short**

Maintainer was explicit: simplest possible language, no wordiness. Four lines: the command, and what to type when asked. Update the extras table row too.

- [x] **Step 3: DEVELOPMENT.md**

Document `ct-suggest:` in contract item 1. Amend hard rule 7 with the prompt exception and both silent traps. Replace the Splashtop roadmap item with RustDesk.

- [x] **Step 4: CHANGELOG entry under the existing `## 2026-07-31` heading**

---

### Task 5: Lint, commit, validate

- [x] **Step 1: `bash -n` + dockerized shellcheck, finding-free; `--list`/`--help` smoke**

- [x] **Step 2: Single feature commit, then push**

- [ ] **Step 3: Validate on a real box**

Not yet done. On a box without Splashtop:

1. `./bootstrap.sh` (core only) — the summary should end with the `--with-splashtop` reminder.
2. `./bootstrap.sh --with-splashtop` — should prompt for the code, install, register, and report `OK splashtop installed and registered`.
3. Confirm the machine appears in the Splashtop console.
4. `./verify.sh` — expect `PASS splashtop streamer active`.
5. Re-run `./bootstrap.sh --with-splashtop` — must print `OK splashtop already installed` **without prompting**. This is the idempotency guarantee that keeps re-runs unattended.
6. Confirm the reminder no longer appears on a plain `./bootstrap.sh` run.

Also worth one pass through the `curl … | bash -s -- --with-splashtop` form, since that's the path where the `/dev/tty` handling actually matters.
