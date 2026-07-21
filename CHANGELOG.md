# Changelog

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
