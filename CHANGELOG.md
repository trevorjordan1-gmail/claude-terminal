# Changelog

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
