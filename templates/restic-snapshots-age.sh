#!/usr/bin/env bash
# restic-snapshots-age.sh — how old is this repo's newest snapshot? Prints ONE line:
#   FRESH — newest snapshot <n>h old (<time>)      exit 0   (younger than MAX_H, default 26)
#   STALE — newest snapshot <n>h old (<time>)      exit 1
#   NONE  — no snapshot in <repo>                  exit 2
#
# Lives on the DROPLET at /opt/<code>/backup/ next to that folder's .env (RESTIC_REPOSITORY,
# RESTIC_PASSWORD, AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY — the restic sub-user keys, never
# the root Wasabi keys). Shipped there by PLATFORM-BUILD §6; platform-verify.sh §5 calls it
# over ssh and greps FRESH. `restic snapshots` is the ground truth for "did the backup run" —
# a DOWN monitoring check is a claim about pings, not about snapshots.
#
#   sudo -n /opt/<code>/backup/restic-snapshots-age.sh [MAX_H]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f ./.env ] || { echo "NONE — no ./.env beside this script (expected the backup env)"; exit 2; }
set -a
# shellcheck disable=SC1091 # the droplet's runtime file, never in the repo
. ./.env
set +a
MAX_H="${1:-26}"
command -v restic >/dev/null 2>&1 || { echo "NONE — restic not installed"; exit 2; }
latest=$(restic snapshots --json --latest 1 2>/dev/null \
  | python3 -c 'import json,sys
try: s=json.load(sys.stdin)
except Exception: s=[]
print(s[-1]["time"] if s else "")' 2>/dev/null)
[ -n "$latest" ] || { echo "NONE — no snapshot in ${RESTIC_REPOSITORY:-?}"; exit 2; }
# restic prints RFC3339 with nanoseconds; trim the fraction before parsing.
age_h=$(python3 -c 'import sys,re,datetime as d
t=d.datetime.fromisoformat(re.sub(r"\.\d+","",sys.argv[1]).replace("Z","+00:00"))
print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()//3600))' "$latest")
if [ "$age_h" -lt "$MAX_H" ]; then
  echo "FRESH — newest snapshot ${age_h}h old ($latest)"
else
  echo "STALE — newest snapshot ${age_h}h old ($latest)"; exit 1
fi
