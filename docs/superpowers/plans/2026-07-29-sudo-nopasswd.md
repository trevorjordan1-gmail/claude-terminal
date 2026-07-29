# sudo-nopasswd Core Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Core module `01-sudo-nopasswd` giving the invoking user passwordless sudo via a visudo-validated drop-in, plus verify.sh check, README and CHANGELOG updates.

**Architecture:** One new module following the repo's module contract (sourced in a subshell, ends via `ok`/`skip`/`fail`, idempotent). It generates the rule to a temp file, no-ops if the installed file already matches, validates with `visudo -cf` before anything touches `/etc/sudoers.d` (a syntactically bad file there disables sudo box-wide), then installs with `install -m 0440`. Spec: `docs/superpowers/specs/2026-07-29-sudo-nopasswd-design.md`.

**Tech Stack:** bash, sudo/visudo, coreutils. No test framework exists in this repo — the test discipline is `bash -n`, dockerized shellcheck, `--list`/`--help` smoke runs, and a standalone `visudo -cf` sanity check (per `docs/DEVELOPMENT.md`). Do NOT add a test framework, and do NOT run `./bootstrap.sh` (module execution) on the development machine — real-box validation happens on a fleet box after push.

---

### Task 1: The module

**Files:**
- Create: `modules/core/01-sudo-nopasswd.sh`

- [ ] **Step 1: Write the module**

Create `modules/core/01-sudo-nopasswd.sh` with exactly:

```bash
# shellcheck shell=bash
# ct-desc: passwordless sudo for the invoking user — asks once at first setup, never again

# A Claude terminal is a single-user box; sudo password prompts stall Claude
# sessions mid-task (and stall users who don't manage the box's password).
# Never install unvalidated content into /etc/sudoers.d — a syntax error
# there disables sudo box-wide, so visudo -cf gates every write.
user="$(id -un)"
rule="$user ALL=(ALL) NOPASSWD:ALL"
# sudo silently ignores sudoers.d file names containing a dot.
target="/etc/sudoers.d/010-${user//./_}-nopasswd"

tmp="$CT_TMP/sudoers-nopasswd"
printf '%s\n' "$rule" > "$tmp" || fail "could not write $tmp"

if sudo cmp -s "$tmp" "$target" 2>/dev/null; then
    ok "already configured ($target)"
fi

visudo -cf "$tmp" >/dev/null \
    || fail "generated rule failed visudo validation — system untouched"

sudo install -o root -g root -m 0440 "$tmp" "$target" \
    || fail "could not install $target"
ok "passwordless sudo for $user ($target)"
```

Notes for the implementer:
- `$CT_TMP` is set by the dispatcher and cleaned by its EXIT trap; referencing it directly in a module is established practice (`modules/extra/docker.sh:30`).
- `ok`/`fail` exit the module subshell — code after them never runs.
- The variable is named `target`, not `file` — the dispatcher's `run_module()` uses a local `file` and shadowing it would be confusing (harmless, but confusing).
- The rule line must stay byte-identical to `<user> ALL=(ALL) NOPASSWD:ALL` — it matches a hand-installed file already in the field, letting that box converge to "already configured" without a rewrite.

- [ ] **Step 2: Syntax check**

Run: `bash -n modules/core/01-sudo-nopasswd.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Sanity-check the generated rule through visudo (nothing installed)**

Run:

```bash
t="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$(id -un)" > "$t"
visudo -cf "$t"; echo "exit: $?"
rm -f "$t"
```

Expected output (works unprivileged; validation only, installs nothing):

```
/tmp/tmp.XXXXXXXXXX: parsed OK
exit: 0
```

- [ ] **Step 4: Confirm the module lists in the right slot**

Run: `./bootstrap.sh --list`
Expected: under "Core modules", a line `01-sudo-nopasswd` with the ct-desc text, appearing between `00-base-cli` and `02-home-dirs`. (`--list` only prints module names — it executes nothing.)

### Task 2: verify.sh check

**Files:**
- Modify: `verify.sh:29` (the `~/Projects` check line)

- [ ] **Step 1: Add the check**

In `verify.sh`, replace:

```bash
if [ -d "$HOME/Projects" ]; then p "~/Projects exists"; else f "~/Projects missing"; fi
```

with (new check first — verify order mirrors module run order, and 01-sudo-nopasswd runs before 02-home-dirs):

```bash
sudoers_rule="/etc/sudoers.d/010-$(id -un | tr '.' '_')-nopasswd"
if [ -s "$sudoers_rule" ]; then
    p "passwordless sudo rule present"
else
    f "passwordless sudo rule missing or empty ($sudoers_rule)"
fi

