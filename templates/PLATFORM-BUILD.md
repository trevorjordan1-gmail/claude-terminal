# PLATFORM BUILD — stand up the client's entire platform

**Audience: Claude Code, launched via `cc` into `~/Projects/<CLIENT_DOMAIN>/` on adNET's
seat, AFTER SETUP.md completed** (workspace exists, pack verified writes-probed). This run
builds onboarding **stage 4** end to end. Work in order; every step ends with its own
proof; flip the STATE.md item only on the proof. Confirm with the engineer before anything
that costs money (droplet create) — nothing else needs a human.

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

## 1 · Droplet — `docker01.<CLIENT_DOMAIN>`

- Create via `doctl … -t "$DO_API_KEY"`: Ubuntu 24.04 LTS, ~4GB/2vCPU (resize later),
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
  egress IP only (`curl -s ifconfig.me`, confirm with the engineer it's the office/site
  egress); outbound ALL TCP+UDP+ICMP (a DO firewall denies outbound by default —
  cloudflared must dial out or every site dies).
  **Proof:** a published test port times out from here (dropped upstream) vs connection-
  refused before attachment; SSH still works; then remove the test publish.
- Docker Engine + Compose from Docker's apt repo; `daemon.json`: log rotation
  (10MB×3) + `live-restore: true`; weekly conservative prune timer (no `-a`, keep-storage);
  DO alerts: disk >80%, mem >90%, CPU >90% → the client contact + adNET alerts mailbox.
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

- **IdP — mint the `<CLIENT_CODE>-sso` registration HERE if the pack lacks `ENTRA_*`**
  (it's a step of this run, not separate homework): for a tenant we can admin, run
  `python3 ~/claude-terminal/templates/entra-sso/provision-sso.py --pack <workspace>/.env`
  (dry-run) then `--apply` — it builds the one-per-client registration with the REAL
  `TEAM_DOMAIN` callback + aiops mail rider and writes `ENTRA_*` straight into the pack;
  the single human act is the engineer opening the printed sign-in link **from their own
  device** (admin credentials never touch this box — ENTRA-SSO.md relay discipline).
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
  not homework.
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
- Nightly (staggered off the DO backup window): droplet — per-app `pg_dump` + every app
  volume + `/opt/<CLIENT_CODE>` configs → restic repo (RESTIC_PASSWORD_DOCKER01); this
  terminal — home directory → its own repo path (RESTIC_PASSWORD_CCT). 7d/4w/6m retention.
  Each job pings its check on success.
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
- **Nightly restore-verify:** restore the latest snapshot into a scratch container,
  integrity-check (row counts / restic check), ping its own check.
- **Proof:** run one full manual drill now — restore, verify content, tear down — and one
  deliberate backup-failure test (break it, see the silence alert, fix it).

## 7 · Verify everything — `platform-verify.sh`

**Generated-secrets rule, throughout the build:** anything you mint that has no template
home (the break-glass console password, meta connection strings) goes into ONE file —
`HANDOFF-TO-HUDU.md` (0600) in the workspace — written as **ready-to-paste Hudu entries**,
one per secret: `Entry name:` / `Username:` / `Password:` / `Notes:`. Name = what it
unlocks + where it's used; notes = where the credential works, when it was set, and the
rotate-after-use rule. The break-glass entry, exactly:
`docker01.<CLIENT_DOMAIN> — break-glass console (<user>)`, username = the sudo user,
notes = "Emergency console access for docker01.<CLIENT_DOMAIN> (DO droplet <id>). Works
ONLY at the DigitalOcean web console — SSH password auth and root login are disabled.
Log in as <user>, then sudo -i. Set at platform build <date>; only its hash ever touched
the droplet. If used: record why, then rotate (passwd <user>) and update this entry."
The engineer sweeps the file into the client's "Ai Foundations" folder at sign-off and
deletes it. No ad-hoc parking spots.

Commit any previous `PLATFORM-VERIFICATION.md` first (uncommitted evidence rightly trips
the lingering-work sweep), then run `scripts/platform-verify.sh`. It re-proves the battery
from the outside in and writes `PLATFORM-VERIFICATION.md` with raw outputs. **The engineer
reviews that report — that's the human gate.** Update STATE.md: stage-4 ✅ with date, live
components table filled, verified-at-close table = the battery results. Commit, push, CI
green, `workspace-status.sh` clean. Report to the engineer in plain language.
