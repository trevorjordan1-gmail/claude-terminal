# Step 2 — Medical mode, kit side

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a DCV terminal marked medical, bootstrap pins Claude Code and claude-mem to Amazon Bedrock (managed settings + system env), sweeps provider API keys off the box, brands the box as PHI-approved, and `verify.sh` proves all of it — while every non-medical box is byte-for-byte unaffected.

**Architecture:** Three new core modules gated on `is_medical_terminal` (skip everywhere else), one asset, small additions to `lib/common.sh` (`is_medical_terminal`, `asp_env`, `sudo_append_block`, Bedrock-aware `claude_ready`), a `--medical` marker flag in `bootstrap.sh`, and a medical section in `verify.sh`. Spec: `docs/superpowers/specs/2026-08-18-medical-mode-design.md` §Kit side. Facts already verified in a container: `claude plugin marketplace add/install` work with no credentials at all, and `claude` under `CLAUDE_CODE_USE_BEDROCK=1` never prompts for a login.

**Tech Stack:** bash, jq, gsettings/dconf via `gui_conf`, docker (`ubuntu:24.04` for validation, `koalaman/shellcheck:stable`).

**Worktree:** `~/.config/superpowers/worktrees/claude-terminal/step2-medical-kit` (branch `step2-medical-kit`, from main `9b249cf`). All paths below are relative to it.

**Validation harness used by several tasks** — save as `/tmp/claude-1000/-home-cc-Projects-claude-terminal/2aeac79b-f648-4a35-9514-a88d87166b63/scratchpad/medical-container.sh` (scratchpad, not in the repo). It builds an `ubuntu:24.04` container that looks like a DCV medical terminal (env file, no AWS creds, GNOME schema stack, passwordless sudo, jq) and runs whatever command you pass as the kit user `u` with the repo copied to `~/kit`:

```bash
#!/usr/bin/env bash
# usage: medical-container.sh <repo-dir> '<bash to run as user u inside ~/kit>' [profile]
# profile: medical (default) | standard | none (no env file at all)
set -eu
REPO="$1"; CMD="$2"; PROFILE="${3:-medical}"
docker run --rm -v "$REPO:/repo:ro" ubuntu:24.04 bash -c '
set -e
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo jq git curl ca-certificates \
  libglib2.0-bin gsettings-desktop-schemas gnome-shell-common dbus-daemon dconf-cli python3 >/dev/null 2>&1
useradd -m -s /bin/bash -G sudo u && echo "u ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/u && chmod 440 /etc/sudoers.d/u
mkdir -p /run/user/1001 && chown u:u /run/user/1001 && chmod 700 /run/user/1001
cp -r /repo /home/u/kit && chown -R u:u /home/u/kit
case "$1" in
  medical)  printf "ASP_BROKER_HOST=cp\nASP_LOCAL_USER=u\nASP_CUSTOMER=acme\nASP_REGION=us-east-2\nASP_BUCKET=acme-asp-artifacts\nASP_PROFILE=medical\n" > /etc/asp-terminal.env ;;
  standard) printf "ASP_BROKER_HOST=cp\nASP_LOCAL_USER=u\nASP_CUSTOMER=acme\nASP_REGION=us-east-2\nASP_BUCKET=acme-asp-artifacts\n" > /etc/asp-terminal.env ;;
  none)     : ;;
esac
# a planted key the sweep must remove
echo "export ANTHROPIC_API_KEY=sk-ant-planted" >> /home/u/.bashrc
mkdir -p /home/u/.claude-mem && printf "ANTHROPIC_API_KEY=sk-ant-planted\nGEMINI_API_KEY=planted\n" > /home/u/.claude-mem/.env && chown -R u:u /home/u/.claude-mem
su - u -c "cd ~/kit && export XDG_RUNTIME_DIR=/run/user/1001 && '"$(printf %s "$CMD" | sed "s/\"/\\\\\"/g")"'"
' _ "$PROFILE"
```

Module-runner snippet used inside that container (runs ONE module the way bootstrap does and prints its status line):

```bash
run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; CT_NEXT=$CT_TMP/n; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS CT_NEXT SCRIPT_DIR; ( . "modules/core/$1" ) 2>/dev/null; cat "$CT_STATUS"; }
```

---

### Task 1: `lib/common.sh` — detection + Bedrock-aware readiness + root append_block

**Files:**
- Modify: `lib/common.sh` (append after `is_dcv_terminal`; and add `sudo_append_block` after `append_block`)

- [ ] **Step 1: Add `sudo_append_block` right after `append_block`** (same marker semantics; reads/writes root-owned files through sudo)

```bash
# sudo_append_block <file> <marker>   (block content on stdin)
# append_block for root-owned files (/etc/bash.bashrc, /etc/profile.d/…):
# same "# >>> marker >>>" span, read + written through sudo.
sudo_append_block() {
    local file="$1" marker="$2" content tmp
    content="$(cat)"
    tmp="$(mktemp)"
    sudo cat "$file" 2>/dev/null | awk -v m="$marker" '
        $0 == "# >>> " m " >>>" { inblock = 1; next }
        $0 == "# <<< " m " <<<" { inblock = 0; next }
        !inblock { print }
    ' > "$tmp"
    printf '# >>> %s >>>\n%s\n# <<< %s <<<\n' "$marker" "$content" "$marker" >> "$tmp"
    sudo install -D -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}
```

