# Changelog

## 2026-08-14

- **The aiops mail rider — terminals can now use email.** New
  `templates/aiops-mail.sh`: send and read mail AS the client's
  `aiops@<clientdomain>` mailbox via Microsoft Graph (users mail the terminal,
  the terminal mails them back). Rides the ONE `<code>-sso` registration —
  delegated Mail.Read/ReadWrite/Send consented **Principal-scoped to the aiops
  account only** (no other mailbox in the tenant is reachable, by construction)
  with the public-client fallback on, so the terminal signs in by device code
  and no client secret sits on the mail path. `New-ClientSSO.ps1` creates all
  of it inline when `-AiopsUpn` is given; new `Grant-AiopsMail.ps1` retrofits
  registrations that predate the rider (idempotent, same relay flow). The tool
  has an identity guard — if anyone but aiops completes the device-code
  sign-in, the token is dropped on the spot — and a `verify` command that
  proves the channel with a self-send round trip and deletes its own probe.
  SETUP gains step 6 (install + login + verify; join-mode terminals log in
  per-machine — the token cache never travels); STATE template records the
  probe result and the token's lifecycle; the external-IT one-pager now names
  the mail permissions honestly (delegated, exercised only by the service
  account we created, on its own mailbox — still nothing tenant-wide).
- **Issues RW joins the fine-grained PAT set** (field-found at the first AI
  Build engagement: the terminals plan and work the repo tracker, not just the
  code). `pack-verify.sh` now proves it empirically — an issue is created in
  the probe repo before deletion — and tells a token minted before the change
  exactly what to add. Guide §4 and the onboarding templates carry the new set.
- `pack-verify.sh` notes `AIOPS_UPN` when absent (the mail tool's expected
  identity; login still works without it, minus the mismatch guard).

## 2026-07-31

- New `windows/` directory: host-side Hyper-V tooling, covering the one step
  that was still manual in front of `get.sh` — building the Ubuntu VM.
  `New-UbuntuHyperVVM.ps1` stages the newest Ubuntu 24.04 Desktop ISO
  (SHA256-verified against Canonical's published sums, re-downloaded only on a
  new point release) and builds a Generation 2 VM interactively.
  `windows/get.ps1` is the Windows counterpart of `get.sh`:
  `irm …/windows/get.ps1 | iex` from an elevated PowerShell.
  The launcher exists because PowerShell treats piped content differently from
  a script file — `#Requires` is ignored, `exit` closes the console instead of
  ending the script, and parameters cannot bind. It downloads the script and
  invokes it as a file, so all three behave. `windows/` sits outside module
  dispatch; the module contract does not apply to it.
- New core module 41-splashtop-cursorfix, working around a use-after-free race
  in the Splashtop streamer's cursor encoder (SRFeature, ≤3.8.0.0). Animated X
  cursors trigger it deterministically — the X server cycles their frames and
  each frame fires an XFixes event the streamer must PNG-encode, so a single
  animated cursor kills the streamer in about two seconds and drops every
  session. Four guards: staticize every animated cursor in every host theme via
  `dpkg-divert` (originals park at `*.animated`, so theme upgrades land
  harmlessly); republish Firefox's `.desktop` with `StartupNotify=false` so
  launching it never asks for a busy cursor; repack and sideload
  `gtk-common-themes`, because snap apps can't see host themes at all; and
  LD_PRELOAD a shim onto the streamer that defers cursor-pixbuf destruction by
  three seconds, closing the race itself — the deterministic trigger is only
  part of it, since ordinary cursor churn fires the same race occasionally.
  Scanning every file in every theme matters: `half-busy`, legacy hash-named
  files, and the Adwaita/DMZ/redglass fallbacks are animated too, and a first
  attempt covering only Yaru's four named cursors kept crashing. The module
  skips entirely unless `splashtop-streamer` is installed, so RustDesk boxes
  are untouched. Live desktop sessions need one logout, since running apps hold
  cursors built from the old files. A version canary raises a NEXT STEPS line
  once the installed streamer is newer than 3.8.0.0, so an upstream fix prompts
  retirement rather than passing silently; revert steps are in the module
  header. Caveat: the sideloaded theme snap no longer auto-refreshes, and a
  manual `snap refresh --amend` would restore animated cursors until the next
  bootstrap run — the shim still prevents crashes in that window.
