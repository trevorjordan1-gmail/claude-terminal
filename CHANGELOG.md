# Changelog

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