- [ ] **Step 2: Replace `claude_ready` and add the medical helpers** — replace the existing block

```bash
# True once Claude Code is installed AND logged in (plugin operations need both).
claude_ready() {
    have claude && [ -f "$HOME/.claude/.credentials.json" ]
}
```
with
```bash
# True when the kit's managed settings pin Claude Code to Amazon Bedrock
# (medical boxes): creds come from the instance role, so no OAuth login
# exists or is needed there.
claude_bedrock_ready() {
    [ -r /etc/claude-code/managed-settings.json ] && have jq \
        && [ "$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // empty' /etc/claude-code/managed-settings.json 2>/dev/null)" = "1" ]
}

# True once Claude Code is installed AND (logged in OR pinned to Bedrock) —
# the state the plugin modules need. (Plugin install itself needs no auth;
# the gate keeps the "run claude to log in" reminder honest.)
claude_ready() {
    have claude && { [ -f "$HOME/.claude/.credentials.json" ] || claude_bedrock_ready; }
}
```
and append after `is_dcv_terminal()`:
```bash

# Read one KEY from /etc/asp-terminal.env (KEY=VALUE lines the platform writes).
asp_env() { sed -n "s/^$1=//p" /etc/asp-terminal.env 2>/dev/null | head -1; }

# True on a medical (Ai Build Medical, PHI-approved) terminal. The signal is
# STATE on the box, never a flag: the DCV updater re-runs get.sh daily with no
# arguments. The platform writes ASP_PROFILE=medical into /etc/asp-terminal.env;
# `bootstrap.sh --medical` writes the marker for a box flipped by hand.
is_medical_terminal() {
    grep -qsx 'ASP_PROFILE=medical' /etc/asp-terminal.env || [ -f /etc/claude-terminal/medical ]
}
```

- [ ] **Step 3: Check + commit**

```bash
bash -n lib/common.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x lib/common.sh && echo ok
git add lib/common.sh && git commit -q -m "feat(common): medical-terminal detection, Bedrock-aware claude_ready, sudo_append_block

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 2: `bootstrap.sh --medical` (marker only)

**Files:**
- Modify: `bootstrap.sh` (usage text, arg parser, one block after `sudo -v`)

- [ ] **Step 1: Usage** — add under `--force-os`:

```
  --medical        Mark this box as an Ai Build Medical (PHI-approved) terminal:
                   writes /etc/claude-terminal/medical so the medical modules run
                   on this and every later run (Claude Code → Amazon Bedrock only).
                   DCV terminals normally get this from the platform instead.
```

- [ ] **Step 2: Parser** — add a case before `--all-extras`:

```bash
        --medical)    CT_MEDICAL=1 ;;
```

- [ ] **Step 3: Marker write** — right after `sudo -v || die "sudo access is required."`:

```bash
# --medical is state, not a per-run switch: the marker persists so unattended
# re-runs (the DCV updater passes no flags) keep the box medical.
if [ "${CT_MEDICAL:-0}" = 1 ]; then
    sudo install -d -m 0755 /etc/claude-terminal && sudo touch /etc/claude-terminal/medical \
        || die "could not write /etc/claude-terminal/medical"
    log "medical mode marker written — the medical modules run on this and every later run"
fi
```

- [ ] **Step 4: Check + commit**

```bash
bash -n bootstrap.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x bootstrap.sh && echo ok
git add bootstrap.sh && git commit -q -m "feat(bootstrap): --medical writes the persistent medical marker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 3: `modules/core/08-medical-bedrock.sh`

**Files:**
- Create: `modules/core/08-medical-bedrock.sh`

- [ ] **Step 1: Write the module**

