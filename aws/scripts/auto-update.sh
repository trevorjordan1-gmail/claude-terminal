#!/bin/bash
# Windows-Update-style self-updater — runs on each terminal via systemd timer.
# Applies a release only when: a newer version is published to the tenant
# bucket AND nobody is connected AND we are not inside the fragile window just
# after a hibernate resume (defers like WU under active use, retrying ~2h).
set -uo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env

# Only ever one of these at a time. Without a lock, a catch-up run and the
# daily run can overlap and re-enter desktop-setup.sh concurrently.
exec 9>/run/asp-auto-update.lock
flock -n 9 || { echo "another update run holds the lock"; exit 0; }

# Never update in the minutes right after a hibernate resume. The user is
# about to connect and the connection count below still reads 0 — that race is
# how a build box lost a live session on 2026-09-01. /run is tmpfs and is
# restored with the RAM image, so this stamp survives a resume and is absent
# after a real boot (where OnBootSec already gives us a delay).
RESUME_GRACE=${ASP_UPDATE_RESUME_GRACE:-900}
if [ -r /run/asp-resumed-at ]; then
  since=$(( $(date +%s) - $(cat /run/asp-resumed-at 2>/dev/null || echo 0) ))
  if [ "$since" -lt "$RESUME_GRACE" ]; then
    echo "deferred: resumed ${since}s ago (grace ${RESUME_GRACE}s)"; exit 0
  fi
fi

WANT=$(aws s3 cp "s3://$ASP_BUCKET/release/version" - 2>/dev/null) || exit 0
CUR=$(cat /opt/asp/applied-version 2>/dev/null || echo none)
[ -z "$WANT" ] || [ "$WANT" = "$CUR" ] && exit 0
# defer while in use. Checked more than once: the download below takes tens of
# seconds, and a user connecting inside that window used to get their session
# destroyed by the setup run (2026-09-01).
in_use() {
  local sid conns
  sid=$(dcv list-sessions 2>/dev/null | grep -oP "Session: .\K[a-f0-9-]+" | head -1)
  [ -n "$sid" ] || return 1
  conns=$(dcv list-connections -j "$sid" 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')
  [ "${conns:-0}" -gt 0 ]
}
in_use && { echo "deferred: session in use"; exit 0; }
echo "applying release $WANT (was $CUR)"
SETUP_OK=1
aws s3 cp "s3://$ASP_BUCKET/scripts/desktop-setup.sh" /opt/asp/setup.sh || SETUP_OK=0
# last look before we run anything that touches the desktop
if [ "$SETUP_OK" = 1 ] && in_use; then
  echo "deferred: user connected during download — not stamped, retries next run"
  exit 0
fi
[ "$SETUP_OK" = 1 ] && { bash /opt/asp/setup.sh >> /var/log/asp-update.log 2>&1 || SETUP_OK=0; }
su - "$ASP_LOCAL_USER" -c 'curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash' >> /var/log/asp-update.log 2>&1
# desktop-setup exits 1 when a sub-step FATALed (#7). Don't stamp the release
# then: the next daily run retries the same version, so a transient failure
# (a dpkg lock, a CDN blip) heals on its own instead of waiting for a new tag.
if [ "$SETUP_OK" = 1 ]; then
  echo "$WANT" > /opt/asp/applied-version
  echo "applied $WANT"
else
  echo "release $WANT: desktop-setup failed — not stamped, will retry on the next run (see /var/log/asp-update.log)"
fi
