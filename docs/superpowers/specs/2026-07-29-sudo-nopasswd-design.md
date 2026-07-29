# sudo-nopasswd Core Module — Design Spec

**Date:** 2026-07-29
**Status:** Approved (maintainer)

## Purpose

A Claude Code terminal is a single-user machine whose owner already runs
Claude with `--dangerously-skip-permissions` (the `cc`/`phonecc` aliases are
the point of the box). Sudo password prompts are the remaining friction:
they stall Claude sessions mid-task and block users who don't manage the
box's password. Field experience confirmed it — a production box had to be
fixed by hand with a one-off NOPASSWD rule. Maintainer decision: every box
needs this, so it joins the core. A box's first-ever bootstrap run prompts
for the password once (unavoidable — installing the rule itself needs root);
after that, never again.

## Behavior

New core module `01-sudo-nopasswd`, running immediately after `00-base-cli`.
It has no dependency on base-cli (sudo, visudo, and coreutils are stock
Ubuntu); slot 01 simply runs it as early as possible.

1. Resolve the invoking user with `id -un` (the dispatcher already refuses
   to run as root).
2. Rule line: `<user> ALL=(ALL) NOPASSWD:ALL` — byte-identical to the
   field-installed one-off, so boxes already carrying it converge without a
   rewrite.
3. Target: `/etc/sudoers.d/010-<user>-nopasswd`, with dots in the username
   replaced by underscores in the *filename only* (sudo silently ignores
   sudoers.d files whose names contain a `.`).
4. Flow: write the rule to a temp file (guarded — a failed write aborts the
   module before anything else happens) → `sudo cmp -s` against the target;
   identical → `ok "already configured"`. Otherwise `visudo -cf` the temp
   file; invalid → `fail` without touching the system. Valid →
   `sudo install -o root -g root -m 0440` into place → `ok`.

## Error handling

The one catastrophic failure mode — installing a syntactically bad sudoers
file, which disables sudo box-wide — is structurally unreachable: nothing
lands in `/etc/sudoers.d` without passing `visudo -cf` first. A validation
failure reports FAIL and leaves the system untouched; re-running bootstrap
remains the retry path.

## verify.sh

New core check: PASS when the expected sudoers.d file exists and is
non-empty, FAIL otherwise. `test -s` only stats the file, so it works
unprivileged (the directory is world-readable even though the file is
not); content was visudo-validated at install, and the non-empty guard
catches a truncated file from any origin — an empty file parses clean
through visudo, so bare existence would miss that state. verify stays
read-only and sudo-free.

## Docs

- README: core-table row for `01-sudo-nopasswd`, plus one sentence in the
  aliases section stating that core configures passwordless sudo and that
  forkers who don't want it can delete the module.
- `CHANGELOG.md` entry (2026-07-29).
- `docs/DEVELOPMENT.md`: unchanged — the module contract already covers
  this.

## Testing

- `bash -n` + dockerized shellcheck on every touched script;
  `--list`/`--help` smoke tests.
- Standalone `visudo -cf` sanity check of generated content on the dev
  machine (validation only; nothing is installed there).
- Field validation on the next real box run; `verify.sh` is the scorecard.

## Out of scope

Narrowing the rule (command allowlists), opt-out flags, and changes to the
existing `weak-passwords` extra. The repo's stance is unchanged: these are
single-user lab boxes, deliberately frictionless.
