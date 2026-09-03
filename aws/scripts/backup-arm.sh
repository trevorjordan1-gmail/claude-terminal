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
HCKEY=$(read_conf HEALTHCHECKS_API_KEY)                  # optional: lets this script mint the check
HCAPI=$(read_conf HEALTHCHECKS_API_URL); HCAPI=${HCAPI:-https://healthchecks.io}
if [ -z "$BUCKET" ] || [ -z "$RPASS" ]; then
  echo "backup-arm: config present but incomplete (need BACKUP_BUCKET + RESTIC_PASSWORD) — not arming" >&2
  exit 1
fi

# Identity: the portal writes both; fall back for terminals provisioned before
# it did, so re-running this on an older box still lands in the right place.
# NOT the hostname — it is the private IP, and AWS recycles those, so two
# different terminals could end up sharing one repo. The instance id cannot
# collide. Set ASP_MACHINE_NAME on an older box first if you want the readable
# name in the prefix.
CLIENT="${ASP_BACKUP_CLIENT:-${ASP_CUSTOMER%%-*}}"
MACHINE="${ASP_MACHINE_NAME:-}"
if [ -z "$MACHINE" ]; then
  TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
  MACHINE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
fi
[ -n "$MACHINE" ] || { echo "backup-arm: cannot determine machine identity — not arming" >&2; exit 1; }
REPO="s3:${ENDPOINT%/}/$BUCKET/$CLIENT/$MACHINE"

# Monitoring ping. Field-found: a box migrated from the cron-era script to this timer
# kept backing up every night while its Healthchecks check showed DOWN for 12 days,
# because the cron script pinged and this one never did. A monitoring gap that LOOKS
# like a backup failure invites exactly the wrong emergency response, so the ping is
# part of the generated script and the URL is resolved here, in this order:
#   1. HEALTHCHECK_URL in the environment at arm time (SSM: `HEALTHCHECK_URL=… bash
#      /opt/asp/backup-arm.sh`), or ASP_BACKUP_HC_URL from /etc/asp-terminal.env —
#      an existing check's ping URL, e.g. one created before this script could;
#   2. HEALTHCHECKS_API_KEY in the tenant config → upsert a check named
#      backup-<client>-<machine> (unique on the name, so re-arming is idempotent);
#   3. whatever the previous /etc/asp-backup.env carried — re-arming never drops it;
#   4. none — still armed, but silence will not alert; said out loud below.
HC_URL="${HEALTHCHECK_URL:-${ASP_BACKUP_HC_URL:-}}"
if [ -z "$HC_URL" ] && [ -n "$HCKEY" ]; then
  HC_URL=$(curl -fsS -m 15 -X POST -H "X-Api-Key: $HCKEY" \
    -d "{\"name\":\"backup-$CLIENT-$MACHINE\",\"tags\":\"asp backup $CLIENT\",\"timeout\":86400,\"grace\":43200,\"unique\":[\"name\"]}" \
    "${HCAPI%/}/api/v3/checks/" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ping_url",""))' 2>/dev/null) || HC_URL=""
  [ -n "$HC_URL" ] || echo "backup-arm: Healthchecks check upsert failed — arming without a ping" >&2
fi
if [ -z "$HC_URL" ] && [ -f /etc/asp-backup.env ]; then
  # shellcheck source=/dev/null  # the file this script wrote last time
  HC_URL=$(. /etc/asp-backup.env 2>/dev/null; printf '%s' "${HEALTHCHECK_URL:-}")
fi

command -v restic >/dev/null || { apt-get update -y && apt-get install -y restic; }

umask 077
# Values are single-quoted: this file is SOURCED, and BACKUP_KEEP is a
# multi-word flag string — unquoted, bash would try to run "7" as a command.
# sq() makes an embedded ' safe inside those quotes ('\'' splice), so a
# generated password containing one cannot break the file.
sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
cat > /etc/asp-backup.env <<ENVEOF
RESTIC_REPOSITORY='$(sq "$REPO")'
RESTIC_PASSWORD='$(sq "$RPASS")'
AWS_ACCESS_KEY_ID='$(sq "$AKID")'
AWS_SECRET_ACCESS_KEY='$(sq "$ASECRET")'
ASP_BACKUP_KEEP='$(sq "$KEEP")'
HEALTHCHECK_URL='$(sq "$HC_URL")'
ENVEOF
chmod 600 /etc/asp-backup.env

# Excluded: regenerable or worthless. Everything a person made is kept.
cat > /etc/asp-backup.exclude <<'EXEOF'
**/.cache
**/.local/share/Trash
**/snap/*/common/.cache
**/snap/*/*/.cache
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
# Healthchecks ping — a no-op when HEALTHCHECK_URL is empty, so the script works
# with no monitoring account at all. /fail on every error path, bare on success:
# the check then alerts on silence (never ran) AND on failure (ran, broke).
# shellcheck disable=SC2015  # `|| true` IS the else branch: a failed ping must never fail the backup
ping_hc() { [ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}$1" >/dev/null 2>&1 || true; }
# First run on a fresh repo: init. `cat config` is the cheap existence probe.
restic cat config >/dev/null 2>&1 || restic init || { ping_hc /fail; exit 1; }
restic backup /home --exclude-file=/etc/asp-backup.exclude --tag nightly || { ping_hc /fail; exit 1; }
# shellcheck disable=SC2086  # KEEP is a deliberate multi-flag string
restic forget $KEEP --prune || true
restic snapshots --compact | tail -3
ping_hc ""
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
if [ -n "$HC_URL" ]; then
  echo "backup-arm: armed $REPO (nightly 03:00 + catch-up on wake; pings Healthchecks)"
else
  echo "backup-arm: armed $REPO (nightly 03:00 + catch-up on wake) — NO monitoring ping: set HEALTHCHECKS_API_KEY in /asp/backup/config or re-arm with HEALTHCHECK_URL=<ping url>"
fi
