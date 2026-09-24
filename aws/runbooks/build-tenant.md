# Build a Claude Code Terminals tenant — agent runbook

> **Fresh AWS account?** Do [`account-foundations.md`](account-foundations.md) first —
> root lockdown, the IAM build user (never root keys), quotas, Cost Explorer, the
> `az`-free Entra path and the Conditional Access MFA check. This runbook assumes all of it.

**Audience:** a Claude Code agent (or human) standing up a complete tenant from
zero. Every command is copy-pasteable; placeholders are in `<angle-brackets>`.
**This is a living document** — refine it after every build/test session.
Validated end-to-end on the pilot tenant, 2026-08-15.

Architecture summary:
EC2 Ubuntu desktops (1:1 per user, private subnets, hibernation) streamed via
Amazon DCV native client through a Connection Gateway; a Session Manager Broker
issues single-use tokens; a FastAPI portal (Entra ID OIDC) is the only
management surface. Admin access is **SSM only** — no SSH anywhere.

---

## 0. Inputs (decide before starting)

| Input | Example | Notes |
|---|---|---|
| `customer` slug | `acme-poc` | tag + IAM scoping |
| AWS account | client-owned | an **IAM user** with AdministratorAccess (`account-foundations.md` §2) — never the root user's keys |
| `region` | `us-east-2` | closest to client |
| Entra tenant | client's tenant | Global Admin or App Admin needed |
| `dns_zone` | `terminals.example.com` | per client: `terminals.<client-domain>` or similar |
| DNS provider | Cloudflare | records stay at the provider — **no NS delegation** |
| Desktops | none at build time | terminals are **portal-managed**: the admin page (add user) provisions from the Terraform launch template; remove user terminates. Naming auto-assigned `<client_code>-cctNN` ("Claude Code Terminal") |
| Workbench | this repo's `get.sh` | the kit bootstrap, runs per-user on every terminal (modules gate themselves via `is_dcv_terminal`) |
| Desktop env | **GNOME** (ubuntu-desktop-minimal, gdm disabled, Xorg virtual sessions) | text-scaling 1.25, lock/blank/suspend forced OFF (users have no OS passwords), TZ America/Chicago |

## 1. Preflight — verify access (all must pass)

```bash
aws sts get-caller-identity                  # admin in the target account
# Entra: no `az` on the build terminal — every directory step is a device-code Graph sitting
# (templates/entra-sso/, account-foundations.md §5–§6); confirm the Global Admin + tenant with the engineer
terraform version                            # >= 1.10 (install to ~/.local/bin if absent)
# Cloudflare: zone-scoped DNS-edit token. VERIFY IT LISTS THE ZONE:
. ~/.config/cloudflare/asp.env               # CF_API_TOKEN, CF_ZONE_ID
curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?per_page=50"   # find zone id for the domain
```

⚠️ **CF token IP filters:** if the token has a client-IP filter, certbot ON THE
CONTROL PLANE will fail with `Cannot use the access token from location: <EIP>`.
Either use an unfiltered zone-scoped token, add the control-plane EIP to the
filter, or (workaround) issue the cert from a machine the token works from and
copy `fullchain.pem`/`privkey.pem` to
`/etc/letsencrypt/live/<portal-host>/` on the control plane via S3+SSM
(delete the privkey object from S3 afterward). In-tenant renewal requires the
token to work from the EIP.

## 2. Buckets (one-time per tenant)

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)
ORG=acme    # short org slug — bucket names are global, prefix them
for B in $ORG-asp-tfstate-$ACCT $ORG-asp-artifacts-$ACCT; do
  aws s3api create-bucket --bucket $B --region us-east-2 \
    --create-bucket-configuration LocationConstraint=us-east-2
  aws s3api put-public-access-block --bucket $B --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
done
aws s3api put-bucket-versioning --bucket $ORG-asp-tfstate-$ACCT --versioning-configuration Status=Enabled
```
Tenant values never live in the repo: they go in a git-ignored `terraform/backend.hcl` + `terraform/terraform.tfvars` (see §5).

## 3. Entra objects

> Written for `az`; the build terminal has none. Supported path: the device-code Graph
> provisioner (#39 — until it lands, the Entra portal by hand with these exact settings).
> This is the **`<code>-terminals`** registration — separate from `<code>-sso` on purpose
> (`account-foundations.md` §6.2). After it exists, run the Conditional Access MFA check
> (§6.3 there) for its app ID.

**The four portal groups — use the provisioner, not `az`.** This box has no `az` (see the
note above), the names below are what every real tenant runs, and an agent can do the whole
step from the repo:

```bash
python3 templates/entra-sso/provision-terminal-groups.py --tenant <tenant-guid>          # dry run
python3 templates/entra-sso/provision-terminal-groups.py --tenant <tenant-guid> \
    --admin <you@client> --user <desktop-owner@client> --app-id <terminals-appId> --apply
