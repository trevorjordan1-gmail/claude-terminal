#!/bin/bash
# cp-tls-harness.sh — aws/scripts/cp-tls.sh in a throwaway container with stubbed
# apt-get/aws/certbot/curl/systemctl (real openssl). Cases: steady state makes no certbot
# call and reads the Healthchecks key from SSM (#50, the key never reaches the xtrace);
# no key anywhere → the alarm says MUTE loudly; fresh tenant → one wildcard-only order.
#
#   bash aws/tests/cp-tls-harness.sh        # ~10 s, exit 0 = all pass
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
has()   { grep -qE -- "$2" "$1" && pass "has /$2/" || fail "lacks /$2/  ($(grep -vE '^\+' "$1" | tr '\n' '|' | cut -c1-400))"; }
# shellcheck disable=SC2015
hasnt() { grep -qE -- "$2" "$1" && fail "unexpectedly has /$2/" || pass "has no /$2/"; }
# run_case OUT LINEAGE=1|0 HCKEY=<key>|"" 
run_case() {
  local out=$1; shift; local envs=()
  for e in "$@"; do envs+=(-e "$e"); done
  docker run --rm -v "$REPO:/kit:ro" "${envs[@]}" "$IMG" bash -c '
set -u
mkdir -p /opt/asp /etc/letsencrypt/renewal /usr/local/bin /root/.secrets
printf "ASP_PORTAL_HOST=portal.zone.test\nASP_GW_HOST=gw.zone.test\nASP_BUCKET=b\nASP_REGION=us-east-2\nASP_CERT_EMAIL=ops@example.test\nASP_CUSTOMER=acme\n" >/etc/asp-terminal.env
mkcert() { mkdir -p /etc/letsencrypt/live/portal.zone.test; openssl req -x509 -newkey rsa:2048 -nodes -days 80 -subj "/CN=*.zone.test" -addext "subjectAltName=DNS:*.zone.test" -keyout /etc/letsencrypt/live/portal.zone.test/privkey.pem -out /etc/letsencrypt/live/portal.zone.test/cert.pem >/dev/null 2>&1; cp /etc/letsencrypt/live/portal.zone.test/cert.pem /etc/letsencrypt/live/portal.zone.test/fullchain.pem; }
if [ "$LINEAGE" = 1 ]; then mkcert; echo "cert_name = portal.zone.test" >/etc/letsencrypt/renewal/portal.zone.test.conf; fi
printf "#!/bin/sh\nexit 0\n" >/usr/local/bin/apt-get
printf "#!/bin/sh\necho \"systemctl \$*\" >>/tmp/calls; exit 0\n" >/usr/local/bin/systemctl
cat >/usr/local/bin/aws <<A
#!/bin/bash
echo "aws \$*" >>/tmp/calls
case "\$*" in
  *"/asp/cloudflare/token"*) echo cf-token-value;;
  *"/asp/healthchecks/api-key"*) [ -n "$HCKEY" ] && echo "$HCKEY" || { echo "ParameterNotFound" >&2; exit 254; };;
  *"s3 cp"*cert-expiry-check.sh*) cp /kit/aws/scripts/cert-expiry-check.sh "\${@: -1}";;
  *) exit 0;;
esac
A
cat >/usr/local/bin/certbot <<C
#!/bin/bash
echo "certbot \$*" >>/tmp/calls
mkdir -p /etc/letsencrypt/live/portal.zone.test
openssl req -x509 -newkey rsa:2048 -nodes -days 80 -subj "/CN=*.zone.test" -addext "subjectAltName=DNS:*.zone.test" -keyout /etc/letsencrypt/live/portal.zone.test/privkey.pem -out /etc/letsencrypt/live/portal.zone.test/cert.pem >/dev/null 2>&1
cp /etc/letsencrypt/live/portal.zone.test/cert.pem /etc/letsencrypt/live/portal.zone.test/fullchain.pem
echo "cert_name = portal.zone.test" >/etc/letsencrypt/renewal/portal.zone.test.conf
C
cat >/usr/local/bin/curl <<C
#!/bin/bash
echo "curl \$*" >>/tmp/calls
case "\$*" in *healthchecks.io/api/v3/checks*) printf "{\"ping_url\":\"https://hc-ping.com/abc\"}";; *) exit 0;; esac
C
chmod +x /usr/local/bin/*
bash /kit/aws/scripts/cp-tls.sh 2>&1; echo "exit=$?"
echo "--- asp-cert.env: $(cat /etc/asp-cert.env 2>/dev/null)"
echo "--- calls:"; cat /tmp/calls 2>/dev/null
' >"$out" 2>&1
}

echo "1. steady state + key in SSM: no certbot call, alarm pings, key never in the xtrace"
run_case "$PWD/.t1" LINEAGE=1 HCKEY=hc-secret-key-123
hasnt .t1 '^certbot '
has .t1 'curl .*X-Api-Key.*healthchecks.io/api/v3/checks'
has .t1 "asp-cert.env: CERT_HEALTHCHECK_URL='https://hc-ping.com/abc'"
has .t1 'expiry alarm armed \(daily; pings Healthchecks\)'
has .t1 'exit=0'
hasnt .t1 '^\+.*hc-secret-key-123'

echo "2. no key anywhere: the alarm says MUTE as a checklist line on stdout, still exit 0 (cp-setup semantics)"
run_case "$PWD/.t2" LINEAGE=1 HCKEY=
has .t2 'cp-tls: CHECKLIST NOT DONE.*MUTE.*/asp/healthchecks/api-key'
has .t2 "asp-cert.env: CERT_HEALTHCHECK_URL=''"
has .t2 'exit=0'
hasnt .t2 '^certbot '

echo "3. fresh tenant: one wildcard-only certbot order, pinned lineage, no --expand"
run_case "$PWD/.t3" LINEAGE=0 HCKEY=hc-secret-key-123
has .t3 'certbot certonly --dns-cloudflare .* -d \*\.zone\.test --cert-name portal\.zone\.test --non-interactive'
hasnt .t3 'certbot .*--expand'
has .t3 'TLS ready'
rm -f .t1 .t2 .t3
echo
# shellcheck disable=SC2015
[ "$FAILS" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
