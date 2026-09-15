# AWS account foundations — from nothing to `build-tenant.md` §1

**Audience: the onboarding engineer (or the agent doing the onboarding) standing up a
client's AWS side for the first time.** `build-tenant.md` starts at "admin creds required"
and assumes the account, the build identity, the quotas, cost visibility and the Entra
prerequisites already exist. This runbook is everything before that line. Every item here
was missed at least once on a real tenant build; the issue numbers say which one.

Run it top to bottom. Each section ends with a check you can paste. Nothing here needs the
`az` CLI — the build terminal is a box bootstrapped from this repo, and it has `aws`,
`terraform` and `python3` only (§5).

---

## 0. Inputs to settle first

| Input | Decide | Record in |
|---|---|---|
| Who owns the account | **The client** (their billing, their data, their offboarding). The operator builds in it. | pack `AWS_ACCOUNT_ID` |
| Region | One region, closest to the client's users. Same value goes to terraform `region` and to every scoped tool (budgets, quotas). | pack `AWS_REGION` |
| Client code | Same `<code>` as everywhere else in the engagement (terminal names are `<code>-cctNN`). | pack `CLIENT_CODE` |
| DNS zone | `terminals.<client-domain>` or similar, at Cloudflare. Records stay at the provider; **no NS delegation**. | pack / tfvars `dns_zone` |
| Profile | `standard`, or `medical` (§11.6 of the tenant runbook — decide BEFORE the first apply; there is no un-medical path). | tfvars `profile` |

## 1. The account and its root user (#40)

A fresh account has exactly one identity: the **root user**. It is for four things — enabling
MFA on itself, creating the first IAM identity, billing/tax settings, and closing the account.
It is never the build identity.

1. **Root MFA on.** IAM → Security credentials → assign an MFA device. Record the device and
   the recovery path in Hudu with the root login (that entry IS the break-glass).
2. **No root access keys.** If the pack or the client hands you root keys
   (`arn:aws:iam::<acct>:root` from `aws sts get-caller-identity`), that is the first thing to
   fix — §2 below, then delete the keys: IAM → root Security credentials → Access keys →
   Delete. Root keys cannot be scoped and bypass every IAM guard.
3. **Alternate contacts.** Account → Alternate contacts: billing, operations, security → the
   client's IT contact plus the operator's ops mailbox. AWS sends abuse and health notices
   there, not to the root login.
4. **Root email** should be a monitored, shared mailbox at the client (not a person who
   might leave).

```bash
# check (run with the build identity from §2, never root):
aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent}'
#   expect {"RootMFA": 1, "RootKeys": 0}
```

## 2. The build identity — an IAM user, never root (#40)

The platform is applied by one long-lived IAM identity that the pack carries. Name it for
what it is so it is recognisable in CloudTrail:

```bash
U=aiops-terraform
aws iam create-user --user-name $U --tags Key=Project,Value=claude-terminal
aws iam attach-user-policy --user-name $U --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name $U        # → AccessKeyId + SecretAccessKey, ONCE
```

