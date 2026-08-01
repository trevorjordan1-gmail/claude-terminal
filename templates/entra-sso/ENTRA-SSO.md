# ENTRA-SSO — stand up the client's sign-in (the `<code>-sso` registration + Cloudflare)

**Audience: Claude Code on the terminal, + the engineer for one sign-in.** Auth model:
Guide §15 (Pattern A default — Access + Entra; Pattern B extends this same registration).
ONE registration per client, ever.

## Step 1 — create the registration (who runs what)

- **Managed tenant (adNET holds admin):** the engineer runs
  `templates/entra-sso/New-ClientSSO.ps1` from any PowerShell with their admin sign-in —
  `./New-ClientSSO.ps1 -ClientCode <code> -AiopsUpn aiops@<clientdomain>` — two minutes,
  zero portal clicking. The human authenticates; the script configures.
- **External IT holds the tenant:** generate the request one-pager from
  `ENTRA-SSO-REQUEST.template.md` (fill every placeholder from the pack), attach the
  script, send it. They run it (or click through the by-hand section). If they decline the
  owner grant, note it in STATE.md — future changes become dictated 60-second requests.

Either way three values come back: **tenant ID · client ID · secret** (secret arrives by
call or one-time link, never plain email).

## Step 2 — Claude wires everything else

1. Values → the workspace `.env` (`ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`,
   `ENTRA_CLIENT_SECRET`, `ENTRA_SECRET_EXPIRES`) + expiry → STATE.md's credential table.
2. **Cloudflare:** add the Entra ID login method to Zero Trust via the API (tenant ID +
   client ID + secret), then flip each Access application's policy from the email-OTP
   allow-list to the Entra identity (allow emails ending `@CLIENT_STAFF_DOMAIN`; keep the
   engineer's email; keep email-OTP enabled as adNET's break-glass). Keep every app's
   Service Auth policy (the `<code>-cct01-probe` token) untouched.
3. **Prove it:** unauthenticated request → Entra login screen appears; a staff sign-in
   reaches the app; the service-token probe still returns 200; email-OTP still works for
   the engineer. Record the drill in STATE.md.

## Later — a Pattern-B app is born (NEW-APP decides)

Never a new registration: add the app's redirect URI + mint a secret labeled `<app>` on
the SAME `<code>-sso` object — via Graph (aiops owner / OwnedBy credentials; verify the
headless path on first use) or a dictated 60-second change by whoever holds the tenant.
