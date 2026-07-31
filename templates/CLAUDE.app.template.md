# CLAUDE.md — {{APP NAME}}

<!--
Stamped by NEW-APP. Platform rules are pre-filled; write Stack / Map / Auth / Data model
fresh for THIS app once it's scoped — never force-fit another app's shape. This file is
living: refine it as the app evolves (the platform contract one level up still governs).
-->

{{One line: what the app does}}, **live at https://{{app}}.{{CLIENT_DOMAIN}}** (behind
Cloudflare Access). Runs as its own container on `docker01.{{CLIENT_DOMAIN}}`.

> ✅ **Right folder for {{app}} work** — its code, schema, routes, deploys.
>
> ❌ **Platform work lives one level up** (`~/Projects/{{CLIENT_DOMAIN}}/`): droplet, DNS,
> tunnel, Traefik, Postgres itself, backups, credentials. Sessions launched from the
> platform root load both contracts automatically.

## Ground rules (the platform contract, restated thin)

{{BUILDER_NAME}} owns this app — no dev team, no review queue:
**change → test → validate → repeat**, and always the **full chain as one motion**:
edit → commit (plain git, straight to `main`, clear message) → push → **CI green**
(`GH_TOKEN="$GITHUB_PAT" gh run watch`) → deploy → verify the live URL → plain-language
report. A red run gets fixed or reverted in the same session — nothing lingers.

- **Deploy:** `scripts/deploy.sh` — one command, idempotent: {{pull the CI image | ship
  the tree + build on the droplet}} → recreate container → wait for health → prune →
  verify `https://{{app}}.{{CLIENT_DOMAIN}}`.
- **Schema changes:** {{migration tool + command}}; versioned migration files committed.
  **Backup before anything destructive** — drops, renames, type changes.
- **Secrets:** never in git. Runtime values live in `/opt/{{CLIENT_CODE}}/{{app}}/.env`
  (0600) on the droplet; `.env.example` documents names. Pre-commit check before every
  commit (no server-side scanning on Free private repos).
- {{If the app has operator-editable content: name what the client changes in the live
  UI (no deploy) vs what is code.}}

## Platform constraints this app must respect

Own Postgres db + login ({{app}}) · own external network `{{app}}-net` (only Traefik +
Postgres bridged in; declared in three compose files; never join `edge`, never share with
another app) · **no `ports:` mapping** (tunnel + Traefik only) · pinned image tags ·
prune on every deploy · DNS + Access managed from the platform folder, not here.

## Stack
{{Framework + versions · build vs run location · external integrations · anything
encrypted at rest and where its key lives.}}

## Map
{{Routes, key files, jobs — enough that a cold session navigates without rediscovery.}}

## Auth model
{{Who signs in and how; what Access gates vs what the app gates; public paths if any —
public requires real auth, not obscurity.}}

## Data model
{{Core entities + relationships; fields with special handling. If ANY operator-sees-all /
user-sees-own shape exists, state the scoping rule here as a standing rule — every
user-facing query scopes by {{tenant field}} + authz.}}

## Provenance & open items ({{DATE}})
{{Born via NEW-APP from the {{date}} brief | rescued from {{platform}} — dumps/rows/
verification. Open items with owners.}}