- No console password for this user (nothing to phish; it is a key pair, not a person).
- The key pair goes into the pack as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, with
  `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_BUILD_USER=aiops-terraform`. Hudu holds the same
  values as the root of trust. `pack-verify.sh` probes them (#48): when the pack declares
  `AWS_ACCESS_KEY_ID` it calls STS with those keys — FAIL on a `:root` ARN, FAIL when the
  account differs from `AWS_ACCOUNT_ID` (recorded from the answer when empty), `AWS_REGION`
  must be a region code — and a pack without AWS keys is a counted SKIP, not a failure.
- If the client already runs **IAM Identity Center** (SSO), a permission set + `aws sso login`
  is the better shape for humans; keep the IAM user anyway for the unattended parts of the
  build (rollouts, budgets, the daily self-update publish).
- **If you were handed root keys:** mint this user WITH them (the four commands above), put
  the new keys in the pack, confirm the check below passes with the new keys, THEN delete the
  root keys (§1 item 2). Order matters — deleting first locks you out.

```bash
# check — the ARN must contain ":user/" (or ":assumed-role/" under Identity Center), never ":root"
aws sts get-caller-identity --query Arn --output text
```

## 3. Service quotas — request before the first apply

New accounts start with quotas sized for experiments, not a fleet. Increases take hours to
days, so ask now. Every terminal is `m5a.large` = **2 vCPUs**; the control plane is
`t4g.small` = 2; the NAT instance `t4g.nano` = 2. All count against one quota.

```bash
R=<region>
# Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances — vCPUs
aws service-quotas get-service-quota --region $R --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value'
# Elastic IPs per region (NAT + control plane = 2 of the default 5)
aws service-quotas get-service-quota --region $R --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value'
```

Size the vCPU quota at `4 + 2 × (terminals expected in 12 months)`, rounded up to a number
AWS grants without a call (64 is routine). Request:

```bash
aws service-quotas request-service-quota-increase --region $R --service-code ec2 --quota-code L-1216C47A --desired-value 64
```

Hibernation (the idle watchdog's Pause) requires **encrypted root volumes**; `ebs.tf` turns
on encryption-by-default for the region at apply time, so nothing to do here — just know that
the first apply changes an account-level setting (tenant runbook §12 for the teardown note).

## 4. Cost visibility — Cost Explorer has no API enable (#40)

`budget-set.sh` (`budgets.md`) sizes each tenant's monthly limit from its **billed history**.
On a fresh account that query fails with `User not enabled for cost explorer access` and the
script correctly falls back to its rate-card model. To get history-based sizing:

1. Console → **Billing and Cost Management → Cost Explorer → Launch/Enable.** One click,
   once, by any admin. There is no CLI or API for this step.
2. Data appears within 24 h; history-based sizing works from the **next complete month**.
3. Write `/asp/budget/config` and run `budget-set.sh` after the first apply, then again
   after the first full month (it is idempotent and re-sizes to reality).

Also enable **IAM access to billing** (Account → IAM user and role access to Billing
information → Activate) or the IAM user cannot read Cost Explorer at all.

## 5. Tooling on the build terminal (#39)

The build runs from an engagement terminal bootstrapped by this repo. It has:

| Tool | Install | Note |
|---|---|---|
| `aws` CLI v2 | in the kit (`00-base-cli`) | `aws configure` with the §2 keys; set the default region |
| `terraform` ≥ 1.10 | to `~/.local/bin` if absent | tenant runbook §5 |
| `python3` (stdlib) | present | runs the Entra provisioner |
| `az` CLI | **not installed, not needed** | every Entra step uses the device-code Graph relay — `templates/entra-sso/` |

The tenant runbook's §3 was first written with `az` commands; the supported path on these
terminals is the Graph provisioner (§6 below). Do not install `az` to work around it.

```bash
aws configure list                      # access_key ****, region set
aws sts get-caller-identity             # §2 check
terraform version                       # >= 1.10
```

## 6. Entra ID prerequisites — the client's Microsoft 365 tenant

### 6.1 One Global Admin sitting

Every Entra step of the build happens in **one** device-code sitting by a Global Admin
(Application Administrator is enough for the registrations but not for the admin-consent
grants). Where that sign-in is performed — a private window on the build box is the normal
path, the engineer's own device works too (#46) — is stated once in
`templates/entra-sso/ENTRA-SSO.md`; this runbook does not change it.

### 6.2 App registrations — one per trust boundary, not one per client

The engagement ends up with **two** registrations, and the split is deliberate:

| Registration | Type | Holds | Secret lives in |
|---|---|---|---|
| `<code>-sso` | delegated login (Pattern A/B) | every application on the client domain behind Cloudflare Access, the aiops mail rider, the appliance `/settings` page | the pack |
| `<code>-terminals` | confidential client with **application** roles (`GroupMember.Read.All`, `User.Read.All`) + delegated `User.Read`, groups claim | the DCV portal in the client's AWS account | SSM `/asp/portal/secrets` only — never disk, never the pack |

Why not fold the portal into `<code>-sso`: application-level directory read is tenant-wide,
and the SSO object's secrets are already held by Cloudflare Access, the exporter and the
appliance. Adding the portal's roles there would hand directory read to every one of those
holders. `ENTRA-SSO.md`'s "never a new registration" rule applies to delegated-login apps;
the portal is the one service that needs its own object.

`<code>-sso` is minted by `provision-sso.py` during PLATFORM-BUILD §3 (it needs a real
`TEAM_DOMAIN`, so it is a platform step, not an accounts-pass step). `<code>-terminals` and
the three portal groups (`ASP-Desktop-Users`, `ASP-Viewers`, `ASP-Admins`) are the tenant
runbook's §3 — the device-code provisioner for them is #39; until it lands, create them by
hand in the Entra portal with the exact permissions in that section.

### 6.3 Conditional Access must actually cover the platform (#41)

Registering the SSO app makes Entra the login for every platform surface — **but Conditional
Access is per-app.** The common MSP shape is a single "Require MFA" policy scoped to
*Office 365* only. Under that policy the Cloudflare Access and portal logins are
**single-factor** and nothing tells you. One tenant ran that way for 11 days.

`provision-sso.py` checks this when it mints the registration and prints a loud WARN if no
enabled policy with an MFA grant (or authentication strength) covers the new app ID or
"All cloud apps". Whether it warned or not, check once by hand for the portal app too:

```bash
# with a delegated Graph token (the relay in templates/entra-sso/get-graph-token-devicecode.sh):
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?\$select=displayName,state,conditions,grantControls" \
  | python3 -c '
import json,sys
for p in json.load(sys.stdin)["value"]:
    apps=p["conditions"]["applications"]["includeApplications"]
    g=p.get("grantControls") or {}
    mfa="mfa" in (g.get("builtInControls") or []) or bool(g.get("authenticationStrength"))
    print(p["state"], "MFA" if mfa else "   ", apps, p["displayName"])'
```

A platform app is covered when an `enabled` row marked `MFA` lists its app ID or `All`.
Two fix shapes, the client's choice: a **targeted policy** naming the platform app IDs
(smallest change), or **widen the existing policy to All cloud apps** — in report-only mode
first, then enabled, because widening is what MSPs narrowed it to avoid. Record which one in
STATE.md. Do not proceed to user onboarding on a tenant that fails this check.

## 7. Cloudflare — token before the control plane boots (#38)

1. The zone exists at Cloudflare and the client (or operator) holds it.
2. Create a **zone-scoped DNS-edit token**, then **pin it to a source IP** — Cloudflare tokens
   support client IP filtering, and it is the one meaningful control available on a token that
   otherwise works from anywhere. **Order matters:** the egress EIP does not exist until after
   the apply, so mint the token unpinned, and add the filter *after* the apply and *before* the
   first `cp-tls.sh` re-run (tenant runbook §1 explains the failure a premature filter causes).
   Pin to the egress EIP of the tenant the token will actually be used from — the operator
   tenant's for a build box, the customer tenant's for a builder's terminal.

   Know what this does and does not buy. Every desktop in a tenant NATs out of **one** shared
   EIP, so a filter does not separate one builder from another: a token pinned to that address
   is equally usable from any terminal in that tenant. What it does buy is that a token lifted
   *off* a box is useless anywhere else. Per-builder separation comes from per-terminal tokens
   and per-machine revocation, not from the filter.

   Apply the same reasoning where else it is available: the `restic-<code>` Wasabi sub-user's
   bucket policy takes an `aws:SourceIp` condition, and it is worth setting precisely because
   the Wasabi keys are shared across terminals by design. GitHub cannot be pinned at all —
   fine-grained PATs carry no IP restriction and org allow lists are Enterprise Cloud only.
3. Put it in SSM **before** the control plane exists: `/asp/cloudflare/token` (SecureString,
   tenant runbook §4). The control plane's boot script fetches it; if the parameter is
   missing at boot, `cp-tls.sh` fails fast and tells you to create it — re-run it via SSM once
   the parameter and the DNS records exist.

## 8. The first boot half-fails by construction — that is expected (#38)

On every fresh tenant the control plane boots **before** the things it needs can exist: the
DNS records need the EIP (post-apply) and the portal needs the Entra values (post-§3/§4). So
the first boot log shows a TLS WARN and the portal unit restarting on a missing
`ENTRA_TENANT_ID`. Neither is a build failure. The order that turns it green:

1. `terraform apply` → note `controlplane_public_ip`, `egress_ip`, `dns_records_needed`.
2. Create the DNS records (tenant runbook §6).
3. Write the SSM parameters (§4 there) — `/asp/portal/config`, `/asp/portal/secrets`,
   `/asp/cloudflare/token`, and `/asp/healthchecks/api-key` (without it the cert-expiry
   alarm arms mute and `cp-verify.sh` reports FAIL, #50).
4. `aws/scripts/rollout.sh cp` (refreshes the control plane's `/opt/asp` from the bucket —
   it is a cache that nothing else updates, #49), then re-run via SSM, in this order:
   `cp-tls.sh` → `dcv-cp-install.sh` → `portal-deploy.sh` (tenant runbook §7).
5. Verify (§8 there).

## 9. What goes where

| Value | Pack (`.env`, 0600) | Hudu (root of trust) | Never |
|---|---|---|---|
| Root login + MFA device + recovery | — | ✔ | the pack, any repo |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_BUILD_USER` | ✔ | ✔ | the public repo |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (IAM user) | ✔ | ✔ | root keys, anywhere |
| Cloudflare token | ✔ | ✔ | — (also SSM, §7) |
| `<code>-terminals` client secret | — | ✔ | disk, the pack (SSM only) |
| Quota request IDs, Cost Explorer enable date, CA policy chosen (§6.3) | — | STATE.md | — |

## 10. Completion checklist

Tick every line before opening `build-tenant.md` §1. Each is a paste-able check above.

- [ ] Root MFA enabled; root access keys **0** (§1)
- [ ] Alternate contacts set (§1)
- [ ] IAM build user exists; `get-caller-identity` ARN is `:user/` or `:assumed-role/` (§2)
- [ ] Pack carries the IAM keys, account ID, region; Hudu matches (§2, §9)
- [ ] vCPU quota ≥ `4 + 2 × terminals`; EIP quota ≥ 2 free (§3)
- [ ] Cost Explorer enabled in the console; IAM billing access activated (§4)
- [ ] Build terminal: `aws configure list` + `terraform version` clean; no `az` (§5)
- [ ] Global Admin identified for the one sitting (§6.1)
- [ ] Registration model understood: `<code>-sso` + `<code>-terminals` (§6.2)
- [ ] Conditional Access covers both platform app IDs or All cloud apps — recorded in STATE.md (§6.3)
- [ ] Cloudflare zone-scoped token created; will be in SSM before the control plane boots (§7)
- [ ] First-boot re-run order understood (§8)

Then continue at [`build-tenant.md`](build-tenant.md) §1.
