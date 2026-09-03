# Changelog

## 2026-09-02 — one sign-in rule, stated once (#32 item 4)

The Entra sign-in was described in four places, each slightly differently, and
the venue clause ("from their own device", "never this box") contradicted what
engineers actually do. Resolved by making the process smaller rather than by
picking a side in the venue argument.

- **The engineer's whole job is now one sentence**: open the printed link in a
  private window, sign in, close the window. Any device, including the desktop
  in front of them. The venue clause is gone — the platform build runs on an
  adNET build box that already holds the resulting directory-wide-write token
  in process memory, so *where the browser ran* was never the control it read
  as.
- **The security rule that does matter is stated alone, so it is not buried:**
  only ever use a link this run just printed. That is the anti-phishing rule,
  and it was previously the fifth clause of a five-clause paragraph.
- **Everything else moved out of the instructions and into a note**, because it
  described how the tool behaves rather than anything a human does: codes are
  single-use, 15-minute expiry, the token never reaches a file, a dead run just
  means running it again.
- **`ENTRA-SSO.md` states it once; `PLATFORM-BUILD.md` and `SETUP.md` now point
  at it** instead of restating it. Four independent restatements is how they
  drifted apart in the first place, so the fix is structural, not editorial.

## 2026-09-02 — doctl in the base module (#36)

`PLATFORM-BUILD` step 1 is doctl-driven and no box had `doctl` — it is not in
Ubuntu's apt, so the image shipped `restic`/`jq`/`gh` and stopped there.
`00-base-cli.sh` now installs the pinned release tarball (`v1.168.0`),
sha256-verified against the release's own checksums file, arch-aware
(amd64/arm64), with no snapd dependency. A download or verification failure
WARNs and continues — a missing convenience must not fail a bootstrap.

The early `ok "all present"` moved below the new block, so doctl is still
installed on a box where every apt package was already there.

The remaining items in that report — `gh api` booleans needing `-F` (a string
`false` makes the PATCH silently no-op), polling `gh run list --commit` instead
of `gh run watch` right after a push, `postgres:18` moving `PGDATA` so the mount
must be the parent `/var/lib/postgresql` or a major bump starts an empty
cluster, and `grep -n '{{'` after stamping `deploy.sh` — all landed with #35.

## 2026-09-02 — HANDOFF-TO-HUDU is append-only; zero-question build fields (#34, #35)

