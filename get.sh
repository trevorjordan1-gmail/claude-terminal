#!/usr/bin/env bash
# claude-terminal one-liner entrypoint:
#
#   curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash -s -- --with-docker
#
# Clones (or updates) the repo to ~/claude-terminal and hands off to bootstrap.sh.
set -euo pipefail

REPO_URL="https://github.com/trevorjordan1-gmail/claude-terminal.git"
DEST="${CLAUDE_TERMINAL_DIR:-$HOME/claude-terminal}"

if ! command -v git >/dev/null 2>&1; then
    echo "[get] git not found — installing it first (sudo may prompt)..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git
fi

if [ -d "$DEST/.git" ]; then
    echo "[get] updating existing checkout at $DEST"
    git -C "$DEST" pull --ff-only
else
    echo "[get] cloning to $DEST"
    git clone "$REPO_URL" "$DEST"
fi

exec bash "$DEST/bootstrap.sh" "$@"
