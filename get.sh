#!/usr/bin/env bash
# claude-terminal has moved — this forwards the old one-liner.
#   Standalone boxes  → the new kit:  curl -fsSL https://get.adnet.tools | bash
#   Fleet (DCV) boxes → their kit from their own tenant bucket, at their channel's version
#                       (older fleet scripts still curl this URL when they build a terminal)
set -euo pipefail
NEW="https://raw.githubusercontent.com/adnettech/ai-terminal/main/get.sh"
say() { printf '[claude-terminal → ai-terminal] %s\n' "$*"; }

ENVF="${ASP_TERMINAL_ENV:-/etc/asp-terminal.env}"
if [ -f "$ENVF" ]; then
    BUCKET=$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?ASP_BUCKET=//p" "$ENVF" | head -1 | tr -d "\"'\r")
    [ -n "$BUCKET" ] || { say "fleet box without ASP_BUCKET in $ENVF — cannot install"; exit 1; }
    V=$(aws s3 cp "s3://$BUCKET/release/version" - 2>/dev/null | tr -d '[:space:]') || V=""
    [ -n "$V" ] || { say "no release/version in s3://$BUCKET — nothing to install"; exit 1; }
    DEST="${CLAUDE_TERMINAL_DIR:-$HOME/claude-terminal}"
    W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
    aws s3 cp "s3://$BUCKET/kit/$V/claude-terminal.tar.gz" "$W/claude-terminal.tar.gz" --quiet \
      && aws s3 cp "s3://$BUCKET/kit/$V/claude-terminal.tar.gz.sha256" "$W/claude-terminal.tar.gz.sha256" --quiet \
      || { say "no kit published for $V in s3://$BUCKET/kit/ — ask the operator for a fleet release"; exit 1; }
    ( cd "$W" && sha256sum -c --quiet claude-terminal.tar.gz.sha256 ) || { say "checksum mismatch for kit $V — refusing"; exit 1; }
    rm -rf "$DEST.new"; mkdir -p "$DEST.new"
    tar xzf "$W/claude-terminal.tar.gz" -C "$DEST.new" --strip-components=1
    [ -x "$DEST.new/bootstrap.sh" ] || { say "kit $V has no bootstrap.sh — refusing"; rm -rf "$DEST.new"; exit 1; }
    rm -rf "$DEST.old"; [ -e "$DEST" ] && mv "$DEST" "$DEST.old"; mv "$DEST.new" "$DEST"
    say "fleet box: kit $V installed from the tenant bucket at $DEST"
    exec bash "$DEST/bootstrap.sh" "$@"
fi

say "claude-terminal is now Ai Terminal (https://github.com/adnettech/ai-terminal) — handing over"
curl -fsSL "$NEW" | bash -s -- "$@"