if [ -d "$HOME/Projects" ]; then p "~/Projects exists"; else f "~/Projects missing"; fi
```

Notes for the implementer:
- `tr '.' '_'` must produce the same name as the module's `${user//./_}` — if you change one, change both.
- Non-empty existence, no sudo: `/etc/sudoers.d` is 0755 and `test -s` only stats, so it works unprivileged even though the file itself is 0440 root-only; content was visudo-validated at install time, and `-s` additionally catches a truncated/empty file from any origin (an empty file parses clean through visudo, so existence alone would miss it). verify.sh stays read-only and sudo-free.
- Do not name the variable `f` — that's verify.sh's FAIL-printer function.

- [ ] **Step 2: Syntax check**

Run: `bash -n verify.sh`
Expected: no output, exit 0.

- [ ] **Step 3: See the check run**

Run: `./verify.sh | grep 'passwordless sudo'`
Expected: exactly one line — `PASS  passwordless sudo rule present` if the dev machine happens to carry the rule, otherwise `FAIL  passwordless sudo rule missing or empty (/etc/sudoers.d/010-<user>-nopasswd)`. Either proves the check executes; a FAIL here is correct behavior on a box that never ran bootstrap (ignore the rest of the report for the same reason).

### Task 3: README

**Files:**
- Modify: `README.md:51-52` (core table), `README.md:71-73` (after the aliases block)

- [ ] **Step 1: Add the core-table row**

In the "What the core installs" table, between the `00-base-cli` and `02-home-dirs` rows, insert:

```markdown
| 01-sudo-nopasswd | passwordless sudo for the installing user — password asked once at first setup, never again |
```

- [ ] **Step 2: Add the posture sentence**

Immediately after the aliases code block (the one ending `alias phonecc=...`, before the `## Extras` heading), insert:

```markdown
In the same spirit, the core sets up **passwordless sudo** for the installing
user (`01-sudo-nopasswd`): the first bootstrap run asks for your password
once, and nothing on the box ever asks again. Deliberate posture for a
single-user lab VM — if you fork this and don't want it, delete that module.
```

### Task 4: CHANGELOG

**Files:**
- Modify: `CHANGELOG.md:1-3` (top of file)

- [ ] **Step 1: Add the entry**

Directly under the `# Changelog` heading, before the `## 2026-07-22` section, insert:

```markdown
## 2026-07-29

- New core module 01-sudo-nopasswd: passwordless sudo for the invoking user
  via a visudo-validated drop-in in /etc/sudoers.d (mode 0440; nothing is
  installed unless it parses). A box's first bootstrap run prompts for the
  password once; after that nothing ever asks — sudo prompts were stalling
  Claude sessions on a field box. `verify.sh` checks for the rule.
```

### Task 5: Lint and smoke (whole repo)

**Files:** none modified — verification gate per `docs/DEVELOPMENT.md`.

- [ ] **Step 1: bash -n every touched script**

Run: `bash -n modules/core/01-sudo-nopasswd.sh && bash -n verify.sh && bash -n bootstrap.sh && echo OK`
Expected: `OK`

- [ ] **Step 2: shellcheck, finding-free**

Run:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x $(git ls-files '*.sh')
```

Expected: no output, exit 0. If it flags something in the new module, fix the code (scoped `# shellcheck disable=` with a reason comment only if genuinely justified — see existing scoped disables for the pattern).

- [ ] **Step 3: smoke --list and --help**

Run: `./bootstrap.sh --list >/dev/null && ./bootstrap.sh --help >/dev/null && echo OK`
Expected: `OK`

### Task 6: Commit and deploy

**Files:** none new — commits the work from Tasks 1–4.

- [ ] **Step 1: Review the diff**

Run: `git status --short && git diff`
Expected changes only in: `modules/core/01-sudo-nopasswd.sh` (new), `verify.sh`, `README.md`, `CHANGELOG.md`.

- [ ] **Step 2: Single feature commit (house style — one commit per feature)**

```bash
git add modules/core/01-sudo-nopasswd.sh verify.sh README.md CHANGELOG.md
git commit -m "feat: core module 01-sudo-nopasswd — passwordless sudo for the invoking user"
```

(Session trailers appended per the operator's global git rules; author must be the repo's configured identity — sanity-check with `git config user.email` first.)

- [ ] **Step 3: Push (deployment — fleet boxes converge via git pull)**

Confirm with the operator, then: `git push`
Expected: pushed to `origin/main`. Field validation per DEVELOPMENT.md: next real box runs `git -C ~/claude-terminal pull && ~/claude-terminal/bootstrap.sh`, then `./verify.sh` as the scorecard; the box already carrying the hand-installed rule should report `01-sudo-nopasswd: OK already configured`.
