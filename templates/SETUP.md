# SETUP — build this terminal's client workspace

**Audience: Claude Code, running on a fresh Claude Code Terminal, on adNET's own seat.**
The engineer points you here ("read ~/claude-terminal/templates/SETUP.md and set everything
up") after the bootstrap has run and the filled scratch template has been staged. Everything
you need is in the staged file — do not ask for keys or the client code.

## Preconditions (verify, don't assume)

1. `~/claude-terminal/` exists AND is current: run `cd ~/claude-terminal && git pull --ff-only`
   FIRST — the bootstrap clone does not auto-update, and a box built before a templates
   change won't have it. If this very file was missing until the pull, that was why.
2. **`~/Projects/.env` exists** — the engineer's scratch template, staged here because the
   permanent home doesn't exist yet. It carries `CLIENT_CODE`, `CLIENT_DOMAIN`, and every
   vendor key (DO / Cloudflare / GitHub / Wasabi / Healthchecks / restic). If it's missing,
   stop and say so — the accounts pass (onboarding stage 2) isn't done.
3. You are logged in on **adNET's Claude seat** (environment work carries no client data).
   At builder handoff this seat logs out and the builder signs in with theirs.

## The run

Load the staged env (`set -a; . ~/Projects/.env; set +a`) and derive everything from it.
Ask the engineer exactly ONE thing: **this terminal's builder — full name + email** (used
only for git author stamps; builders have NO GitHub accounts, the machine token pushes).

Then, in order:

1. **Workspace skeleton**
   - `~/Projects/<CLIENT_DOMAIN>/` — the platform folder and the launch root for all client
     work. Stamp into it, filling every `{{placeholder}}` from the env + what you know:
     - `CLAUDE.md` ← `templates/CLAUDE.platform.template.md`
     - `STATE.md` ← `templates/STATE.template.md` (all chunks ⬜ — flip only on VERIFIED)
     - `.env.example` — every name in the staged env, values as `CHANGE-ME`, one comment
       each on where it comes from / how it's scoped
     - `.gitignore` — `.env`, `os-changes` never applies here (it lives outside), and the
       nested app folders: `*.<CLIENT_DOMAIN>/` (each app is its OWN repo — the platform
       repo must never swallow one)
     - `scripts/` ← copy `templates/workspace-status.sh` (+ make executable)
   - `~/Projects/os-changes/` and `~/Projects/misc/` — create if missing (the launcher
     stamps their CLAUDE/README files; you may stamp them now using the same content).
2. **Move the keys home:** `mv ~/Projects/.env ~/Projects/<CLIENT_DOMAIN>/.env && chmod 600` —
   the staging copy must not remain. Remind the engineer to delete the Notepad++ scratch.
3. **Launcher:** install `templates/cc-launcher.sh` → `~/.local/bin/cc-launcher` (0755) and
   point the `cc` alias in `~/.bashrc`'s claude-terminal block at it (keep `phonecc` = tmux
   wrapper around the same). Log this in `~/Projects/os-changes/README.md` (new top row).
4. **Git + GitHub (machine identity — a NON-NEGOTIABLE):**
   - `git init` the platform folder; set `user.name`/`user.email` to the builder (local).
   - Local credential helper that feeds the machine token from the environment at push
     time — never store the token in any file git reads:
     `git config credential.helper '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_PAT"; }; f'`
   - Create the private repo `<GITHUB_ORG>/<CLIENT_DOMAIN>` (`GH_TOKEN="$GITHUB_PAT" gh repo create …`),
     wiki/projects off, Dependabot alerts on. Folder name == repo name == domain — the law.
   - First commit + push. **Run the pre-commit secret check before every commit** (it's in
     the platform CLAUDE.md; GitHub Free private repos have NO server-side net).
5. **Verify the pack empirically — probe WRITES, clean up after probes.** For each provider
   confirm the credential can do what the platform build will need (Guide §2–§6 has the
   click-paths; the Cloudflare lesson: a token can succeed on GET while holding no write
   permission at all). Any probe object you create, you delete, and confirm deleted.
6. **Close the loop:** update `STATE.md` (what exists now, what's verified, next = platform
   build), commit, push, then run `scripts/workspace-status.sh` — it must come back clean.
   Report to the engineer in plain language: what was built, what was verified, what's next.

## What you do NOT do here

- No droplet, DNS, tunnel, or any client-cloud resource — that is `PLATFORM-BUILD.md`,
  the next step, run from the workspace you just built.
- No changes to `~/claude-terminal` itself (version-pinned; updates come from upstream).