```bash
# shellcheck shell=bash
# ct-desc: Medical mode — Claude Code pinned to Amazon Bedrock (managed settings + system env); no provider API keys on the box

# Ai Build Medical: the box is the compliance boundary. Every Claude call goes
# to Bedrock in the tenant's own AWS account; creds come from the instance
# role, so no OAuth login exists. Runs before 10-claude-code on purpose — the
# plugin modules read claude_ready(), which this module makes true.
is_medical_terminal || skip "not a medical terminal"
is_dcv_terminal || skip "medical mode is DCV-only for now (marker present, but this is not a DCV terminal)"
have jq || fail "jq missing (00-base-cli installs it — re-run ./bootstrap.sh)"

REGION="$(asp_env ASP_REGION)"
[ -n "$REGION" ] || fail "ASP_REGION missing from /etc/asp-terminal.env — the platform must supply the Bedrock region"

# Cross-region inference-profile IDs (what Claude Code sends to Bedrock).
# Sonnet is the default model, Opus reachable with /model, Haiku is the
# small/fast slot. Tenants override per model via ASP_BEDROCK_* in the env
# file; claude-mem resolves through these too (it uses the CLI's aliases).
SONNET="$(asp_env ASP_BEDROCK_SONNET)"; SONNET="${SONNET:-us.anthropic.claude-sonnet-5}"
OPUS="$(asp_env ASP_BEDROCK_OPUS)";     OPUS="${OPUS:-us.anthropic.claude-opus-5}"
HAIKU="$(asp_env ASP_BEDROCK_HAIKU)";   HAIKU="${HAIKU:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"

# If the instance role lets us list profiles, sanity-check the IDs — a typo
# here is a dead terminal. Never fail on the listing itself (no aws, no
# permission, no network at provision time are all fine).
if have aws; then
    PROFILES="$(aws bedrock list-inference-profiles --region "$REGION" \
        --query 'inferenceProfileSummaries[].inferenceProfileId' --output text 2>/dev/null | tr '\t\n' '  ')"
    if [ -n "$PROFILES" ]; then
        for m in "$SONNET" "$OPUS" "$HAIKU"; do
            case " $PROFILES " in *" $m "*) ;; *) warn "Bedrock lists no inference profile '$m' in $REGION — check the model ID / model access" ;; esac
        done
    fi
fi

# 1. Managed settings — the guarantee. User settings cannot override these.
#    Kit-owned on medical boxes. The "hooks" slot is reserved for the optional
#    PHI-tripwire pack (UserPromptSubmit/PreToolUse pattern scan) — only
#    two-terminal deployments need it; not built.
MANAGED=/etc/claude-code/managed-settings.json
NEW="$(jq -n --arg r "$REGION" --arg s "$SONNET" --arg o "$OPUS" --arg h "$HAIKU" '{
  env: {
    CLAUDE_CODE_USE_BEDROCK: "1",
    AWS_REGION: $r,
    ANTHROPIC_MODEL: $s,
    ANTHROPIC_DEFAULT_SONNET_MODEL: $s,
    ANTHROPIC_DEFAULT_OPUS_MODEL: $o,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: $h,
    DISABLE_TELEMETRY: "1",
    DISABLE_ERROR_REPORTING: "1"
  }
}')"
if [ "$(sudo cat "$MANAGED" 2>/dev/null)" != "$NEW" ]; then
    sudo install -d -m 0755 /etc/claude-code \
        && printf '%s\n' "$NEW" | sudo tee "$MANAGED" >/dev/null \
        && sudo chmod 0644 "$MANAGED" \
        || fail "could not write $MANAGED"
fi

# 2. Shell env — DCV shells are non-login (gnome-terminal), so /etc/bash.bashrc
#    is what they read; profile.d covers SSH/console. claude-mem's worker
#    inherits its process env from Claude Code, which applies the managed env
#    itself, but the shell copy keeps `aws` and hand-run tools consistent.
ENVBLOCK="export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION=$REGION
export ANTHROPIC_MODEL=$SONNET
export ANTHROPIC_DEFAULT_SONNET_MODEL=$SONNET
export ANTHROPIC_DEFAULT_OPUS_MODEL=$OPUS
export ANTHROPIC_DEFAULT_HAIKU_MODEL=$HAIKU
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1"
printf '%s\n' "$ENVBLOCK" | sudo_append_block /etc/bash.bashrc "claude-terminal medical env" \
    || fail "could not update /etc/bash.bashrc"
PROFILED=/etc/profile.d/claude-terminal-medical.sh
if [ "$(sudo cat "$PROFILED" 2>/dev/null)" != "# claude-terminal medical mode — Claude Code talks to Amazon Bedrock only
$ENVBLOCK" ]; then
    printf '# claude-terminal medical mode — Claude Code talks to Amazon Bedrock only\n%s\n' "$ENVBLOCK" \
        | sudo tee "$PROFILED" >/dev/null && sudo chmod 0644 "$PROFILED" \
        || fail "could not write $PROFILED"
fi

# 3. No provider API keys anywhere on the box. Direct keys would route
#    around Bedrock (and the tenant's ZDR posture) — strip and say so.
KEYRE='^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_(API_KEY|AUTH_TOKEN)='
for f in /etc/environment /etc/profile.d/*.sh; do
    [ -f "$f" ] && [ "$f" != "$PROFILED" ] || continue
    if sudo grep -qE "$KEYRE" "$f" 2>/dev/null; then
        sudo sed -i -E "/$KEYRE/d" "$f" && warn "removed an ANTHROPIC_* credential line from $f (medical boxes talk to Bedrock only)"
    fi
done
for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    [ -f "$f" ] || continue
    if grep -qE "$KEYRE" "$f"; then
        sed -i -E "/$KEYRE/d" "$f" && warn "removed an ANTHROPIC_* credential line from $f (medical boxes talk to Bedrock only)"
    fi
done
US="$HOME/.claude/settings.json"
if [ -s "$US" ] && jq -e '(.env.ANTHROPIC_API_KEY // .env.ANTHROPIC_AUTH_TOKEN // .apiKeyHelper) != null' "$US" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq 'del(.env.ANTHROPIC_API_KEY, .env.ANTHROPIC_AUTH_TOKEN, .apiKeyHelper)' "$US" > "$tmp" && mv "$tmp" "$US" \
        && warn "removed API-key settings from ~/.claude/settings.json (medical boxes talk to Bedrock only)"
fi
[ -f "$HOME/.claude/.credentials.json" ] \
    && warn "an OAuth login exists in ~/.claude — unused (managed settings force Bedrock), but a medical box should not carry one"

ok "Claude Code → Bedrock ($REGION; sonnet=$SONNET)"
```

- [ ] **Step 2: Lint**

