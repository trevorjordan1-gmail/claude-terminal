# MERGE BRIEF — `aws-dcv-platform`

> Review brief for this branch. **Delete this file as part of the merge** —
> its durable content lives in `aws/README.md`, the runbook, and the CHANGELOG.

**For the claude-terminal maintainer agent.** This branch makes the repo the **source of truth for the whole stack**: the AWS/DCV cloud platform moves in under `aws/`, the cloud sibling of `windows/`. It supersedes the prior platform-support request document — everything that request asked for already landed on main (`is_dcv_terminal`, `27-postlogin-finish`/`cct-finish`, `.bashrc` PATH, gui_conf one-shot-bus, dark terminal seeding) and is verified working on the cloud fleet.

## What's in it

| Path | Contents |
|---|---|
| `aws/terraform/` | Tenant substrate: VPC, control plane + EIP, desktop launch template (hibernation), SG-to-SG rules, IAM; SSM-only posture, no SSH anywhere. No org defaults; backend is init-time config; new required var `cert_email`. |
| `aws/portal/` | FastAPI portal: Entra OIDC login, machine list w/ true states, power controls, Connect (broker token + `dcv://` handoff), session share/join/revoke, admin add/remove user, idle & cost settings, `/downloads`. Branding neutral. |
| `aws/scripts/` | Idempotent provisioning + ops: desktop GNOME/DCV stack, control-plane broker/gateway/TLS, idle watchdog (auto-pause = hibernate), WU-style self-update timer, `rollout.sh` multi-tenant release (reads git-ignored `tenants.json`; `ASP_TENANTS` overrides). |
| `aws/runbooks/build-tenant.md` | Zero-to-tenant runbook, genericized, incl. the full gotcha table — every row was a production failure first. |
| plus | `aws/tenants.example.json`, root README section, CHANGELOG entry, `.gitignore` guards (tenants.json, `*.tfvars`, `backend.hcl`, tfstate). |

**This branch does NOT touch** `get.sh`, `bootstrap.sh`, `modules/`, `verify.sh`, or `lib/` — merging cannot affect kit consumers or the fleet's daily self-update.

## Safety

- pii-guard is green on the branch (author identity + private denylist).
- Independent identifier scan before push (account IDs, bucket names, hostnames/zones, Entra GUIDs, EIPs, instance/template/subnet IDs, org names, usernames): clean.
- Tenant identity never lands in the repo by construction: variables have no org defaults, terraform backend is init-time config, the fleet registry is git-ignored with a committed example — the same "no machine-specific identifiers" rule the kit has always had.

## Invariants to preserve (load-bearing)

1. **No tenant identity in the repo, ever.** Operators keep it in git-ignored files; scripts read `/etc/asp-terminal.env` (dropped by terraform user-data) — that is the interface.
2. **main is production twice over**: terminals re-run `get.sh` from main daily (kit), and operators sync `aws/scripts/` to tenant buckets at release tags (platform). Idempotent + non-interactive are hard requirements in `aws/` too.
3. Layered scripts: `desktop-setup.sh` chains `dcv-desktop-install.sh`; every script is safe to re-run via SSM — that IS the update mechanism.
4. Version discipline: repo tags = platform releases; `rollout.sh` stamps `git describe` into each tenant's release channel; portal `/healthz` reports the running version.

## Platform facts kit modules can rely on

- Sessions run the **real branded Ubuntu session**: `/etc/dcv/dcvsessioninit` (ASP-owned) exports `XDG_CURRENT_DESKTOP=ubuntu:GNOME` + `GNOME_SHELL_SESSION_MODE=ubuntu`, then execs `/etc/X11/Xsession`. That file is what dcvserver actually runs — the SM agent `init/` dir is NOT in the code path; never put logic there.
- **No printing by design**: session permissions disallow the DCV `printer` feature; cups/cups-browsed are masked. Never install or enable cups on DCV boxes; keep the `printing-direct` extra gated off DCV.
- **The browser is Google Chrome (native deb)**, pinned first in the dock; favorites are dconf-locked host-side (kit follow-up: gate `40-gnome-qol`'s Firefox pin + verify.sh's dock expectation off DCV, or align them to Chrome there).
- **File transfer is on** (storage root = user's home, both directions).
- `dcvserver` is explicitly boot-enabled — the package does not do this; the first clean reboot exposed it.

## Known open items (inherited — fix at will)

- Portal `_ensure_session` doesn't retry broker "No DCV server found" (availability settles ~1–2 min after a boot or session close); users get a friendly try-again page today.
- Portal branding is hardcoded-neutral; per-tenant branding would be a config value (e.g. `ASP_BRAND`) if wanted.
- Broker session records + portal share-grants are in-memory (documented pilot limitation; DynamoDB/MySQL persistence is the upgrade path).
- The gateway also serves an unsupported web client on :8443 — keep/block decision open.

## After merge (operator-side context, not your work)

The pilot operator repoints fleet ops to this repo's `aws/` with private `tenants.json` + `backend.hcl` + `terraform.tfvars`. Two known repoint gotchas on their side: the `cert_email` user-data addition makes terraform plan a control-plane replacement (lifecycle-ignore or accept), and `ASP_CERT_EMAIL` must be added to the existing control plane's env once via SSM. From then on, kit and platform changes ship as one commit.
