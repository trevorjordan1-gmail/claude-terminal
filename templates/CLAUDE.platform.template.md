# CLAUDE.md — {{CLIENT_NAME}} platform ({{CLIENT_DOMAIN}})

<!--
Stamped by SETUP.md from claude-terminal templates/. Fill every {{placeholder}} from the
terminal's .env + the engagement facts. This file is a LIVING DOCUMENT with one fence:
the NON-NEGOTIABLES block is adNET's platform contract — everything below "House rules"
is the client's to shape, and Claude edits it freely when the builder asks.
-->

**The platform folder and launch root for all {{CLIENT_NAME}} work.** Every app runs as its
own Docker container on `docker01.{{CLIENT_DOMAIN}}`, the client's own droplet in the
client's own cloud account. This folder owns the box, the edge, the database, the backups,
and the recipe for new apps. Loaded at the start of every `cc` session rooted here.

> ✅ **Right folder for:** the droplet, DNS, tunnel, Traefik, Postgres, backups, credentials,
> standing up a new app, and any question about "the platform."
>
> ❌ **App behavior lives with the app:** each app is a subfolder here —
> `{{app}}.{{CLIENT_DOMAIN}}/` — with its OWN repo and OWN CLAUDE.md. For "change a page /
> a query / a feature," work in that subfolder (its contract loads automatically).

## Resume point (auto-loaded)

@STATE.md

---

## ⛔ NON-NEGOTIABLES (adNET platform contract — do not weaken; flag any conflict)

1. **The client owns everything.** Accounts, domain, repos, droplet, data — all in
   {{CLIENT_NAME}}'s name. Never create a resource under any other identity.
2. **Never commit secrets.** Real values live in `.env` files (0600) — this folder's `.env`
   on the terminal, per-app `.env` on the droplet. `.env.example` documents names only.
   Run the pre-commit check below before EVERY commit: GitHub Free private repos have no
   server-side secret scanning. This check is the only net.
3. **No builder GitHub accounts.** All pushes authenticate as the machine account
   ({{GITHUB_ORG}} org token, fed from the environment at push time); commits are
   author-stamped with the builder's own name/email. Never `gh auth login`, never store a
   token where git can read it from disk.
4. **The full chain, every change:** edit → commit (clear message, plain git, straight to
   `main`) → push → **watch CI to green** (`GH_TOKEN="$GITHUB_PAT" gh run watch`) → deploy →
   verify the live URL → report in plain language. Commit and deploy are implied, never
   asked about. **Nothing lingers:** run `scripts/workspace-status.sh` at every session
   START and CLOSE; anything dirty, unpushed, or red gets finished or reverted before new
   work.
5. **Zero inbound web ports.** Traffic arrives ONLY via the Cloudflare tunnel → Traefik.
   Never add a `ports:` mapping. SSH is gated at the **DigitalOcean cloud firewall** to the
   build box's IP — do NOT install UFW (Docker's DOCKER-USER chain bypasses it; the cloud
   firewall filters upstream where Docker can't).
6. **Per-app isolation:** own Postgres database + login (`REVOKE CONNECT FROM PUBLIC`), own
   Docker network with only Traefik + Postgres bridged in (declared `external:` in every
   compose file that uses it), own repo, own droplet `.env`. Apps never share a network.
7. **Backup before anything destructive** (drops, renames, type changes, deletes) — and an
   untested backup is a hope, not a backup: restore-verify stays automated and green.
8. **Pin every image tag; prune on every deploy.** Never `latest`.
9. **Verify empirically.** Probe writes, not reads; trust refusals, not success messages;
   clean up probe objects and confirm the deletion. Flip STATE.md items to ✅ only on
   verified, never on attempted.
10. **The builder never touches git, the droplet, or internals.** You own the mechanics
    end to end and explain outcomes in plain language — no git/PR/CI jargon in conversation.

**Pre-commit secret check** (run inside the repo being committed):
```bash
set -a; . {{PLATFORM_DIR}}/.env; set +a
git add -A
git diff --cached --name-only | grep -x '.env' && { echo "ABORT: .env staged"; exit 1; }
git diff --cached | grep -qE "$(printf '%s' "$CLOUDFLARE_API_TOKEN" | head -c 32)|$(printf '%s' "$GITHUB_PAT" | head -c 32)|gh[pousr]_[A-Za-z0-9]{16,}|dop_v1_[a-f0-9]{40,}|github_pat_[A-Za-z0-9_]{20,}" \
  && { echo "ABORT: live secret in staged diff"; exit 1; }
```

---

## House rules (the client's section — shape it as you go)

<!-- Claude: when the builder says "from now on, do it this way," record it HERE with the
     date. This section is expected to grow. It may refine but never override the
     non-negotiables above — if a request conflicts, say so and offer the closest safe
     version. -->

- {{House rules accumulate here — working hours for deploys, naming tastes, who to CC,
  review preferences, app-specific customs.}}

## The workspace

```
~/Projects/
├── {{CLIENT_DOMAIN}}/          ← YOU ARE HERE — platform repo + launch root (cc lands here)
│   ├── CLAUDE.md · STATE.md    contract + living resume point
│   ├── .env                    the pack (0600, never committed)
│   ├── scripts/                workspace-status.sh + platform helpers
│   ├── edge/ · postgres/       platform stacks (arrive at PLATFORM BUILD; droplet copies
│   │                           live at /opt/{{CLIENT_CODE}}/…)
│   └── <app>.{{CLIENT_DOMAIN}}/  one folder PER APP — each its OWN repo (gitignored here)
├── os-changes/                 THIS machine's change log — LOCAL ONLY, never GitHub
└── misc/                       research & scratch — one subfolder per project, local only
```

- New app? Follow `~/claude-terminal/templates/NEW-APP.md` — repo in {{GITHUB_ORG}}, CI from
  day one, container on docker01, tunnel hostname + Access, backup hook, Healthchecks check,
  STATE.md entry. Folder name == repo name == subdomain, always.
- OS-level change on this terminal? Log it in `~/Projects/os-changes/README.md` (top row,
  with how to undo it).

## Stack

{{One paragraph once PLATFORM-BUILD completes: droplet size/region · Docker+Compose ·
Cloudflare tunnel (catch-all → Traefik) + Access · shared Postgres, db-per-app ·
Healthchecks.io monitoring + status.{{CLIENT_DOMAIN}} · restic → Wasabi nightly with
automated restore-verify. Until then: "platform not yet built — see STATE.md."}}

**This terminal** ({{HOSTNAME}}): the builder's Claude Code Terminal — no Docker here;
builds and containers run on the droplet. Environment work ran on adNET's seat;
{{after handoff:}} this terminal runs on {{BUILDER_NAME}}'s seat, commits stamped
`{{BUILDER_NAME}} <{{BUILDER_EMAIL}}>`.

## Reaching the droplet

{{Filled at PLATFORM BUILD: ssh key path, `ssh {{CLIENT_CODE}}-docker01` alias, the
sudo -n bash -s pattern, "never docker exec -i in a piped script".}}

## What requires a human (verified limits — don't retry these)

- Creating a GitHub organization (no API exists) · Cloudflare Zero Trust bootstrap +
  domain registration (dashboard-once) · minting/rotating the vendor tokens (dashboard;
  identify CF tokens by ID, never name) · Splashtop deployment package + builder invites ·
  anything on the client's card.
