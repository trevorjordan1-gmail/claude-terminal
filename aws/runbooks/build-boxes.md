# Build boxes — per-engagement operator workbenches

An **operator capability**, dormant on every customer tenant: engagements need
a machine that exists *before* the customer's environment does (platform
builds) or without any customer infrastructure existing at all
(analysis/adoption engagements). A build box is one hibernatable desktop per
engagement in the **operator's own tenant** — `acme-build01` — that every
build engineer can see, start, and enter through the portal.

Nothing here applies to customer tenants. The feature activates only where
`GROUP_BUILD_ENGINEERS` is set in the portal env; customer portals run the
identical code with no UI surface and no authz path.

## How it works

- The machines page shows a **New build box** card to members of the
  build-engineers group (and admins). Enter the engagement's short client
  code → `<code>-buildNN` launches from the normal desktop launch template.
- Tags: `Owner`/`Creator` = the engineer who created it, `OwnerGroup` = the
  build-engineers group (this is what grants the whole team access),
  `BuildFor` = the engagement code, `Customer` = the operator tenant as usual
  (so the idle watchdog, rollout, and portal treat it as a normal desktop).
- The box's local session user is the fixed **`build`** — a group-owned box
  has no single UPN to derive a user from. Everyone who connects shares the
  ONE session (screen and input); the portal's state list shows when someone
  is already on.
- Client codes live in AWS tags and the portal only. **Never commit a real
  client code to this repo** — docs and examples stay `acme`.

## Conventions for engineers

**Identity belongs to the box, not the visitor.** Everything provider-facing
— git author, `gh`, cloud CLIs, mail — is the engagement's service identity
(for platform builds: `aiops@<clientdomain>` everywhere), configured once at
box setup and never changed per visitor. The **only** per-visitor switch is
the Claude seat: `/login` when you enter a box you didn't create, and check
`/status` first so you don't burn a teammate's weekly usage. claude-mem stays
per-box on purpose — it is the engagement's journal, shared by whoever
drives.

**Recorded at box setup (per engagement, not fixed policy):**

| Decision | Platform build (Ai Build) | Analysis/adoption (Ai Adopt) |
|---|---|---|
| Credential set | full pack + aiops identity | only the access the engagement grants |
| Backups | nightly restic → the client's storage bucket (SETUP join-mode) | operator bucket, or explicitly skip (git + vault are the durable stores) |

**Lifecycle.** Hibernate-by-default via the idle watchdog (defaults as
shipped). A pause older than the configured limit auto-converts to a clean
power-off — fine for workbenches; they cold-boot in a few minutes. Keep the
box for the whole engagement; purge when the customer is flying:

1. `workspace-status.sh` clean — nothing uncommitted or unpushed anywhere.
2. Engagement state pushed to its repo; credential vault current.
3. Terminate the instance (the disk goes with it). Armed backups outlive the
   box in the client's bucket.

Analysis workbenches deserve the strictest purge discipline — they hold
credentials into a customer's *live* systems, not greenfield accounts.

## Deployment (operator's admin agent)

One-time, on the operator tenant only:

1. Entra: create a security group for build engineers (plain security group;
   the app's `groupMembershipClaims: SecurityGroup` already puts it in
   tokens). Add the engineers.
2. Portal config: add `"GROUP_BUILD_ENGINEERS": "<that group's object ID>"`
   to the `/asp/portal/config` SSM parameter (JSON), then re-run
   `portal-deploy.sh` (or `rollout.sh portal`). Do NOT hand-edit
   `/etc/asp-portal.env` — `portal-deploy.sh` regenerates it from SSM on
   every deploy, so a hand-added line vanishes at the next rollout.
3. Provision the first box from the machines page form.
4. Verify **both directions**: an engineer who didn't create the box can see
   it, start it, and connect; a desktop user who is NOT in the group gets no
   card and a 403 on a direct POST to `/build-boxes/new` and
   `/machines/<id>/*` for that box.

Known Entra caveat (documented so nobody re-debugs it): group claims are
omitted from tokens on claim overage (~200 groups per user). Irrelevant at
operator scale; if a member ever "loses" access, check their group count
before anything else.