```

It is idempotent (re-run to adopt what exists), creates ASSIGNED SECURITY groups —
`Ai_Terminals_Admins`, `Ai_Terminals_Users`, `Ai_Terminals_Viewers`, `Ai_Build_Engineers` —
sets `groupMembershipClaims` on the registration, and prints the object IDs for §4.

**`Ai_Terminals_Admins` is a real capability**: a member sees every active session in
"Sessions you can join" and joining self-grants CONTROL (keyboard, mouse, clipboard both
ways, file transfer), with no consent prompt and no notice to the session owner, on
unattended sessions included. Since #58 an admin can also **Connect as owner** to a Running
terminal that has no live session at all: that starts the owner's session and connects as the
owner's local user — their desktop, unattended. The button confirms what it does and every
such connect (and every admin Join) is written to the portal's journal as an `AUDIT` line
(`journalctl -u asp-portal | grep AUDIT`). Put people in the group deliberately — and put at
least one person in it, or nobody can administer the portal.

**Group membership is read at sign-in** and cached in the portal session cookie for 8 hours:
anyone already signed in must sign out and back in before a change takes effect.

<details><summary>By hand with <code>az</code>, if you are on a box that has it</summary>

```bash
# 4 groups; record the object IDs. Security, assigned — NOT M365, NOT dynamic.
az ad group create --display-name Ai_Terminals_Admins   --mail-nickname ai-terminals-admins
az ad group create --display-name Ai_Terminals_Users    --mail-nickname ai-terminals-users
az ad group create --display-name Ai_Terminals_Viewers  --mail-nickname ai-terminals-viewers
az ad group create --display-name Ai_Build_Engineers    --mail-nickname ai-build-engineers
az ad group member add --group <users-id>  --member-id <user-object-id>    # per desktop owner
az ad group member add --group <admins-id> --member-id <admin-user-object-id>
```

</details>

# app registration (web, auth-code flow)
APPID=$(az ad app create --display-name "<code>-terminals" --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://portal.<dns_zone>/auth/callback" --query appId -o tsv)
OBJID=$(az ad app show --id $APPID --query id -o tsv)
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$OBJID" \
  --body '{"groupMembershipClaims":"SecurityGroup"}'          # portal authz = group claims
# Graph perms: GroupMember.Read.All + User.Read.All (app roles), User.Read (delegated)
az ad app permission add --id $APPID --api 00000003-0000-0000-c000-000000000000 --api-permissions \
  98830695-27a2-44f7-8c18-0c3ebc9698f6=Role df021288-bdef-4463-88db-98f22de89214=Role e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope
az ad sp create --id $APPID
az ad app permission admin-consent --id $APPID                # wait ~10s after sp create
SECRET=$(az ad app credential reset --id $APPID --years 2 --query password -o tsv)  # store, never print
```

## 4. SSM parameters (portal config + secrets + CF token)

```bash
aws ssm put-parameter --name /asp/portal/config --type String --overwrite --value \
 '{"ENTRA_TENANT_ID":"<tenant-guid>","ENTRA_CLIENT_ID":"<appid>","BROKER_URL":"https://localhost:8446","BROKER_VERIFY_TLS":"false","GROUP_DESKTOP_USERS":"<id>","GROUP_VIEWERS":"<id>","GROUP_ADMINS":"<id>","GROUP_BUILD_ENGINEERS":"<id>"}'
aws ssm put-parameter --name /asp/portal/secrets --type SecureString --overwrite --value \
 '{"ENTRA_CLIENT_SECRET":"<secret>","SESSION_SECRET":"<openssl rand -hex 32>"}'
aws ssm put-parameter --name /asp/cloudflare/token --type SecureString --overwrite --value '<cf-token>'
# ONE Healthchecks MANAGEMENT key for every alarm (#50, #53): the cert-expiry check on the CP and each
# terminal's backup check. Without it they arm MUTE and cp-verify.sh reports FAIL until it exists
# (back-fill: put it, then `rollout.sh cp` + re-run cp-tls.sh; terminals re-arm on their next auto-update)
aws ssm put-parameter --name /asp/healthchecks/api-key --type SecureString --overwrite --value '<healthchecks-management-key>'
```

## 5. Upload scripts + portal, then Terraform

```bash
cd claude-terminal/aws
aws s3 sync scripts/ s3://$ORG-asp-artifacts-$ACCT/scripts/ --exclude "*" --include "*.sh" --include "*.py"
(cd portal && zip -qr /tmp/portal.zip . -x "__pycache__/*") && \
  aws s3 cp /tmp/portal.zip s3://$ORG-asp-artifacts-$ACCT/portal/portal.zip
cd terraform
cat > backend.hcl <<EOF          # git-ignored: tenant state location
bucket       = "$ORG-asp-tfstate-$ACCT"
key          = "<tenant>/terraform.tfstate"
region       = "us-east-2"
use_lockfile = true
EOF
cat > terraform.tfvars <<EOF     # git-ignored: tenant identity
customer         = "acme-poc"
client_code      = "acme"
dns_zone         = "terminals.example.com"
cert_email       = "<ops-contact@org>"
artifacts_bucket = "$ORG-asp-artifacts-$ACCT"
# portal_public      = false                  # portal behind Cloudflare Tunnel + Access (§6.1)
# portal_public_host = "terminals.example.com" # its first-level public name (§6.1)
EOF
terraform init -backend-config=backend.hcl && terraform apply
# outputs: portal_url, gateway_endpoint, controlplane_public_ip, controlplane_instance_id, dns_records_needed, desktop_launch_template_id, desktop_subnet_ids, client_code, bedrock_zdr_scp_json
```
What it creates: VPC 10.60.0.0/16 (public subnet + 2 private), fck-nat t4g.nano,
SG-to-SG rules (desktops reachable ONLY from control plane on 8443 tcp+udp;
broker 8445 only from desktops; world sees 443 + 8443 only), IAM roles
(dcv-license S3 read; portal: tag-scoped power+terminate, RunInstances +
PassRole(desktop role) + CreateTags-on-RunInstances, tag-scoped ssm:SendCommand;
SSM core + artifacts + `/asp/*` params), control plane t4g.small + EIP, and the
**desktop launch template** (m5a.large, hibernation, 50 GB encrypted gp3, 250 MB/s).
**No desktop instances** — users/terminals are created from the portal admin
page after §7. Add LAUNCH_TEMPLATE_ID + SUBNET_IDS + CLIENT_CODE (from the
Terraform outputs) to the `/asp/portal/config` SSM param. New desktops
self-provision at boot from the artifacts bucket (needs the broker CA
published first — run §7 before adding users).

