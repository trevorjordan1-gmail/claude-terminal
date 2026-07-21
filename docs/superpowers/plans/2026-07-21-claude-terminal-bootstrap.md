# claude-terminal Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution note:** this plan was executed inline by its author on 2026-07-21
> in the same session that wrote it (maintainer requested same-day bones with a
> test VM standing by). Full file contents live in the repo itself — the single
> source of truth; tasks below carry the load-bearing snippets and the exact
> commands/expected results.

**Goal:** Public repo that turns stock Ubuntu 24.04 Desktop into a Claude Code terminal via one idempotent `bootstrap.sh` (core + `--with-*` extras).

**Architecture:** Thin `bootstrap.sh` dispatcher sources `lib/common.sh`, runs `modules/core/NN-*.sh` in lexical order, then requested `modules/extra/<flag>.sh`; every module records OK/SKIPPED/FAILED and the run ends with a NEXT STEPS summary. `get.sh` is the curl-able wrapper (clone/update + exec).

**Tech Stack:** bash (no other runtime assumed present), apt, official vendor installers (NodeSource, claude.ai, bun.sh, astral.sh, docker.com, tailscale.com), Claude Code plugin CLI.

---

### Task 1: Scaffold + docs
**Files:** Create `LICENSE` (MIT), `.gitignore` (ignore `os-audit*/`, `*.tar.gz`), `CHANGELOG.md`, this plan, the spec.
- [x] Step 1: `git init -b main`; repo-local `git config user.email trevorjordan1@gmail.com`
- [x] Step 2: Write the five files
- [x] Step 3: Commit `chore: scaffold repo with spec, plan, license`

### Task 2: lib/common.sh + bootstrap.sh + get.sh
**Files:** Create `lib/common.sh`, `bootstrap.sh`, `get.sh`.
Key contracts (used by every module):
```bash
have()            # command -v wrapper
apt_install PKG…  # sudo DEBIAN_FRONTEND=noninteractive apt-get install -y
append_block FILE MARKER <<'EOF' … EOF   # idempotent marker-delimited block:
                  # replaces existing "# >>> MARKER >>> … # <<< MARKER <<<" span
ok / skip "why" / fail "why"             # exactly one per module run
ensure_user_dbus  # export DBUS_SESSION_BUS_ADDRESS for gsettings from SSH
claude_ready      # true if `claude` on PATH and ~/.claude/.credentials.json exists
```
`bootstrap.sh` flags: `--list`, `--help`, `--with-<extra>` (repeatable), `--all-extras` (all extras except weak-passwords + splashtop), `--force-os`. Guards: not root; Ubuntu 24.04 (else `--force-os`). Modules run in subshells; summary table + NEXT STEPS print at the end.
- [x] Step 1: Write the three files
- [x] Step 2: `bash -n` each — expect no output
- [x] Step 3: `./bootstrap.sh --list` prints core+extra tables; `--help` prints usage
- [x] Step 4: Commit `feat: bootstrap dispatcher, common lib, curl entrypoint`

### Task 3: Core modules
**Files:** Create `modules/core/{00-base-cli,05-node,10-claude-code,15-bun,20-claude-mem,25-superpowers,30-uv,40-gnome-qol,45-hyperv-qol,50-okular-md}.sh`
Load-bearing details:
- 05-node: NodeSource `setup_20.x` only if node major != 20; `npm config set prefix ~/.npm-global`; PATH via `append_block ~/.bashrc claude-terminal-npm`.
- 10-claude-code: `curl -fsSL https://claude.ai/install.sh | bash` unless `have claude`; aliases block:
```bash
alias cc='claude --dangerously-skip-permissions'
alias phonecc='tmux new-session -A -s claude claude --dangerously-skip-permissions'
```
- 20-claude-mem / 25-superpowers: require `claude_ready` else `skip "run 'claude' once to log in, then re-run"`; then
```bash
claude plugin marketplace add thedotmack/claude-mem
claude plugin install claude-mem@thedotmack
claude plugin marketplace add obra/superpowers-marketplace
claude plugin install superpowers@superpowers-marketplace
```
(each guarded: already-added/installed → OK)
- 40-gnome-qol: `ensure_user_dbus`; `gsettings set org.gnome.desktop.screensaver lock-enabled false`; `gsettings set org.gnome.desktop.session idle-delay 0`; skip if no user bus.
- 45-hyperv-qol: only when `systemd-detect-virt` = microsoft. Writes `/etc/X11/xorg.conf.d/99-libinput-no-hires-scroll.conf`:
```
Section "InputClass"
    Identifier  "Disable high-resolution wheel scrolling (fix over-fast VM scroll)"
    MatchDriver "libinput"
    Option      "HighResolutionWheelScrolling" "off"
EndSection
```
plus `sudo usermod -aG video $USER`.
- 50-okular-md: `apt_install okular okular-extra-backends`; `xdg-mime default okularApplication_md.desktop text/markdown`.
- [x] Step 1: Write all ten files
- [x] Step 2: `bash -n modules/core/*.sh` — no output
- [x] Step 3: Commit `feat: core modules`

