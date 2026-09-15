#!/bin/bash
# cp-verify-harness.sh — exercise aws/scripts/cp-verify.sh in a throwaway container:
# real openssl + a real self-signed wildcard cert, the real cert-expiry-check.sh, and
# stubbed certbot/curl/systemctl whose behaviour each case sets. No AWS, no tenant.
#
#   bash aws/tests/cp-verify-harness.sh        # ~10 s, exit 0 = all pass
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
IMG=claude-terminal-harness:2
docker image inspect "$IMG" >/dev/null 2>&1 || docker build -q -t "$IMG" - <<'DF' >/dev/null
FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends openssl ca-certificates python3 >/dev/null && rm -rf /var/lib/apt/lists/*
DF
FAILS=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILS=$((FAILS+1)); }
# shellcheck disable=SC2015 # pass/fail always return 0
has()   { grep -qE -- "$2" "$1" && pass "has /$2/" || fail "lacks /$2/  ($(tr '\n' '|' <"$1" | cut -c1-400))"; }
# shellcheck disable=SC2015
hasnt() { grep -qE -- "$2" "$1" && fail "unexpectedly has /$2/" || pass "has no /$2/"; }

# run_case OUT then env assignments: LINEAGE=1|0 DRYRUN=ok|fail|busy|busy-then-ok TIMER=active|inactive
#   ENVQUOTED=1|shlex|0 HCURL=1|0. CP_VERIFY_LOCK_WAIT=0 keeps the certbot-busy retry from sleeping.
run_case() {
  local out=$1; shift; local envs=()
  for e in "$@"; do envs+=(-e "$e"); done
  docker run --rm -v "$REPO:/kit:ro" "${envs[@]}" "$IMG" bash -c '
set -u
mkdir -p /opt/asp /etc/letsencrypt/live/portal.zone.test /etc/letsencrypt/renewal /usr/local/bin
printf "ASP_PORTAL_HOST=portal.zone.test\nASP_GW_HOST=gw.zone.test\nASP_BUCKET=b\nASP_CUSTOMER=acme\n" >/etc/asp-terminal.env
openssl req -x509 -newkey rsa:2048 -nodes -days 80 -subj "/CN=*.zone.test" -addext "subjectAltName=DNS:*.zone.test" \
  -keyout /etc/letsencrypt/live/portal.zone.test/privkey.pem -out /etc/letsencrypt/live/portal.zone.test/cert.pem >/dev/null 2>&1
[ "$LINEAGE" = 1 ] && echo "cert_name = portal.zone.test" >/etc/letsencrypt/renewal/portal.zone.test.conf
cp /kit/aws/scripts/cert-expiry-check.sh /opt/asp/cert-expiry-check.sh; chmod +x /opt/asp/cert-expiry-check.sh
if [ "${HCURL:-1}" = 1 ]; then echo "CERT_HEALTHCHECK_URL='https://hc-ping.com/abc'" >/etc/asp-cert.env; else echo "CERT_HEALTHCHECK_URL=''" >/etc/asp-cert.env; fi
case "$ENVQUOTED" in
  1)     printf "ASP_CUSTOMER='"'"'acme'"'"'\nASP_PROFILE='"'"'standard'"'"'\n" >/etc/asp-portal.env ;;
  shlex) # what portal-deploy.sh really writes (#51): shlex.quote leaves safe values BARE
         printf "ASP_CUSTOMER='"'"'acme'"'"'\nASP_BRAND='"'"'Acme Terminals'"'"'\nBROKER_VERIFY_TLS=false\nENTRA_TENANT_ID=3e0d7d89-0000-4000-8000-000000000000\nSUBNET_IDS=subnet-06b,subnet-01e\nBROKER_URL=https://broker.zone.test:8443\nASP_GW_VANITY=\n" >/etc/asp-portal.env ;;
  *)     printf "ASP_CUSTOMER='"'"'acme'"'"'\nASP_BRAND=Acme Terminals\nSESSION_SECRET=ab\$cd\nBROKER_URL='"'"'https://x'"'"'\n" >/etc/asp-portal.env ;;
esac
cat >/usr/local/bin/certbot <<C
#!/bin/bash
echo "certbot \$*" >>/tmp/calls
n=\$(grep -c "certbot renew" /tmp/calls)
mode="$DRYRUN"; [ "\$mode" = busy-then-ok ] && { [ "\$n" -ge 2 ] && mode=ok || mode=busy; }
case "\$mode" in
  ok)   echo "Simulating renewal of an existing certificate for *.zone.test"; echo "Congratulations, all simulated renewals succeeded"; exit 0;;
  busy) echo "Another instance of Certbot is already running."; exit 1;;
  *)    echo "Certbot failed to authenticate some domains (authenticator: dns-cloudflare)"; echo "Error determining zone_id: 6003 Invalid request headers"; exit 1;;
esac
C
cat >/usr/local/bin/curl <<C
#!/bin/bash
case "\$*" in *checkip*) echo 1.2.3.4;; *8080/healthz*) printf "{\"ok\":true,\"customer\":\"acme\",\"version\":\"v2026.09.14-2\"}";; *) exit 7;; esac
C
cat >/usr/local/bin/systemctl <<C
#!/bin/bash
case "\$*" in *is-active*asp-cert-check.timer*) echo $TIMER; [ "$TIMER" = active ];; *) exit 0;; esac
C
chmod +x /usr/local/bin/*
CP_VERIFY_LOCK_WAIT=0 bash /kit/aws/scripts/cp-verify.sh; echo "exit=$?"; echo "calls: $(cat /tmp/calls 2>/dev/null | tr "\n" ";")"
' >"$out" 2>&1
}

echo "1. healthy control plane → every line PASS, exit 0"
run_case "$PWD/.h1" LINEAGE=1 DRYRUN=ok TIMER=active ENVQUOTED=1
has .h1 'PASS.*cp-tls steady state'
has .h1 'PASS.*renewal dry-run'
has .h1 'egress.*1\.2\.3\.4'
has .h1 'PASS.*OK — [0-9]+d left'
has .h1 'PASS.*asp-cert-check\.timer'
has .h1 'PASS.*portal.*v2026\.09\.14-2'
has .h1 'PASS.*asp-portal\.env'
has .h1 'PASS.*expiry alarm pings'
hasnt .h1 'FAIL'
has .h1 'exit=0'
has .h1 'calls: certbot renew --dry-run'

echo "2. no renewal lineage → cp-tls would reissue, dry-run skipped, expiry says UNMANAGED, exit 1"
run_case "$PWD/.h2" LINEAGE=0 DRYRUN=ok TIMER=active ENVQUOTED=1
has .h2 'FAIL.*cp-tls.*no certbot lineage'
has .h2 'SKIP.*renewal dry-run'
has .h2 'FAIL.*UNMANAGED'
has .h2 'exit=1'
hasnt .h2 'calls: certbot'

echo "3. dry-run fails → FAIL names the Cloudflare allowlist and shows certbot's last line"
run_case "$PWD/.h3" LINEAGE=1 DRYRUN=fail TIMER=active ENVQUOTED=1
has .h3 'FAIL.*renewal dry-run.*allowlist'
has .h3 'Error determining zone_id'
has .h3 'exit=1'

echo "4. timer inactive + bare portal env values a shell would act on (space, \$) → both FAIL, keys named, quoted one not"
run_case "$PWD/.h4" LINEAGE=1 DRYRUN=ok TIMER=inactive ENVQUOTED=0
has .h4 'FAIL.*asp-cert-check\.timer'
has .h4 'FAIL.*asp-portal\.env.*ASP_BRAND SESSION_SECRET — '
hasnt .h4 'FAIL.*asp-portal\.env.*BROKER_URL'
has .h4 'exit=1'
echo "6. the env file exactly as portal-deploy.sh writes it (shlex.quote: safe values bare) → PASS (#51)"
run_case "$PWD/.h6" LINEAGE=1 DRYRUN=ok TIMER=active ENVQUOTED=shlex
has .h6 'PASS.*asp-portal\.env'
hasnt .h6 'FAIL.*asp-portal\.env'
has .h6 'exit=0'
echo "7. certbot busy on the first try, free on the second → dry-run retried, PASS (#52)"
run_case "$PWD/.h7" LINEAGE=1 DRYRUN=busy-then-ok TIMER=active ENVQUOTED=1
has .h7 'PASS.*renewal dry-run'
has .h7 'calls: certbot renew --dry-run[^;]*;certbot renew --dry-run'
has .h7 'exit=0'
echo "8. certbot stays busy → SKIP naming certbot busy with a retry hint, never the allowlist, exit 0 (#52)"
run_case "$PWD/.h8" LINEAGE=1 DRYRUN=busy TIMER=active ENVQUOTED=1
has .h8 'SKIP.*renewal dry-run.*certbot busy'
hasnt .h8 'FAIL.*renewal dry-run'
hasnt .h8 'allowlist against'
has .h8 'exit=0'
echo "5. expiry alarm armed with an empty ping URL → FAIL that names it MUTE and the SSM parameter (#50)"
run_case "$PWD/.h5" LINEAGE=1 DRYRUN=ok TIMER=active ENVQUOTED=1 HCURL=0
has .h5 'FAIL.*expiry alarm.*MUTE.*/asp/healthchecks/api-key'
has .h5 'exit=1'
rm -f .h1 .h2 .h3 .h4 .h5 .h6 .h7 .h8
echo
# shellcheck disable=SC2015
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
