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

On a fresh Ubuntu 24.04 Desktop box (regular user with sudo) — if you still
need to *build* that box on a Hyper-V host, see
[Provisioning the VM](#provisioning-the-vm-hyper-v-hosts) below first.

**Install `curl` first.** A fresh Ubuntu 24.04 Desktop install doesn't have
it, and it's what fetches the one-liner — so it's the one thing the bootstrap
can't install for you. Bring the box up to date at the same time:

```bash
sudo apt-get update
sudo apt-get upgrade
sudo apt install -y curl
```

Then:

```bash
curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash
```

Short version — an HTTPS 301 to the exact URL above (verify any time with
`curl -sI https://get.wtfapps.net`):

```bash
curl -fsSL https://get.wtfapps.net | bash
```

or, if you prefer to look first (this route needs `git` rather than curl —
`sudo apt install -y git`; the one-liners above install it for you):

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

## Provisioning the VM (Hyper-V hosts)

The step before everything above: building the Ubuntu VM itself. From an
**elevated PowerShell on the Hyper-V host** (not in the guest):

```powershell
irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/get.ps1 | iex
```

That fetches `windows/New-UbuntuHyperVVM.ps1` and runs it. The script stages
the newest Ubuntu 24.04 Desktop ISO in `C:\VMs\ISOs` — downloading it only if
a newer point release has shipped, and verifying it against Canonical's
published `SHA256SUMS` — then prompts for name, memory, CPUs, and disk, lets
you pick the ISO and virtual switch, and builds a Generation 2 VM with a
dynamic VHDX and static memory. Boot it, install Ubuntu, then run the
quick-start one-liner inside the guest.

To pass the script's switches (`-VMRoot`, `-SkipIsoUpdate`, `-SkipHashCheck`),
bind them to the launcher instead of piping — `iex` cannot forward arguments:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/get.ps1))) -SkipIsoUpdate
```

The launcher downloads to `$env:TEMP` and invokes the script as a file rather
than running it inline, which is what keeps its `#Requires -RunAsAdministrator`
guard working and keeps a mistyped menu answer from closing your console. It
also enables TLS 1.2 and sets a **process-scoped** execution policy bypass —
nothing persists past that console window.

## Provisioning cloud terminals (AWS + Amazon DCV)

The cloud sibling of the Hyper-V path: [`aws/`](aws/README.md) builds a whole
**tenant** — client-owned AWS account, streamed DCV desktops (1:1 per user,
auto-pause when idle), an Entra-login portal for connect/power/sharing, and a
fleet self-update channel. Terminals provision themselves from the tenant's
artifacts bucket and run this same kit per user (`is_dcv_terminal` gates the
modules that don't apply). Start at
[`aws/runbooks/build-tenant.md`](aws/runbooks/build-tenant.md).

## Windows: temporary troubleshooting install (`cctemp`) — not a terminal build

Everything else in this repo builds a machine that *keeps* Claude Code. This
one deliberately doesn't: [`windows/cctemp.ps1`](windows/cctemp.ps1) puts
Claude Code on a Windows box **for the duration of a troubleshooting
engagement only** — user-profile-scoped, no admin, no services — and removes
it completely (binary, config, credentials) when you're done. It drops an
intent marker (`%LOCALAPPDATA%\cctemp\installed.json`) so anyone finding it
later can tell it apart from a deliberate install.

Install (works from a ScreenConnect Backstage PowerShell):

```powershell
irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/cctemp.ps1 | iex
```

A dead-man switch is armed by default: a daily task checks when Claude Code
was last *used* (newest write under `~\.claude`) and purges everything only
after **30 days of no use** — so an engagement that revives with a ticket
keeps its install, and a forgotten one removes itself. Tune with
`-AutoCleanupDays N` (0 disables). Remove immediately when finished:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/cctemp.ps1))) -Cleanup
```

## What the core installs

| Module | Purpose |
|---|---|
| 00-base-cli | git, gh, tmux, curl, jq, unzip, lynx, xvfb, openssh-server |
| 01-sudo-nopasswd | passwordless sudo for the installing user — password asked once at first setup, never again |
| 02-home-dirs | creates the `~/Projects` workspace folder |
| 05-node | Node.js 20 (NodeSource) + user-owned npm prefix `~/.npm-global` |
| 10-claude-code | Claude Code native install + `cc` / `phonecc` aliases |
| 15-bun | Bun runtime (claude-mem v10's worker needs it) |
| 20-claude-mem | [claude-mem](https://github.com/thedotmack/claude-mem) persistent memory, v10 plugin |
| 25-superpowers | [superpowers](https://github.com/obra/superpowers) skills plugin |
| 27-postlogin-finish | installs `cct-finish` + a `.bashrc` hook: the first shell after `claude` login finishes the plugin installs automatically (headless/cloud provisions never see the "re-run after login" reminder) |
| 30-uv | uv/uvx (Chroma MCP server runs through it) |
| 38-x11-session | forces X11 (Wayland off at GDM) — RustDesk/Splashtop can't inject input on Wayland (skipped on DCV terminals, where the host owns session config) |
| 40-gnome-qol | screen lock off, idle blanking off; dock = Firefox, Files, Terminal (App Center and Help unpinned) |
| 41-splashtop-cursorfix | works around a Splashtop ≤3.8.0.0 crash: static cursors (host + snap themes), no Firefox launch spinner, LD_PRELOAD shim on the streamer (only runs where Splashtop is installed) |
| 42-terminal-prefs | seeds GNOME Terminal prefs (Ctrl+C/V copy-paste, 200×50 window) on fresh boxes — never overwrites later tweaks |
| 45-hyperv-qol | fixes over-fast wheel scrolling on Hyper-V/remote mice; adds user to `video` group (only runs on Hyper-V) |
| 50-okular-md | double-clicking a `.md` file opens it rendered (Okular) |

The aliases the core adds (they're the point of the box — remove them from
`~/.bashrc` if they're not your style):

```bash
alias cc='claude --dangerously-skip-permissions'
alias phonecc='tmux new-session -A -s claude claude --dangerously-skip-permissions'
```

In the same spirit, the core sets up **passwordless sudo** for the installing
user (`01-sudo-nopasswd`): the first bootstrap run asks for your password
once, and sudo never asks again. Deliberate posture for a
single-user lab VM — if you fork this and don't want it, delete that module.

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
| `--with-splashtop` | Splashtop Streamer for remote access — asks for your deployment code |

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

## Splashtop (optional)

Remote access. Install it and register the machine in one step:

```bash
./bootstrap.sh --with-splashtop
```

Type your 12-digit deployment code when it asks. The machine then shows up in
your Splashtop console.

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
