# aws/ — cloud Claude Code Terminals (AWS + Amazon DCV)

The cloud platform of the stack: where `windows/` builds a Hyper-V VM for the
kit to land on, this directory builds an entire **tenant** — a client-owned
AWS account serving streamed Ubuntu desktops that exist to run Claude Code.
Each user gets a 1:1 EC2 desktop (private subnet, hibernation for pause),
streamed by [Amazon DCV](https://aws.amazon.com/hpc/dcv/) through a Connection
Gateway, brokered by single-use tokens, fronted by a small FastAPI portal with
Entra ID (Microsoft 365) login. No SSH anywhere — admin access is SSM only.

```
user ── Entra login ──> portal ──> Session Manager Broker ──> token
  └───── DCV native client ──> Connection Gateway (8443) ──> desktop
```

## Layout

| Path | What it is |
|---|---|
| `terraform/` | Tenant substrate: VPC, control plane + EIP, desktop launch template, SG-to-SG rules, IAM. **No desktop instances** — users are provisioned from the portal admin page. |
| `portal/` | FastAPI portal: Entra OIDC login, machine list with real states, power controls, Connect (broker token + `dcv://` handoff), session share/join/revoke, admin add/remove user, idle & cost settings, `/downloads`. |
| `scripts/` | Idempotent provisioning + operations: desktop GNOME/DCV setup, control-plane broker/gateway/TLS, idle watchdog (auto-pause), WU-style self-update, fleet rollout. |
| `runbooks/build-tenant.md` | **Start here** — builds a complete tenant from zero, with every hard-won gotcha. |
| `tenants.example.json` | Template for the git-ignored `tenants.json` fleet registry. |

## Quick start

1. Read [`runbooks/build-tenant.md`](runbooks/build-tenant.md) end to end.
2. Tenant identity lives ONLY in git-ignored files: `terraform/backend.hcl`,
   `terraform/terraform.tfvars`, and `tenants.json` (copy the example).
3. Iterate with the scripts→S3→SSM pattern (runbook §9); never hand-edit a
   remote box without folding the change back into the script.

## How the platform and the kit divide the work

The kit (`modules/`, via `get.sh`) runs per-user on every terminal and gates
itself with `is_dcv_terminal` (set by `/etc/asp-terminal.env`). The platform
(this directory) owns everything below that:

- GNOME (`ubuntu-desktop-minimal` + ubuntu-dock/appindicator), the **real
  branded Ubuntu session** (`/etc/dcv/dcvsessioninit` exports
  `XDG_CURRENT_DESKTOP=ubuntu:GNOME` + `GNOME_SHELL_SESSION_MODE=ubuntu` —
  that file is what dcvserver actually runs; the SM agent `init/` dir is not
  in the path), text scaling, wallpaper, dock favorites, welcome terminal.
- DCV server/agent/broker/gateway config, session permissions (**printing
  disallowed by design**; cups masked), file transfer (storage root = home),
  single-display policy, TLS, idle watchdog, self-update timer.
- Users and sudo (`/etc/sudoers.d/010-<user>-nopasswd`, dir mode 755).
- Firefox (snap) installed and pinned; snap XDG paths wired into the session.

Terminals re-run the kit's `get.sh` from `main` on every fleet release —
**main is production** for cloud fleets: idempotent and non-interactive are
hard requirements.

## Fleet updates (Windows-Update model)

- `scripts/rollout.sh portal|scripts|workbench|all` loops the `tenants.json`
  registry (git-ignored; `ASP_TENANTS` overrides the path) — syncs scripts to
  each tenant bucket, publishes the release channel, redeploys portals.
- Every terminal runs a daily self-update timer (plus on wake): applies a
  newer channel version only when nobody is connected, then re-runs the kit
  bootstrap. Paused terminals catch up ~10 min after waking.
- Tag releases; `portal /healthz` reports the running version per tenant.

## What never lands in this public directory

Tenant identity and records: account IDs, bucket names, hostnames/zones,
Entra tenant/app/group GUIDs, EIPs, instance IDs, `tenants.json`,
`terraform.tfvars`/`backend.hcl`, tfstate, and per-tenant as-built docs.
Those live with the operator (private overlay repo or local files). The
same rule as the repo root: no machine- or tenant-specific identifiers.
