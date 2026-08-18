#!/bin/bash
# Arm this terminal's nightly backup — idempotent, re-runnable via SSM.
#
# DORMANT BY DEFAULT, exactly like build boxes: if the tenant has no
# /asp/backup/config parameter, this is a no-op and the box simply has no
# backup. A tenant opts in by creating that parameter (see runbooks/backups.md).
#
# Repository layout is one repo per machine, grouped by engagement:
#     <bucket>/<client>/<machine>/
# where <client> is the engagement code for a build box (BuildFor) and the
# tenant's own client code for a normal terminal. One machine never writes
# into another's repo, and everything for one engagement sits in one prefix.
#
# The S3 credentials come from the config parameter rather than the instance
# role on purpose: the same script must work against a customer's Wasabi (or
# any S3-compatible) bucket, where no AWS role exists.
set -uo pipefail
# shellcheck source=/dev/null  # written by the platform at boot; not in the repo
source /etc/asp-terminal.env

CONF=$(aws ssm get-parameter --name /asp/backup/config --with-decryption \
        --region "$ASP_REGION" --query Parameter.Value --output text 2>/dev/null) || CONF=""
if [ -z "$CONF" ] || [ "$CONF" = "None" ]; then
  echo "backup-arm: no /asp/backup/config in this tenant — backups not armed (by design)"
  exit 0
fi

read_conf() { echo "$CONF" | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }
BUCKET=$(read_conf BACKUP_BUCKET)
ENDPOINT=$(read_conf BACKUP_ENDPOINT)
AKID=$(read_conf BACKUP_ACCESS_KEY)
ASECRET=$(read_conf BACKUP_SECRET_KEY)
RPASS=$(read_conf RESTIC_PASSWORD)
KEEP=$(read_conf BACKUP_KEEP); KEEP=${KEEP:-"--keep-daily 7 --keep-weekly 4 --keep-monthly 6"}
if [ -z "$BUCKET" ] || [ -z "$RPASS" ]; then
  echo "backup-arm: config present but incomplete (need BACKUP_BUCKET + RESTIC_PASSWORD) — not arming" >&2
  exit 1
fi

# Identity: the portal writes both; fall back for terminals provisioned before
# it did, so re-running this on an older box still lands in the right place.
CLIENT="${ASP_BACKUP_CLIENT:-${ASP_CUSTOMER%%-*}}"
MACHINE="${ASP_MACHINE_NAME:-$(hostname -s)}"
REPO="s3:${ENDPOINT%/}/$BUCKET/$CLIENT/$MACHINE"

command -v restic >/dev/null || { apt-get update -y && apt-get install -y restic; }

umask 077
# Values are single-quoted: this file is SOURCED, and BACKUP_KEEP is a
# multi-word flag string — unquoted, bash would try to run "7" as a command.
cat > /etc/asp-backup.env <<ENVEOF
RESTIC_REPOSITORY='$REPO'
RESTIC_PASSWORD='$RPASS'
AWS_ACCESS_KEY_ID='$AKID'
AWS_SECRET_ACCESS_KEY='$ASECRET'
ASP_BACKUP_KEEP='$KEEP'
ENVEOF
chmod 600 /etc/asp-backup.env

# Excluded: regenerable or worthless. Everything a person made is kept.
cat > /etc/asp-backup.exclude <<'EXEOF'
**/.cache
**/.local/share/Trash
**/snap
**/.npm
**/.cargo/registry
**/.rustup
**/node_modules
**/.venv
**/venv
**/__pycache__
**/.config/google-chrome/*/Cache*
**/.config/google-chrome/*/Code Cache
**/.mozilla/firefox/*/cache2
EXEOF

cat > /opt/asp/backup-run.sh <<'RUNEOF'
#!/bin/bash
# Nightly backup of /home. One restic repo per machine.
set -uo pipefail
set -a; . /etc/asp-backup.env; set +a
KEEP="${ASP_BACKUP_KEEP:---keep-daily 7 --keep-weekly 4 --keep-monthly 6}"
# First run on a fresh repo: init. `cat config` is the cheap existence probe.
restic cat config >/dev/null 2>&1 || restic init || exit 1
restic backup /home --exclude-file=/etc/asp-backup.exclude --tag nightly || exit 1
# shellcheck disable=SC2086  # KEEP is a deliberate multi-flag string
restic forget $KEEP --prune || true
restic snapshots --compact | tail -3
RUNEOF
chmod +x /opt/asp/backup-run.sh

cat > /etc/systemd/system/asp-backup.service <<'UNITEOF'
[Unit]
Description=ASP terminal nightly backup (restic)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/asp/backup-run.sh
# systemd services get no HOME; without a cache restic re-reads every file
# every night instead of comparing against the parent snapshot.
Environment=HOME=/root
Environment=RESTIC_CACHE_DIR=/var/cache/restic
Nice=10
IOSchedulingClass=idle
UNITEOF

# Persistent=true is what makes this work on a hibernate-by-default fleet:
# a box that was paused overnight runs its missed backup shortly after it wakes.
cat > /etc/systemd/system/asp-backup.timer <<'TIMEREOF'
[Unit]
Description=Nightly ASP terminal backup

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

mkdir -p /var/cache/restic
systemctl daemon-reload
systemctl enable --now asp-backup.timer
echo "backup-arm: armed $REPO (nightly 03:00 + catch-up on wake)"