```bash
bash -n modules/core/08-medical-bedrock.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x modules/core/08-medical-bedrock.sh && echo ok
```
Expected: `ok` (SC2034/SC1090 must not appear; if shellcheck flags the `for f in … [ … ] || continue` shape, keep it — it is deliberate).

- [ ] **Step 3: Container check (medical)** — run the harness with the module runner:

```bash
S=/tmp/claude-1000/-home-cc-Projects-claude-terminal/2aeac79b-f648-4a35-9514-a88d87166b63/scratchpad/medical-container.sh
bash "$S" "$PWD" 'run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; CT_NEXT=$CT_TMP/n; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS CT_NEXT SCRIPT_DIR; ( . "modules/core/$1" ) 2>&1 | grep -v "^$" ; cat "$CT_STATUS"; }
run_mod 08-medical-bedrock.sh
echo "--- managed ---"; sudo cat /etc/claude-code/managed-settings.json
echo "--- bashrc block ---"; grep -c "claude-terminal medical env" /etc/bash.bashrc
echo "--- profile.d ---"; head -2 /etc/profile.d/claude-terminal-medical.sh
echo "--- planted key gone? ---"; grep -c ANTHROPIC_API_KEY ~/.bashrc || true
echo "--- claude_ready without claude binary (expect 1) ---"; . lib/common.sh; claude_ready; echo rc=$?
echo "--- second run idempotent ---"; run_mod 08-medical-bedrock.sh; grep -c "claude-terminal medical env >>>" /etc/bash.bashrc'
```
Expected: first status `OK	Claude Code → Bedrock (us-east-2; sonnet=us.anthropic.claude-sonnet-5)` with a `warn` line about the planted key; managed JSON shows the 8 env keys; bashrc count `1`; planted-key count `0`; `rc=1` (no `claude` binary yet — the Bedrock half is true, `have claude` false); after the second run the marker count is still `1`.

- [ ] **Step 4: Container check (standard + none → SKIP)**

```bash
bash "$S" "$PWD" 'run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS SCRIPT_DIR; ( . "modules/core/$1" ) 2>/dev/null; cat "$CT_STATUS"; }; run_mod 08-medical-bedrock.sh; ls /etc/claude-code 2>&1' standard
bash "$S" "$PWD" 'run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS SCRIPT_DIR; ( . "modules/core/$1" ) 2>/dev/null; cat "$CT_STATUS"; }; sudo mkdir -p /etc/claude-terminal && sudo touch /etc/claude-terminal/medical; run_mod 08-medical-bedrock.sh' none
```
Expected: `SKIP	not a medical terminal` + `No such file or directory`; and `SKIP	medical mode is DCV-only for now (…)`.

- [ ] **Step 5: Commit**

```bash
git add modules/core/08-medical-bedrock.sh && git commit -q -m "feat(medical): 08-medical-bedrock — Claude Code pinned to Bedrock via managed settings + system env; API-key sweep

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 4: `modules/core/21-medical-claude-mem.sh`

**Files:**
- Create: `modules/core/21-medical-claude-mem.sh`

- [ ] **Step 1: Write the module**

```bash
# shellcheck shell=bash
# ct-desc: Medical mode — claude-mem rides Bedrock through the CLI (sonnet), telemetry + cloud sync off, no provider keys

# claude-mem (v12.4.9+) spawns the `claude` CLI for compression and passes
# CLAUDE_CODE_USE_BEDROCK/AWS_* through, so 08's env already routes it to
# Bedrock. What it does NOT do on its own: its default model ID is rejected by
# Bedrock, PostHog telemetry is on, and ~/.claude-mem/.env may carry direct
# provider keys that would route around Bedrock. Pin all three. Runs whether
# or not the plugin is installed yet — the file is read on first use.
is_medical_terminal || skip "not a medical terminal"
is_dcv_terminal || skip "medical mode is DCV-only for now"
have jq || fail "jq missing (00-base-cli installs it — re-run ./bootstrap.sh)"

D="$HOME/.claude-mem"
S="$D/settings.json"
mkdir -p "$D"
[ -s "$S" ] || printf '{}\n' > "$S"
jq empty "$S" 2>/dev/null || fail "$S is not valid JSON — fix or remove it, then re-run"

# Model aliases resolve through the CLI's ANTHROPIC_DEFAULT_*_MODEL, so the
# Bedrock IDs live in one place (08-medical-bedrock). Cloud-sync keys default
# empty; pinning them empty makes the intent explicit. Values are strings —
# that is what claude-mem's settings loader stores.
NEW="$(jq '. + {
  CLAUDE_MEM_MODEL: "sonnet",
  CLAUDE_MEM_PROVIDER: "claude",
  CLAUDE_MEM_TELEMETRY: "0",
  CLAUDE_MEM_CLOUD_SYNC_TOKEN: "",
  CLAUDE_MEM_CLOUD_SYNC_USER_ID: "",
  CLAUDE_MEM_CLOUD_SYNC_HUB_URL: ""
}' "$S")"
[ "$NEW" = "$(cat "$S")" ] || printf '%s\n' "$NEW" > "$S" || fail "could not write $S"

T="$D/telemetry.json"
[ "$(cat "$T" 2>/dev/null)" = '{"enabled": false}' ] || printf '{"enabled": false}\n' > "$T"

