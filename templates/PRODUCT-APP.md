# PRODUCT-APP — put an existing product on the client's platform

**Audience: Claude Code in `~/Projects/<CLIENT_DOMAIN>/`.** `NEW-APP.md` is for an app that is
*born* here. This is for one that already exists somewhere else and ships as an image from a
private registry: one codebase serving many clients, where only the compose file and the config are
per-client. The nine moves below are the platform's shape; everything else you need is in the
product's own repo.

**The law: the product's own deploy docs describe the box it was developed on, not this platform.**
Read them for what the product *is* — its env, its migrations, its endpoints. Do not take *how it
deploys* from them. A vendor's dev box has no platform Postgres, no Traefik, no tunnel and no
Access, so its compose file encodes assumptions that are wrong here, and following it produces a
deployment that looks right and sits outside everything the platform proves.

## Before you touch anything

- **Read the product's docs.** Whatever it has — README, architecture, handoff notes. You are
  after: what env it needs, whether it self-migrates, what it exposes, what it calls out to.
- **Prove the pull credential.** `docker login` the registry and pull the tag you intend to run.
  Do this first; a registry-auth failure three moves in looks like a platform problem.
- **Decide the hostnames and the front door for each** before writing labels (move 6).

## The nine moves

1. **Registry credential, in the right place.** The pull token belongs in the app's `.env` on the
   droplet, carried there via the pack. It authenticates *on the customer's behalf* — it is theirs
   to hold. A credential that authenticates **to the vendor** instead (filing issues, fetching
   private docs) is not: keep it terminal-local, outside `~/Projects/`, and pass it per command so
   the identity switch is visible where it happens rather than hidden in a config file. The
   convention, so two terminals do not invent two: `~/.config/adnet/<product>.env` (0600) holding
   `<PRODUCT>_ISSUES_TOKEN`, used as `GH_TOKEN="$<PRODUCT>_ISSUES_TOKEN" gh issue create -R <vendor>/<product> …`
   — never exported into the shell, never in the pack.

2. **Delete the product's database service.** Its compose almost certainly ships its own Postgres,
   because its dev box had none to share. This platform has exactly one instance with per-app
   isolated databases, and `platform-verify.sh` proves that isolation with negative tests. So:
   remove the service, `cd /opt/<CLIENT_CODE>/postgres && ./db-add.sh <app>`, point the connection
   string at the platform instance. A second Postgres sits outside both the proven walls and the
   backup set — and nothing will tell you, because it works.

3. **Publish no ports.** Its compose will bind loopback ports because that is how the vendor
   reaches it. Here Traefik routing labels do that job and the tunnel is the only ingress. Drop
   every `ports:` block.

4. **Pin an exact tag. Never `:latest`, and no auto-update.** This matters most when the image runs
   migrations at container start: a floating tag plus any unattended pull applies a schema change
   to live customer data at a moment nobody chose. Pinned, "what schema is this client on?" is a
   fact you read out of a file. **The pack carries that fact:** `<PRODUCT>_IMAGE=ghcr.io/<org>/<product>:<tag>`,
   written at the accounts pass and updated by whoever cuts each release — the pull token can
   pull but cannot list packages or read the vendor repo, so the current tag is not discoverable
   from this box (field-hit: it took the issues token's repo read to find it).

5. **Snapshot before any release that carries migrations.** `IF NOT EXISTS`-safe means
   **re-runnable, not reversible** — an easy sentence to misread. Nothing in a forward-only
   migration set undoes itself, so rollback is: restore the dump, re-pin the previous tag. The
   nightly backup covers yesterday, not the ten minutes you are migrating through.

6. **One app per front door.** A product with an identity-gated UI *and* a token-authenticated
   ingest endpoint is two apps here, not one compose file. Give each its own folder: different
   labels, different hostnames, and different release cadences — the UI ships often, the ingest
   path almost never, and one file means every UI update restarts ingest for nothing.
   **Never put an Access app in front of a bearer-token endpoint.** Bearer clients cannot answer an
   identity challenge, so it does not degrade — it breaks every sender.

7. **Parameterise the product's health monitor.** If it ships one, its defaults name the vendor's
   own container and database. Left alone here it probes things that do not exist and reports
   failures that are pure misconfiguration — which reads as a broken platform and costs an hour.

8. **Look for silent egress defaults.** A catalog, telemetry or licence URL that defaults to the
   vendor's own host is a cross-tenant call *out of the customer's platform*. Sometimes that is
   exactly what you want. Set it deliberately either way, because it is invisible until someone
   asks where the customer's traffic goes.

9. **Verify the version that is running, not the one you asked for.** If the product exposes a
   version or health endpoint, the acceptance test is that endpoint reporting your pinned tag —
   not the tag you typed into compose, and not the image name `docker inspect` shows. Those are
   three different facts and only the first one is the app's own answer.

## Done means

- the app answers on its hostname through the tunnel, with the front door move 6 chose, and the
  droplet's own `:80`/`:443` still time out from outside
- a token-authenticated endpoint, if there is one, gives **401 without** and **200 with** the
  token, proven **from outside** the droplet
- its version endpoint reports the tag you pinned
- it has its own monitoring check, and it appears in a nightly restore-verify — confirmed, not
  assumed from move 2 having created the database
- the product's own docs told you what it is; this file told you how it lives here. If the two
  disagreed, this file won.
