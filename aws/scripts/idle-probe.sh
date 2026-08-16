#!/bin/bash
# Activity probe — run ON a desktop by the control plane's idle watchdog (SSM).
# Emits one JSON line: DCV connections, claude processes + their cumulative CPU
# ticks, 1-min load, uptime.

SID=$(dcv list-sessions 2>/dev/null | awk -F"'" '/Session:/ {print $2; exit}')
CONNS=0
if [ -n "$SID" ]; then
  CONNS=$(dcv list-connections -j "$SID" 2>/dev/null | python3 -c '
import json, sys
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(0)')
fi

PIDS=$({ pgrep -x claude; pgrep -f "claude-code|bin/claude"; } 2>/dev/null | sort -u)
NPROC=0
CPU=0
for p in $PIDS; do
  [ -d "/proc/$p" ] || continue
  NPROC=$((NPROC + 1))
  T=$(awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null || echo 0)
  CPU=$((CPU + T))
done

LOAD1=$(cut -d' ' -f1 /proc/loadavg)
UP=$(cut -d. -f1 /proc/uptime)
# package work in flight? (the watchdog must never power off mid-apt)
# The dpkg lock is the canonical signal — process-name greps match Ubuntu's
# always-running unattended-upgrade-shutdown monitor and never read 0.
APT=$(flock -n /var/lib/dpkg/lock-frontend -c true 2>/dev/null && echo 0 || echo 1)

echo "{\"conns\":$CONNS,\"claude_procs\":$NPROC,\"claude_cpu\":$CPU,\"load1\":$LOAD1,\"uptime\":$UP,\"apt\":$APT}"
