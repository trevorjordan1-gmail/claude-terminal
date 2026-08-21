# {{CLIENT_DOMAIN}} — Resume Point (STATE.md)

**Last updated:** {{DATE}} · **Read first when resuming.** Rewrite sections in place as
facts change — never append a changelog. Absolute dates only. A cold session must be able
to resume from this file alone.

<!-- Flip ⬜ → ✅ only on VERIFIED, never on attempted. Stage numbers mirror the client's
     onboarding portal (onboarding.adnet.tools) so the checklist and the portal speak the
     same language. -->

## Where we are right now

{{One paragraph, rewritten each session: what's live, what's verified, what's next, what's
blocked on whom.}}

```
⬜ Stage 2a Accounts & pack — 5 vendor accounts + tokens minted; pack-verify
            writes probed on this terminal (MACHINE-VERIFIED)
⬜ Stage 2b Hudu "Ai Foundations" root-of-trust vaulted (ENGINEER ATTESTS —
            not verifiable from this box)
⬜ Stage 3  Terminal + workspace — VM built, bootstrap run, Streamer running
            (machine-verified) + machine bound under the client in Splashtop
            (ENGINEER ATTESTS) · SETUP complete (folder + repo + launcher)
⬜ Stage 4  PLATFORM BUILD — droplet hardened → tunnel → edge → Access → Postgres
            (isolation PROVEN) → Healthchecks → status.{{CLIENT_DOMAIN}} →
            restic + restore-verify → platform-verify battery PASSED
⬜ Stage 6  Build day — builder handoff (own password, own seat), first real app
⬜ Stage 7  Billing — cards swapped to the client (inside Wasabi's 30-day trial!)
⬜ Stage 8  Handoff — exit gate: everything owned, documented, drilled
```

## Verified at last session close ({{DATE}})

| Check | Result |
|---|---|
| `scripts/workspace-status.sh` | {{clean / findings}} |
| Credential pack (writes probed) | {{n/n providers}} |
| aiops mail (`aiops-mail.sh verify` round trip) | {{PASS / pending ENTRA_* / not provisioned — no machine-mailbox capability (MAIL_CAPABILITY=none, {{who decided, date}})}} |
| {{platform-verify.sh once stage 4 runs — port scan, isolation, silent-alarm, restore drill}} | |

## Live components

- **Droplet `docker01.{{CLIENT_DOMAIN}}`** — {{DO id · IP · region · size · created date ·
  daily DO backups window · cloud firewall id + the one allowed SSH source}}
- **Edge** — {{tunnel name/id · catch-all → traefik · pinned image tags}}
- **Postgres** — {{version · volume · no host port · tenants list}}
- **Monitoring** — {{Healthchecks project · checks list · status page URL}}
- **Backups** — {{restic repos (docker01 + this terminal) · schedule · restore-verify check}}
- **Apps** — one line each: {{name · repo · net · db · URL · CI badge state}}

## Repos (org: {{GITHUB_ORG}})

- `{{GITHUB_ORG}}/{{CLIENT_DOMAIN}}` — this platform folder.
- {{one per app — folder name == repo name == subdomain}}

## Access / credentials

Pack lives ONLY in `./.env` (0600). Hudu "Ai Foundations" = root of trust (logins, TOTP
seeds, backup codes, break-glass, both restic passwords — NOT regenerable). API keys are
never vaulted — regenerable from the logins.

| Credential | Named | Expires | Notes |
|---|---|---|---|
| Cloudflare token | {{CLIENT_CODE}}-cct01 {{BUILDER_NAME}} | {{date — CF max 1 yr}} | identify by ID: {{id}} |
| DigitalOcean token | 〃 | {{date}} | full-access, 1 yr |
| GitHub machine PAT | 〃 | {{date}} | fine-grained, org-scoped, all-RW set (incl. Issues) |
| Wasabi root keys | — | — | ⚠ billing session must land inside the 30-day trial |
| Healthchecks keys | — | — | management + read-only (status page uses RO) |
| aiops mail token | this terminal | renews with use | device-code as aiops; re-`login` if it lapses — no admin needed |

## Next actions (resume point)

{{Rewrite each session: what's next · gated on whom · by when.}}

## Growth / hardening watch-list (seeded from the pilots' real failure modes)

1. **Secret expiry** — every token above has a real date recorded + a calendar owner; the
   pilot's non-expiring PAT was its weakest link.
2. **Disk on the shared droplet** — prune on every deploy (CI images add up); DO alert at 80%.
3. **Network-bridge fragility** — every external Docker net declared in every compose file
   that uses it; runtime `network connect` is forbidden.
4. **Backup restore** — automated restore-verify must stay green; a manual drill happened
   {{date}} on this engagement.
5. **Silent monitoring death** — the status page pings its own check; Healthchecks is the
   off-box vantage that sees the box die.
6. **Object storage is a third store** — DB dumps don't carry uploaded files; every app with
   a volume is in the restic scope (a pilot engagement nearly lost its uploads this way).
7. **Apps with no login** ride entirely on Access/allowlists — adding real auth gates any
   exposure change.
8. **Image bumps are deliberate** — pinned tags mean someone schedules security bumps.
9. {{engagement-specific risks appear here}}

## Open questions

- {{unratified assumptions — name them so nobody cites them as settled}}
