# claude-terminal

Turn a stock **Ubuntu 24.04 LTS Desktop** install into a **Claude Code
terminal** — a machine whose main job is running
[Claude Code](https://claude.com/claude-code) sessions comfortably: the
CLI stack, persistent memory, agent skills, and the quality-of-life fixes
that make a (typically Hyper-V) VM pleasant to live in.

Distilled from two production machines that were audited file-by-file; what
they agreed on became the default **core**, the rest became opt-in
**extras**. Public so anyone can use or fork it; only the maintainer pushes.

## Quick start

On a fresh Ubuntu 24.04 Desktop box (regular user with sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash
```

Short version — an HTTPS 301 to the exact URL above (verify any time with
`curl -sI https://get.wtfapps.net`):

```bash
curl -fsSL https://get.wtfapps.net | bash
```

or, if you prefer to look first:

```bash
git clone https://github.com/trevorjordan1-gmail/claude-terminal ~/claude-terminal
cd ~/claude-terminal
./bootstrap.sh
```

Then:

1. Run `claude` once and log in.
2. Re-run `./bootstrap.sh` — the two plugin modules (claude-mem, superpowers)
   finish now that you're logged in.
3. `./verify.sh` to confirm everything, and read the printed **NEXT STEPS**.

Extras are flags: `./bootstrap.sh --with-docker --with-xrdp --with-tailscale`
(see `--list` for everything). The whole thing is **idempotent** — re-running
is always safe and is also how you pick up updates (`git pull && ./bootstrap.sh`).

## What the core installs

| Module | Purpose |
|---|---|
| 00-base-cli | git, gh, tmux, curl, jq, unzip, lynx, xvfb, openssh-server |
| 05-node | Node.js 20 (NodeSource) + user-owned npm prefix `~/.npm-global` |
| 10-claude-code | Claude Code native install + `cc` / `phonecc` aliases |
| 15-bun | Bun runtime (claude-mem v10's worker needs it) |
| 20-claude-mem | [claude-mem](https://github.com/thedotmack/claude-mem) persistent memory, v10 plugin |
| 25-superpowers | [superpowers](https://github.com/obra/superpowers) skills plugin |
| 30-uv | uv/uvx (Chroma MCP server runs through it) |
| 40-gnome-qol | screen lock off, idle blanking off |
| 45-hyperv-qol | fixes over-fast wheel scrolling on Hyper-V/remote mice; adds user to `video` group (only runs on Hyper-V) |
| 50-okular-md | double-clicking a `.md` file opens it rendered (Okular) |

The aliases the core adds (they're the point of the box — remove them from
`~/.bashrc` if they're not your style):

```bash
alias cc='claude --dangerously-skip-permissions'
alias phonecc='tmux new-session -A -s claude claude --dangerously-skip-permissions'
```

## Extras

| Flag | What you get |
|---|---|
| `--with-docker` | Docker CE + buildx + compose from docker.com, user in `docker` group |
| `--with-xrdp` | RDP access (xrdp) + XFCE session; RDP logins source your `~/.profile` |
| `--with-tailscale` | Tailscale installed + enabled (you still run `sudo tailscale up`) |
| `--with-printing-direct` | disables flaky `cups-browsed` auto-queues; add printers with `tools/add-printer.sh` |
| `--with-buildtools` | build-essential, maven, JDK, msitools/wixl, osslsigncode, mdbtools |
| `--with-usagemeter` | Claude subscription usage meter (tray icon + `localhost:7777`) |
| `--with-weak-passwords` | lab-VM password policy (anything goes). Deliberately **not** in `--all-extras` |
| `--with-splashtop` | prints manual install steps (see below) |

`--all-extras` = every extra except `weak-passwords` and `splashtop`.

## Printers (direct IPP, no auto-queue roulette)

`cups-browsed` auto-creates stub queues, then re-registers them under new
names over time, orphaning the old ones — jobs silently die. The
`printing-direct` extra disables it; then add each printer once, permanently:

```bash
./tools/add-printer.sh Office_Printer ipp://printer-hostname.local/ipp/print
```

Any modern printer speaks IPP Everywhere (driverless). Find its hostname/IP
on the printer's network config page.

## Splashtop (manual for now)

Automation is planned; today it's three steps:

1. Download the Ubuntu 64-bit Streamer .deb: <https://www.splashtop.com/downloads#streamer>
2. `sudo apt-get install -y ./Splashtop_Streamer_Ubuntu_*.deb`
3. Launch **Splashtop Streamer**, log in, allow autostart.

## Verifying and auditing

- `./verify.sh` — read-only PASS/FAIL/SKIP report of the expected state.
- `./audit/system-audit.sh` — full read-only system snapshot (packages,
  services, desktop settings, …) into sorted text files + a tarball, built
  for diffing two machines. This tool produced the core/extras split in the
  first place. **Snapshots contain hostnames — don't commit or share them.**

## What this repo will never do

Install SSH keys, VPN/Tailscale credentials, printer addresses, or any other
machine-specific secret or identifier. Those stay yours. Modules that need
that kind of input either take it as an argument (`add-printer.sh`) or leave
you a NEXT STEPS line.

## Maintenance discipline

Every generic setup change lands here as a module edit + `CHANGELOG.md`
entry; machines converge by `git pull && ./bootstrap.sh`. Design/spec history
lives in `docs/superpowers/`.

## License

MIT — see [LICENSE](LICENSE).
