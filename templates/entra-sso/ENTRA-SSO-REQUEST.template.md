# Single sign-on setup for {{CLIENT_NAME}}'s internal tools — one-time request

<!-- Generated per client from the pack (fill every {{placeholder}}); sent to the client's
     IT provider when adNET does not manage the tenant. Attach New-ClientSSO.ps1. -->

Hello — adNET is standing up {{CLIENT_NAME}}'s internal tools platform. So their staff can
sign in with their **normal Microsoft 365 accounts** (your MFA and conditional-access
policies apply automatically; disabling a user in Entra revokes their tool access), we need
**one app registration** created in the {{CLIENT_NAME}} tenant. This is a one-time,
~10-minute action, and it is the ONLY thing we will ever ask for in your tenant — no
directory roles, no mailbox access, nothing tenant-wide.

## Easiest path — run the attached script

`New-ClientSSO.ps1` (read it first — it's short) as a Global Administrator:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser   # if not present
./New-ClientSSO.ps1 -ClientCode {{CLIENT_CODE}} -AiopsUpn {{AIOPS_UPN}}
```

It creates the registration, grants the sign-in permissions, and prints three values to
hand back. Done.

## Or by hand (identical result)

Entra admin center → App registrations → **New registration**:

1. Name **`{{CLIENT_CODE}}-sso`** · single tenant · platform **Web**, redirect URI
   `https://{{CLIENT_CODE}}.cloudflareaccess.com/cdn-cgi/access/callback`
2. API permissions → Microsoft Graph → **Delegated**: `openid`, `profile`, `email`,
   `offline_access` → **Grant admin consent**
   _(These only let the sign-in flow confirm who a user is — name and email. We never see
   passwords; nothing can read mail, files, or the directory.)_
3. **Owners** → add **`{{AIOPS_UPN}}`** — recommended, not required. Owners can maintain
   THIS object only (add a redirect URI when a new internal tool launches, rotate its
   secrets) — it is not a directory role and grants nothing else. Skip it and we'll simply
   send you a 60-second change request when needed.
4. Certificates & secrets → **New client secret** · description `cloudflare-access` ·
   **12 months**.

## Hand back

- **Tenant ID** and **Application (client) ID** — email is fine.
- **The secret value** — displays once; please read it to us on a call or use a one-time
  secret link ({{ONE_TIME_LINK_SERVICE}}), not plain email.

Questions welcome: {{ADNET_CONTACT}}. Thank you!