# The five credential keys claude-mem reads from .env; any of them bypasses
# Bedrock (direct API key / gateway / Gemini / OpenRouter).
E="$D/.env"
KEYRE='^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|GEMINI_API_KEY|OPENROUTER_API_KEY)='
if [ -f "$E" ] && grep -qE "$KEYRE" "$E"; then
    sed -i -E "/$KEYRE/d" "$E" \
        && warn "stripped provider credentials from ~/.claude-mem/.env (medical boxes talk to Bedrock only)"
fi

ok "claude-mem → Bedrock via the CLI (sonnet); telemetry + cloud sync off"
```

- [ ] **Step 2: Lint + container check**

```bash
bash -n modules/core/21-medical-claude-mem.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x modules/core/21-medical-claude-mem.sh && echo ok
S=/tmp/claude-1000/-home-cc-Projects-claude-terminal/2aeac79b-f648-4a35-9514-a88d87166b63/scratchpad/medical-container.sh
bash "$S" "$PWD" 'run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS SCRIPT_DIR; ( . "modules/core/$1" ) 2>&1; cat "$CT_STATUS"; }
run_mod 21-medical-claude-mem.sh; cat ~/.claude-mem/settings.json ~/.claude-mem/telemetry.json; echo "--- .env now ---"; cat ~/.claude-mem/.env; echo "(end)"; run_mod 21-medical-claude-mem.sh'
```
Expected: `warn` about stripped credentials, `OK	claude-mem → Bedrock …`, settings JSON with the six keys, telemetry `{"enabled": false}`, `.env` empty, second run `OK` with no warn.

- [ ] **Step 3: Commit**

```bash
git add modules/core/21-medical-claude-mem.sh && git commit -q -m "feat(medical): 21-medical-claude-mem — sonnet via CLI aliases, telemetry + cloud sync off, credential strip

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 5: `assets/medical-wallpaper.svg` + `modules/core/43-medical-cues.sh`

**Files:**
- Create: `assets/medical-wallpaper.svg`
- Create: `modules/core/43-medical-cues.sh`

- [ ] **Step 1: The wallpaper** (1920×1080, dark, text-only, no client identity)

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#101622"/>
      <stop offset="1" stop-color="#1c2740"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <rect x="120" y="120" width="1680" height="840" rx="24" fill="none" stroke="#3b82f6" stroke-opacity="0.35" stroke-width="3"/>
  <g font-family="DejaVu Sans, Ubuntu, sans-serif" fill="#e5e7eb" text-anchor="middle">
    <text x="960" y="470" font-size="96" font-weight="bold" letter-spacing="2">Ai Build Medical</text>
    <text x="960" y="560" font-size="40" fill="#93c5fd">PHI-approved environment</text>
    <text x="960" y="640" font-size="30" fill="#cbd5e1">Claude runs on Amazon Bedrock inside this tenant only — zero data retention</text>
    <text x="960" y="700" font-size="26" fill="#94a3b8">No files leave this session. Treat everything on this screen as protected health information.</text>
    <text x="960" y="900" font-size="22" fill="#64748b">claude-terminal · medical profile</text>
  </g>
</svg>
```

- [ ] **Step 2: The module**

```bash
# shellcheck shell=bash
# ct-desc: Medical mode — PHI-approved identity cues (wallpaper, shell banner, motd)

# Users must not mistake this box for an ordinary terminal: PHI is allowed
# here and nowhere else. On DCV the terminal opens at sign-in and MOTD never
# shows (non-login shells), so the shell banner and wallpaper are what people
# actually see; motd is kept for SSH/console completeness.
is_medical_terminal || skip "not a medical terminal"
is_dcv_terminal || skip "medical mode is DCV-only for now"

WP=/usr/share/backgrounds/claude-terminal-medical.svg
if ! sudo cmp -s "$SCRIPT_DIR/assets/medical-wallpaper.svg" "$WP" 2>/dev/null; then
    sudo install -D -m 0644 "$SCRIPT_DIR/assets/medical-wallpaper.svg" "$WP" || fail "could not install $WP"
fi

# GNOME renders SVG backgrounds through gdk-pixbuf's librsvg loader.
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.desktop\.background$' && gui_conf_ready; then
    pkg_installed librsvg2-common || apt_install librsvg2-common || warn "librsvg2-common not installed — SVG wallpaper may not render"
    URI="file://$WP"
    for k in picture-uri picture-uri-dark; do
        if [ "$(gsettings get org.gnome.desktop.background "$k" 2>/dev/null)" != "'$URI'" ]; then
            gui_conf gsettings set org.gnome.desktop.background "$k" "$URI" || fail "could not set $k"
        fi
    done
else
    warn "no GNOME here — wallpaper installed but not selected"
fi

append_block "$HOME/.bashrc" "claude-terminal medical banner" <<'EOF'
case $- in *i*) printf '\033[1;35m[Ai Build Medical]\033[0m PHI-approved environment — Claude runs on Amazon Bedrock in this tenant only.\n' ;; esac
EOF

MOTD_LINE="Ai Build Medical — PHI-approved environment. Claude runs on Amazon Bedrock in this tenant only."
if ! sudo grep -qxF "$MOTD_LINE" /etc/motd 2>/dev/null; then
    printf '%s\n' "$MOTD_LINE" | sudo tee -a /etc/motd >/dev/null || fail "could not update /etc/motd"