## 6. DNS records (Cloudflare — records stay at the provider)

```bash
. ~/.config/cloudflare/asp.env
for host in portal.<subdomain> gw.<subdomain>; do    # e.g. portal.terminals
  curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -d "{\"type\":\"A\",\"name\":\"$host\",\"content\":\"<EIP>\",\"ttl\":300,\"proxied\":false}"
done
```
**`proxied` MUST be `false` (grey cloud)** — DCV's 8443 TCP/QUIC cannot pass
the Cloudflare proxy, and certbot DNS-01 doesn't care either way.

### 6.1 Portal behind Cloudflare Tunnel + Access (optional, #57)

A tenant that fronts everything with Cloudflare Access may want the portal there too.
Two facts decide the shape:

- **Universal SSL covers ONE label** under the zone (`*.<zone>` + apex). `portal.terminals.<zone>`
  is two labels, so a proxied record for it has **no edge certificate** and TLS fails at the edge
  (`sslv3 alert handshake failure`). Either buy Advanced Certificate Manager, or give the portal a
  **first-level public name** — `terminals.<zone>` — which is what the field did.
- **The DCV gateway cannot traverse the proxy.** `gw.<subdomain>` stays a grey-cloud A record, so
  `cp-tls.sh`'s wildcard cert is **still required** for the gateway and the per-terminal vanity
  names. Moving the portal behind Access removes nothing from the certbot path.

Recipe (field-verified 2026-09-16 on a client tenant):

1. **Terraform**: `portal_public = false` (closes 443 on the EIP — external scan shows 8443 only)
   and `portal_public_host = "terminals.<zone>"`. On a **new** tenant that is all: the name reaches
   the control plane at boot as `ASP_PORTAL_PUBLIC_HOST`. On a **live** control plane a `user_data`
   change stops/starts the instance — instead append
   `ASP_PORTAL_PUBLIC_HOST='terminals.<zone>'` to `/etc/asp-terminal.env` from the tenant's
   `tenant-custom-cp.sh` and still set the two variables so the state matches reality.
2. **`portal-deploy.sh`** (via `rollout.sh cp` + `rollout.sh portal`) then writes the public name
   as the portal's `ASP_PORTAL_HOST` in `/etc/asp-portal.env` (OIDC redirect URI + links) and adds
   it to nginx `server_name`. `ASP_PORTAL_HOST` in `/etc/asp-terminal.env` is untouched, so the
   cert lineage and `cp-verify.sh` keep working.
3. **Tunnel** (`cloudflared` as a system service on the CP, token from an SSM SecureString such
   as `/asp/cloudflare/tunnel-token`, pinned version, installed by `tenant-custom-cp.sh`):
   remote-managed ingress `terminals.<zone> → https://localhost:443` with `originServerName` and
   `httpHostHeader` both set to `portal.terminals.<zone>`, so nginx, the cert and the portal see
   the request they always did. Access application on the public name with the tenant's standard
   policies; an off-box probe sends the Access service token.
4. **Entra**: add `https://terminals.<zone>/auth/callback` as a redirect URI on the portal app
   registration (Global Admin, one sitting). Verify: `/login` through the tunnel redirects to
   Entra with the public name in `redirect_uri`.

**Do not** do this on the gateway name, and do not read it as "certbot is optional now".

## 7. Provision the control plane (SSM, in this order)

