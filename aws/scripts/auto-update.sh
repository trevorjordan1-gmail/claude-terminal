#!/bin/bash
# Windows-Update-style self-updater — runs on each terminal via systemd timer.
# Applies a release only when: a newer version is published to the tenant
# bucket AND nobody is connected (defers like WU under active use).
set -uo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env
WANT=$(aws s3 cp "s3://$ASP_BUCKET/release/version" - 2>/dev/null) || exit 0
CUR=$(cat /opt/asp/applied-version 2>/dev/null || echo none)
[ -z "$WANT" ] || [ "$WANT" = "$CUR" ] && exit 0
# defer while in use
SID=$(dcv list-sessions 2>/dev/null | grep -oP "Session: .\K[a-f0-9-]+" | head -1)
if [ -n "$SID" ]; then
  CONNS=$(dcv list-connections -j "$SID" 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')
  [ "${CONNS:-0}" -gt 0 ] && { echo "deferred: session in use"; exit 0; }
fi
echo "applying release $WANT (was $CUR)"
aws s3 cp "s3://$ASP_BUCKET/scripts/desktop-setup.sh" /opt/asp/setup.sh && bash /opt/asp/setup.sh >> /var/log/asp-update.log 2>&1
su - "$ASP_LOCAL_USER" -c 'curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash' >> /var/log/asp-update.log 2>&1
echo "$WANT" > /opt/asp/applied-version
echo "applied $WANT"