- `bootstrap.sh`: a core module may now carry `# ct-after-extras` to run at the
  very end of a run instead of in the core pass. 41-splashtop-cursorfix needs
  the streamer that `--with-splashtop` installs during the extras pass, and
  extras run after core — without this, a fresh box would skip the crash guard
  on the very run that installed Splashtop.
- `modules/extra/splashtop.sh` is real: `./bootstrap.sh --with-splashtop`
  installs Splashtop Streamer, asks for your 12-digit deployment code, and
  registers the machine, so it appears in the Splashtop console when the run
  ends. It also enables the streamer's own auto-update, because Splashtop
  publishes no "latest" download URL — the pinned URL only has to get the
  package on the box once. An already-installed streamer is left alone, so
  re-running bootstrap stays unattended.
- Modules may now advertise themselves with `# ct-suggest: <command>|<hint>`.
  Bootstrap prints the hint under NEXT STEPS when that extra didn't run and
  the command isn't present, so a core-only run ends by telling you the switch
  to add. Adding the next opt-in product (RustDesk) is a module file only.
- `docs/DEVELOPMENT.md`: the no-prompts rule gains one narrow exception —
  an extra requested by its own `--with-` flag may prompt for inherently
  per-machine secrets, via `/dev/tty`, and must skip when there's no terminal.
  Under `curl | bash` a bare `read` eats the script's next line, and `[ -t 0 ]`
  is false even in a real console; both traps are documented.
- README: state the `curl` prerequisite. A fresh Ubuntu 24.04 Desktop install
  doesn't include it, and since curl is what fetches `get.sh`, it's the one
  dependency the bootstrap can't resolve for itself — the documented quick
  start simply failed on a clean box. Also notes that the `git clone` route
  needs `git`, which `get.sh` installs but a manual clone does not.

## 2026-07-29

- New core module 01-sudo-nopasswd: passwordless sudo for the invoking user
  via a visudo-validated drop-in in `/etc/sudoers.d` (mode 0440; nothing is
  installed unless it parses). A box's first bootstrap run prompts for the
  password once; sudo never prompts again — password prompts were stalling
  Claude sessions on a field box. `verify.sh` checks for the rule.

## 2026-07-22

- docs/DEVELOPMENT.md: maintainer guide — module contract, add-a-feature
  checklist, hard rules, roadmap. verify.sh gained claude-mem runtime checks
  the day before; both close out the v1 validation cycle.

## 2026-07-21 (updates)

- New core module 02-home-dirs: creates the `~/Projects` workspace folder.
- New core module 38-x11-session: sets `WaylandEnable=false` in
  `/etc/gdm3/custom.conf` (takes effect at next login/reboot). RustDesk and
  Splashtop cannot capture or inject input on Wayland, and the Hyper-V scroll
  fix is an Xorg InputClass — both reference machines already ran X11-only.
  This was in the machine audit's shared core but was missed in the first
  release. `verify.sh` now checks it.

All notable system-setup changes tracked by this repo. Machines converge by
re-running `./bootstrap.sh` (it is idempotent).

## 2026-07-21

- Initial release: core bootstrap (base CLI, Node 20 + user npm prefix,
  Claude Code native install + aliases, bun, claude-mem v10 plugin,
  superpowers plugin, uv, GNOME QoL, Hyper-V QoL, Okular as Markdown viewer)
  plus opt-in extras (docker, xrdp, tailscale, printing-direct,
  weak-passwords, buildtools, usagemeter) and tools (add-printer, verify,
  system-audit).
- Splashtop: manual install for now (see README) — automation planned.
- Short install URL: `https://get.wtfapps.net` (Cloudflare-edge 301 to the raw
  `get.sh`; canonical URL unchanged).
- 40-gnome-qol now also converges the dock to Firefox / Files / Terminal
  (removes App Center and Help pins).
- New core module 42-terminal-prefs: seeds GNOME Terminal preferences
  (Ctrl+C/V copy-paste keybindings, 200×50 default window, bold-is-bright)
  from `assets/gnome-terminal.dconf` — fresh boxes only, never overwrites an
  already-customized terminal.
