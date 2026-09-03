# PLATFORM BUILD — stand up the client's entire platform

**Audience: Claude Code, launched via `cc` into `~/Projects/<CLIENT_DOMAIN>/` on adNET's
seat, AFTER SETUP.md completed** (workspace exists, pack verified writes-probed). This run
builds onboarding **stage 4** end to end. Work in order; every step ends with its own
proof; flip the STATE.md item only on the proof. **Zero questions is the standard** (the
engineer's rule: installs ask nothing): the pack pre-answers everything a build otherwise
asks — `DROPLET_SIZE` (its presence IS the spend authorisation), `CLIENT_LOCATION`,
`SSO_AT_BUILD`, `ENGAGEMENT`. Ask exactly once, only for a field the pack lacks, and record
the answer in STATE.md so the next terminal does not ask again.

**End state:** a hardened droplet whose only open port is SSH from THIS build box's IP,
serving `status.<CLIENT_DOMAIN>` over the tunnel behind Cloudflare Access, with isolated
Postgres, monitoring that alerts on silence, and encrypted offsite backups whose restore
is verified nightly. Then `platform-verify.sh` must pass, and its report goes to the
engineer.

Throughout: load the pack per-invocation (`set -a; . ./.env; set +a`); pin every image
tag; clean up every probe object and confirm the deletion; record each component in
STATE.md as it goes live, with IDs. **One stdin per remote command** (field-hit): heredoc
OR pipe, never both — `archive | ssh 'bash -s' <<EOF` silently loses the pipe; ship
archives as files (scp) and never `docker exec -i` inside a piped script.

**Droplet layout — stated once, used everywhere:** `/opt/<CLIENT_CODE>/{edge,postgres,backup,scripts}/`
for the platform pieces, `/opt/<CLIENT_CODE>/<app>.<CLIENT_DOMAIN>/` per app (NEW-APP /
PRODUCT-APP). `platform-verify.sh` expects `postgres/db-verify-isolation.sh` and
`backup/restic-snapshots-age.sh` at exactly those paths.

## 1 · Droplet — `docker01.<CLIENT_DOMAIN>`

- Create via `doctl … -t "$DO_API_KEY"` (the kit's base module installs doctl; if it is
  missing, re-run `get.sh` — do not improvise with the API): Ubuntu 24.04 LTS, **size =
  `DROPLET_SIZE` from the pack** (e.g. `s-2vcpu-4gb`; its presence is the pre-authorised
  spend — absent → ask once, record the answer; resize later is cheap),
  **region = nearest to `CLIENT_LOCATION`** from the pack (unset → **`nyc3`**, the
  operator default — the field exists for the exceptions, #17), no
  IPv6, **daily DO backups ON at creation** (hour must be 0/4/8/12/16/20 UTC — remember the
  window when scheduling droplet crons later; terminal jobs follow §6's scheduling
  contract instead), monitoring agent, the terminal's SSH key (generate
  ed25519 here if none; passphrase-less is deliberate — 0600 + firewall are the controls).
- Harden immediately, before anything else touches it: non-root sudo user
  `<CLIENT_CODE>` (NOPASSWD — non-interactive deploys; key already grants root-equivalent),
  sshd drop-in named `00-*.conf` (root login off, password auth off, AllowUsers — Ubuntu
  24.04 includes are alphabetical and FIRST value wins; apply behind a self-revert timer,
  confirm with `sshd -T`, restart `ssh.socket` not just the service), fail2ban
  (`backend = systemd`), auditd, 4GB swap, unattended security upgrades. Break-glass: set a
  sudo password, generated here, only its hash ever leaves the terminal → Hudu, usable only
  at the DO web console. **Reboot and re-verify all of it.**
- **DO Cloud Firewall** (NOT UFW — non-negotiable #5): inbound TCP 22 from THIS build box's
  egress IP only (`curl -s ifconfig.me`). **On a cloud terminal (`/etc/asp-terminal.env`
  present) the box's own egress IS the answer — nothing to confirm**; only a terminal on
  someone's LAN needs the engineer to confirm it is the office/site egress. Outbound ALL
  TCP+UDP+ICMP (a DO firewall denies outbound by default —
  cloudflared must dial out or every site dies).
  **Proof:** a published test port times out from here (dropped upstream) vs connection-
  refused before attachment; SSH still works; then remove the test publish.
- Docker Engine + Compose from Docker's apt repo; `daemon.json`: log rotation
  (10MB×3) + `live-restore: true`; weekly conservative prune timer (no `-a`, keep-storage);
  DO alerts: disk >80%, mem >90%, CPU >90% → `CLIENT_ALERT_EMAILS`. **DO alert policies
  accept only verified DO team members' addresses** (`email is not verified` otherwise,
  field-hit), so the operator's alerts mailbox reaches DO alerts only if it was invited to
  the client's DO team at the accounts pass. If it was not: route DO alerts to the client
  contact alone, say so in STATE.md, and do not stall — Healthchecks is the operator's
  vantage on this platform anyway.
- No public DNS record for the droplet — SSH by IP/alias; web traffic arrives by tunnel.

## 2 · Edge — tunnel (set-once) + Traefik

Ship `edge/` from this folder to `/opt/<CLIENT_CODE>/edge` (tar over ssh, `.env` excluded —
the droplet's `.env` is authoritative for its secrets):

- **Tunnel `<CLIENT_CODE>-edge`** created via the CF API, remotely-managed, ingress =
  a single **catch-all → `http://edge-traefik:80`** — set once, never touched again; every
  future app is just a DNS record + Traefik labels.
- **Traefik**: `exposedByDefault: false`; api/dashboard off; `/ping` on an internal-only
  entrypoint; **`forwardedHeaders.trustedIPs` scoped to the tunnel network's subnet** (or
  apps see `X-Forwarded-Proto: http` and break secure cookies — the pilot's subtle one).
- **Three networks:** `tunnel` (cloudflared ↔ Traefik only — NOT `internal:`, cloudflared
  must dial out), `edge` (external; **Traefik's home base only — apps NEVER join it**;
  Traefik reaches each app over that app's own `<app>-net`, declared per NEW-APP move 4),
  `socket` (`internal: true`; Traefik reads Docker labels via a socket-proxy allowing only
  CONTAINERS/EVENTS/PING/VERSION — Traefik never touches the raw socket).
- No `ports:` anywhere in any compose file, ever.
- **Proof:** temporary `edge-test.<CLIENT_DOMAIN>` proxied CNAME + whoami container → HTTP
  200 over real HTTPS from outside; simultaneously ports 80/443 on the droplet IP time out;
  host listens on `:22` only. Tear the test down (DNS + container), confirm gone.

## 3 · Cloudflare Access on every app hostname

Access application per hostname (`status.<CLIENT_DOMAIN>` now; NEW-APP adds one per app):

- **IdP — `SSO_AT_BUILD` from the pack decides, no question asked:** `yes` → mint the
  `<CLIENT_CODE>-sso` registration HERE if the pack lacks `ENTRA_*` (a step of this run,
  not separate homework); `otp` → ship email-OTP policies now and let ENTRA-SSO.md step 2
  flip them when the values land; absent → ask once, record the answer. For a tenant we
  can admin, run
  `python3 ~/claude-terminal/templates/entra-sso/provision-sso.py --pack <workspace>/.env --confirm`
  — ONE sign-in: it prints the plan, takes a typed `APPLY`, and writes with the same
  token (dry-run then `--apply` cost two Global-Admin sign-ins within minutes, field-hit).
  It builds the one-per-client registration with the REAL `TEAM_DOMAIN` callback (+ the
  aiops mail rider unless the pack says `MAIL_CAPABILITY=none`) and writes `ENTRA_*`
  straight into the pack; the single human act is the engineer opening the printed
  sign-in link **from their own device** (ENTRA-SSO.md relay discipline: admin
  credentials never touch the box, token only in the process). *Where that sign-in
  should physically happen is under review — see issue #32 item 4.*
  Then wire the Entra login method into Zero Trust (API) and the policies allow the
  client's staff via Entra: `@CLIENT_STAFF_DOMAIN` + `@<tenant>.onmicrosoft.com`, nothing
  else (no personal adNET emails) — normal M365 sign-in, MFA applies, Entra offboarding
  kills access. **External IT holds the tenant and hasn't replied: do NOT block the
  build** — ship email-OTP policies on `CLIENT_STAFF_DOMAIN`, note it in STATE.md, and
  ENTRA-SSO.md step 2 flips them when the values land (field-proven). Keep OTP enabled as
  adNET's break-glass either way.
- **The headless proof, standardized:** mint the Access **service token**
  `<CLIENT_CODE>-cct01-probe` (needs `Access: Service Tokens Edit` on the CF token) + a
  Service Auth policy on each app; append `ACCESS_PROBE_CLIENT_ID`/`ACCESS_PROBE_CLIENT_SECRET`
  to the workspace `.env`. Every deploy and the verification battery can then assert
  **authenticated → 200** with headers, no human OTP login ever needed.
- **Proof:** unauthenticated request → Access challenge; request with the probe token's
  `CF-Access-Client-Id`/`CF-Access-Client-Secret` headers → 200. Service tokens never
  touch the IdP (no OIDC redirect, no reply-URL check, #18) — the *interactive* staff
  login is proven at ENTRA-SSO step 2 and re-asserted by §7's HUMAN GATE line.

## 4 · Postgres — one instance, walls proven

Ship `postgres/` → `/opt/<CLIENT_CODE>/postgres`: pinned Debian-family image (collation —
never Alpine for a database), **`--data-checksums` at initdb** (init-only, can't retrofit),
no host port, `data` network, modest shared-box tuning, `01-harden.sql` (REVOKE CONNECT on
postgres/template1 from PUBLIC) — runs once on empty PGDATA only.
- **PGDATA on `postgres:18+`:** the image moved the data directory to
  `/var/lib/postgresql/<major>/docker`. Mount the **parent** `/var/lib/postgresql` as the
  volume, or a major bump silently starts an empty cluster beside the real data.
- `db-add.sh <app>` mints an isolated db + login (own schema, password printed once →
  droplet app `.env` only). `db-verify-isolation.sh` asserts the negatives from a separate
  client container over the network: wrong-db connect REFUSED, `pg_authid` REFUSED,
  CREATE DATABASE refused, cross-app network route DEAD.
- **Proof:** the isolation script passes with zero leftovers (only `postgres` db, no app
  roles, no probe networks).

## 5 · Monitoring — silence alerts (Healthchecks.io) + the status app

- Via `$HEALTHCHECKS_API_KEY` create one check per system: each site (curled via its
  PUBLIC URL from the droplet cron — edge failures alert too), each backup job,
  restore-verify, disk/containers, status-page-up. Success-ping only; silence past grace →
  email (down + recovery). **Bind the two email integrations pre-created at the accounts
  pass** (`CLIENT_ALERT_EMAILS` contact + `ADNET_ALERTS_MAILBOX`) to every check via the
  API — channels can't be API-created, but binding them can; alerting is complete today,
  not homework. `pack-verify.sh` FAILs when fewer than two email channels exist; if you
  still find one, bind what exists, write the missing channel into STATE.md's next
  actions as an accounts-pass gap, and never invent a channel.
- **`status.<CLIENT_DOMAIN>`** — the platform's first container, scaffolded exactly as
  NEW-APP.md prescribes (own repo `<GITHUB_ORG>/status.<CLIENT_DOMAIN>`, own net/db-less,
  CI from day one, Access-gated hostname): a tiny page reading the Healthchecks
  **read-only** key every minute — overall banner, checks grouped by tag, last-ping ages,
  client-branded. Engine off-box, display on-box; it pings its own check.
- **Proof:** all checks green; then a deliberate **silent-alarm test** — suspend one cron
  and wait out the FULL silence window (check period + grace; set the drill check to
  period 1m / grace 3m so the wait is ~4 minutes — restarting one minute early voids the
  drill), watch the alert actually arrive, restore, watch recovery arrive.

## 6 · Backups — restic → Wasabi, restore verified nightly

- Via the root Wasabi keys create bucket `<CLIENT_CODE>-backups` + IAM sub-user
  `restic-<CLIENT_CODE>` scoped to that bucket; sub-user keys land in the droplet's backup
  `.env`; **root keys never land in runtime config**.
- Ship `backup/` → `/opt/<CLIENT_CODE>/backup/`: the droplet's backup `.env` (restic
  sub-user keys — never the root Wasabi keys), the backup + restore-verify scripts, and
  **`templates/restic-snapshots-age.sh`** — the helper `platform-verify.sh` §5 calls by
  that path (FRESH/STALE/NONE from `restic snapshots`, the ground truth for "did it run").
- Nightly (staggered off the DO backup window): droplet — per-app `pg_dump` + every app
  volume + `/opt/<CLIENT_CODE>` configs → restic repo (RESTIC_PASSWORD_DOCKER01); this
  terminal — home directory → its own repo path (RESTIC_PASSWORD_CCT). 7d/4w/6m retention.
  Each job pings its check on success **and `/fail` on error** — a job that runs but never
  pings is the worst of both: the check says DOWN while snapshots are fine, and someone
  answers the wrong emergency (field-hit: 12 days). A DOWN check is triaged as
  *monitoring vs backup* — `restic snapshots` decides which.
- **Scheduling contract (#16) — where a job lives decides how it is scheduled.** On the
  **droplet** (always-on): cron is fine, as used throughout this playbook. On a
  **terminal**: NEVER a timed crontab entry — the box hibernates more than it runs, plain
  cron has no catch-up, so `45 3 * * *` silently skips and nothing alerts, because nothing
  ran (field-hit: a terminal restic job missed two nights unnoticed). anacron covers only
  `/etc/cron.daily|weekly|monthly`. Terminal jobs are **systemd timers with
  `Persistent=true`** — copy `asp-backup.timer`'s shape; missed runs then fire on the next
  wake. Either way the job pings a Healthchecks check: the silence alert is the only thing
  that catches "never ran" (§5's silent-alarm instinct — alert on staleness, not only on
  error). The kit's `verify.sh` FAILs local calendar timers without `Persistent=true` and
  timed crontab entries on terminals.
  **When the job must NOT run during a wake, use a monotonic timer instead**
  (`OnBootSec=` + `OnUnitActiveSec=`, no `OnCalendar`, and therefore no
  `Persistent=`). `Persistent=true` fires its catch-up the *instant* a box
  resumes — exactly when the user is connecting — so it is the wrong shape for
  anything destructive. The platform's own `asp-auto-update.timer` is monotonic
  for precisely this reason: as a `Persistent=true` calendar timer it restarted
  `dcvserver` under a live session on resume and destroyed the user's desktop
  (2026-09-01). A monotonic timer polls only while the box is awake, so it needs
  no catch-up at all, and `verify.sh` does not police it — that check gates on
  `TimersCalendar`, so a timer with no `OnCalendar` is exempt by construction.
  Do not "fix" such a timer back to `Persistent=true`.
- **Nightly restore-verify:** restore the latest snapshot into a scratch container,
  integrity-check (row counts / restic check), ping its own check.
- **Proof:** run one full manual drill now — restore, verify content, tear down — and one
  deliberate backup-failure test (break it, see the silence alert, fix it).

## 7 · Verify everything — `platform-verify.sh`

**Generated-secrets rule, throughout the build AND every later deploy on this platform:**
anything you mint that has no template home (the break-glass console password, meta
connection strings) goes into ONE file — `HANDOFF-TO-HUDU.md` (0600) in the workspace —
**append-only, never recreated.** A multi-stage engagement mints in batches (platform build:
break-glass, postgres, Entra secret; a later product deploy: its KEK, upload key, telemetry
bearer), so the file outlives its first sweep. Each entry is a **ready-to-paste Hudu
record** with a checkbox and a batch stamp:

```
- [ ] swept · batch <YYYY-MM-DD> · Entry name: … / Username: … / Password: … / Notes: … / Runtime home: …
```

`Runtime home` is mandatory — where the value also lives on the platform (e.g.
`/opt/<code>/postgres/.env`, "nowhere else" if truly nowhere): it is the recovery path when
a sweep goes wrong. The engineer ticks each box as they vault the entry. **Deletion rule:
the file is deleted only when every box is ticked — never on a whole-file statement.**
("I have the handoff copied off" once meant batch 1; batch 2 sat unswept beneath it and was
deleted with it — recovered only because every entry had a runtime home.) Name = what it
unlocks + where it's used; notes = where the credential works, when it was set, and the
rotate-after-use rule. The break-glass entry, exactly:
`docker01.<CLIENT_DOMAIN> — break-glass console (<user>)`, username = the sudo user,
notes = "Emergency console access for docker01.<CLIENT_DOMAIN> (DO droplet <id>). Works
ONLY at the DigitalOcean web console — SSH password auth and root login are disabled.
Log in as <user>, then sudo -i. Set at platform build <date>; only its hash ever touched
the droplet. If used: record why, then rotate (passwd <user>) and update this entry."
The engineer sweeps entries into the client's "Ai Foundations" folder, ticking each; the
file goes only when every entry is ticked. No ad-hoc parking spots.

Commit any previous `PLATFORM-VERIFICATION.md` first (uncommitted evidence rightly trips
the lingering-work sweep), then run `scripts/platform-verify.sh`. It re-proves the battery
from the outside in and writes `PLATFORM-VERIFICATION.md` with raw outputs. **The engineer
reviews that report — that's the human gate.** Update STATE.md: stage-4 ✅ with date, live
components table filled, verified-at-close table = the battery results. Commit, push, CI
green, `workspace-status.sh` clean. Report to the engineer in plain language.
