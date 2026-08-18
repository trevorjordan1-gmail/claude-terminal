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
            case " $PROFILES " in
                *" $m "*) ;;
                *) warn "Bedrock lists no inference profile '$m' in $REGION — check the model ID / model access" ;;
            esac
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
    { sudo install -d -m 0755 /etc/claude-code \
        && printf '%s\n' "$NEW" | sudo tee "$MANAGED" >/dev/null \
        && sudo chmod 0644 "$MANAGED"; } \
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
PROFILED_WANT="# claude-terminal medical mode — Claude Code talks to Amazon Bedrock only
$ENVBLOCK"
if [ "$(sudo cat "$PROFILED" 2>/dev/null)" != "$PROFILED_WANT" ]; then
    { printf '%s\n' "$PROFILED_WANT" | sudo tee "$PROFILED" >/dev/null && sudo chmod 0644 "$PROFILED"; } \
        || fail "could not write $PROFILED"
fi

# 3. No provider credentials anywhere on the box. Direct keys, a base-URL
#    gateway, or a Gemini/OpenRouter key (claude-mem providers) would route
#    around Bedrock (and the tenant's ZDR posture) — strip and say so. Same
#    five keys verify.sh checks, same regex.
KEYRE='^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|GEMINI_API_KEY|OPENROUTER_API_KEY)='
for f in /etc/environment /etc/profile.d/*.sh; do
    if [ ! -f "$f" ] || [ "$f" = "$PROFILED" ]; then continue; fi
    if sudo grep -qE "$KEYRE" "$f" 2>/dev/null; then
        sudo sed -i -E "/$KEYRE/d" "$f" \
            && warn "removed a provider credential line from $f (medical boxes talk to Bedrock only)"
    fi
done
for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    [ -f "$f" ] || continue
    if grep -qE "$KEYRE" "$f"; then
        sed -i -E "/$KEYRE/d" "$f" \
            && warn "removed a provider credential line from $f (medical boxes talk to Bedrock only)"
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
