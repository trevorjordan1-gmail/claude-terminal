# Operator build boxes (engagement workbenches) — design

**Status:** approved 2026-08-18 (brainstormed with the operator 2026-08-16→18).
**Scope:** `aws/portal/` + one new runbook. No kit, terraform, or customer-tenant
behavior changes.

## Problem

Engagements need a workbench that exists *before* the customer's environment
does. Standing up a customer platform (droplet, Cloudflare, Entra, or a DCV
tenant) requires a box to build FROM — and analysis-style engagements need a
box to work from even though nothing is ever provisioned in the customer's
name. Using personal machines for this has repeatedly caused identity bleed
(wrong git authors, mixed credentials).

The operator's own DCV tenant is the natural home: one hibernatable desktop
per engagement (`<code>-build01`), any engineer on the team can enter it,
customer-scoped credentials live on that box and nowhere else, and the box is
purged when the engagement stabilizes.

## Decision: config-gated capability on main — no operator branch

Group-owned machines and self-service build-box provisioning are a **generic
operator capability** of the platform, dormant unless configured. This follows
the portal's existing pattern (`GROUP_VIEWERS`/`GROUP_ADMINS` are optional
config): a new optional `GROUP_BUILD_ENGINEERS` value enables everything; no
customer tenant sets it, so customer deployments carry identical code with no
UI surface, no authz path, and no behavior change.

Rejected alternatives: a long-lived operator branch (permanent merge debt, two
release tracks, two sources of truth for one fleet) and a private overlay repo
(patch machinery for ~three files of difference). Deployment divergence
belongs in config, not in git branches.

Invariants preserved: main stays the single production track for kit and
platform; tenant/operator identity (group IDs, client codes) lives only in
deployment config and AWS tags — never in this repo. Docs and examples use
`acme` placeholders exclusively.

## Portal changes

1. **Group ownership.** Machines may carry an `OwnerGroup` tag (an Entra
   security-group object ID). List/power/connect authz becomes: Owner UPN
   matches the signed-in user **or** `OwnerGroup` is present in the user's
   group claims. Absent the tag, behavior is exactly today's 1:1 model.
2. **Self-service provisioning.** The admin area gains a "New build box" form,
   rendered only when `GROUP_BUILD_ENGINEERS` is configured and the user is in
   that group (or an admin). Input: a short client code. Action: launch
   `<code>-buildNN` from the existing desktop launch template (index logic
   reused from `cctNN` naming) with tags:
   - `OwnerGroup` = the build-engineers group ID
   - `BuildFor` = the client code (the engagement)
   - `Creator` = the signed-in engineer's UPN
   - `Customer` = the operator tenant's own value, unchanged — so the idle
     watchdog, rollout, and portal treat the box as a normal desktop.
   `BuildFor` is deliberately a separate tag: `Customer` means "which tenant
   owns this instance," and overloading it would break watchdog/rollout
   filters.
3. **No terraform changes.** Provisioning reuses the desktop launch template;
   group ownership is tags + portal logic only.

Group-claims caveat (documented, not coded around): Entra omits the groups
claim on token overage (~200 groups). Irrelevant at operator scale; noted in
the runbook so a future debugging session doesn't rediscover it.

## Runbook: `aws/runbooks/build-boxes.md`

Committed, operator-framed, `acme` examples only. Two audiences:

**Conventions (for engineers).** The workbench is engagement-type-agnostic:
- *Identity belongs to the box, not the visitor.* All provider-facing identity
  (git author, gh, mail, cloud CLIs) is the engagement's service identity —
  for platform builds that is `aiops@<clientdomain>` everywhere — configured
  once at setup and never switched per visitor. The **only** per-visitor
  switch is the Claude seat (`/login`); check `/status` when entering a box
  you didn't create (seat fairness). Claude-mem stays per-box on purpose: it
  is the engagement's journal, shared by whoever drives.
- *Per-engagement decisions recorded at box setup* (not fixed policy):
  **credential set** (platform builds get the full pack; analysis/adoption
  engagements get only the access the engagement grants) and **backup
  destination** (platform builds arm nightly restic to the client's storage
  bucket per SETUP join-mode; engagements with no client bucket choose an
  operator bucket or explicitly skip, leaning on git + the credential vault).
- *Lifecycle:* hibernate-by-default via the idle watchdog (defaults as
  shipped; pauses older than the configured limit auto-convert to power-off —
  fine for workbenches, they cold-boot). Keep the box for the whole
  engagement; purge when the customer is flying: workspace-status clean →
  state pushed → vault current → terminate. Backups (if armed) outlive the
  box in the client's bucket. Analysis workbenches deserve the strictest
  purge discipline — they hold credentials into live customer systems.
- Simultaneous connects share one session (screen + input) — the portal's
  state list shows who's on.

**Deployment (for the operator's admin agent).** Create the build-engineers
Entra security group and add the engineers; set `GROUP_BUILD_ENGINEERS` in the
portal env; restart the portal; provision the first boxes from the admin form;
verify a non-creator engineer can see/start/connect a group-owned box and a
non-member cannot.

## Testing

- Dormancy proof: with `GROUP_BUILD_ENGINEERS` unset, the portal renders no
  new UI and the authz path is byte-equivalent to today (unit-style check on
  the machines-list filter plus template render).
- Group path: claims containing the group → box visible/controllable; claims
  without it → 404/denied, exactly as a foreign 1:1 box behaves today.
- First real deployment is the operator's own tenant — the only tenant that
  will ever enable the feature — so field risk never touches a customer.

## Non-goals

- NAT EIP pinning (deliberately dropped by the operator — post-build access
  moves on with the engagement).
- Automated seat banners / usage enforcement (`/status` convention +
  optionally `--with-usagemeter` cover it; revisit only if fairness breaks in
  practice).
- Any customer-facing exposure of the feature, ever.
