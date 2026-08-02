# NEW-APP — mint the next app on the client's platform

**Audience: Claude Code in `~/Projects/<CLIENT_DOMAIN>/`.** The builder says "I want an app
that does X" — this is how X is born. The status page was built exactly this way; every
app after it follows the same nine moves. Nothing here needs a human except the idea.

**The law: folder name == repo name == subdomain.** Pick `<app>` short and lowercase →
`<app>.<CLIENT_DOMAIN>/` here, `<GITHUB_ORG>/<app>.<CLIENT_DOMAIN>` on GitHub, live at
`https://<app>.<CLIENT_DOMAIN>`.

## Before writing code

Write the brief WITH the builder (greenfield discipline — the plan exists before the code):
problem · users · data model · what stays out of scope. It becomes the top of the app's
ARCHITECTURE.md. Default stack unless the brief demands otherwise: our standard container
shape on the droplet, Postgres if it needs a database, the built frontend served by its own
backend.

**The auth decision is part of the brief** — one line, decided here, wired by you:
- **Pattern A (default):** internal tool, client's authenticating users fit Access's free
  tier (≤50) → no auth code in the app; Cloudflare Access + the client's Entra IdP gate the
  hostname (move 6 covers it).
- **Pattern B:** external/customer users, >50 users, or per-user roles inside the app →
  the ONE `<code>-sso` registration extends (never a new registration): add the redirect
  URI `https://<app>.<CLIENT_DOMAIN>/auth/callback` + mint a per-app secret labeled
  `<app>` (12 months) — self-serve via Graph with the registration's own credentials
  (`Application.ReadWrite.OwnedBy`; verify on first use) or dictate the exact values for a
  60-second tenant-holder click. Secret → the app's droplet `.env`, expiry → STATE.md. In
  the app: the stack's standard OIDC library (auth-code + PKCE) — never hand-rolled token
  validation. Access may stay in front too.
- Google-workspace clients: not productized yet — stop and flag it.

## The nine moves

1. **Folder + repo:** `~/Projects/<CLIENT_DOMAIN>/<app>.<CLIENT_DOMAIN>/` (the platform
   repo's `.gitignore` already excludes it — it is its OWN repo). Stamp its `CLAUDE.md`
   from `templates/CLAUDE.app.template.md` + an `ARCHITECTURE.md` from the brief. git init,
   same machine-identity credential helper + builder author stamp as the platform repo,
   private repo in `<GITHUB_ORG>`, wiki/projects off, Dependabot alerts on.
2. **CI from day one:** copy `templates/tool-ci.yml` → `.github/workflows/ci.yml`, fill the
   real test step. First push must go green before anything deploys. Dockerfile trap
   (field-hit): `node:*-slim` runtime stages ship npm/corepack with vulnerable bundled deps
   that fail the Trivy gate — build in a builder stage, copy artifacts only, and strip the
   package managers from the final image:
   `RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn*`
   The app's `scripts/deploy.sh` comes from `templates/deploy.app.template` — the
   dual-path deploy (pull the CI image from GHCR; if the PAT lacks Packages, ship the
   CI-green tree and build the identical tag on the droplet — CI stays the record either
   way), ending with the Access-challenge + probe-token verification.
3. **Database (if needed):** on the droplet, `cd /opt/<CLIENT_CODE>/postgres &&
   ./db-add.sh <app>` — the printed `DATABASE_URL` goes ONLY into the app's droplet `.env`
   (0600). Never reuse another app's database or credentials.
4. **Network:** `docker network create <app>-net`, then declare it `external: true` in
   THREE compose files — the app's own, `postgres/docker-compose.yml`, and
   `edge/docker-compose.yml` (Traefik's service networks) — and `up -d` each. Each app-net
   holds exactly {app, traefik, postgres}. Apps never share a network, never join `edge`.
5. **Routing labels** (nothing routes without them — `exposedByDefault: false`):
   `traefik.enable=true` · `traefik.docker.network=<app>-net` ·
   `` traefik.http.routers.<app>.rule=Host(`<app>.<CLIENT_DOMAIN>`) `` ·
   entrypoint `web` · loadbalancer port = the container port. **No `ports:` mapping, ever.**
6. **DNS + Access:** proxied CNAME `<app>` → `<TUNNEL_ID>.cfargotunnel.com` (the tunnel
   config itself never changes) + a Cloudflare Access application for the hostname with
   the standard policy: **allow `@CLIENT_STAFF_DOMAIN` + `@<tenant>.onmicrosoft.com`,
   nothing else** (no personal adNET emails — they can't use the client-tenant IdP), plus
   the Service Auth policy for the probe token. Public hostnames require real auth in the
   app first.
7. **Backups join automatically:** the app's droplet folder + named volumes land in the
   nightly restic scope (`/opt/<CLIENT_CODE>` + volumes). If the app stores uploads,
   confirm its volume is in the backup include list — DB dumps do NOT carry files (the
   photos lesson).
8. **Monitoring:** create the app's Healthchecks check; the droplet cron curls the PUBLIC
   URL (edge failures alert too) and pings on success. Container healthcheck on an ungated
   `/healthz`.
9. **Prove + record:** deploy (pull the CI image or build on the droplet per the app's
   deploy.sh) → live URL verified through Access → `db-verify-isolation.sh` still passes
   with the new tenant → STATE.md live-components table + repo list updated → full chain
   green → tell the builder, in their language, where their app lives.
