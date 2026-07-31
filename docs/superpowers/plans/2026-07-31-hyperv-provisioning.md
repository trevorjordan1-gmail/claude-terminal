# Hyper-V VM Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the maintainer's Hyper-V provisioning script as `windows/New-UbuntuHyperVVM.ps1`, reachable from an elevated PowerShell in one copy-pasted line via a `windows/get.ps1` launcher, plus README, CHANGELOG, and DEVELOPMENT updates.

**Architecture:** Two PowerShell files in a new `windows/` directory. `get.ps1` is the Windows counterpart of `get.sh`: it is safe to run inline (no `#Requires`, no `exit`, no `param()`), and its job is to fix TLS, set a process-scoped execution policy, download the provisioning script, and invoke it **as a file** so that `#Requires`, `exit`, and parameter binding all behave. `windows/` is standalone host-side tooling in the spirit of `tools/` — it is not part of `bootstrap.sh` module dispatch and the module contract does not apply. Spec: `docs/superpowers/specs/2026-07-31-hyperv-provisioning-design.md`.

**Tech Stack:** Windows PowerShell 5.1 / PowerShell 7 on the Hyper-V host; the Hyper-V module. This repo has no test framework and the dev machine is Linux, so the test discipline is a parser-level syntax check plus behavioural tests of the launcher's dispatch, both run in a `mcr.microsoft.com/powershell` container (the PowerShell analogue of the repo's `bash -n` + dockerized shellcheck rule in `docs/DEVELOPMENT.md`). Do NOT attempt to run the provisioning script itself off-host — it needs Hyper-V and Administrator rights; real-host validation happens after push.

---

### Task 1: The provisioning script

**Files:**
- Create: `windows/New-UbuntuHyperVVM.ps1`

- [x] **Step 1: Copy the maintainer's script in, deleting only identifying comments**

Three comment lines are removed and nothing else changes — the logic is already field-validated and must not drift:

- the `.NOTES` author attribution (repo no-identifiers rule);
- the two-line comment above `Set-VMFirmware` describing which host-side controls compensated for disabling Secure Boot (internal security posture).

`-EnableSecureBoot Off` stays exactly as written. It is a deliberate choice for a vanilla guest; the reasoning belongs in the maintainer's gitignored `CLAUDE.md`, not in a public file.

- [x] **Step 2: Prove the diff is deletions only**

```bash
diff <original> windows/New-UbuntuHyperVVM.ps1
```

Must show three deleted lines and zero additions or modifications.

---

### Task 2: The launcher

**Files:**
- Create: `windows/get.ps1`

- [x] **Step 1: Write the launcher**

In order: `$ErrorActionPreference = 'Stop'`; add TLS 1.2 to the enabled protocols inside `try`/`catch`; `Set-ExecutionPolicy Bypass -Scope Process -Force` inside `try`/`catch`; `Invoke-WebRequest -OutFile` into `$env:TEMP`; `Unblock-File`; then `& $Dest @args`.

- [x] **Step 2: Use `$args`, not a declared parameter, for forwarding**

Do NOT add `param([Parameter(ValueFromRemainingArguments = $true)] $ScriptArgs)`. It reads better and is wrong: splatting a bound array forwards **positionally**, so `-VMRoot D:\Custom` binds the literal string `-VMRoot` to `-VMRoot` and discards the value. Only splatting the automatic `$args` preserves named parameters and switches. The file carries a comment recording this so nobody "tidies" it back.

---

### Task 3: Verification

- [x] **Step 1: Syntax-check both files (the `bash -n` equivalent)**

```bash
docker run --rm -v "$PWD:/repo:ro" mcr.microsoft.com/powershell:latest pwsh -NoProfile -Command \
  "foreach (\$f in @('/repo/windows/get.ps1','/repo/windows/New-UbuntuHyperVVM.ps1')) {
     \$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile(\$f,[ref]\$null,[ref]\$e)
     if (\$e) { Write-Host \"FAIL \$f\"; \$e | ForEach-Object { Write-Host \"  \$_\" } } else { Write-Host \"OK \$f\" } }"
```

Both must report OK.

- [x] **Step 2: Exercise the launcher's dispatch against a stand-in target**

Copy `get.ps1`, replace only the `$Dest` assignment and the download line with a local file, then run the result both ways: piped to `iex` with no arguments (expect the target's defaults), and via `& ([scriptblock]::Create($src))` with `-VMRoot 'D:\Engagement' -SkipIsoUpdate` (expect both bound by name). Both passed.

---

### Task 4: README

**Files:**
- Modify: `README.md`

- [x] **Step 1: Add the provisioning section**

Placed immediately after the Ubuntu quick start, with a forward pointer added to the quick start's opening line so the host-then-guest order is discoverable without demoting the repo's main event. States the elevated-PowerShell requirement and shows the switch form as the alternative.

---

### Task 5: CHANGELOG and DEVELOPMENT

**Files:**
- Modify: `CHANGELOG.md`, `docs/DEVELOPMENT.md`

- [x] **Step 1: CHANGELOG entry under a `## 2026-07-31` heading**

House format: prose explaining what and why, not a bare bullet list.

- [x] **Step 2: DEVELOPMENT repo-map rows for `windows/get.ps1` and `windows/New-UbuntuHyperVVM.ps1`**

Plus a sentence noting that `windows/` is host-side tooling outside module dispatch, so the module contract does not apply to it.

---

### Task 6: Commit

- [x] **Step 1: Review the diff, confirm no identifiers reached the public tree**

```bash
git diff --cached | grep -niE 'adnet|bitlocker|entra|intune|hostname|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
```

Must return nothing.

- [x] **Step 2: Single feature commit (house style — one commit per feature)**

- [ ] **Step 3: Push, then validate on a real Hyper-V host**

The scorecard is a real run: from an elevated PowerShell, the one-liner should download, print `[get] running …`, and land in the script's first `VM Name` prompt. Confirm too that a deliberate bad answer (an out-of-range ISO number) prints the script's red error and returns to the prompt with the console still open — that is the behaviour the launcher exists to preserve.
