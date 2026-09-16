#!/bin/bash
# Activity probe — run ON a desktop by the control plane's idle watchdog (SSM).
# Emits one JSON line describing who/what is actually using this terminal.
#
# WHY IT NO LONGER TRUSTS CPU (#55, field data 2026-09-16): an idle Claude REPL
# is NOT free. It keeps its MCP servers alive as children (mcp-remote,
# claude-mem's mcp-server.cjs) and burns 0.4-0.9% CPU forever, i.e. 120-260
# ticks per 300s window. Two REPLs left open therefore clear ANY sane
# "claude is working" tick threshold permanently: terminal A stayed awake
# 45h and build box B 188h with nobody connected and every session idle.
# claude_cpu is still reported (telemetry, and the old watchdog reads it), but
# the decision now rests on signals that were correct in every field case:
#
#   conns            a DCV client is connected — a human is looking at it
#   last_conn_age_s  seconds since the last client connected, from the DCV
#                    server log. DCV drops a connected-but-untouched client
#                    after 60 minutes (its own idle-timeout, observed firing
#                    24 times across two boxes), so "no connection" already
#                    means "nobody has touched this for an hour".
#   claude_busy      sessions Claude itself reports as busy, from its
#                    first-party ~/.claude/sessions/<pid>.json status file
#   busy_entry_age_s how long since a BUSY session last wrote a transcript
#                    entry — a real agent run keeps writing; a wedged one
#                    stops. Two agreeing signals, so neither alone can pin
#                    a box awake.
#   hold_until       an explicit `asp-hold` lease (long monitors), with a TTL
#
# Signals deliberately NOT used, each a measured false positive (#55):
#   transcript FILE mtime (idle REPLs rewrite it ~every 20 min with no new
#   entries), policy-limits.json / backups/, mutter IdleMonitor (reported
#   1.7h since "input" with no client connected for 9h), who/last (DCV never
#   registers in utmp), loginctl IdleHint (permanently active), pty mtime,
#   dcvagent/Xdcv CPU (they burn more than the REPLs with nobody connected).

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

# ---- Claude's own view of itself, + the viewer history ----------------------
# One python pass: session status files across every user, their transcripts,
# the DCV connect log, and the hold lease.
CLAUDE=$(CONNS="$CONNS" python3 <<'PY'
import glob, json, os, re, time

now = time.time()
busy = idle = 0
busy_entry_age = None     # youngest transcript entry across BUSY sessions
newest_entry_age = None   # youngest across all live sessions (corroboration)


def proc_alive(pid, proc_start):
    """Live pid AND the same process — starttime guards against pid reuse."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            fields = fh.read().rsplit(b") ", 1)[1].split()
        return not proc_start or fields[19].decode() == str(proc_start)
    except Exception:
        return False


def last_entry_age(home, session_id):
    """Seconds since the last ENTRY inside the transcript. NOT the file mtime:
    an idle REPL rewrites the file without adding entries (#55)."""
    for path in glob.glob(f"{home}/.claude/projects/*/{session_id}.jsonl"):
        last = None
        try:
            with open(path, "rb") as fh:
                for line in fh:
                    if line.strip():
                        last = line
        except OSError:
            continue
        if not last:
            continue
        try:
            ts = json.loads(last).get("timestamp", "")
            # stored as UTC ISO-8601 with a trailing Z
            t = time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
            return max(0, int(now - t))
        except Exception:
            continue
    return None


for sess in glob.glob("/home/*/.claude/sessions/*.json"):
    home = sess.split("/.claude/", 1)[0]
    try:
        d = json.load(open(sess))
    except Exception:
        continue
    if not proc_alive(d.get("pid"), d.get("procStart")):
        continue          # stale file for a process that has gone
    age = last_entry_age(home, d.get("sessionId", ""))
    if age is not None and (newest_entry_age is None or age < newest_entry_age):
        newest_entry_age = age
    if d.get("status") == "busy":
        busy += 1
        if age is not None and (busy_entry_age is None or age < busy_entry_age):
            busy_entry_age = age
    else:
        idle += 1

# ---- when did a viewer last connect? ---------------------------------------
# The DCV server log is the durable record and survives a watchdog restart.
# Timestamps are LOCAL time ("2026-09-15 13:04:14,656443").
last_conn_age = -1
if int(os.environ.get("CONNS", "0")) > 0:
    last_conn_age = 0
else:
    newest = None
    pat = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ .*Client \d+ \(user: [^)]+\) connected")
    for log in glob.glob("/var/log/dcv/server.log*"):
        try:
            with open(log, "r", errors="replace") as fh:
                for line in fh:
                    m = pat.match(line)
                    if m:
                        t = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
                        if newest is None or t > newest:
                            newest = t
        except OSError:
            continue
    if newest is not None:
        last_conn_age = max(0, int(now - newest))

# ---- explicit keep-awake lease (long-running monitors) ----------------------
hold_until, hold_why = 0, ""
try:
    h = json.load(open("/var/lib/asp/keep-awake.json"))
    hold_until = int(h.get("until", 0))
    hold_why = str(h.get("why", ""))[:80].replace('"', "'")
except Exception:
    pass

print(json.dumps({
    "claude_busy": busy,
    "claude_idle": idle,
    "busy_entry_age_s": -1 if busy_entry_age is None else busy_entry_age,
    "newest_entry_age_s": -1 if newest_entry_age is None else newest_entry_age,
    "last_conn_age_s": last_conn_age,
    "hold_until": hold_until,
    "hold_why": hold_why,
}))
PY
)
# a python failure must never make the box look busy — fail to "nothing known"
case "$CLAUDE" in
  \{*\}) : ;;
  *) CLAUDE='{"claude_busy":0,"claude_idle":0,"busy_entry_age_s":-1,"newest_entry_age_s":-1,"last_conn_age_s":-1,"hold_until":0,"hold_why":"probe-error"}' ;;
esac

echo "{\"conns\":$CONNS,\"claude_procs\":$NPROC,\"claude_cpu\":$CPU,\"load1\":$LOAD1,\"uptime\":$UP,\"apt\":$APT,\"probe_version\":2,${CLAUDE#\{}"
