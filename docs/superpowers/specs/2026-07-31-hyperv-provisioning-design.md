# Hyper-V VM Provisioning (Windows host) — Design Spec

**Date:** 2026-07-31
**Status:** Approved (maintainer)

## Purpose

Every box this repo bootstraps starts life as an Ubuntu 24.04 VM on a Hyper-V
host, and building that VM by hand through the Hyper-V Manager wizard is the
one remaining manual step in front of `get.sh`. The maintainer already had a
working PowerShell script for it, carried between machines by hand. Copying a
script around is exactly the failure mode this repo exists to remove, so the
script joins the repo and gets a documented one-line invocation.

The two halves now compose: `windows/get.ps1` builds the VM on the Windows
host, and `get.sh` turns the resulting Ubuntu guest into a Claude terminal.

## Why a launcher rather than piping the script itself

The obvious move is `irm <url> | iex`, the PowerShell analogue of
`curl | bash`. It does not work here, because PowerShell treats content
executed from a pipe differently from a script file in three ways that this
script depends on. All three were verified against a PowerShell 7.4 container
rather than assumed:

1. **`#Requires` is enforced only for script files.** The provisioning script
   opens with `#Requires -RunAsAdministrator` and `#Requires -Modules Hyper-V`.
   Run from a pipe — or through `[scriptblock]::Create()` — both are ignored
   silently. A non-elevated run would reach `New-VM` and fail there with an
   access-denied error instead of the clean refusal the guard exists to give.
2. **`exit` terminates the caller, not the script.** The script has eight
   `exit 1` paths for ordinary conditions like a name collision or a bad menu
   selection. Executed inline at an interactive prompt, the first one closes
   the console window.
3. **Parameters cannot be bound.** `-VMRoot`, `-SkipIsoUpdate`, and
   `-SkipHashCheck` are unreachable through `iex`, which has no way to pass
   arguments.

Landing the file on disk and invoking it with `&` restores all three: the
`#Requires` guards fire, `exit 1` ends the script and returns to the prompt
with `$LASTEXITCODE` set, and parameters bind normally. It also means the
script runs in exactly the mode it was already field-tested in, so publishing
it required no changes to its logic.

Unlike `curl | bash`, the interactive design survives either way — a
PowerShell pipeline passes objects in-process and never consumes the console's
stdin, so the script's six `Read-Host` prompts keep working. The launcher is
about `#Requires`, `exit`, and parameters, not about stdin.

## Behavior

`windows/get.ps1` is the Windows counterpart of `get.sh`, and is small enough
to be safe to run inline — it has no `#Requires`, no `exit`, and no parameters
of its own. From an elevated PowerShell:

```powershell
irm https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/windows/get.ps1 | iex
```

It then:

1. Adds TLS 1.2 to the enabled protocols. Windows PowerShell 5.1 on older
   Server builds still offers TLS 1.0 first, which raw.githubusercontent.com
   refuses; the failure reads as an opaque "could not create SSL/TLS secure
   channel" and is a bad thing to debug on site. Wrapped in `try`/`catch` so
   hosts that have already hardened this are unaffected.
2. Sets `Set-ExecutionPolicy Bypass -Scope Process -Force`. Process scope
   only: it governs the current console and changes no machine or user policy.
3. Downloads `New-UbuntuHyperVVM.ps1` to `$env:TEMP`.
4. Calls `Unblock-File` — belt and braces, since `Invoke-WebRequest -OutFile`
   does not normally attach a zone marker.
5. Invokes the file with `& $Dest @args`.

Argument forwarding uses the automatic `$args` variable with no `param()`
block. This is deliberate and load-bearing: declaring the arguments via
`[Parameter(ValueFromRemainingArguments = $true)]` reads better but forwards
them **positionally**, so `-VMRoot D:\Custom` binds the literal string
`-VMRoot` to `-VMRoot` and drops the value. Splatting `$args` preserves named
parameters and switches. Both forms were tested; only `$args` is correct, and
the file carries a comment saying so.

Because `iex` cannot pass arguments, the switch form is the documented
alternative:

```powershell
& ([scriptblock]::Create((irm <same-url>))) -SkipIsoUpdate
```

## Changes to the provisioning script

Logic is untouched. Three lines were deleted, all comments:

- The `.NOTES` author attribution, per the repo's no-identifiers rule.
- A two-line comment above `Set-VMFirmware` explaining which host-side
  controls compensated for disabling Secure Boot. That is internal security
  posture and does not belong in a public repo.

`-EnableSecureBoot Off` itself is unchanged. It is a deliberate choice for a
vanilla guest, not an oversight; the reasoning is recorded in the maintainer's
local context file rather than in public.

## Error handling

The launcher runs under `$ErrorActionPreference = 'Stop'`, so a failed
download aborts before anything is invoked. The two environment fixes are
individually wrapped in `try`/`catch` because on a host where they are
unnecessary or blocked they should not be fatal. Everything past the handoff
is the provisioning script's own error handling, which is unchanged and
already covers free space, hash mismatch, name collisions, and empty ISO or
switch lists.

One environment can defeat this design: a host where execution policy is
enforced by Group Policy, since `-Scope Process` cannot override the machine
scope. That is not the maintainer's own hosts, and the fallback is to clone
the repo and run the script directly.

## Docs

- README: a Hyper-V provisioning section with the one-liner, positioned to
  make the host-then-guest sequence obvious.
- `CHANGELOG.md` entry (2026-07-31).
- `docs/DEVELOPMENT.md`: two repo-map rows, plus a note that `windows/` holds
  standalone host-side tooling and is not part of module dispatch.

## Testing

- Both files pass a parser-level syntax check
  (`[System.Management.Automation.Language.Parser]::ParseFile`), the
  PowerShell equivalent of `bash -n`, run in a `mcr.microsoft.com/powershell`
  container.
- The launcher's dispatch was exercised end to end against a stand-in target
  in both supported forms — piped to `iex` with no arguments, and via
  `[scriptblock]::Create()` with `-VMRoot` and a switch — confirming defaults
  apply in the first case and named binding survives in the second.
- The provisioning script itself is field-validated by the maintainer, and its
  logic did not change. Real-host validation of the launcher is the next step.

## Out of scope

- **The short link.** The command is meant to be copied from the repo page, so
  a memorable URL earns little and costs infrastructure work. Deferred, with
  the route recorded in the maintainer's local notes.
- Turning the script into a bootstrap module. It targets a Windows host, not
  the Ubuntu guest, so the module contract does not apply — `windows/` is
  standalone tooling in the spirit of `tools/`.
- Non-interactive or fully parameterised provisioning, unattended installs,
  and Secure Boot changes. The script's interactive shape is what the
  maintainer wants today.
