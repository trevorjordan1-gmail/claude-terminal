#!/bin/bash
# Keep the DCV session-manager agent's broker link alive across hibernation.
# Idempotent, re-runnable via SSM.
#
# THE BUG THIS EXISTS FOR: an EC2 hibernate/resume restores the agent's TCP
# connection to the broker as ESTABLISHED in the kernel, but the broker's end
# closed hours earlier. The agent never learns this — it keeps writing session
# updates into a socket that will never drain (Send-Q climbs, nothing comes
# back), so it never re-registers. The broker keeps reporting the terminal
# UNAVAILABLE, the portal gates Connect on exactly that, and the user sits
# looking at a box that is fully awake and idle. Observed: 6+ minutes after a
# resume, DCV up, session alive, 8443 listening, and still unreachable.
#
# Restarting the agent fixes it in seconds and does NOT disturb a running
# session. So: restart it on resume, and keep a backstop for every other way
# the link can die (broker restart, network blip, a resume path that skips the
# sleep hooks).
set -uo pipefail

install -d /opt/asp

# ---- 1. fast path: restart on resume ----------------------------------
# systemd runs these on every sleep transition; EC2 hibernation goes through
# systemd-hibernate.service, so 'post hibernate' is our wake signal.
# --no-block: system-sleep hooks stall the resume until they return.
cat > /usr/lib/systemd/system-sleep/asp-dcv-relink <<'HOOK'
#!/bin/bash
[ "$1" = "post" ] || exit 0
systemctl restart --no-block dcv-session-manager-agent
logger -t asp-dcv-relink "resumed from $2 — reconnecting the DCV agent to the broker"
HOOK
chmod 755 /usr/lib/systemd/system-sleep/asp-dcv-relink

# ---- 2. backstop: notice a mute agent and restart it -------------------
# The agent exchanges a session update with the broker every ~10s and logs it,
# so a stale log IS a dead link — a far more direct signal than probing the
# socket, which reads healthy in precisely the case we care about.
cat > /opt/asp/dcv-relink-check.sh <<'CHECK'
#!/bin/bash
set -uo pipefail
UNIT=dcv-session-manager-agent
LOG=/var/log/dcv-session-manager-agent/agent.log
STAMP=/run/asp-dcv-relink.stamp
MAX_SILENCE=120   # heartbeats are ~10s apart; 120s is unambiguous
MIN_INTERVAL=300  # never thrash when the BROKER is what's down

systemctl is-active --quiet "$UNIT" || exit 0
[ -f "$LOG" ] || exit 0
now=$(date +%s)
if [ -f "$STAMP" ] && [ $(( now - $(cat "$STAMP" 2>/dev/null || echo 0) )) -lt "$MIN_INTERVAL" ]; then
  exit 0
fi
age=$(( now - $(stat -c %Y "$LOG") ))
[ "$age" -le "$MAX_SILENCE" ] && exit 0
echo "$now" > "$STAMP"
logger -t asp-dcv-relink "broker link silent for ${age}s — restarting $UNIT"
systemctl restart "$UNIT"
CHECK
chmod +x /opt/asp/dcv-relink-check.sh

cat > /etc/systemd/system/asp-dcv-relink.service <<'UNIT'
[Unit]
Description=Restart the DCV agent when its broker link has gone silent
[Service]
Type=oneshot
ExecStart=/opt/asp/dcv-relink-check.sh
UNIT

cat > /etc/systemd/system/asp-dcv-relink.timer <<'TIMER'
[Unit]
Description=Watch the DCV agent's broker link
[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10s
[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now asp-dcv-relink.timer
echo "dcv-relink: armed (resume hook + 60s backstop)"
