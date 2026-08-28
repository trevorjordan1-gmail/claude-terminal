#!/bin/bash
# session-paint-probe.sh — detect + self-heal the flat-framebuffer stall (#20/#21).
#
# Runs as the SESSION USER, backgrounded from /etc/dcv/dcvsessioninit, so it
# inherits the session's DISPLAY/XAUTHORITY. A healthy desktop paints many
# distinct colours; a shell whose frame clock never started streams exactly
# the one (or two) it was born with — no log ever says so, only the pixels.
# Recovery is cheap and in-place: TERM the user's gnome-shell —
# org.gnome.Shell@x11.service is Restart=always, systemd relaunches it and
# X11 apps survive. Defense in depth: stays useful even after #20's
# session-init pre-mode fix, catching any future mutter/Xdcv regression.
#
#   session-paint-probe.sh          wait for the shell, probe, heal, report
#   session-paint-probe.sh --count  print the framebuffer's distinct-colour
#                                   count (capped: 3 means "3 or more") and
#                                   exit — the #20 repro harness's measuring
#                                   tool. Needs DISPLAY (+ XAUTHORITY).
set -u

TAG="asp-paint-probe"

count_colours() {
  # XWD header: 25 big-endian u32 — header_size[0], pixmap_height[5],
  # bits_per_pixel[11], bytes_per_line[12], ncolors[19]; then ncolors 12-byte
  # colormap entries, then 4-byte BGRX pixels. No ImageMagick on the desktops.
  xwd -root -silent 2>/dev/null | python3 -c '
import sys, struct
d = sys.stdin.buffer.read()
if len(d) < 100:
    print(0); sys.exit()          # capture failed/truncated: not a stall verdict
h = struct.unpack(">25I", d[:100])
if h[11] != 32:
    print(3); sys.exit()          # unexpected format: report healthy, never false-kill
off = h[0] + h[19] * 12
px = d[off:off + h[12] * h[5]]
seen = set()
for i in range(0, len(px) - 3, 4):
    seen.add(px[i:i + 4])
    if len(seen) > 2:
        print(3); sys.exit()
print(len(seen))'
}

if [ "${1:-}" = "--count" ]; then count_colours; exit 0; fi

report() {  # $1 result, $2 colours — journal always, S3 marker best-effort
  logger -t "$TAG" "result=$1 colours=$2 display=${DISPLAY:-?} user=$(id -un)"
  # shellcheck source=/dev/null  # written by the platform at boot; not in the repo
  [ -f /etc/asp-terminal.env ] && . /etc/asp-terminal.env
  { [ -n "${ASP_BUCKET:-}" ] && command -v aws >/dev/null 2>&1; } || return 0
  local tok iid
  tok=$(curl -s --connect-timeout 2 -X PUT http://169.254.169.254/latest/api/token \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
  iid=$(curl -s --connect-timeout 2 -H "X-aws-ec2-metadata-token: $tok" \
        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
  [ -n "$iid" ] || return 0
  printf '{"iid":"%s","result":"%s","colours":%s,"ts":%s}\n' \
    "$iid" "$1" "$2" "$(date +%s)" \
    | aws s3 cp - "s3://$ASP_BUCKET/status/paint/$iid-$(date +%s).json" --quiet 2>/dev/null || true
}

# wait for the shell, then give its first frames time to land
for _ in $(seq 1 30); do
  pgrep -u "$(id -u)" -x gnome-shell >/dev/null 2>&1 && break
  sleep 1
done
pgrep -u "$(id -u)" -x gnome-shell >/dev/null 2>&1 || { report no-shell 0; exit 0; }
sleep 10

# probe → heal → re-probe. Max 2 restarts: org.gnome.Shell@x11's rate limit is
# StartLimitBurst=3 per 15 s — the 10 s settle between attempts stays under it.
C=0
for attempt in 1 2 3; do
  C=$(count_colours)
  case "${C:-0}" in
    0) report probe-failed 0; exit 0 ;;       # no capture — not a stall verdict
    3) if [ "$attempt" -gt 1 ]; then report recovered 3; else report ok 3; fi
       exit 0 ;;
  esac
  if [ "$attempt" -lt 3 ]; then
    logger -t "$TAG" "flat framebuffer ($C colours) — restarting gnome-shell in place (attempt $attempt)"
    pkill -TERM -u "$(id -u)" -x gnome-shell
    sleep 10
  fi
done
report stalled-unrecovered "${C:-0}"
logger -t "$TAG" "GIVING UP: framebuffer still flat after 2 gnome-shell restarts — session needs an operator (runbook §10, flat-frame gotcha)"
exit 1