### Task 4: Extra modules + printer tool
**Files:** Create `modules/extra/{docker,xrdp,tailscale,printing-direct,weak-passwords,buildtools,usagemeter,splashtop}.sh`, `tools/add-printer.sh`
Load-bearing details:
- docker: docker.com keyring + apt repo, `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`, `usermod -aG docker`.
- xrdp: `apt_install xrdp xfce4 xfce4-goodies`; ensure startwm.sh sources `~/.profile` before Xsession exec (insert once, `grep -q` guard); enable xrdp.
- printing-direct: `systemctl disable --now cups-browsed` (+ mask option documented); NEXT STEPS points at `tools/add-printer.sh <Name> <ipp://host/ipp/print>` which runs `lpadmin -p NAME -E -v URI -m everywhere` after an `ipptool` reachability probe.
- weak-passwords: backs up `/etc/security/pwquality.conf` then writes all-zero policy; prints (does not apply) the optional GDM PAM root-guard removal.
- splashtop: stub — prints download URL + dpkg steps, records SKIPPED(manual).
- [x] Step 1: Write all nine files
- [x] Step 2: `bash -n` all — no output
- [x] Step 3: Commit `feat: extra modules and add-printer tool`

### Task 5: verify.sh + audit + README
**Files:** Create `verify.sh`, `audit/system-audit.sh` (copied from the private os-changes tracker — already generic), `README.md`
- verify.sh: read-only PASS/FAIL/SKIP on: node major=20, npm prefix, claude on PATH, bun, plugins present under `~/.claude/plugins/cache/{thedotmack,superpowers-marketplace}`, uv, gsettings values, xorg conf file (VM only), video group, per-extra service states when the extra's artifacts exist.
- README: quick start (`git clone … && ./bootstrap.sh` AND `curl -fsSL …/get.sh | bash -s --`), requirements, module tables, NEXT STEPS explanation, Splashtop manual section, re-run/upgrade discipline, "public but maintainer-only pushes" note.
- [x] Step 1: Write files; `bash -n verify.sh`
- [x] Step 2: Commit `feat: verify script, system audit tool, README`

### Task 6: Lint everything
- [x] Step 1: `bash -n` every `.sh` — expect silence
- [x] Step 2: `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable $(git ls-files '*.sh')` — fix all errors; warnings fixed or explicitly `# shellcheck disable=` with reason
- [x] Step 3: Re-run `./bootstrap.sh --list` smoke test
- [x] Step 4: Commit `chore: shellcheck fixes`

### Task 7: Publish
- [x] Step 1: `gh repo create claude-terminal --public --source . --push` (account trevorjordan1-gmail; fall back to https remote + `gh auth setup-git` if SSH push fails)
- [x] Step 2: `curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | head -5` — expect script header (proves the one-liner URL)
- [x] Step 3: Hand maintainer the test-box command

### Verification on the test VM (maintainer)
```bash
curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash
claude   # log in, exit
~/claude-terminal/bootstrap.sh          # picks up the two plugin modules
~/claude-terminal/verify.sh             # expect all PASS/SKIP, no FAIL
```