fi

ok "wallpaper, shell banner, motd"
```

- [ ] **Step 3: Lint + container check**

```bash
bash -n modules/core/43-medical-cues.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x modules/core/43-medical-cues.sh && echo ok
xmllint --noout assets/medical-wallpaper.svg 2>/dev/null && echo svg-ok || python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('assets/medical-wallpaper.svg'); print('svg-ok')"
S=/tmp/claude-1000/-home-cc-Projects-claude-terminal/2aeac79b-f648-4a35-9514-a88d87166b63/scratchpad/medical-container.sh
bash "$S" "$PWD" 'run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS SCRIPT_DIR; ( . "modules/core/$1" ) 2>&1 | grep -vE "^$|dconf-CRITICAL|dbus" ; cat "$CT_STATUS"; }
run_mod 43-medical-cues.sh; gsettings get org.gnome.desktop.background picture-uri; grep -c "medical banner" ~/.bashrc; cat /etc/motd; run_mod 43-medical-cues.sh; grep -c "Ai Build Medical" /etc/motd'
```
Expected: `OK	wallpaper, shell banner, motd`, `'file:///usr/share/backgrounds/claude-terminal-medical.svg'`, `1`, the motd line, second run `OK`, motd count `1`.

- [ ] **Step 4: Commit**

```bash
git add assets/medical-wallpaper.svg modules/core/43-medical-cues.sh && git commit -q -m "feat(medical): 43-medical-cues — PHI-approved wallpaper, shell banner, motd

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 6: `verify.sh` — Bedrock-aware login line + medical section

**Files:**
- Modify: `verify.sh`

- [ ] **Step 1: Login line** — replace

```bash
    if claude_ready; then p "claude logged in"; else s "claude not logged in yet (run 'claude')"; fi
```
with
```bash
    if claude_bedrock_ready; then p "claude → Amazon Bedrock (managed settings; no login needed)"
    elif claude_ready; then p "claude logged in"
    else s "claude not logged in yet (run 'claude')"; fi
```

- [ ] **Step 2: Medical section** — insert immediately before `log "extras (reported only when artifacts exist)"`:

```bash
# ---- medical mode ----------------------------------------------------------------
# Only on Ai Build Medical terminals; the bar is zero FAILs on a fresh provision.
if is_medical_terminal; then
    log "medical mode (Ai Build Medical)"
    M=/etc/claude-code/managed-settings.json
    if [ -r "$M" ] && [ "$(jq -r '.env.CLAUDE_CODE_USE_BEDROCK // empty' "$M" 2>/dev/null)" = "1" ]; then
        p "managed settings pin Claude Code to Bedrock"
        for k in AWS_REGION ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL; do
            v="$(jq -r ".env.$k // empty" "$M" 2>/dev/null)"
            if [ -n "$v" ]; then p "managed env $k=$v"; else f "managed env $k missing"; fi
        done
    else
        f "$M missing or does not set CLAUDE_CODE_USE_BEDROCK=1 (08-medical-bedrock)"
    fi
    if grep -q '^# >>> claude-terminal medical env >>>' /etc/bash.bashrc 2>/dev/null; then
        p "/etc/bash.bashrc exports the Bedrock env (DCV shells are non-login)"
    else
        f "/etc/bash.bashrc lacks the medical env block"
    fi
    if [ -f /etc/profile.d/claude-terminal-medical.sh ]; then p "profile.d medical env present"; else f "/etc/profile.d/claude-terminal-medical.sh missing"; fi

    KEYRE='^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|GEMINI_API_KEY|OPENROUTER_API_KEY)='
    keyhit=0
    for kf in /etc/environment /etc/profile.d/*.sh "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.claude-mem/.env"; do
        [ -f "$kf" ] || continue
        if grep -qE "$KEYRE" "$kf" 2>/dev/null; then f "provider credential line in $kf"; keyhit=1; fi
    done
    if [ -s "$HOME/.claude/settings.json" ] && jq -e '(.env.ANTHROPIC_API_KEY // .env.ANTHROPIC_AUTH_TOKEN // .apiKeyHelper) != null' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
        f "API-key settings in ~/.claude/settings.json"; keyhit=1
    fi
    [ "$keyhit" = 0 ] && p "no provider API keys on the box"
    [ -f "$HOME/.claude/.credentials.json" ] && s "OAuth login present in ~/.claude (unused — Bedrock forced; a medical box should not carry one)"

    CMS="$HOME/.claude-mem/settings.json"
    if [ -s "$CMS" ] && [ "$(jq -r '.CLAUDE_MEM_MODEL // empty' "$CMS" 2>/dev/null)" = "sonnet" ] \
       && [ "$(jq -r '.CLAUDE_MEM_TELEMETRY // empty' "$CMS" 2>/dev/null)" = "0" ]; then
        p "claude-mem pinned (sonnet via CLI, telemetry off)"
    else
        f "claude-mem settings not pinned (21-medical-claude-mem)"
    fi

    if [ -f /usr/share/backgrounds/claude-terminal-medical.svg ]; then p "medical wallpaper installed"; else f "medical wallpaper missing"; fi
    if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org\.gnome\.desktop\.background$'; then
        if [ "$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)" = "'file:///usr/share/backgrounds/claude-terminal-medical.svg'" ]; then
            p "medical wallpaper selected"
        else
            f "wallpaper is $(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null || echo unreadable)"
        fi
    fi
    if grep -q '^# >>> claude-terminal medical banner >>>' "$HOME/.bashrc" 2>/dev/null; then p "shell banner installed"; else f "shell banner missing from ~/.bashrc"; fi
    if grep -q 'Ai Build Medical' /etc/motd 2>/dev/null; then p "motd line present"; else f "motd line missing"; fi

    # Host-side belt-and-braces: the enforced permissions come from the broker
    # per session; desktop-setup.sh also writes the deny into default.perm.
    if grep -qE '^[[:space:]]*%any%[[:space:]]+deny[[:space:]]+.*file-download' /etc/dcv/default.perm 2>/dev/null; then
        p "DCV default.perm denies file-download"
    else
        f "/etc/dcv/default.perm does not deny file-download (host: desktop-setup.sh medical branch)"
    fi
fi

```

