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
if [ "$NEW" != "$(cat "$S")" ]; then
    printf '%s\n' "$NEW" > "$S" || fail "could not write $S"
fi

T="$D/telemetry.json"
[ "$(cat "$T" 2>/dev/null)" = '{"enabled": false}' ] || printf '{"enabled": false}\n' > "$T"

# The five credential keys claude-mem reads from .env; any of them bypasses
# Bedrock (direct API key / gateway / Gemini / OpenRouter).
E="$D/.env"
KEYRE='^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|GEMINI_API_KEY|OPENROUTER_API_KEY)='
if [ -f "$E" ] && grep -qE "$KEYRE" "$E"; then
    sed -i -E "/$KEYRE/d" "$E" \
        && warn "stripped provider credentials from ~/.claude-mem/.env (medical boxes talk to Bedrock only)"
fi

ok "claude-mem → Bedrock via the CLI (sonnet); telemetry + cloud sync off"