Run each via `aws ssm send-command --instance-ids <cp-id> --document-name AWS-RunShellScript --parameters 'commands=[...]'`;
the pattern for every script: **`aws/scripts/rollout.sh cp` first** (refreshes `/opt/asp` from the
bucket), then SSM `bash /opt/asp/<x>.sh`. **A control plane's `/opt/asp` is a cache of the bucket and
only `rollout.sh` refreshes it** (#49): `cp-setup.sh` stages the scripts once at first boot, nothing
else ever updates them, and `rollout.sh scripts` only updates the bucket — so a bare re-run of
`/opt/asp/<x>.sh` executes whatever shipped the day that CP was built (found on the operator tenant:
re-runs of cp-tls.sh that predated #38 entirely).

1. `cp-tls.sh` — certbot via Cloudflare DNS-01 (see §1 token warning) + gateway cert
   deploy-hook. It also arms **`asp-cert-check.timer`** (daily), which reports days-to-expiry
   and pings Healthchecks. That check is deliberately about the **cert**, not the renewal
   run: renewal can fail because the timer is off, the lineage is missing (a hand-placed cert
   has no `renewal/*.conf` and will never renew — the failure that went unnoticed until it was
   found by accident), a deploy hook broke, or the Cloudflare token's IP allowlist does not
   cover the control plane's own egress EIP. One signal catches all of them. It alerts under
   21 days, i.e. after certbot's 30-day renewal window has already been missed once, so there
   is ~3 weeks of runway rather than a morning-of surprise. Triage: `systemctl status
   certbot.timer`, then `certbot renew --dry-run` — a DNS-01 failure there points at the token
   allowlist.
2. `dcv-cp-install.sh` — broker (heap-patched for 2 GB), gateway, publishes broker CA
   to `s3://<artifacts>/certs/`, registers the portal API client
   (`/etc/asp-broker-client.env`). **Idempotent — re-run after certs exist so the
   gateway conf picks up cert-file lines.**
3. `portal-deploy.sh` — venv + systemd `asp-portal` on 127.0.0.1:8080, nginx TLS front.

Desktops: boot user-data runs `desktop-setup.sh` (users, GNOME, workbench) and
chains `dcv-desktop-install.sh` **only if that script is already in the
bucket** (it then copies the broker CA from `certs/` — publish the CA in step 2
first, or the agent's `ca-file` points at nothing); otherwise re-run
`desktop-setup.sh` via SSM after step 2.

## 8. Verify (expected outputs in brackets)

```bash
# on the control plane via SSM:
systemctl is-active dcv-session-manager-broker dcv-connection-gateway asp-portal  # [active ×3]
curl -sk https://localhost:8446/sessionConnectionData/x/y | head -c 200        # [broker answers (auth error is fine)]
curl -s http://127.0.0.1:8080/healthz  # [{"ok":true,...}]
# after the first terminal is provisioned: its DCV server shows AVAILABLE on the portal (Connect works)
# from anywhere:
curl -s https://portal.<dns_zone>/healthz          # valid LE cert + {"ok":true}
openssl s_client -connect gw.<dns_zone>:8443 </dev/null | openssl x509 -noout -issuer  # [Let's Encrypt]
# external scan: ONLY 443 + 8443 open on the EIP (8443 alone with portal_public = false, §6.1); desktops unreachable; no port 22 anywhere
# from inside any terminal: egress is the NAT's Elastic IP (terraform output egress_ip) — static, allow-listable
curl -s https://checkip.amazonaws.com                 # [== terraform output egress_ip]
```
Then disable sshd fleet-wide: `systemctl disable --now ssh && systemctl mask ssh` (via SSM).

**The control plane, any time after (#27):** `aws/scripts/rollout.sh verify` from the
operator box runs `cp-verify.sh` on every registered control plane over SSM and prints
its report — cp-tls steady state (a re-run would make no certbot call), `certbot renew
--dry-run` (a real DNS-01 from the CP, so it IS the Cloudflare token allowlist test), the
egress IP that allowlist must contain, the expiry alarm + its timer, the portal release,
and that `/etc/asp-portal.env` sources safely (quoted, or shell-safe bare — the shape
`portal-deploy.sh` actually writes, #51). A certbot lock collision on the dry-run is a
SKIP with a retry hint, not a FAIL (#52). Any FAIL line fails the tenant. By hand on a CP:
`sudo bash /opt/asp/cp-verify.sh`.

## 9. Iteration workflow (how to change anything)

Scripts are the source of truth, S3 is the transport, SSM is the executor:
```
edit scripts/<x>.sh → rollout.sh scripts (bucket) → rollout.sh cp (the CP's /opt/asp, #49) → SSM "bash /opt/asp/<x>.sh"
```
**Always `s3 sync` the whole scripts/ dir, never cp a single file** — a re-run
of any stale script silently regresses live config (this exact drift re-broke
the gateway resolver URL on PoC day 1: live conf was hot-fixed, S3 script
wasn't, a later cert re-run rewrote the old value back). All scripts are
idempotent. Portal code changes: rebuild portal.zip → s3 cp →
re-run `portal-deploy.sh`. Never SSH (there is none); never hand-edit remote
files without folding the change back into the script + this runbook.

## 9.5 Shipping improvements to live fleets

Nothing here requires rebuilding terminals — stock-AMI + idempotent scripts
means every layer updates in place, and terminals created later are always
born current (boot pulls latest from the tenant bucket).

| What changed | How it reaches deployments |
|---|---|
| **claude-terminal** (workbench/kit) | maintainer ships to its `main` → per tenant: SSM re-run of the get.sh bootstrap as each terminal's user (idempotent). One command per tenant fleet. |
| **`aws/scripts/`** (desktop/DCV layer, watchdog) | commit → `rollout.sh scripts` (bucket) → SSM re-run the touched script on affected instances. **Control planes: `rollout.sh cp` first** — `/opt/asp` there is a cache of the bucket that only rollout.sh refreshes (#49) |
| **Portal** | commit → `rollout.sh portal` (zip → bucket → the CP's *local* `portal-deploy.sh`; `rollout.sh all` refreshes that script first) |
| **Infra** (Terraform) | `terraform apply` per tenant |

**Paused terminals converge on their *next* wake — after it, not before.** A
hibernated box gets a release via `auto-update.sh` → `desktop-setup.sh` on
its next boot, apt work included, so the wake that installs a fix is still a
wake without it. For anything that fixes the wake path itself (the #8 broker
re-link is the example — a box paused since before the rollout hit the same
dead link on resume, 13.8 h silent), either accept one bad wake per paused
box or proactively start the paused fleet, let the updater run, and pause
again. "Merged + synced" is not "protected" until each box has cycled once.

Multi-tenant discipline (when client #1 lands): tag releases in this repo;
roll out per tenant = sync-at-tag + SSM re-run; record each tenant's running
tag. The kit (modules/, get.sh) and this platform live in ONE repo now: a
change that spans both ships as one commit — no cross-repo contract dance.

## 10. Gotchas (each cost real time — do not rediscover)

| Gotcha | Fix (already encoded in scripts) |
|---|---|
| DCV package URL 404 | never pin versioned CDN paths — the `-1` packaging suffix moved once. Both install scripts now use the CDN root's **always-latest aliases** (`nice-dcv-connection-gateway_arm64.ubuntu2404.deb` etc.) and exit FATAL on a failed download |
| Agent won't start: `missing field version` | `agent.conf` requires top-level `version = '0.1'` |
| Agent/gateway TLS fails to broker | broker's self-signed cert SAN covers ONLY the short hostname (`ip-10-60-0-x`) + IP → use the short name in `broker_host`, `auth-token-verifier`, `[resolver] url` (resolves via VPC search domain; keeps `tls_strict = true`) |
| Gateway `Permission denied` on conf | a `umask 077` earlier in a script made the conf unreadable — keep tight umasks in subshells |
| Broker OOM risk on t4g.small | patch `-Xmx2g→-Xmx1g` in `/usr/share/dcv-session-manager-broker/bin/common.sh`, set `broker-to-broker-distributed-memory-max-size-mb=256`, add 2 GB swap |
| SG rules vanish on apply | never mix inline SG rules with `aws_security_group_rule` on the same SG (control-plane SG is standalone-rules-only) |
| Broker API port | broker client API default 8443 collides with the gateway → moved to **8446**; agents 8445; resolver 8447 |
| CF token IP filter | see §1 — breaks in-tenant certbot with a confusing error |
| `certbot renew --dry-run` says `Another instance of Certbot is already running` | a **lock collision**, not a token problem: `certbot.timer` fires twice a day at a random offset, and two verifies can overlap too. `cp-verify.sh` retries ~1 min then reports `SKIP — certbot busy` (never the allowlist FAIL — that sends someone into Cloudflare to re-scope a token that is fine); re-run `rollout.sh verify` (#52) |
| `GET /client/v4/user/tokens/verify` answers `1000 Invalid API Token` for a token that works | that endpoint needs *User → API Tokens → Read* **on the token itself**; a correctly scoped zone-DNS token fails it exactly like a revoked one. It is NOT a liveness test — the DNS-01 dry-run is (`rollout.sh verify`), and `pack-verify.sh` uses `/accounts/{id}/tokens/verify` for the same reason (#41, #52) |
| certbot: `Either dns_cloudflare_api_token ... are required` on every run, first boot onward | the control plane booted before `/asp/cloudflare/token` existed (§4 comes after the apply) and `cp-tls.sh` cached an EMPTY token, then skipped the fetch forever (#38). Now: a cached ini only counts if it carries a token, a missing/empty parameter is FATAL by name with the fix, and nothing is cached. Repair an old box: create the parameter, re-run `cp-tls.sh` via SSM (it re-fetches). The first boot WARNing on TLS is expected on every fresh tenant — `account-foundations.md` §8 has the re-run order |
| Collab guests 403 at DCV | guests must exist as OS users on the target desktop — the portal creates them on demand at share time (`ensure_os_user` via SSM); provisioning writes the owner only |
| (historical) Renaming/re-keying terraform-managed desktops destroyed them | desktops left terraform state 2026-08-15 (portal-provisioned from the launch template) — kept only as a warning if anyone puts instances back under `for_each` |
| SG rules silently missing after refactor | converting inline SG rules to standalone resources leaves the ORIGINAL rules in AWS → duplicate errors that `-auto-approve` piping can hide; revoke the unmanaged rules then apply, and never grep terraform output for `^Apply` (ANSI codes defeat anchors — use `-no-color`) |
| EC2 reboot looks like "nothing happened" | instance state stays `running` through a reboot — the portal shows an action banner explaining this; don't chase a phantom bug |
| Settings → Displays 125%/150% applies 200% | GNOME on Xorg (Xdcv) offers integer scaling only; fractional needs mutter's experimental `x11-randr-fractional-scaling`, which renders larger and downscales — a real CPU/encode cost on these GPU-less desktops, so it stays OFF. The supported size knob is **text scaling** (host default 1.25; any value: `gsettings set org.gnome.desktop.interface text-scaling-factor 1.5`) plus per-app zoom (#4) |
| Session created but never READY | check `nice-xdcv` installed and `/etc/dcv/dcvsessioninit` (ASP-owned: exports the Ubuntu desktop identity, execs `/etc/X11/Xsession`) |
| No dock/sidebar, no tray icons, light gnome-terminal — session is unbranded "GNOME" | virtual sessions start via **`/etc/dcv/dcvsessioninit`**, NOT the SM agent's `init/` dir (that dir is a decoy — broker sessions pass no InitFilePath, nothing ever ran it; we lost hours to scripts there). Stock dcvsessioninit execs Xsession with no desktop identity → every ubuntu-branded gschema override + the ubuntu shell mode silently vanish. Fix (dcv-desktop-install.sh): rewrite it to `export XDG_CURRENT_DESKTOP=ubuntu:GNOME` + `GNOME_SHELL_SESSION_MODE=ubuntu` then `exec /etc/X11/Xsession`. Verify in-session: `gnome-extensions list --enabled` shows ubuntu-dock; a package update can restore the stock file — re-run the script after DCV upgrades |
| dcvserver dead after the first clean reboot — broker says "No DCV server found" while the agent heartbeats happily | the nice-dcv-server package does **not** enable its systemd unit, and hibernate/resume (never a real boot) masks it for days. `systemctl enable dcvserver` (dcv-desktop-install.sh does) |
| createSessions → "No DCV server found" for ~1–2 min after a boot or a session close, with dcvserver + agent both active | broker availability settles slowly; check `systemctl is-active dcvserver` first, then just retry for up to ~3 min before digging deeper |
| Client's local printers all appear in the session (as `*-Redirected-(<PC>)` cups queues) | `printer` is part of the `builtin` permission set. Disallow it (`%any% disallow printer` — portal default + share re-grants) and mask cups/cups-browsed on desktops (desktop-setup.sh). CCTs don't print by design |
| "Black screen" that isn't: dark empty GNOME Overview + tiny multi-head layout | the gateway serves a **web client** at `https://gw.<dns_zone>:8443` (unsupported path — sessions can end up as 4×800×600 heads); GNOME parks empty sessions in its dark Overview. Repair a mangled session: `dcv set-display-layout --session=<sid> 1920x1080` on the desktop. Prevention: native client with auto-resize (product path), wallpaper + auto-opened terminal at login (desktop-setup.sh), and `dcv get-screenshot` is the instant server-side truth for "what is this session actually showing" |
| A REAL black screen: fresh session streams one flat colour from its first frame, gnome-shell alive and idle, windows mapped, `xrefresh`/RandR changes don't help | mutter started against Xdcv's default `800x600 @ 0.00 Hz` mode and latched a dead frame clock (#20; intermittent — depends on how far shell startup gets before dcvagent's real mode lands). Diagnose: `dcv get-screenshot`, or `xwd -root` → 1 distinct colour; dcvagent I-frames ~5–7 KB vs 30–200 KB painted. Recover in place, user apps survive: as root `kill -TERM $(pgrep -u <user> -x gnome-shell)` (`org.gnome.Shell@x11.service` is `Restart=always`; `systemctl --user restart` is refused), then `dcv set-display-layout --session=<sid> 1920x1080` — the fresh shell may pick the tiled default. Prevention: dcvsessioninit sets a real 1920x1080 mode before gnome-session (#20) and the paint probe self-heals stragglers (#21) |
| **"4 screens, then black" on the FIRST Connect** — with #20's pre-mode in place | mutter starts ~2 s after session init, sees all four Xdcv `VNC-output-N` as *connected* (`max-num-heads=1` only limits `-enabledoutputs`) and enables them at their only mode → 4×800x600; the portal's Connect-time `set-display-layout` wins for ~100 ms, then the layout flips to ONE 3200x600 head at 0.00 Hz → the #20 dead frame clock. Every guard fired once and too early. Fix (#42): `session-layout-guard.sh`, backgrounded from `dcvsessioninit` as the session user, waits for gnome-shell then re-asserts the single 1920x1080 head for 60 s whenever the Xdcv default signature appears (extra output active / screen 3200x600 / primary at 800x600) and re-runs the paint probe after a correction. It cannot fight a real client resize. Since #47 it stays resident and re-runs the 60 s window whenever gnome-shell's PID changes (paint-probe TERM, crash → `Restart=always`), because mutter's startup never honours the X layout. **Prevention (#43, shipped):** `session-monitors-xml.sh`, run synchronously by `dcvsessioninit` after the #20 pre-mode, writes the session user's `~/.config/monitors.xml` from the live RandR set (real connector names `VNC-output-N`, the extras in `<disabled>`), so mutter finds a stored layout and the four heads never appear — fresh session logs `corrections=0`, a client resize still moves the head (root cause + re-verification: [display-layout-experiment.md](display-layout-experiment.md)). The guard is the backstop for a box whose output set does not match. Journal tags `asp-monitors-xml`, `asp-layout-guard`; `dcv get-screenshot -o <file> <session>` is the truth (write to `/var/tmp` — `/tmp` is private to the snap SSM agent) |
| "No DCV server found for the given criteria" on create | the SM agent pairs with the *running* dcvserver — after any dcvserver restart the agent must restart too or the broker drops the server. Fixed: agent unit drop-in `PartOf=dcvserver.service` (restart propagates). Verify with describeServers → AVAILABLE, then a test create |
| Connect silently does nothing / session never READY | `dcvserver` **exits when its last session is deleted** and the packaged unit has no Restart= — a dead dcvserver breaks Connect with no visible error. Fixed: systemd drop-in `Restart=always` (dcv-desktop-install.sh); portal also surfaces broker create failures on an error page now |
| `dcvserver` restarted at resume, box had **no** session | Expected, and NOT the #28 self-update bug: with no sessions `dcvserver` exits at resume and `Restart=always` brings it straight back. The discriminator is a box *with* a live session — there the same resume leaves the PID and `ActiveEnterTimestamp` unchanged. "dcvserver restarted" alone is not evidence of the update race |
| Instance wedged in `stopping` after Pause | hibernating within ~2 min of a boot/reboot can hang the stop — `aws ec2 stop-instances --force` clears it (RAM state lost, clean cold start). The idle-guard build should refuse hibernate right after boot |
| Sandbox DNS looks broken | builder workstation may not resolve fresh records — verify with `https://dns.google/resolve?name=<host>&type=A`, and `curl --resolve host:443:IP` to test |
| Instance goes network-dead ~5 min into provisioning (SSM ConnectionLost, EC2 "impaired") | the `network-manager` package (pulled by `ubuntu-desktop*`) ships `/usr/lib/netplan/00-network-manager-all.yaml`, flipping the netplan **renderer** to NM for all interfaces: networkd releases the ENI and — if NM is told unmanaged — NOBODY owns it. Fix (both, BEFORE the GNOME install; desktop-setup.sh does): keyfile `unmanaged-devices` guard AND shadow the renderer file (`/etc/netplan/00-network-manager-all.yaml` containing just `network: {version: 2}`). Recovery of a dead box: stop → attach root vol to a helper in the SAME AZ → write the shadow file → reattach → start (confirmed working); cross-AZ boxes are cheaper to rebuild |
| Portal shows **Build failed** on a terminal | `desktop-setup.sh` runs without `-e` by design, so a FATAL in a chained sub-step (DCV install, workbench) used to end in "Ready 100%" — the only clue was line ~5000 of `/var/log/asp-setup.log` (#7). Now the script records the failed step, publishes a marker with `failed`, and exits 1; the portal renders "Build failed (DCV)" instead of a "Waking up…" that never resolves. Repair = re-run `bash /opt/asp/setup.sh` (SSM) once nothing else holds the dpkg lock — the daily updater also retries the same release until it succeeds. Once DCV answers on 8443 the marker is treated as history |
| Two apt consumers on one dpkg lock during a build | `rollout.sh workbench` used to target every *running* desktop — including one that had booted 10 min ago and was mid-build; whichever apt lost the lock left a silently broken box (#7, hit for real). It now skips instances whose `status/<id>.json` marker is fresh and unfinished, says so, and tells you to rerun once they report Ready |
| Portal shows the default brand although `brand` is set | `/etc/asp-terminal.env` is **sourced** by every consumer; a bare `ASP_BRAND=Acme Terminals` is a prefix assignment to a command called `Terminals`, so the variable was never set and `portal-deploy.sh` wrote the default (#12). The template now single-quotes every value (`'` spliced). A control plane built before that: quote the line in place and re-run `portal-deploy.sh` — or just re-apply, the next replace writes it quoted |
| Client PCs get NXDOMAIN for a live domain | MSP **DNS filtering** (roaming agent or firewall port-53 interception) blocks the portal/gw hostnames as "newly seen" — nslookup even "to 8.8.8.8" gets an injected NXDOMAIN while DoH (`https://dns.google/resolve?...`) answers fine. Fix: allowlist the hostnames in the DNS filter (see §11). Hit the pilot org's own desktops on day 1 |

## 11. Client-side rollout

**Do these BEFORE the first user session:**

1. **DNS-filter allowlist** — add `portal.<dns_zone>` and `gw.<dns_zone>` (or
   `*.<dns_zone>`) to whatever DNS filtering the client runs (DNSFilter,
   Umbrella, firewall DNS interception, …). Fresh hostnames get NXDOMAIN'd as
   "newly seen" otherwise — see gotchas.
2. **DCV native client** — the portal's `/downloads` page always serves the
   newest build for every platform (CDN *root aliases* are always-latest;
   version labels resolved by `portal/downloads.py`: scrape amazondcv.com,
   fall back to `latest.json` — note latest.json LAGS the aliases, don't trust
   it for URLs). Managed clients: push the Windows MSI with your RMM
   (silent: `msiexec /i nice-dcv-client-Release.msi /qn`).
3. **Client firewall**: outbound TCP 8443 required, UDP 8443 preferred (QUIC;
   auto-falls back to TCP).
4. **Egress allow-lists** — anything the customer pins to "the terminals'
   address" (their firewall, vendor APIs, conditional access) gets
   `terraform output egress_ip`: the NAT's **Elastic IP**, which survives the
   NAT being stopped or replaced (#11). On a tenant built before the EIP
   existed the address changes **once** on the apply that adds it — if the
   operator hand-allocated one already, `terraform import aws_eip.nat
   <allocation-id>` first so it is adopted rather than replaced. An attached
   EIP costs what the auto-assigned address already cost; release it if the
   NAT is ever torn down (unattached ones bill the same).

Then: `https://portal.<dns_zone>` → Entra login → Connect.

## 11.4 Cost control — the idle watchdog

Compute is the only meaningful variable cost; the watchdog (control plane,
systemd timer, every 5 min — installed by `portal-deploy.sh`) pauses idle
terminals. **Pause (hibernate) is always preferred over power-off: identical
cost (~EBS only), but state survives** — *for pauses shorter than the pause→off
limit below (default 48 h)*. Past that the watchdog deliberately converts the
pause into a full power-off, so a box paused for days **cold-boots** and its
desktop is gone. `Hibernation: Configured=true` is not a promise that a
long-paused box restores a session; the conversion limit is what decides that
(field-confirmed 2026-09-01 — five user desktops paused multi-day all cold-
booted, while two boxes paused briefly came back as genuine resumes). Activity = any of:

1. a DCV client connected (someone is looking),
2. `claude` consumed CPU this window (`idle-probe.sh` sums claude process CPU
   ticks; an *active* agent run burns CPU, an idle open REPL doesn't — and
   hibernate preserves an idle REPL anyway, so only in-flight work keeps a
   machine up),
3. 1-min load ≥ 0.25 (builds, tests, servers).

**`IdlePolicy=pause-on-disconnect` was proposed and declined (operator, 2026-09-03).**
It came out of a "client disconnected but the box didn't hibernate" report — where the
investigation found the box legitimately busy for hours on an agent run, i.e. the watchdog
working correctly. Three reasons it stays declined, so nobody rebuilds it from the same
symptom:

- **A disconnect is not an intent signal.** A closed lid, a wifi switch, a DCV client crash
  and a deliberate walk-away are indistinguishable here, and only one of them means "stop".
  The signals above are OR'd precisely so a disconnect is *necessary but not sufficient*.
- **It would break jobs, not pause them.** Hibernate preserves RAM but not sockets, so a
  long agent run resumes with dead connections mid-call — and resume is already this
  fleet's fragile moment (#28's update race). The feature would manufacture more of them,
  during work.
- **The legitimate want is already served by `IdleMinutes`.** Set it to 5 and a terminal
  pauses five minutes after you disconnect *provided nothing is running*. All
  pause-on-disconnect would add is ignoring the work check — which is the part that is
  wrong.

Default: 30 idle minutes → hibernate; never within 15 min of boot (wedge risk).
**All tunable from the admin page** ("Idle & cost settings": enable/disable,
idle minutes, sensitivity preset — stored in SSM `/asp/idle/config`; the raw
CPU-sec/load thresholds are the watchdog's constants), with **per-terminal
overrides** on each terminal card
(default / keep awake / custom minutes — stored as instance tags
`IdlePolicy` / `IdleMinutes`, so they survive everything and are visible in
the AWS console too). Logs: `journalctl -u asp-idle-watchdog`.

**Pause→off conversion:** a pause older than the admin-set limit (default
48 h, 0 = never) is converted to a full power-off — the watchdog wakes the
machine (tag `AspConvert=off`), lets it settle, and issues a clean stop once
the dpkg lock is free and nobody is connected; any connection cancels the
conversion. Cost is identical either way; this exists because a 2-day-old
session is stale anyway and it sidesteps EC2's 60-day hibernation cap. Two
hard-won details: the "apt busy" signal must be the **dpkg lock**
(`flock -n /var/lib/dpkg/lock-frontend`), never a process grep — Ubuntu's
always-running `unattended-upgrade-shutdown` monitor makes greps read busy
forever; and **uptime persists across hibernate**, so it cannot gate
"time since wake". The portal's honest wake state rides the same truth: a
TCP probe of desktop:8443 from the control plane (EC2 `running` and even
broker AVAILABLE both lie during the ~1.5–3.5 min RAM restore).

## 11.5 Access & user-lifecycle model

- **Login:** any account in the client's Entra tenant can authenticate; the
  portal authorizes by **terminal ownership** (Owner tag), so adding a user on
  the admin page is fully self-contained — no Entra group edits needed.
- **Groups:** `ASP-Admins` = full admin page (per client this is the **aiops
  account**). Viewer-only users (join shared sessions, never own a terminal)
  are managed on the **admin page** ("Viewer-only users" card, stored in SSM
  `/asp/portal/viewers`); the `ASP-Viewers` Entra group also still works.
- **Add user (admin page):** provisions `<client_code>-cctNN` from the launch
  template (first boot ~15–25 min). **Remove user:** deletes their broker
  sessions and terminates the instance + disk (confirm dialog; no snapshot —
  add one first if the client wants offboard retention).
- **Sharing:** owners (and admins) grant view/control per session; the OS user
  for a guest is created on the target desktop on demand (SSM). Owners see
  active grants on their page and can revoke; admins can revoke any.
- Share grants live in portal memory (PoC): a portal restart clears the grant
  *list* (existing DCV connections continue; re-share to re-grant).

## 11.6 Medical profile (Ai Build Medical — regulated data)

Opt-in per tenant. What it changes: every terminal boots with
`ASP_PROFILE=medical` (the kit then pins Claude Code + claude-mem to Bedrock
in THIS account, sweeps API keys, brands the desktop PHI-approved — see the
repo README "Medical mode"), the desktop role may invoke Claude on Bedrock,
DCV sessions deny `file-download` + `printer` (owner and guests), and a
zero-data-retention lock keeps Fable/Mythos-tier models — the ones that
require provider data sharing — unavailable.

Build:
1. `profile = "medical"` in the tenant tfvars; `terraform apply`. (Standard
   tenants: nothing changes; `aws_ebs_encryption_by_default` is applied to
   ALL tenants from now on.)
2. **Enable Anthropic model access once** in the Bedrock console for the
   tenant Region (the instance role only gets `ViewSubscriptions`, on
   purpose).
3. `aws/scripts/bedrock-zdr.sh --apply --region <R>` (with the tenant
   profile), then `--check`: retention `none`, EBS default on, invocation
   logging off, a Fable request refused. If `--check` says it could not prove
   the Fable exclusion, pass `--fable-id` with the Region's actual ID.
4. Deploy the control plane / portal as usual — `ASP_PROFILE` flows
   automatically (`portal-deploy.sh` → `/etc/asp-portal.env`).
5. Optional: `terraform output -raw bedrock_zdr_scp_json` → hand to the
   client's AWS Organization admin. Standalone accounts have no SCP; be
   plain with the client that their own account admins could weaken the
   retention setting (the role-level guard stops the platform's roles, not
   humans) — `--check` is the audit.

Acceptance on a fresh medical terminal: `~/claude-terminal/verify.sh` zero
FAILs (medical section included), first login shows the PHI wallpaper +
shell banner and `claude` answers with no login prompt, a DCV client cannot
download a file from the session, and one claude-mem compression cycle shows
egress only to Bedrock endpoints.

Offboarding a medical user/terminal — the wipe list matters when a box is
kept or repurposed rather than terminated (termination = encrypted EBS
crypto-shred, plus the portal's Remove-user path): `~/.claude-mem/` (memory
DB + Chroma — PHI store), `~/.claude/` (project transcripts are PHI too),
`~/.cache/claude-cli-nodejs`, and the home directory in general. Never
snapshot a medical terminal on removal.

## 12. Teardown

`terraform destroy` in the tenant, delete the two buckets, the 3 Entra groups,
the app registration, the CF A records, and the SSM `/asp/*` params.
`aws_ebs_encryption_by_default.this` has `prevent_destroy` — it is
account/Region-wide, so `terraform state rm aws_ebs_encryption_by_default.this`
first (leaves the setting ON, which is what you want), then destroy.

## Known open items (update as they land)

- (done 2026-08-16) 60-day hibernation cap: the watchdog converts Pause→Off
  after 48 h (§11.4).
- Broker persistence is in-memory: a control-plane reboot drops session records
  (they recreate on next Connect); enable DynamoDB/MySQL persistence if that bites.
- Portal share-grants (`_grants`) are in-process memory — restart loses guest
  grants until re-shared; fine for PoC.
- In-tenant cert renewal blocked on the CF token IP filter (§1).