- [ ] **Step 3: Lint + container check** (medical container: run 08, 21, 43 then verify; expect the medical section with exactly one FAIL — the DCV `default.perm`, which the host writes in step 3 — and the login line reading Bedrock even without `claude`)

```bash
bash -n verify.sh && docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x verify.sh && echo ok
S=/tmp/claude-1000/-home-cc-Projects-claude-terminal/2aeac79b-f648-4a35-9514-a88d87166b63/scratchpad/medical-container.sh
bash "$S" "$PWD" 'run_mod() { . lib/common.sh; CT_TMP=$(mktemp -d); CT_STATUS=$CT_TMP/s; SCRIPT_DIR=$PWD; export CT_TMP CT_STATUS SCRIPT_DIR; ( . "modules/core/$1" ) >/dev/null 2>&1; }
for m in 08-medical-bedrock.sh 21-medical-claude-mem.sh 43-medical-cues.sh; do run_mod $m; done
sudo mkdir -p /etc/dcv && printf "[permissions]\n%%owner%% allow builtin\n%%any%% deny file-download printer\n" | sudo tee /etc/dcv/default.perm >/dev/null
bash verify.sh 2>/dev/null | sed -n "/medical mode/,\$p"'
```
Expected: every medical line `PASS` (with `default.perm` faked as the host will write it), no `FAIL` in the section. Also run the `standard` profile: `bash "$S" "$PWD" 'bash verify.sh 2>/dev/null | grep -c "medical mode"' standard` → `0`.

- [ ] **Step 4: Commit**

```bash
git add verify.sh && git commit -q -m "feat(verify): medical-mode section + Bedrock-aware login line

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 7: Full-bootstrap container run (the real proof) + non-medical regression

**Files:** none (validation only)

- [ ] **Step 1: Medical container, full `./bootstrap.sh`** — this exercises ordering (08 before 10), plugin install at bootstrap without any login, and the summary having no "run claude to log in" step:

```bash
S=/tmp/claude-1000/-home-cc-Projects-claude-terminal/2aeac79b-f648-4a35-9514-a88d87166b63/scratchpad/medical-container.sh
timeout 1800 bash "$S" "$PWD" 'bash bootstrap.sh 2>&1 | tail -45; echo "=== plugins ==="; ls ~/.claude/plugins/cache/; echo "=== verify ==="; sudo mkdir -p /etc/dcv && printf "[permissions]\n%%owner%% allow builtin\n%%any%% deny file-download printer\n" | sudo tee /etc/dcv/default.perm >/dev/null; bash verify.sh 2>/dev/null | grep -E "FAIL|Bedrock|medical|plugin" ; echo "=== second bootstrap (idempotent) ==="; bash bootstrap.sh 2>&1 | grep -E "^  (OK|SKIPPED|FAILED)" | grep -E "medical|claude-mem|superpowers|claude-code"' 2>&1 | tail -80
```
Expected: summary shows `OK 08-medical-bedrock`, `OK 21-medical-claude-mem`, `OK 43-medical-cues`, `OK 20-claude-mem installed…`, `OK 25-superpowers installed…`; NEXT STEPS contains no login reminder; both plugin caches listed; verify shows `claude → Amazon Bedrock` and no `FAIL` lines apart from GNOME-only items the container cannot satisfy (screen-lock/idle checks need the schemas — they are installed by the harness, so expect none); the second run is all `OK`.

- [ ] **Step 2: Standard container, full bootstrap — the three modules SKIP and nothing medical lands**

```bash
timeout 1800 bash "$S" "$PWD" 'bash bootstrap.sh 2>&1 | grep -E "^  (OK|SKIPPED|FAILED)" | grep -E "medical|claude-mem|superpowers"; ls /etc/claude-code 2>&1; grep -c "medical" /etc/bash.bashrc ~/.bashrc; bash verify.sh 2>/dev/null | grep -cE "medical|Bedrock"' standard 2>&1 | tail -12
```
Expected: `SKIPPED 08-medical-bedrock not a medical terminal` (and 21, 43), `SKIPPED 20-claude-mem … not logged in` (unchanged behaviour), `No such file or directory`, `0` and `0`, `0`.

### Task 8: Docs — README, DEVELOPMENT.md, CHANGELOG

**Files:**
- Modify: `README.md` (new section after "Provisioning cloud terminals (AWS + Amazon DCV)")
- Modify: `docs/DEVELOPMENT.md` (module contract helper list + repo map)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: README section**

```markdown
## Medical mode (Ai Build Medical) — regulated-data terminals

