# Splashtop Cursor-Crash Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the already-written, already-field-tested `41-splashtop-cursorfix` module into this repo, wired to repo conventions, and close the core-runs-before-extras ordering gap so one bootstrap run both installs Splashtop and guards it.

**Architecture:** One new core module, gated on `pkg_installed splashtop-streamer` so non-Splashtop boxes are untouched (precedent: `45-hyperv-qol` gates on Hyper-V). Plus a small dispatcher capability, `# ct-after-extras`, which defers a core module past the extras pass. Spec: `docs/superpowers/specs/2026-07-31-splashtop-cursorfix-design.md`.

**Tech Stack:** bash, stdlib python3 (Xcursor rewrite), dpkg-divert, squashfs-tools + snapd, gcc (LD_PRELOAD shim). This was NOT designed here — do not redesign it. Guardrails in the original handoff are load-bearing and were each written after a real recurrence: the python stays stdlib-only; guard 1 keeps scanning all files in all themes; keep `--rename` diversion parking; keep the logout `next_step`; keep guard 4's deferred-unref design and its cmp-based converge check.

---

### Task 1: Add the module

**Files:**
- Create: `modules/core/41-splashtop-cursorfix.sh`

- [x] **Step 1: Add verbatim, then make exactly three edits**

1. Scrub the test machine's hostname from two header comments — the repo's hard rule is no machine identifiers, ever, and this file goes public.
2. Replace `ls … | head -1` with a glob loop to clear shellcheck SC2012, preserving selection order (the shell sorts too).
3. Add the `# ct-after-extras` marker plus a header note saying why.

- [x] **Step 2: Confirm the two supplied copies agree before trusting either**

The handoff embeds the module inline *and* ships it as a file. Diff them first; they were identical.

- [x] **Step 3: Contract check + shellcheck**

Unattended, no prompts, `$CT_TMP` for scratch, terminates through `ok`/`skip`/`fail` exactly once, `next_step` for the logout advisory. `bash -n` and shellcheck clean.

---

### Task 2: Close the ordering gap

**Files:**
- Modify: `bootstrap.sh`

- [x] **Step 1: Defer core modules marked `# ct-after-extras` to the end of the run**

Collect them during the core pass instead of running them, then run them after extras. Must survive `set -u` with an empty array — use the existing `${ARR[@]+"${ARR[@]}"}` idiom.

Chosen over the handoff's minimal `next_step`-telling-you-to-re-run fallback, which would leave a fresh box crashing until someone ran bootstrap a second time.

- [x] **Step 2: Verify the resulting order**

`./bootstrap.sh --with-splashtop` must place `extra/splashtop` before `core/41-splashtop-cursorfix`.

---

### Task 3: verify.sh, README, CHANGELOG, DEVELOPMENT

- [x] **Step 1: verify.sh checks in `p/f/s` style**

All skipped when `splashtop-streamer` is absent, so RustDesk boxes SKIP rather than FAIL. Deviation from the handoff: it proposed `sudo grep /proc/<pid>/maps`, but `verify.sh` is read-only *and sudo-free* by design — use `systemctl show SRStreamer.service -p Environment` instead.

- [x] **Step 2: README core-table row, CHANGELOG entry, DEVELOPMENT `ct-after-extras` docs**

---

### Task 4: Ship

- [x] **Step 1: Full-repo lint, identifier sweep, commit, push**

- [ ] **Step 2: Field-validate on a Splashtop box**

Deferred 2026-07-31 — no new box being built for a while, so this waits for the
next fresh VM rather than being testable now. The module arrived already
field-proven on the machine it was written for; what's unvalidated is this
repo's *wiring* of it (the `ct-after-extras` deferral, the verify checks, and
the converge path), not the fix itself.

Checklist when a box is available:

1. `./bootstrap.sh --with-splashtop` on a fresh box — `41-splashtop-cursorfix` should run *after* `extra/splashtop` and report OK, with a NEXT STEPS logout line.
2. Re-run — must report `OK already converged` and must **not** restart the streamer (a restart drops live sessions).
3. `./verify.sh` — five new PASS lines.
4. On a box without Splashtop: module SKIPs, and `dpkg-divert --list | grep -c animated` is 0 before and after.
5. Confirm the crash is actually gone in active use. That needs a Splashtop-registered machine; it was already validated in production on the originating box, so this is confirmation rather than proof.
