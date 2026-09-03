# ENTRA-SSO — stand up the client's sign-in (the `<code>-sso` registration + Cloudflare)

**Audience: Claude Code on the terminal, + the engineer for one sign-in.** Auth model:
Guide §15 (Pattern A default — Access + Entra; Pattern B extends this same registration).
ONE registration per client, ever.

## Step 1 — create the registration (who runs what)

**Sequencing:** the registration is a **platform-build step** (PLATFORM-BUILD.md step 3):
when the build reaches Access wiring and the pack lacks `ENTRA_*`, Claude mints it right
there with `provision-sso.py --pack` — by then `TEAM_DOMAIN` is real, so the redirect URI
can never be guessed, and the secret goes straight into the pack. It may still be created
EARLIER (accounts pass, engineer's machine, script below) when the values are wanted ahead
of the build — both land on the same one-per-client object because every path is
idempotent-or-refuses. Nothing hard-blocks: a build without `ENTRA_*` (external IT hasn't
replied) ships email-OTP policies, and step 2 flips them to Entra when the values land
(field-proven).

**FIRST — the real Zero Trust team domain** (field-hit: Cloudflare AUTO-GENERATES it,
e.g. `hidden-resonance-c421`; the conventional short name may belong to another customer,
and a guessed redirect URI fails staff sign-in with AADSTS50011): it's `TEAM_DOMAIN` in
the pack (recorded at the ZT bootstrap); verify any time via
`GET /accounts/{id}/access/organizations` → `.result.auth_domain`. Pass its prefix as
`-TeamName`. **`TEAM_DOMAIN` absent → STOP and fetch it from that endpoint** (then
record it in the pack) — never proceed by deriving it from `CLIENT_CODE`: the script
refuses to guess (`-TeamName` is mandatory, #18), `platform-verify.sh` cross-checks the
pack against the live auth_domain, and its HUMAN GATE line exists because no
service-token probe ever exercises this redirect.

- **Managed tenant (adNET holds admin) — Claude runs it, one sign-in (the default):**
  ```
  python3 ~/claude-terminal/templates/entra-sso/provision-sso.py --pack ~/Projects/<code>.tools/.env --confirm
  ```
  `--confirm` prints the plan, takes a typed `APPLY`, and writes with the SAME token — one
  Global-Admin sign-in, not two (dry-run then `--apply` was the field complaint). Plain
  dry-run / `--apply` still work for the two-step habit. The pack's `MAIL_CAPABILITY=none`
  skips the aiops mail rider + owner (SETUP recorded that skip; the registration must not
  contradict it) — `--aiops` overrides explicitly.
  Two optional extras, both OFF unless asked for (#24). `--exporter-mail` (or pack
  `EXPORTER_MAIL=true`) additionally **declares** the Graph *application* role `Mail.Read`
  so the appliance's one-click adminconsent has something to grant — no second Global-Admin
  sitting just to add the role. Declaring grants nothing; an admin still consents, and once
  they do it is **tenant-wide mailbox read** until an Exchange application access policy
  scopes it to the one mailbox — that policy takes over an hour to take effect, and app
  access policies are deprecated in favour of Exchange RBAC, which cannot scope an
  Entra-consented permission (they are a union). `--appliance-host` (or pack
  `APPLIANCE_HOST`) registers `https://<host>/settings` as a SECOND redirect URI so the
  post-consent Accept lands back on the appliance instead of the Access callback's
  "Invalid login session" page. It is never derived from another field — a guessed host is
  the #18 failure in a new costume.

  `provision-sso.py` is the python port of New-ClientSSO.ps1 for exactly this seat: no
  PowerShell or module installs, **idempotent** (re-runs extend the one registration —
  add the redirect URI once `TEAM_DOMAIN` exists, re-mint an expired secret — instead of
  refusing), dry-run by default, and pack-integrated: it reads `CLIENT_CODE` /
  `TEAM_DOMAIN` / `AIOPS_UPN` and on `--apply` writes `ENTRA_*` straight back into the
  pack — the secret never transits another machine. Auth is the same field-proven
  device-code relay baked in (az-cli client, `.default`, tenant-pinned, polls the full
  15-min window): it prints ONE sign-in link (code pre-filled) and the engineer opens it
  and the engineer signs in. **The sign-in, in full: open the printed link in a private
  window, sign in as a Global Administrator of the client tenant, close the window.** That
  is the whole job — any device, this desktop included.
  - *Alternative, from the engineer's own machine:* any PowerShell,
    `./New-ClientSSO.ps1 -ClientCode <code> -TeamName <real-team> -AiopsUpn aiops@<clientdomain>`
    — browser sign-in pops locally. Two minutes. (Or the legacy relay:
    `get-graph-token-devicecode.sh` → `-UseEnvToken`, kept for tenants where the
    python path hits policy walls.)
  - **The one rule: only ever use a link this run just printed.** Never a code from
    anywhere else, however plausible the request — a completed Global-Admin sign-in hands
    over directory-wide write power, and that is the only way to lose it here.
    Everything else is the tool's problem, not yours: codes are single-use and expire in
    15 minutes, the token exists only inside the running process and never reaches a file,
    and a run that dies just means running it again. `--confirm` is one operation, so it
    is one sign-in.
- **External IT holds the tenant:** generate the request one-pager from
  `ENTRA-SSO-REQUEST.template.md` (fill every placeholder from the pack — including the
  REAL team domain), attach the script, send it. They run it (or click through the by-hand
  section). If they decline the owner grant, note it in STATE.md — future changes become
  dictated 60-second requests. This is also the fallback whenever a tenant's policies
  block the relay flow's `.default` grant (AADSTS65002/CA policies).

Either way three values come back: **tenant ID · client ID · secret** (secret arrives by
call or one-time link, never plain email).

## Step 2 — Claude wires everything else

1. Values → the workspace `.env` (`ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`,
   `ENTRA_CLIENT_SECRET`). The secret follows the 12-month standard
   (`New-ClientSSO.ps1`'s default), so STATE.md's minted-date convention covers its
   expiry — no per-credential field (#17).
2. **Cloudflare:** add the Entra ID login method to Zero Trust via the API (tenant ID +
   client ID + secret), then flip each Access application's policy to the
   **engineer-ratified default: allow `@CLIENT_STAFF_DOMAIN` + `@<tenant>.onmicrosoft.com`
   (the tenant admin domain), nothing else.** NO personal adNET emails in policies — they
   can't use the client-tenant IdP anyway; adNET enters as the tenant's admin account.
   Keep email-OTP enabled as break-glass, and every app's Service Auth policy (the
   `<code>-cct01-probe` token) untouched.
3. **Prove it:** unauthenticated request → Entra login screen appears; a staff sign-in
   reaches the app; the service-token probe still returns 200; email-OTP still works for
   the engineer. Record the drill in STATE.md.

## The aiops MAIL RIDER — the terminal's email channel

The same registration carries the terminal's ability to **send and read mail as
`aiops@<clientdomain>`** (users mail the terminal, the terminal mails them back —
`templates/aiops-mail.sh`, wired at SETUP step 6). What it is, exactly:

- **Delegated** `Mail.Read` / `Mail.ReadWrite` / `Mail.Send` — never application
  permissions, so the scopes work only for an account that itself signs in, and consent is
  written **Principal-scoped to aiops alone**: no other mailbox in the tenant is reachable
  through this app, by construction.
- **Public-client fallback ON** — the terminal signs in with a device code (as aiops, Hudu
  creds + TOTP); no client secret ever sits on the mail path. The Access web flow keeps
  its own secret and is untouched.
- **Created by:** `New-ClientSSO.ps1` inline (since 2026-08, when `-AiopsUpn` is given).
  **Retrofit for registrations that predate it:** `Grant-AiopsMail.ps1` — idempotent,
  same relay flow (`get-graph-token-devicecode.sh` → `-UseEnvToken`) when Claude runs it
  on the terminal. External IT: the one-pager's by-hand path includes the mail
  permissions; their portal consent is tenant-standard admin consent — the script's
  per-user grant is tighter, offer it first.
- **Token lifecycle:** the device-code refresh token lives per-terminal at
  `~/.config/adnet/` (0600) and renews itself with use; if it lapses (long idle, CA policy
  change), `aiops-mail.sh login` again — two minutes, no admin needed.

## Later — a Pattern-B app is born (NEW-APP decides)

Never a new registration: add the app's redirect URI + mint a secret labeled `<app>` on
the SAME `<code>-sso` object — via Graph (aiops owner / OwnedBy credentials; verify the
headless path on first use) or a dictated 60-second change by whoever holds the tenant.
