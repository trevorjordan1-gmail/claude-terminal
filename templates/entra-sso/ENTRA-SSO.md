# ENTRA-SSO — stand up the client's sign-in (the `<code>-sso` registration + Cloudflare)

**Audience: Claude Code on the terminal, + the engineer for one sign-in.** Auth model:
Guide §15 (Pattern A default — Access + Entra; Pattern B extends this same registration).
ONE registration per client, ever.

## Step 1 — create the registration (who runs what)

**Sequencing:** the registration needs no terminal and no platform — on a FRESH
engagement the engineer creates it during the accounts pass (stage 2, script path below)
and this runbook's step 2 runs later at platform build. The relay flow exists for
RETROFITS (a terminal already lives, the accounts pass predates the SSO step — the field-hit
case). Nothing hard-blocks: a build without `ENTRA_*` ships email-OTP policies, and step 2
flips them to Entra when the values land (field-proven).

**FIRST — the real Zero Trust team domain** (field-hit: Cloudflare AUTO-GENERATES it,
e.g. `hidden-resonance-c421`; the conventional short name may belong to another customer,
and a guessed redirect URI fails staff sign-in with AADSTS50011): it's `TEAM_DOMAIN` in
the pack (recorded at the ZT bootstrap); verify any time via
`GET /accounts/{id}/access/organizations` → `.result.auth_domain`. Pass its prefix as
`-TeamName`.

- **Managed tenant (adNET holds admin) — two equivalent ways:**
  - *From the engineer's own machine:* any PowerShell,
    `./New-ClientSSO.ps1 -ClientCode <code> -TeamName <real-team> -AiopsUpn aiops@<clientdomain>`
    — browser sign-in pops locally. Two minutes.
  - *Claude runs it ON this terminal (preferred — admin credentials never touch the box).*
    One-time tooling: `sudo snap install powershell --classic`, then in pwsh install the
    FOUR Graph submodules only (`Microsoft.Graph.Authentication`, `.Applications`,
    `.Users`, `.Identity.SignIns` — ~1 min; the 39-module meta-package is unnecessary);
    log both in os-changes. Then the **field-proven relay flow** (the SDK's own
    `-UseDeviceCode` waits only ~120s — too short for a relayed code; and repeated mints
    on `common` trip AADSTS50059 throttling, so this flow is tenant-pinned with a 15-min
    window):
    ```
    GRAPH_TOKEN=$(./get-graph-token-devicecode.sh <tenant-id-or-domain>)   # relay the printed code
    GRAPH_TOKEN="$GRAPH_TOKEN" pwsh ./New-ClientSSO.ps1 -ClientCode <code> \
      -TeamName <real-team> -AiopsUpn aiops@<clientdomain> -UseEnvToken
    ```
    Claude relays the code; the engineer signs in from their OWN device at
    microsoft.com/devicelogin (MFA applies). Claude feeds the printed values straight into
    the pack — no copy/paste hop.
  - **Relay-flow discipline (non-negotiable):** a completed Global-Admin sign-in yields a
    token with directory-wide write power. The engineer enters only a code they requested
    seconds ago from this flow and no other; codes are single-use, 15-minute expiry; the
    token lives only in the run's process, never a file that outlives it; one sign-in per
    operation — a burned call means a fresh sign-in, never a cached token.
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
   `ENTRA_CLIENT_SECRET`, `ENTRA_SECRET_EXPIRES`) + expiry → STATE.md's credential table.
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

## Later — a Pattern-B app is born (NEW-APP decides)

Never a new registration: add the app's redirect URI + mint a secret labeled `<app>` on
the SAME `<code>-sso` object — via Graph (aiops owner / OwnedBy credentials; verify the
headless path on first use) or a dictated 60-second change by whoever holds the tenant.