An opt-in profile for HIPAA-adjacent engagements, DCV terminals only for now.
The box is the compliance boundary: **Claude Code and claude-mem talk to
Amazon Bedrock inside the tenant's own AWS account and to nothing else**, no
provider API keys may exist on the box, and the desktop is visibly marked
PHI-approved (wallpaper, shell banner, motd). No Claude login exists on such
a box — credentials come from the instance role.

Activation is state on the box, not a flag on a run (the fleet updater
re-runs `get.sh` daily with no arguments): the platform writes
`ASP_PROFILE=medical` into `/etc/asp-terminal.env`, or an operator flips a
box by hand with `./bootstrap.sh --medical` (writes
`/etc/claude-terminal/medical`). Region and model IDs come from
`/etc/asp-terminal.env` (`ASP_REGION`, optional `ASP_BEDROCK_SONNET|OPUS|HAIKU`).
`./verify.sh` grows a **medical mode** section whose bar is zero FAILs.

What it pins: `/etc/claude-code/managed-settings.json` (Bedrock, region,
model IDs; user settings cannot override), the same env in `/etc/bash.bashrc`
+ `/etc/profile.d/`, claude-mem's model/telemetry/cloud-sync settings, and a
sweep that removes `ANTHROPIC_*`/`GEMINI_*`/`OPENROUTER_*` credential lines
it finds. The tenant-side half (IAM, Bedrock zero-data-retention lock, DCV
file-download deny) lives in `aws/` — see `aws/runbooks/build-tenant.md`.
```

- [ ] **Step 2: DEVELOPMENT.md** — in the repo map add `| `modules/core/08-medical-bedrock.sh`, `21-…`, `43-…` | medical-profile modules; skip unless `is_medical_terminal` (see README "Medical mode") |` and in the helpers list (rule 4) append: "`is_dcv_terminal` / `is_medical_terminal` / `asp_env KEY` (platform facts from `/etc/asp-terminal.env`), `sudo_append_block` (append_block for root-owned files), `claude_bedrock_ready` (managed settings pin Claude Code to Bedrock — `claude_ready` is true then too)."

- [ ] **Step 3: CHANGELOG** — new top section:

```markdown
## 2026-08-18 — medical mode (Ai Build Medical), kit side

- **New opt-in profile for regulated-data terminals (DCV only).** Activated by
  state (`ASP_PROFILE=medical` in `/etc/asp-terminal.env` or
  `./bootstrap.sh --medical` → `/etc/claude-terminal/medical`), three core
  modules that skip everywhere else: `08-medical-bedrock` (Claude Code pinned
  to Amazon Bedrock via `/etc/claude-code/managed-settings.json` + system env;
  provider API keys swept off the box), `21-medical-claude-mem` (sonnet via
  the CLI's aliases, telemetry + cloud sync off, credential strip),
  `43-medical-cues` (PHI-approved wallpaper, shell banner, motd).
  `claude_ready` is now true when Bedrock is pinned — plugins install during
  bootstrap and no login reminder is printed. `verify.sh` gains a medical
  section (bar: zero FAILs). Design:
  `docs/superpowers/specs/2026-08-18-medical-mode-design.md`. The aws/ half
  (profile var, IAM, ZDR lock, DCV deny) is the next step.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/DEVELOPMENT.md CHANGELOG.md && git commit -q -m "docs: medical mode (kit side) — README section, DEVELOPMENT helpers, changelog

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
```

### Task 9: Land on main

- [ ] **Step 1: Final lint + sweep on the branch**

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x $(git ls-files '*.sh' | grep -v '^aws/') && echo kit-shellcheck-clean
git diff origin/main...HEAD | grep -E "^\+" | grep -nEi "@[a-z0-9.-]+\.(com|net|org)|i-0[0-9a-f]{8,}|[0-9]{12}|arn:aws|adnet|oldco-|cct0[0-9]|trevor|clientslug" | grep -viE "example\.com|acme|<account-id>|Co-Authored-By|noreply@anthropic" || echo sweep-clean
```

- [ ] **Step 2: Reconcile + merge from the primary checkout**

```bash
cd /home/cc/Projects/claude-terminal && git fetch -q origin && git log --oneline main..origin/main
git merge --ff-only origin/main -q 2>/dev/null || true
git merge --no-ff step2-medical-kit -m "Merge step2-medical-kit: medical mode, kit side

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_017jHNL68dJDtBz9QTN7w3yS"
git push -q origin main && git log --oneline -1
```
If `origin/main` moved with conflicting edits, merge `origin/main` into the branch in the worktree, re-run Task 7 Step 1, then retry.

- [ ] **Step 3: Cleanup + notes** — `git worktree remove` the step-2 worktree, `git branch -d step2-medical-kit`, add the step-2 status to `/home/cc/Projects/claude-terminal/CLAUDE.md` (gitignored) and the memory file.
