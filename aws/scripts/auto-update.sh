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
# ---- is this terminal busy? -------------------------------------------------
# Deferring is a RETRY, not a skip: we exit without stamping applied-version,
# so the ~2h timer re-attempts until the box is genuinely free.
#
# "Busy" is answered by idle-probe.sh -- the SAME probe the control plane's idle
# watchdog runs -- so busy means one thing platform-wide instead of two
# definitions drifting apart. It reports three things we must respect:
#   conns        a viewer is connected (someone is looking at it)
#   claude_cpu   cumulative CPU ticks across claude processes; a DELTA means an
#                agent run is in flight. A detached session with a live Claude
#                job reads as 0 connections but must not be updated under --
#                desktop-setup reinstalls the workbench and can swap the CLI
#                out from under a running job.
#   apt          dpkg mid-transaction; two apt consumers on one lock and the
#                loser breaks silently (#7).
PROBE=/opt/asp/idle-probe.sh
BUSY_WINDOW=${ASP_UPDATE_BUSY_WINDOW:-60}
# 60 ticks per 60s is the same RATE as the watchdog's 300 ticks per 5-min
# window, so both agree on what "claude is working" means.
BUSY_TICKS=${ASP_UPDATE_BUSY_TICKS:-60}

probe_field() { printf '%s' "$1" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('$2', 0))
except Exception: print(0)"; }

# Fallback for a box whose probe hasn't been staged yet: connections only,
# i.e. exactly the old behaviour. Never defer forever just because it's absent.
legacy_in_use() {
  local sid conns
  sid=$(dcv list-sessions 2>/dev/null | grep -oP "Session: .\K[a-f0-9-]+" | head -1)
  [ -n "$sid" ] || return 1
  conns=$(dcv list-connections -j "$sid" 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')
  [ "${conns:-0}" -gt 0 ]
}

# Echoes a human reason when busy, nothing when free.
busy_reason() {
  local a b c apt cpu1 cpu2 delta
  # -r, not -x: the watchdog stages this file without an exec bit and always
  # invokes it as `bash idle-probe.sh`, so testing -x here silently disabled
  # the probe on every box (caught on a build box, 2026-09-01).
  if [ ! -r "$PROBE" ]; then
    legacy_in_use && echo "session in use (probe unavailable)"
    return
  fi
  a=$(bash "$PROBE" 2>/dev/null)
  [ -n "$a" ] || { legacy_in_use && echo "session in use (probe failed)"; return; }
  c=$(probe_field "$a" conns); apt=$(probe_field "$a" apt)
  [ "${c:-0}" -gt 0 ]   && { echo "viewer connected ($c)"; return; }
  [ "${apt:-0}" -gt 0 ] && { echo "dpkg transaction in flight"; return; }
  # Only now spend the sample window, and only to catch a DETACHED agent run.
  cpu1=$(probe_field "$a" claude_cpu)
  sleep "$BUSY_WINDOW"
  b=$(bash "$PROBE" 2>/dev/null)
  [ -n "$b" ] || return
  cpu2=$(probe_field "$b" claude_cpu)
  delta=$(( cpu2 - cpu1 ))
  # negative = claude restarted inside the window; treat as activity, as the
  # watchdog does
  if [ "$delta" -ge "$BUSY_TICKS" ] || [ "$delta" -lt 0 ]; then
    echo "claude working (${delta} ticks in ${BUSY_WINDOW}s)"
  fi
}

# Leave a breadcrumb so a box that keeps deferring is VISIBLE rather than
# silently stale -- otherwise "it retries" quietly becomes "it never updates".
note_deferral() {
  install -d /var/lib/asp
  WANT="$WANT" REASON="$1" python3 -c "
import json, os, pathlib, time
f = pathlib.Path('/var/lib/asp/update-deferred.json')
try:
    d = json.loads(f.read_text())
except Exception:
    d = {}
now = int(time.time())
if d.get('want') != os.environ['WANT']:
    d = {'want': os.environ['WANT'], 'first_deferred_at': now, 'count': 0}
d['count'] = d.get('count', 0) + 1
d['last_deferred_at'] = now
d['last_reason'] = os.environ['REASON']
f.write_text(json.dumps(d))
hours = (now - d.get('first_deferred_at', now)) / 3600.0
if hours >= 72:
    print('WARNING: %s deferred for %.0fh (%d attempts) - still on the old release'
          % (os.environ['WANT'], hours, d['count']))
" || true
}

BUSY=$(busy_reason)
[ -n "$BUSY" ] && { echo "deferred: $BUSY - will retry next tick"; note_deferral "$BUSY"; exit 0; }
echo "applying release $WANT (was $CUR)"
SETUP_OK=1
aws s3 cp "s3://$ASP_BUCKET/scripts/desktop-setup.sh" /opt/asp/setup.sh || SETUP_OK=0
# last look before we run anything that touches the desktop
if [ "$SETUP_OK" = 1 ]; then
  BUSY=$(busy_reason)
  if [ -n "$BUSY" ]; then
    echo "deferred: $BUSY during download - not stamped, retries next tick"
    note_deferral "$BUSY"; exit 0
  fi
fi
[ "$SETUP_OK" = 1 ] && { bash /opt/asp/setup.sh >> /var/log/asp-update.log 2>&1 || SETUP_OK=0; }
su - "$ASP_LOCAL_USER" -c 'curl -fsSL https://raw.githubusercontent.com/trevorjordan1-gmail/claude-terminal/main/get.sh | bash' >> /var/log/asp-update.log 2>&1
# desktop-setup exits 1 when a sub-step FATALed (#7). Don't stamp the release
# then: the next daily run retries the same version, so a transient failure
# (a dpkg lock, a CDN blip) heals on its own instead of waiting for a new tag.
if [ "$SETUP_OK" = 1 ]; then
  echo "$WANT" > /opt/asp/applied-version
  rm -f /var/lib/asp/update-deferred.json
  echo "applied $WANT"
else
  echo "release $WANT: desktop-setup failed — not stamped, will retry on the next run (see /var/log/asp-update.log)"
fi