- **`HANDOFF-TO-HUDU.md` is append-only and swept per entry** (#34). It was
  designed as one file swept once at sign-off, but a multi-stage engagement
  mints secrets in batches, so the file got **recreated under the same name**
  after the first sweep. An engineer said "I have the handoff copied off" about
  batch 1 and the agent deleted **batch 2, unswept**. It was recovered only
  because every entry happened to have a runtime home; a value with no other
  home would simply have been lost.
  Now: later batches append, never recreate. Every entry carries a checkbox and
  a batch stamp, and a mandatory **`Runtime home`** field — where the value also
  lives on the platform, or "nowhere else" if truly nowhere; that field is the
  recovery path that saved this one. **The file goes only when every box is
  ticked** — never on a whole-file statement, because "the handoff" is
  ambiguous the moment there is more than one batch. PRODUCT-APP deploys append
  to the same file.
- **The droplet layout is stated once** (#33's doc half):
  `/opt/<CLIENT_CODE>/{edge,postgres,backup,scripts}/` plus
  `/opt/<CLIENT_CODE>/<app>.<CLIENT_DOMAIN>/`. `platform-verify.sh` already
  assumed it; nothing said it. SETUP step 1 now also lists `platform-verify.sh`
  and `restic-snapshots-age.sh`, which it had never mentioned.
- **Zero-question build fields** (#35): `DROPLET_SIZE` (its presence is the
  pre-authorised spend), `SSO_AT_BUILD=yes|otp`, `ENGAGEMENT=build|adopt`, and
  `<PRODUCT>_IMAGE` — each removing a question the build would otherwise stop
  to ask.

**Held back again:** the relay-flow venue wording (#32 item 4) appears in this
diff too, in `PLATFORM-BUILD.md` and `SETUP.md`. Both now read as they did —
sign-in from the engineer's own device — with a pointer to the open question.
Landing it here would have decided by the back door what #32 raises directly.

## 2026-09-02 — pack-verify: lint the code, keep the errors, record what the API knows (#31)

- **Uppercase `CLIENT_CODE` is now a lint FAIL.** It names S3 buckets, which
  must be lowercase, so a pack staged with `CLIENT_CODE=ACME` failed the Wasabi
  probe with `InvalidBucketName` while the keys were fine. Rejected rather than
  normalised on purpose: a silently lowercased value would leave the pack
  disagreeing with whatever the accounts pass already created.
- **Probe stderr is kept.** It was going to `/dev/null`, so a FAIL could only
  be guessed at — root-causing the above needed a manual re-run with errors
  visible. A `why` helper now prints the last stderr line under every FAIL.
  Bucket cleanup also empties via the paginator and retries `delete_bucket`
  with backoff, since eventual consistency was reporting a spurious cleanup
  FAIL on otherwise-green runs.
- **`CF_TOKEN_ID` and `CREDENTIALS_MINTED` are recorded from the API**, not
  transcribed. Both were reliably empty because the notes say "only on screen
  at mint time" — but for account-owned tokens
  `GET /accounts/{id}/tokens/verify` returns the id and `expires_on`, and
  expiry − 12 months pins the mint date under #17's one-lifetime rule. Only
  ever fills fields that are **empty**; a value a human set always wins.
- **Alert routing is linted, not discovered at build time.**
  `CLIENT_ALERT_EMAILS` and `ADNET_ALERTS_MAILBOX` become FAILs, and a full run
  counts Healthchecks email channels and FAILs below the two PLATFORM-BUILD §5
  binds. Channels cannot be API-created, so this is an accounts-pass gap the
  build cannot close on its own — which is exactly why it belongs at lint.
- Notes for the zero-question-build fields (`DROPLET_SIZE`, `SSO_AT_BUILD`,
  `ENGAGEMENT`) and for a missing `doctl`.

**Fixed on review:** `pack_record` interpolated its value into a `sed`
replacement, where `\` and `&` are special and `|` was the delimiter — and it
printed its success line regardless of whether `sed` succeeded. A value
containing any of those broke the substitution while the tool reported having
recorded it. Today's two callers pass a hex id and a date, but the helper is
generic. The value is now escaped and the success line is gated on the write.

`pack-verify` now writes to the pack, which is new for a tool named *verify* —
it is confined to the full run (never `--lint`), only fills empty fields, and
preserves both file mode `0600` and any inline comment.

## 2026-09-02 — platform-verify: TEAM_DOMAIN false FAIL, and a helper it called but nobody shipped (#33)

- **The battery FAILed a correct platform.** The pack stores the Zero Trust team
  **prefix** (per ENTRA-SSO.md) while `/access/organizations` answers the
  **FQDN** `<prefix>.cloudflareaccess.com`; the check compared them literally.
  It now compares prefixes, accepts either spelling in the pack, and prints both
  in the evidence. A verifier that cries wolf on a correct platform is worse
  than no verifier — people learn to skip it.
- **`templates/restic-snapshots-age.sh` is new.** §5 called
  `/opt/<code>/backup/restic-snapshots-age.sh` and no template ever shipped it,
  so every platform SKIPped its backup check — the battery quietly not checking
  the thing it claimed to. Prints one line — FRESH / STALE / NONE, exit 0/1/2 —
  from `restic snapshots --json --latest 1`, sourcing the backup `.env` beside
  it. This is the ground-truth half of #30's triage rule: a DOWN monitoring
  check is a claim about pings; this is a claim about snapshots.

**Fixed on review:** the new prefix comparison expanded `$TEAM_DOMAIN` *before*
the guard that handles it being missing. `platform-verify.sh` runs under
`set -u` and the pack omitting `TEAM_DOMAIN` leaves it **unset**, so the whole
battery would have died with "unbound variable" instead of printing the FAIL —
in exactly the case the guard exists for, which is the #18 failure it was
written to catch.

## 2026-09-02 — the nightly backup never pinged Healthchecks (#30)

A terminal migrated from the cron-era backup script to `asp-backup.timer` — the
right fix, since the box hibernates through the cron hour — kept taking nightly
restic snapshots while its Healthchecks check showed **DOWN for 12 days**. The
snapshots were fine the entire time. The old cron script pinged; the generated
`backup-run.sh` never did, so the migration silently dropped monitoring.

The failure mode is worse than no monitoring: a check that reads DOWN while
backups are healthy invites an emergency response to the wrong problem, and it
teaches people to distrust the alert.

- **The ping is now part of the job.** `backup-run.sh` pings `/fail` on the init
  and backup error paths and bare on success, so the check alerts on **silence**
  (never ran) and on **failure** (ran, broke) — the two ways a timer on a
  hibernating fleet goes wrong. With no URL configured it is a no-op, so the
  script still works with no monitoring account. A failed ping can never fail
  the backup.
- **`backup-arm.sh` resolves the URL** from, in order: `HEALTHCHECK_URL` in the
  arm-time environment (or `ASP_BACKUP_HC_URL` in `/etc/asp-terminal.env`); a
  `HEALTHCHECKS_API_KEY` in the tenant config, which upserts a check named
  `backup-<client>-<machine>` (unique on the name, so re-arming is idempotent);
  the value the previous `/etc/asp-backup.env` carried, so **re-arming never
  drops monitoring**; or none, said out loud on the arm line.
- **`backups.md` gains a Monitoring section and the triage rule that matters:
  a DOWN check is a claim about pings, not about snapshots.** `restic snapshots`
  is the ground truth. Fresh snapshots plus a DOWN check is a monitoring gap;
  stale snapshots are a backup problem.

**Operator action:** boxes armed before this have no `HEALTHCHECK_URL` line.
Re-run `backup-arm.sh` over SSM — with `HEALTHCHECKS_API_KEY` in the tenant
config it mints the check, or pass `HEALTHCHECK_URL=<existing ping url>` to keep
one that already exists. New boxes arm with the ping at build.

## 2026-09-02 — first real `provision-sso.py --apply`: three field defects (#32)

`provision-sso.py --apply` ran against a real managed tenant on 2026-08-31 —
the answer to #27 item 6. The registration was created, the secret landed in
the pack and Access sign-in works. Three defects surfaced, all fixed here:

- **`read_pack()` kept inline comments.** Every staged pack line carries a
  trailing ` # comment`, so the tenant derived from `AIOPS_UPN` came out as
  `acme-example.com  # the machine mailbox` and the device-code request died
  with `InvalidURL`. `pack_value()` now reads a line the way `. pack.env`
  would: a quoted value is the quoted text (a `#` inside quotes is literal),
  an unquoted value ends at the first whitespace-then-`#`.
- **Two Global-Admin sign-ins per mint.** Dry-run then `--apply` meant two
  sign-ins minutes apart. `--confirm` does both on one: print the plan, take a
  typed `APPLY`, write with the same in-process token. `main()` splits into
  `resolve()` (everything decided before the token) and `provision()`, which
  also makes the pack contract testable without a token. Plain dry-run and
  `--apply` are unchanged.
- **`MAIL_CAPABILITY=none` was ignored.** SETUP step 6 had recorded "no machine
  mailbox in this engagement" and the script consented `Mail.*` for the aiops
  principal anyway, so the registration contradicted the recorded skip. `none`
  now skips the rider and owner (printed); an explicit `--aiops` overrides; the
  tenant is still derived from the pack's UPN domain either way.

Self-test grows two checks: inline comments (including a quoted `#` that must
survive), and `MAIL_CAPABILITY=none` skipping the rider with the flag override.

**Not taken: the relay-flow venue wording** (issue #32 item 4). The templates
say the Global-Admin sign-in happens on the engineer's own device, "never this
box"; the field proposes a private window on the terminal itself via the DCV
session. That is a security-posture change, not a defect fix — it decides
whether Global-Admin credentials are typed into a browser running on a
client-facing terminal — so it is held for the operator. The wording now points
at the issue instead of pretending the contradiction is not there.

## 2026-09-02 — `verify.sh` answers "am I up to date?"

There were three separate version clocks on a box and nothing reported them
together, so the only way to answer the question was to know which files to
`cat`. `verify.sh` — already the scorecard — now closes with a versions section:

- **Kit version** from `git describe`, plus its commit date. `get.sh` pulls on
  every run and the fleet runs it daily, so a checkout more than **7 days** old
  FAILs: that means the pull is not happening, not that nothing shipped. The
  message carries the exact recovery command.
- **Platform release** from `/opt/asp/applied-version` (DCV boxes only).
- **A deferred release**, read from `auto-update.sh`'s breadcrumb. Its presence
  is the honest "you are behind, and here is why" signal — it exists only while
  the updater is actively refusing to apply something. Under 72 h it is a SKIP
  with the reason and age ("deferring normally, will retry"); past 72 h it
  **FAILs**, matching the threshold the updater itself warns at, so a box quietly
  stuck on an old release shows up in the scorecard instead of never.

Offline by design — no network call, so it never hangs and never reports
staleness it could not actually check. The control plane's own portal version is
not visible from a terminal and is deliberately not guessed at.

`asp_defer_summary` in `lib/common.sh` parses the breadcrumb as JSON (never
grep) and stays silent on a malformed file, which downgrades to a SKIP.

## 2026-09-02 — context percentage read 5x high; the window is now learned, not guessed

Field report: the statusline showed `⚠ context 99% — wrap up` while `/context`
showed 32%. Both the statusline and the launcher divided by a **hardcoded
200,000-token window**; the Claude 5 family has a **1M** window, so every real
session read ~5x high and pinned at the 99% cap. The numerator was always fine
— the denominator was wrong, and the cap hid it.

- **`cc-statusline.sh` takes the window from Claude Code**, which supplies
  `context_window.context_window_size` and a pre-computed
  `context_window.used_percentage` for the model actually running. Nothing is
  hardcoded and nothing is inferred from the model name, so a future model with
  a 2M window is correct on day one. Falls back to `total_input_tokens` ÷ window,
  then to the transcript's latest turn, because `used_percentage` and
  `current_usage` are null before the first API call and again after `/compact`.
- **`cc-launcher.sh` no longer guesses.** Its old test was `"1m" in model`,
  which never matches a real id like `claude-opus-5` — so the "1M auto-detect"
  never once fired. A transcript records the model id and usage but no window,
  so the statusline now caches `model_id → window` at
  `~/.local/state/cc-launcher/model-windows.json` and the launcher reads it. A
  new model teaches the cache the first time it is used; there is no table here
  to go stale.
- **An unknown window reports unknown** (`-`), never a guessed number. The
  statusline is not installed when the user already has a `statusLine` of their
  own — `10-claude-code.sh` never clobbers one — so the cache can stay cold
  indefinitely, and a guessed denominator would read 5x high on every 1M
  session forever, flag every folder FULL, and train people to ignore the one
  signal this feature exists to give. A missing number is honest; the launcher
  already skips `-` when deciding what to flag. `CC_CONTEXT_WINDOW` still
  overrides both.
- The `min(99, …)` cap is gone; percentages are true values clamped to 0–100.

**Do not use `exceeds_200k_tokens` as a fill signal** — it is a fixed 200k
threshold regardless of the model's actual window.

## 2026-08-31 — field round: session-recall launcher, portal UX, real cert lineage (#26)

- **`cc` launcher is now a session-recall TUI** (`templates/cc-launcher.sh`,
  rewritten): alt-screen with arrow/`jk` navigation, every folder under
  `~/Projects` (not just `<code>.tools`), "pick up where you left off" cards
  across workspaces showing gist/exchanges/duration/context-fill, and a
  wrap-up → `HANDOFF.md` → "new session from hand-off" loop. Context fill is
  read from the transcript's latest-turn usage; ≥85% flags red, ≥80% nudges.
  Plain numbered fallback whenever stdin/stdout is not a tty, so scripts and
  tests drive it exactly as before. `cc <folder>` and pass-through args are
  unchanged.
- **`templates/cc-statusline.sh` (new)** — `project · model · context N%` in
  every session, flipping to a wrap-up warning at 80%. Installed and wired
  into `~/.claude/settings.json` by `10-claude-code.sh`, and only when the
  user has no `statusLine` of their own. `SETUP.md`'s manual launcher step
  gained the same two actions so the two paths cannot drift.
- **Portal**: stale pages reload on tab-return and every 5 min; the connect
  page returns to `/` once the client launches (and offers the download card
  when nothing takes the handoff); sessions are named after the machine;
  `.dcv` downloads as `<machine>.dcv`; **zombie `UNKNOWN` sessions** on an
  up-and-available box are given ~30 s to re-report, then force-deleted and
  recreated, instead of wedging Connect forever.
- **Vanity gateway hosts** (`ASP_GW_VANITY`, default off): the native client
  titles its window by connect host and the `.dcv` format has no title key, so
  the portal can hand out `<terminal>.<zone>` names that all resolve to the
  gateway. Needs the tenant's wildcard DNS record and a wildcard cert SAN.
- **TLS — the cert had no renewal at all** (`aws/scripts/cp-tls.sh`): a
  hand-placed cert leaves files under `live/` with no `renewal/*.conf`, and
  the old `[ ! -d "$CERT_DIR" ]` guard read that as "managed" and skipped
  issuance forever — expiry was a scheduled silent outage. The lineage is now
  the test, an unmanaged `live/` dir is moved aside (the gateway and nginx
  serve their own copies, so no downtime), and the order requests **only**
  `*.<zone>` — Boulder rejects an order mixing a wildcard with names it
  already covers. `--cert-name` keeps the paths stable.
- **Desktop**: Chrome warms with `--no-startup-window` instead of the ignored
  `--start-minimized`, which had been putting a window in the user's face on
  every fresh session; `40-gnome-qol.sh` seeds `~/.config/xdg-terminals.list`
  so GNOME 46+ stops asking each user to confirm a default terminal.
- Portal suite 36 → 39.

**Operator action:** `rollout.sh portal` and the normal kit `get.sh`. Vanity
hosts additionally need the tenant's wildcard DNS record, `ASP_GW_VANITY=true`
in `/asp/portal/config`, and a cert carrying the wildcard — which `cp-tls.sh`
now converges on its own.

## 2026-08-31 — build-box session routing: host-qualify every session lookup (#25)

Field report: with two operator build boxes running, **Connect on either one
opened the same desktop**, and the second box was unreachable from the portal.

- **Root cause:** every build box runs its session as the fixed local user
  `build` (group boxes have no single UPN to map), but the portal identified
  sessions by **owner alone**. `_ensure_session` returned the first READY
  session *anywhere in the fleet*. Session creation was unpinned too —
  `createSessions` without `Requirements` lets the broker place a session on
  any server where the owner exists.
- **Fix:** `broker.create_session()` takes `requirements`, and `_ensure_session`
  pins placement with `server:Host.Aws.Ec2InstanceId`. A new
  `_session_on_host()` matches a session to a machine by the broker's
  `Server.Ip`/`Hostname`, and the four owner-only lookups — Connect, `share`,
  `admin_remove`, and the `join` admin self-grant — are host-filtered.
- **The destructive one was `admin_remove`**: it swept *all* of the owner's
  sessions, so removing one build box tore down its siblings' live sessions.
  Now scoped to the machine being removed.
- **Added on review:** `_ensure_session` fails fast with a 409 when the machine
  has no private IP. It cannot match a session without one, and the wait loop
  would otherwise spin its full 90 seconds and then blame the DCV service —
  slow and misdiagnosed. `connect()` already tolerates a missing `private_ip`,
  so the path is reachable.
- Portal suite 31 → 36. The three field tests cover host matching and Connect
  routing; review added the two paths the issue named but left untested — the
  `admin_remove` sibling sweep and the no-IP case. Both were confirmed to fail
  against the pre-fix code.

Only *manifests* on operator tenants (customer tenants never set
`GROUP_BUILD_ENGINEERS`, so build boxes are dormant), but the invariant —
session lookups are host-qualified, placement is instance-pinned — is general
hardening and a no-op wherever an owner has exactly one box.

**Operator action:** portal rollout only. No changes on the boxes, existing
sessions are untouched, and each build box gets its own session on next Connect.

## 2026-08-31 — exporter consent, appliance redirect, two pack fields (#24)

Follow-on to #22, from field use of the appliance's portal-managed exporter config.

- **`--exporter-mail`** (or pack `EXPORTER_MAIL=true`, default off) additionally
  **declares** the Graph *application* role `Mail.Read` on the registration, so
  the appliance's one-click adminconsent link has something to grant. This
  removes the manual step the field hit: a separate Global-Admin device-code
  sitting whose only purpose was adding the role. Declaring grants nothing —
  an admin still consents.
  The flag prints a warning, and it is not decoration: once consented, an Entra
  app role is **tenant-wide mailbox read** until an Exchange application access
  policy scopes it to the one mailbox; that policy takes **over an hour** to
  take effect; and app access policies are **deprecated** in favour of Exchange
  RBAC, which cannot scope an Entra-consented permission — the two are a union,
  so this design has a migration ahead of it.
- **`--appliance-host`** (or pack `APPLIANCE_HOST`) registers
  `https://<host>/settings` as a second web redirect URI, so the post-consent
  Accept lands back on the appliance instead of the Access callback's "Invalid
  login session" page. Accepts a bare host or a full URL, and is **never
  derived** from another pack field — a guessed host is the #18 AADSTS50011
  failure in a new costume.
- **`ENTRA_ADMIN_DOMAIN`** is now captured automatically: the tenant's initial
  `<slug>.onmicrosoft.com` is read from Graph on `--apply`, while the GA token
  is in hand, and written back to the pack — so Zero Trust policy defaults
  (staff domain + admin domain) are not left half-built. No human transcription.
- **`AIOPS_TOTP_SEED`** is now a recognised pack field. The aiops second factor
  lives in the pack because the exporter runs **unattended**; the alternative —
  a Conditional Access policy exempting the account by IP — was weighed and
  declined (operator decision). Hudu remains root of trust and `STATE.template`
  says so; the pack holds a working copy, and it is credential-grade: rotating
  it means re-enrolling the authenticator.
- Self-test grows to 16 checks, including that the role is declared **only**
  when asked, that nothing is invented when `APPLIANCE_HOST` is absent, and
  that a retrofit adds `/settings` without dropping the Access callback.

## 2026-08-30 — root-owned `~/.config` broke user-level writes on new boxes

Field report from a fresh DCV build box: `42-terminal-prefs` FAILED with
`Failed to create file “/home/build/.config/dconf/user.XXXX”: No such file or
directory`, `50-okular-md` could not write `mimeapps.list`, and `40-gnome-qol`
reported **OK while writing nothing**.

- **Root cause** (`aws/scripts/desktop-setup.sh`): `seed_chrome_first_run` ran
  `install -d "$1/.config/google-chrome"` as root and then chowned only
  `google-chrome/`. `install -d` creates the missing **parent** too, so on any
  box where `~/.config` did not already exist — fresh build boxes — it was left
  `root:root`. Every later user-level write into `~/.config` then failed.
  Fixed: `.config` is created and chowned explicitly alongside its child.
- **`gsettings set` exits 0 when dconf cannot commit**, which is why a module
  could report OK with nothing written — the same silent-write class as the
  busless-bus defect fixed in 43b6e27, different cause.
- **`bootstrap.sh` now self-heals** — before any module runs, a `~/.config`,
  `~/.local` or `~/.cache` not owned by the invoking user is chowned back (it
  already holds sudo at that point). Repair rather than `die` because the fleet
  re-runs bootstrap unattended. **This is what fixes boxes already in the
  field**: the kit self-propagates via the daily `get.sh`, so affected boxes
  repair themselves on their next run without waiting on an aws-side rollout.
- **`verify.sh` scores it** — XDG dirs not owned by the user FAIL with the
  remediation, and the check sits above the GNOME checks whose results it
  would otherwise silently invalidate.
- `seed_chrome_first_run` also returned 1 on its `/etc/skel` call (trailing
  `&&` chain with no owner arg) — harmless under the script's
  `set -uxo pipefail`, a hard stop the day anyone adds `-e`. Now an `if`.

**Operator action:** the `desktop-setup.sh` half only affects newly provisioned
boxes and needs `rollout.sh scripts` to land; existing boxes are covered by the
bootstrap self-heal on their next daily run.

## 2026-08-30 — Entra SSO registration becomes a build step (#22)

- **`templates/entra-sso/provision-sso.py`** — python port of
  `New-ClientSSO.ps1` for the terminal seat, so the `<code>-sso` registration
  stops being operator homework: stdlib only (no PowerShell, no Graph module
  installs), device-code relay built in (az-cli first-party client,
  `.default` scopes, tenant-pinned, polling the FULL ~15-min window — the old
  two-step `get-graph-token-devicecode.sh` → `-UseEnvToken` hop and the SDK's
  ~120s trap both disappear). It prints ONE sign-in link and the engineer
  opens it from their own device — admin credentials still never touch the
  box. Dry-run by default; `--pack` reads `CLIENT_CODE`/`TEAM_DOMAIN`/
  `AIOPS_UPN` and on `--apply` writes `ENTRA_*` straight back, so the secret
  never transits another machine.
- **Idempotent by construction** — "ONE registration per client, ever" is now
  enforced rather than asked for: a re-run extends the existing object (adds
  the real redirect URI once `TEAM_DOMAIN` exists, widens a grant, adds the
  owner, re-mints only a dead secret) instead of refusing or duplicating.
- **Moved into `PLATFORM-BUILD.md` step 3** — minting happens where
  `TEAM_DOMAIN` is already real, which removes the #18 guessed-redirect
  failure by sequencing instead of by warning. `--defer-redirect` is the
  explicit opt-in for creating before Zero Trust exists; without a team
  domain the script refuses and cites AADSTS50011. `New-ClientSSO.ps1` stays
  for the engineer's-own-machine path and the external-IT one-pager.
- **Follows #17's one-lifetime rule**: no `ENTRA_SECRET_EXPIRES` pack field —
  the secret takes the standard 12-month lifetime (real calendar months) that
  `CREDENTIALS_MINTED` already carries.
- `templates/entra-sso/test-provision-sso.py` — stdlib self-test (fake Graph,
  no tenant) covering the refusal, dry-run purity, pack round-trip, grant
  scoping, idempotency and the missing-mailbox path.
- **Not yet field-run.** First `--apply` goes against a tenant we control;
  fix-forward from there.

## 2026-08-28 — engagement-kit hardening (#16, #17, #18)

- **Scheduling contract** (#16): droplets (always-on) schedule with cron;
  terminals (hibernate more than they run) use systemd timers with
  `Persistent=true` — plain cron has no catch-up and a job that never runs
  raises no error. Stated in PLATFORM-BUILD §6 + SETUP join-mode; `verify.sh`
  now FAILs local calendar timers without `Persistent=true` and timed
  crontab entries.
- **One credential lifetime, one minted date** (#17): the five `*_EXPIRES`
  pack fields are gone — the operator standard is a 12-month lifetime for
  every mintable credential, so `CREDENTIALS_MINTED` (optional, one date)
  plus the convention replaces per-credential transcription. `CF_TOKEN_ID`
  stays (revocation identifier). STATE template's credential table loses its
  Expires column; `CLIENT_LOCATION` gets a documented default (`nyc3`).
- **Human login gate + TEAM_DOMAIN discipline** (#18): the service-token
  probe never touches the IdP, so `platform-verify.sh` now prints a counted
  HUMAN GATE line (interactive Access login by a named person, recorded in
  STATE.md) and cross-checks the pack's `TEAM_DOMAIN` against the live Zero
  Trust `auth_domain`. `New-ClientSSO.ps1 -TeamName` is mandatory — its old
  `= $ClientCode` default was the guessed redirect URI behind a field
  AADSTS50011.

## 2026-08-28 — the cct02 incident cluster (#19, #20, #21)

- **needrestart no longer restarts DCV services** (#19): library security
  updates (libpam, libssl) were triggering needrestart's apt hook to restart
  `dcvserver` — tearing down every live session and the Claude job inside it.
  `dcv-desktop-install.sh` writes `/etc/needrestart/conf.d/asp-dcv.conf`
  deferring dcvserver / dcvsessionlauncher / dcv-session-manager-agent to the
  next reboot or pause→off conversion (their existing restart cadence).
- **Flat-framebuffer stall mitigated at the source** (#20): mutter could
  start against Xdcv's default `800x600 @ 0.00 Hz` mode and latch a dead
  frame clock — the session then streamed one flat colour and no RandR
  change recovered it. `dcvsessioninit` now creates and applies a real
  1920x1080@59.96 mode before gnome-session starts (best-effort, never
  blocks login). Runbook §10 gains the diagnose/recover gotcha.
- **Session paint probe** (#21): `session-paint-probe.sh`, backgrounded from
  `dcvsessioninit` — counts distinct framebuffer colours ~10 s after
  gnome-shell starts; ≤2 means "never painted" → TERM gnome-shell (unit is
  `Restart=always`; relaunches in place, apps survive), max 2 attempts, loud
  journal give-up, S3 marker under `status/paint/` either way so the fleet's
  real failure rate becomes measurable. `--count` mode doubles as the #20
  repro harness's measuring tool.

- **`templates/PRODUCT-APP.md`**: how an existing product — one image from a
  private registry serving many clients — lands on an already-built platform.
  Sibling of NEW-APP (nine moves), each move a correction from a live run:
  delete the vendor's bundled Postgres (`db-add.sh` instead), publish no
  ports, pin exact tags (no auto-update where images self-migrate), snapshot
  before migrating releases, one app per front door (never Access in front of
  a bearer-token endpoint), registry credential in the app's droplet `.env`
  vs vendor-facing credentials terminal-local and per-command, parameterise
  vendor health monitors, check silent egress defaults, verify the *running*
  version. NEW-APP.md and the stamped platform CLAUDE.md both point at it.

## 2026-08-21 — aiops mailbox gated on capability (#13)

- SETUP step 6 no longer runs unconditionally: the pack's `MAIL_CAPABILITY`
  (`outbound` / `inbound` / `both` / `none`) decides whether the machine
  mailbox is provisioned — outbound for platforms that mail their users,
  inbound for unattended ingestion of time-limited mail (Claude Team
  admin-export links). Absent → SETUP asks the engineer that one question,
  both reasons named. `none` → the skip is recorded in STATE.md, never
  silent. `pack-verify.sh` validates the value; build-boxes runbook table
  points at the gate. Capability, not service line — an adoption engagement
  can need mail for the opposite reason a build does.

## 2026-08-21 — cost controls (#14)

- **S3 gateway endpoint** in every tenant VPC (`aws_vpc_endpoint.s3`, both
  route tables): script downloads, status markers and nightly backups no
  longer transit the NAT or cross AZs on the way to same-region S3. Gateway
  endpoints carry no hourly and no per-GB charge.
- **Per-tenant spending limit** (`aws/scripts/budget-set.sh`, dormant without
  `/asp/budget/config`): sized as the larger of the tenant's own worst
  complete month and a measured rate-card model × the terminals that exist,
  plus headroom — both sizing query and budget scoped to the platform's
  region (unscoped, the numbers are fiction). Alerts at 80/100% actual and
  120% forecast; deliberately no automatic shutdown — enforcement, if wanted,
  belongs on `ec2:RunInstances` (runbook `aws/runbooks/budgets.md`, incl.
  what to check when it fires).

## 2026-08-19 — ASP_BRAND survives sourcing (#12)

- The control-plane bootstrap template now single-quotes every
  `/etc/asp-terminal.env` value (`'` spliced as `'\''`). A bare
  `ASP_BRAND=Acme Terminals` was a prefix assignment to a missing command, so
  the brand silently fell back to the default on every tenant with a real
  brand — and would regress again on any control-plane rebuild. Rendered and
  round-tripped with terraform; `idle-watchdog.py` tolerates quoted values.

## 2026-08-19 — static egress IP (#11)

- **The NAT carries an Elastic IP** (`aws_eip.nat`), so the one address every
  terminal egresses through — the thing customer firewalls, DNS filters, vendor
  allow-lists and conditional access get pinned to — survives the NAT being
  stopped or replaced. Costs what the auto-assigned address already cost. New
  `terraform output egress_ip`; runbook covers the one-time change on adoption
  (`terraform import aws_eip.nat <allocation-id>` to adopt a hand-allocated
  one) and a §9.5 note from #8: a paused terminal only converges on the wake
  *after* a rollout, so wake-path fixes need one cycle per paused box.

## 2026-08-18 — cc-launcher can stand up `<code>.tools` (#9)

- On a terminal that carries an engagement code (`ASP_BACKUP_CLIENT` in
  `/etc/asp-terminal.env` — build boxes and customer deployments) with no
  `<code>.tools` yet, `cc` leads with **`+ set up <code>.tools`**. Picking it
  runs the real SETUP flow (`templates/SETUP.md`) in `~/Projects` with the
  box's code passed as a cross-check against the pack's `CLIENT_CODE` —
  never a bare `mkdir`. No staged pack → it says what the pack is and where
  it goes. Terminals without a code get a one-line note on what creates a
  workspace. Container-tested; the entry disappears once the workspace exists.

## 2026-08-18 — a failed build says so (#7)

- **"Build failed" is a real state now.** `desktop-setup.sh` runs without `-e`
  by design, so a FATAL in a chained sub-step (DCV install losing the dpkg
  lock, the workbench producing no `claude`) used to end in "Ready 100%".
  It now records the failed step, publishes the progress marker with a
  `failed` key and exits 1; the portal keeps that marker live and renders
  **Build failed (DCV)** — with the repair path in the card — instead of a
  "Waking up…" that never resolves (once DCV answers, the marker is history).
  `auto-update.sh` stamps a release only when setup succeeded, so the daily
  run retries until it heals. 6 tests (31 total).
- **`rollout.sh workbench` skips still-provisioning boxes** (fresh, unfinished
  marker) and says so — a booting desktop is "running" 20 minutes before its
  build ends, and queueing `get.sh` there put two apt consumers on one lock.

## 2026-08-18 — nightly backups (#6), broker re-link after hibernation + Chrome ToS (#8), Software Updater polkit + sudo -v (#10)

- **Nightly restic backups for every DCV system (#6):** `aws/scripts/backup-arm.sh`
  (dormant unless the tenant has an `/asp/backup/config` SSM parameter) arms a
  03:00 timer (`Persistent=true` — a paused box catches up on wake) backing
  `/home` to `<bucket>/<client>/<machine>/`; `<client>` is the engagement code
  for a build box and the tenant's own code for an ordinary terminal
  (`ASP_MACHINE_NAME` / `ASP_BACKUP_CLIENT` now ride in `/etc/asp-terminal.env`
  — the box cannot read its own tags). Fallback identity is the instance id,
  never the hostname (a private IP AWS recycles). IAM: desktop role reads that
  one parameter. Runbook `aws/runbooks/backups.md` (retention must match the
  bucket's minimum-storage billing). Admin hardening on merge: env values are
  quote-escaped, and the exclude list keeps Firefox-snap profiles (only snap
  caches are skipped). 5 tests (25 total).
- **The broker link survives hibernation (#8):** `aws/scripts/dcv-relink.sh`
  restarts `dcv-session-manager-agent` on resume (system-sleep hook, `--no-block`)
  and from a 60 s timer whenever its log has been silent 120 s (rate-limited to
  one restart per 5 min) — a resumed box otherwise held an ESTABLISHED socket the
  broker had long closed and stayed UNAVAILABLE. Chrome's first-run ToS wall is
  retired at build (`First Run` sentinel for every user + `/etc/skel`, and
  `initial_preferences`).
- **Software Updater works (#10):** the terminal owner joins the `sudo` group —
  the aptdaemon/snapd polkit rule (#2) keys on `isInGroup("sudo")`, which a
  sudoers drop-in never satisfied, so the GUI fell to `auth_admin` for a user
  with no password. **Kit follow-through, both platforms:** with a user in `sudo`,
  sudoers' default `verifypw=all` makes `sudo -v` demand a password even with a
  NOPASSWD rule (container-reproduced) — `bootstrap.sh` now tries `sudo -n true`
  before the interactive `sudo -v`, and `01-sudo-nopasswd` / `desktop-setup.sh`
  write the same two-line drop-in (`Defaults:<user> verifypw=any` + the rule),
  byte-for-byte, so neither rewrites the other's file.

## 2026-08-18 — portal: pick the owner from the directory (#5)

- **Add-user searches Entra as you type** (name / UPN / mail prefix; Graph
  `$filter` with the app registration's `User.Read.All` app role, admin-only,
  8-result cap, quotes stripped; unlicensed / `.onmicrosoft.com` / guest /
  disabled accounts hidden but revealable). Degrades to "type the full
  email" if Graph is unavailable. The Linux-user field is gone: the local
  user always derives from the UPN, now sanitized to a valid name (dots and
  invalid chars dropped, leading non-letters trimmed, 31-char cap) — the same
  `config.local_user()` for provisioning and session mapping.
- **Admin hardening on merge:** owner checks in revoke / join / dcvfile accept
  the current mapping *and* the `LocalUser` tag of machines the user owns
  (`_my_locals()`), so terminals provisioned under the older mapping (dotted
  mailbox names) keep working for their owners. 3 tests (23 total).

## 2026-08-18 — operator loop (#1), menu-first cc on DCV (#3), display-scaling guidance (#4)

- **Issues are the handoff channel now.** `docs/DEVELOPMENT.md` "Operator
  loop": issue first (public — no identifiers), `<area>/<slug>` branch,
  admin merges with `Fixes #N`, every shipping merge tagged `vYYYY.MM.DD`
  (`rollout.sh` stamps tenants with `git describe`, so tags make tenant
  version records meaningful — first tag `v2026.08.18`).
- **Tenant extension hook (#1):** `desktop-setup.sh` / `cp-setup.sh` finish by
  running `scripts/tenant-custom.sh` / `tenant-custom-cp.sh` from the tenant
  bucket if present — idempotent, non-fatal, logged to
  `/var/log/asp-tenant-custom.log`. Sanctioned per-tenant customization; the
  shipped scripts are never patched downstream.
- **`ASP_BRAND` (#1):** portal title/header from env (terraform `brand` →
  control plane → `portal-deploy.sh` → `config.BRAND` → jinja global);
  neutral default unchanged. 3 new tests (20 total).
- **cc is menu-first on DCV (#3):** `10-claude-code` installs
  `templates/cc-launcher.sh` → `~/.local/bin/cc-launcher` and points the
  `cc`/`phonecc` aliases at it on DCV terminals (same file + alias shape as
  SETUP.md step 3, so the two converge); Hyper-V keeps the plain alias;
  `verify.sh` checks it on DCV.
- **Display scaling (#4):** documented — Settings → Displays 125/150 % snaps
  to 200 % on Xorg; text scaling + per-app zoom are the supported knobs
  (runbook gotcha + a "Making things bigger" note on the portal downloads
  page). Fractional scaling stays off (CPU/encode cost on GPU-less desktops).
- Also merged today: `operator-fixes` (#2) — sign-in lands on the terminal,
  aptdaemon/snapd polkit gap closed.

## 2026-08-18 — cleanup: every script shellcheck-clean, rollout waits properly, one ETA, tags

- **aws/scripts are now held to the same shellcheck bar as the kit** (all 30
  tracked scripts finding-free; `docs/DEVELOPMENT.md` step 5 already lints
  everything). `rollout.sh portal` waits for the SSM invocation to finish
  (up to ~3 min) instead of a fixed 25 s that could report a phantom VERSION
  MISMATCH; the "Ready 100%" marker moves to the very end of
  `desktop-setup.sh` (after the medical default.perm + update timer);
  first-boot ETA is "~15–25 min" everywhere (was 15–20 / 20–30 / 24);
  `cp-setup.sh` no longer installs the unused route53 certbot plugin;
  `aws/portal/tests/stub-portal.env` is regenerated by conftest and now
  ignored, not tracked.
- **terraform tags:** `Project = "claude-terminal"` (this repo is the
  platform now); VPC/IGW Name tags `asp-vpc` / `asp-igw`. Tag-only change —
  `terraform apply` updates tags in place.
- **kit:** module 08 validates the Bedrock inference-profile IDs only when it
  (re)writes the managed settings — no daily network call for a warn.

## 2026-08-18 — review follow-ups: always-latest DCV packages, medical consistency, doc drift

- **aws:** DCV installs use the CDN root's always-latest aliases (a hand-pinned
  gateway filename had already 404'd — the `-1` packaging suffix moved), and
  fail loudly instead of leaving a control plane without a gateway; `rollout.sh`
  no longer dirties the tracked `portal/VERSION`; `client_code` is now a
  terraform output (the runbook always said "from the outputs"); portal lint.
- **kit (medical):** `--medical` refuses non-DCV boxes and verify's medical
  section SKIPs there instead of FAILing forever; the API-key sweep removes
  the same five provider keys verify checks; one parser for
  `/etc/asp-terminal.env`; the post-login hook now fires on Bedrock boxes
  (no OAuth login there) and bakes the repo path; verify's `default.perm`
  check SKIPs until DCV is installed (provision-time verify runs first).
- **kit:** `$(id -un)` instead of `$USER` in 45-hyperv-qol and the docker
  extra (`set -u` hazard).
- **docs:** runbook (m5a.large, verify commands, gateway gotcha, guest OS
  users, admin tuning, closed open item), build-boxes (GROUP_BUILD_ENGINEERS
  goes in SSM `/asp/portal/config`, not the regenerated env file), aws/README
  (Chrome), root README (core table incl. medical modules, base-cli list,
  updater cadence, quick start), DEVELOPMENT repo map, spec naming.

## 2026-08-17 — Windows: `cctemp`, a temporary troubleshooting install

- `windows/cctemp.ps1` puts Claude Code on a Windows box for the duration of a
  troubleshooting engagement only (user-profile scoped, no admin), with a
  dead-man switch that purges it after 30 days without use (idle-based,
  offline-safe; `-AutoCleanupDays`, `-Cleanup`). README "Windows: temporary
  troubleshooting install".

## 2026-08-18 — medical mode (Ai Build Medical), aws/ side

- **`profile = "medical"` per tenant.** One terraform variable reaches every
  terminal as `ASP_PROFILE` (control plane env → `portal-deploy.sh` →
  portal `config.PROFILE` → new `_terminal_env()` used by both provisioners
  — the duplicated env block is gone). Medical-only IAM (`count`): the
  desktop role may `InvokeModel*` on Anthropic Claude models + resolve
  inference profiles; both roles carry a guard that denies weakening Bedrock
  data retention or enabling model-invocation logging. `bedrock-zdr.sh
  --apply/--check` sets and audits zero-data-retention (no Terraform resource
  exists). Output `bedrock_zdr_scp_json` for clients with an Organization.
- **DCV lockdown on medical tenants:** broker permissions append
  `%any% deny file-download printer` (owner and guests; `deny` is final);
  `desktop-setup.sh` writes the same into `/etc/dcv/default.perm` (what
  `verify.sh` asserts).
- **All tenants:** `aws_ebs_encryption_by_default` (with `prevent_destroy`;
  runbook §12 has the teardown step).
- Runbook §11.6: build, verify, offboard (wipe list incl. `~/.claude-mem/`
  and `~/.claude/`). Portal tests: 17 (7 new).

## 2026-08-18 — medical mode (Ai Build Medical), kit side

- **New opt-in profile for regulated-data terminals (DCV only).** Activated by
  state (`ASP_PROFILE=medical` in `/etc/asp-terminal.env` or
  `./bootstrap.sh --medical` → `/etc/claude-terminal/medical`), three core
  modules that skip everywhere else: `08-medical-bedrock` (Claude Code pinned
  to Amazon Bedrock via `/etc/claude-code/managed-settings.json` + system env;
  provider API keys swept off the box), `21-medical-claude-mem` (sonnet via
  the CLI's aliases, telemetry + cloud sync off, credential strip),
  `43-medical-cues` (PHI-approved wallpaper, shell banner, motd).
  `claude_ready` is now true when Bedrock is pinned — plugins install during
  bootstrap and no login reminder is printed. `verify.sh` gains a medical
  section (bar: zero FAILs). Container-validated: full bootstrap twice on a
  fake medical DCV box (all OK, idempotent) and once non-medical (modules
  SKIP, nothing else changes). Design:
  `docs/superpowers/specs/2026-08-18-medical-mode-design.md`. The aws/ half
  (profile var, IAM, ZDR lock, DCV deny) landed the same day — see above.

## 2026-08-18 — platform: Chrome + streaming tuning land on main; kit follows the dock

- **aws/ (merged from `aws-dcv-platform`):** Google Chrome (native deb) with a
  managed streaming policy pack replaces the Firefox snap on DCV terminals;
  30 fps virtual sessions + GNOME animations off (idle render burn); wake
  truthfulness v2 (Connect gates on DCV port *and* broker availability, with
  an "Almost ready…" state); launch template `update_default_version` +
  250 MB/s root throughput; `m5a.large` default; swap fallback; Chrome
  keyring fix and polkit grants for passwordless users.
- **kit:** DCV hosts dconf-lock the dock to Chrome/Files/Terminal, so
  `40-gnome-qol` no longer pins Firefox there (the locked write was FAILING
  the module) and `verify.sh` expects Chrome on DCV (Firefox everywhere else).
  Without this, every fleet box would FAIL two checks on its next daily run.
- **repo hygiene:** `__pycache__/` and `*.pyc` are ignored; the nine bytecode
  files that slipped in with the build-boxes commits are untracked.

## 2026-08-18 — operator build boxes (engagement workbenches)

- **Group-owned machines + self-service build boxes in the portal — dormant
  on every customer tenant.** New optional `GROUP_BUILD_ENGINEERS` config
  (same pattern as `GROUP_VIEWERS`/`GROUP_ADMINS`): when set, machines may
  carry an `OwnerGroup` tag that extends full use to that Entra group's
  members, and the machines page gains a "New build box" form that launches
  `<code>-buildNN` from the normal launch template (tags: `BuildFor`,
  `Creator`, `OwnerGroup`; `Customer` stays the tenant's own value so the
  watchdog and rollout treat it as a normal desktop). Unset — every customer
  tenant — the code paths are unreachable: no UI, group tags grant nothing,
  the route 403s. Design + rationale:
  `docs/superpowers/specs/2026-08-18-operator-build-boxes-design.md`;
  conventions + deployment: `aws/runbooks/build-boxes.md`.
- Build boxes share ONE session as the fixed local user `build` — so
  `connect`/`share` now use the machine's `LocalUser` tag instead of deriving
  the session owner from the Owner UPN (also more correct for 1:1 boxes,
  which set both at provision). The admin "add terminal" duplicate guard
  skips build boxes — owning a workbench doesn't block an engineer's own
  1:1 terminal.
- First portal test suite: `aws/portal/tests/` (pytest via
  `uv run --with pytest --with httpx --with-requirements requirements.txt`),
  importable with a stub env file — dormancy is asserted at predicate,
  template, and route level.

## 2026-08-15 (even later) — the AWS/DCV platform moves in: `aws/`

- This repo is now the **source of truth for the whole stack**, not just the
  per-user kit. `aws/` carries the cloud platform the DCV fleet gate was built
  for: Terraform tenant substrate, the Entra-login portal, provisioning +
  operations scripts (GNOME/DCV desktop, broker/gateway/TLS control plane,
  idle auto-pause watchdog, WU-style self-update, multi-tenant rollout), and
  the build-a-tenant runbook with every production gotcha.
- Tenant identity stays OUT of the repo by construction: variables have no
  org defaults, the terraform backend is init-time config, the fleet registry
  (`aws/tenants.json`) is git-ignored with a committed example — same "no
  machine-specific identifiers" rule the kit has always had.
- Notable platform behaviors baked in from the pilot: sessions run the real
  branded Ubuntu session (dock/appindicators/Yaru — `/etc/dcv/dcvsessioninit`
  is the init that actually runs), printing disabled by design (session
  permissions + cups masked), file transfer both ways (storage root = home),
  Firefox snap pinned first, dcvserver explicitly boot-enabled.

## 2026-08-15 (later) — DCV/cloud terminals become a first-class platform

- **New platform gate `is_dcv_terminal`** (`/etc/asp-terminal.env` or the DCV
  server package): on DCV fleet boxes the host owns session/login config, so
  `38-x11-session` and verify.sh's Wayland check now skip there instead of
  fighting it (GDM is not in use; DCV brings its own X server). Hyper-V and
  Splashtop gating unchanged.
- **New `27-postlogin-finish` + `tools/cct-finish.sh`**: headless provisions
  end before `claude` login and cloud users never see the "re-run bootstrap
  after login" reminder — now the first interactive shell where claude is
  logged in but the plugins are missing runs `cct-finish` automatically,
  which executes just the login-gated modules (claude-mem, superpowers; no
  sudo, no apt). Also runnable by hand any time.
- **`~/.local/bin` now exported in `.bashrc`** (10-claude-code's block):
  DCV/cloud sessions never pass through a login shell, so `~/.profile`'s
  PATH addition doesn't apply and `claude` was off PATH in terminals.
- verify.sh: sudoers check falls back to a prompt-free `sudo -n` read (cloud
  AMIs can ship `/etc/sudoers.d` closed to non-root at 0750); new checks for
  the `.bashrc` PATH export and cct-finish hook.
- `assets/gnome-terminal.dconf`: `use-theme-colors=false` — the recorded dark
  colors now apply explicitly, so seeded terminals are dark even where the
  host's system style is light. Seed-only as ever: no existing box changes.

## 2026-08-15

- **GNOME settings now apply on headless provisions** (cloud/DCV terminals,
  unattended Hyper-V builds). `40-gnome-qol` and `42-terminal-prefs` used to
  skip whenever no user D-Bus session existed — on fleet boxes built without a
  desktop login that meant no dock pins and stock terminal prefs, visibly wrong
  on first connect. New `gui_conf` helper in `lib/common.sh`: writes use the
  live user bus when there is one (running desktops see changes instantly) and
  otherwise run on a private one-shot bus (`dbus-run-session`), which lands in
  the same `~/.config/dconf/user` the first session reads. Container-proven
  detail worth knowing: a busless `gsettings set` **exits 0 while writing
  nothing** (memory backend) — the wrapper is what makes the write real.
- `verify.sh` GNOME checks no longer skip without a session bus — dconf reads
  the database file directly, so they now run everywhere GNOME is installed,
  and two new checks cover the exact fleet defects: dock favorites converged,
  terminal prefs tree non-empty. The GNOME gate is now schema presence (real
  GNOME) rather than bus presence (logged-in GNOME).
- `verify.sh` no longer FAILs the Wayland check on boxes without GDM (DCV/xrdp
  sessions bring their own X server) — mirrors `38-x11-session`'s own gate,
  which already skipped there; now the scorecard agrees.
- `.gitignore`: new local-only `docs/internal/` area for notes that reference
  private infrastructure (same rule as the root `CLAUDE.md`).

## 2026-08-14

- **The aiops mail rider — terminals can now use email.** New
  `templates/aiops-mail.sh`: send and read mail AS the client's
  `aiops@<clientdomain>` mailbox via Microsoft Graph (users mail the terminal,
  the terminal mails them back). Rides the ONE `<code>-sso` registration —
  delegated Mail.Read/ReadWrite/Send consented **Principal-scoped to the aiops
  account only** (no other mailbox in the tenant is reachable, by construction)
  with the public-client fallback on, so the terminal signs in by device code
  and no client secret sits on the mail path. `New-ClientSSO.ps1` creates all
  of it inline when `-AiopsUpn` is given; new `Grant-AiopsMail.ps1` retrofits
  registrations that predate the rider (idempotent, same relay flow). The tool
  has an identity guard — if anyone but aiops completes the device-code
  sign-in, the token is dropped on the spot — and a `verify` command that
  proves the channel with a self-send round trip and deletes its own probe.
  SETUP gains step 6 (install + login + verify; join-mode terminals log in
  per-machine — the token cache never travels); STATE template records the
  probe result and the token's lifecycle; the external-IT one-pager now names
  the mail permissions honestly (delegated, exercised only by the service
  account we created, on its own mailbox — still nothing tenant-wide).
- **Issues RW joins the fine-grained PAT set** (field-found at the first AI
  Build engagement: the terminals plan and work the repo tracker, not just the
  code). `pack-verify.sh` now proves it empirically — an issue is created in
  the probe repo before deletion — and tells a token minted before the change
  exactly what to add. Guide §4 and the onboarding templates carry the new set.
- `pack-verify.sh` notes `AIOPS_UPN` when absent (the mail tool's expected
  identity; login still works without it, minus the mismatch guard).

## 2026-07-31

- New `windows/` directory: host-side Hyper-V tooling, covering the one step
  that was still manual in front of `get.sh` — building the Ubuntu VM.
  `New-UbuntuHyperVVM.ps1` stages the newest Ubuntu 24.04 Desktop ISO
  (SHA256-verified against Canonical's published sums, re-downloaded only on a
  new point release) and builds a Generation 2 VM interactively.
  `windows/get.ps1` is the Windows counterpart of `get.sh`:
  `irm …/windows/get.ps1 | iex` from an elevated PowerShell.
  The launcher exists because PowerShell treats piped content differently from
  a script file — `#Requires` is ignored, `exit` closes the console instead of
  ending the script, and parameters cannot bind. It downloads the script and
  invokes it as a file, so all three behave. `windows/` sits outside module
  dispatch; the module contract does not apply to it.
- New core module 41-splashtop-cursorfix, working around a use-after-free race
  in the Splashtop streamer's cursor encoder (SRFeature, ≤3.8.0.0). Animated X
  cursors trigger it deterministically — the X server cycles their frames and
  each frame fires an XFixes event the streamer must PNG-encode, so a single
  animated cursor kills the streamer in about two seconds and drops every
  session. Four guards: staticize every animated cursor in every host theme via
  `dpkg-divert` (originals park at `*.animated`, so theme upgrades land
  harmlessly); republish Firefox's `.desktop` with `StartupNotify=false` so
  launching it never asks for a busy cursor; repack and sideload
  `gtk-common-themes`, because snap apps can't see host themes at all; and
  LD_PRELOAD a shim onto the streamer that defers cursor-pixbuf destruction by
  three seconds, closing the race itself — the deterministic trigger is only
  part of it, since ordinary cursor churn fires the same race occasionally.
  Scanning every file in every theme matters: `half-busy`, legacy hash-named
  files, and the Adwaita/DMZ/redglass fallbacks are animated too, and a first
  attempt covering only Yaru's four named cursors kept crashing. The module
  skips entirely unless `splashtop-streamer` is installed, so RustDesk boxes
  are untouched. Live desktop sessions need one logout, since running apps hold
  cursors built from the old files. A version canary raises a NEXT STEPS line
  once the installed streamer is newer than 3.8.0.0, so an upstream fix prompts
  retirement rather than passing silently; revert steps are in the module
  header. Caveat: the sideloaded theme snap no longer auto-refreshes, and a
  manual `snap refresh --amend` would restore animated cursors until the next
  bootstrap run — the shim still prevents crashes in that window.
- `bootstrap.sh`: a core module may now carry `# ct-after-extras` to run at the
  very end of a run instead of in the core pass. 41-splashtop-cursorfix needs
  the streamer that `--with-splashtop` installs during the extras pass, and
  extras run after core — without this, a fresh box would skip the crash guard
  on the very run that installed Splashtop.
- `modules/extra/splashtop.sh` is real: `./bootstrap.sh --with-splashtop`
  installs Splashtop Streamer, asks for your 12-digit deployment code, and
  registers the machine, so it appears in the Splashtop console when the run
  ends. It also enables the streamer's own auto-update, because Splashtop
  publishes no "latest" download URL — the pinned URL only has to get the
  package on the box once. An already-installed streamer is left alone, so
  re-running bootstrap stays unattended.
- Modules may now advertise themselves with `# ct-suggest: <command>|<hint>`.
  Bootstrap prints the hint under NEXT STEPS when that extra didn't run and
  the command isn't present, so a core-only run ends by telling you the switch
  to add. Adding the next opt-in product (RustDesk) is a module file only.
- `docs/DEVELOPMENT.md`: the no-prompts rule gains one narrow exception —
  an extra requested by its own `--with-` flag may prompt for inherently
  per-machine secrets, via `/dev/tty`, and must skip when there's no terminal.
  Under `curl | bash` a bare `read` eats the script's next line, and `[ -t 0 ]`
  is false even in a real console; both traps are documented.
- README: state the `curl` prerequisite. A fresh Ubuntu 24.04 Desktop install
  doesn't include it, and since curl is what fetches `get.sh`, it's the one
  dependency the bootstrap can't resolve for itself — the documented quick
  start simply failed on a clean box. Also notes that the `git clone` route
  needs `git`, which `get.sh` installs but a manual clone does not.

## 2026-07-29

- New core module 01-sudo-nopasswd: passwordless sudo for the invoking user
  via a visudo-validated drop-in in `/etc/sudoers.d` (mode 0440; nothing is
  installed unless it parses). A box's first bootstrap run prompts for the
  password once; sudo never prompts again — password prompts were stalling
  Claude sessions on a field box. `verify.sh` checks for the rule.

## 2026-07-22

- docs/DEVELOPMENT.md: maintainer guide — module contract, add-a-feature
  checklist, hard rules, roadmap. verify.sh gained claude-mem runtime checks
  the day before; both close out the v1 validation cycle.

## 2026-07-21 (updates)

- New core module 02-home-dirs: creates the `~/Projects` workspace folder.
- New core module 38-x11-session: sets `WaylandEnable=false` in
  `/etc/gdm3/custom.conf` (takes effect at next login/reboot). RustDesk and
  Splashtop cannot capture or inject input on Wayland, and the Hyper-V scroll
  fix is an Xorg InputClass — both reference machines already ran X11-only.
  This was in the machine audit's shared core but was missed in the first
  release. `verify.sh` now checks it.

All notable system-setup changes tracked by this repo. Machines converge by
re-running `./bootstrap.sh` (it is idempotent).

## 2026-07-21

- Initial release: core bootstrap (base CLI, Node 20 + user npm prefix,
  Claude Code native install + aliases, bun, claude-mem v10 plugin,
  superpowers plugin, uv, GNOME QoL, Hyper-V QoL, Okular as Markdown viewer)
  plus opt-in extras (docker, xrdp, tailscale, printing-direct,
  weak-passwords, buildtools, usagemeter) and tools (add-printer, verify,
  system-audit).
- Splashtop: manual install for now (see README) — automation planned.
- Short install URL: `https://get.wtfapps.net` (Cloudflare-edge 301 to the raw
  `get.sh`; canonical URL unchanged).
- 40-gnome-qol now also converges the dock to Firefox / Files / Terminal
  (removes App Center and Help pins).
- New core module 42-terminal-prefs: seeds GNOME Terminal preferences
  (Ctrl+C/V copy-paste keybindings, 200×50 default window, bold-is-bright)
  from `assets/gnome-terminal.dconf` — fresh boxes only, never overwrites an
  already-customized terminal.
