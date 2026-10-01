#!/usr/bin/env bash
# claude-terminal has moved. An old checkout that pulled this repo lands here: hand over to
# the new kit (it moves this checkout aside, keeps it, and links the old path).
set -euo pipefail
printf '[claude-terminal → ai-terminal] this checkout is retired — installing Ai Terminal\n'
cd "$HOME"
curl -fsSL https://raw.githubusercontent.com/adnettech/ai-terminal/main/get.sh | bash -s -- "$@"
