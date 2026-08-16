#!/usr/bin/env bash
# shellcheck disable=SC2016  # OData query params ($select/$filter/$orderby) are Graph
# API literals — the single quotes are what keeps the shell from eating the $.
# aiops-mail.sh — the terminal's email channel: send and read mail AS the client's
# aiops@<clientdomain> mailbox, via Microsoft Graph on the ONE <code>-sso registration
# (delegated Mail.Read/ReadWrite/Send, consented for the aiops principal ONLY; device-code
# sign-in — no client secret on the mail path). Users mail the terminal; the terminal
# mails them back. Installed to the workspace scripts/ by SETUP; runs anywhere.
#
#   aiops-mail.sh login                      # one-time per terminal: device code, sign in AS aiops
#   aiops-mail.sh whoami                     # prove which mailbox we act as
#   aiops-mail.sh send --to a@b.com --subject "S" --body "text"
#                 [--to x --cc y ...] [--body-file f] [--html] [--attach file ...]
#   aiops-mail.sh list [--unread] [--top N]  # inbox summary, newest first (numbered)
#   aiops-mail.sh read <n|id> [--save-attachments DIR]
#   aiops-mail.sh mark-read <n|id>
#   aiops-mail.sh verify                     # self-send round-trip probe (cleans up after itself)
#   aiops-mail.sh logout                     # drop this terminal's cached token
#
# Config from the environment or the workspace .env (ENTRA_TENANT_ID, ENTRA_CLIENT_ID,
# AIOPS_UPN). Token cache: ~/.config/adnet/aiops-mail.json (0600) — per-terminal, renews
# itself with use; if it lapses (long idle, CA change), `login` again — no admin needed.
set -uo pipefail
# shellcheck disable=SC2016 # OData literals ($select, $filter…) are meant to stay unexpanded

GRAPH="https://graph.microsoft.com/v1.0"
CACHE_DIR="$HOME/.config/adnet"
CACHE="$CACHE_DIR/aiops-mail.json"
LAST_LIST="$CACHE_DIR/aiops-mail-last-list.json"
MAX_ATTACH=$((3 * 1024 * 1024))   # sendMail JSON cap is ~4MB total; keep each file under 3MB
TMP="$(mktemp "${TMPDIR:-/tmp}/aiops-mail.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

die() { echo "aiops-mail: $*" >&2; exit 1; }
py()  { python3 - "$@"; }   # script on stdin (heredoc), data files/values via argv

# ── config: env first, then the workspace .env (script lives in <workspace>/scripts/) ──
load_env() {
  if [ -z "${ENTRA_TENANT_ID:-}" ] || [ -z "${ENTRA_CLIENT_ID:-}" ]; then
    local here f; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for f in "./.env" "$here/../.env"; do
      # shellcheck disable=SC1090 # the credential pack — runtime file
      [ -f "$f" ] && { set -a; . "$f"; set +a; break; }
    done
  fi
  [ -n "${ENTRA_TENANT_ID:-}" ] || die "ENTRA_TENANT_ID not set (pack missing, or the Entra step hasn't landed yet)"
  [ -n "${ENTRA_CLIENT_ID:-}" ] || die "ENTRA_CLIENT_ID not set"
}

SCOPE="openid profile offline_access https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send"

cache_get() { # field → value (empty if absent)
  [ -f "$CACHE" ] || return 1
  py "$CACHE" "$1" <<'PYEOF'
import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception: print("")
PYEOF
}

cache_put() { # token-endpoint JSON on stdin → merged into the cache, expiry stamped
  cat > "$TMP"
  mkdir -p "$CACHE_DIR"; touch "$CACHE"; chmod 600 "$CACHE"
  py "$TMP" "$CACHE" <<'PYEOF'
import json,sys,time
new=json.load(open(sys.argv[1]))
if "error" in new: sys.exit(f'token endpoint: {new.get("error")}: {new.get("error_description","")[:200]}')
try: cur=json.load(open(sys.argv[2]))
except Exception: cur={}
cur["access_token"]=new["access_token"]
if new.get("refresh_token"): cur["refresh_token"]=new["refresh_token"]
cur["expires_at"]=int(time.time())+int(new.get("expires_in",3599))
json.dump(cur,open(sys.argv[2],"w"))
PYEOF
}

token() { # prints a live access token, refreshing if needed
  [ -f "$CACHE" ] || die "not logged in — run: aiops-mail.sh login"
  local exp now rt
  exp="$(cache_get expires_at)"; now="$(date +%s)"
  if [ -z "$exp" ] || [ "$now" -ge "$((exp - 60))" ]; then
    rt="$(cache_get refresh_token)"
    [ -n "$rt" ] || die "token cache has no refresh token — run: aiops-mail.sh login"
    curl -s -X POST "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" \
      -d "client_id=$ENTRA_CLIENT_ID" -d "grant_type=refresh_token" \
      --data-urlencode "refresh_token=$rt" --data-urlencode "scope=$SCOPE" | cache_put \
      || die "refresh failed — run: aiops-mail.sh login"
  fi
  cache_get access_token
}

gcurl() { # method path [curl extra args…] — auth'd Graph call (use -G + --data-urlencode for querystrings with spaces)
  local m="$1" p="$2" tk; shift 2
  tk="$(token)"; [ -n "$tk" ] || exit 1   # token() already said why on stderr
  curl -s -X "$m" -H "Authorization: Bearer $tk" -H "Content-Type: application/json" "$@" "$GRAPH$p"
}

graph_ok() { # $TMP holds a Graph reply — stop with its error if it is one
  py "$TMP" <<'PYEOF' || exit 1
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit("Graph: non-JSON reply (network? token?)")
if isinstance(d,dict) and "error" in d:
    sys.exit(f'Graph: {d["error"].get("code")}: {d["error"].get("message","")[:200]}')
PYEOF
}

resolve_id() { # <n|full-id> → full Graph message id (n = index from the last `list`)
  case "$1" in
    (*[!0-9]*) printf '%s' "$1" ;;
    (*) [ -f "$LAST_LIST" ] || die "no cached list — run: aiops-mail.sh list"
        py "$LAST_LIST" "$1" <<'PYEOF'
import json,sys
rows=json.load(open(sys.argv[1])); n=int(sys.argv[2])
if not 1<=n<=len(rows): sys.exit(f"index {n} out of range (last list had {len(rows)})")
print(rows[n-1]["id"])
PYEOF
  esac
}

urlq() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

# ── commands ────────────────────────────────────────────────────────────────
cmd_login() {
  mkdir -p "$CACHE_DIR"
  curl -s -X POST "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/devicecode" \
    -d "client_id=$ENTRA_CLIENT_ID" --data-urlencode "scope=$SCOPE" > "$TMP"
  local code uri device_code interval
  read -r code uri device_code interval < <(py "$TMP" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
if "error" in d: sys.exit(f'devicecode: {d["error"]}: {d.get("error_description","")[:200]}')
print(d["user_code"], d["verification_uri"], d["device_code"], d.get("interval",5))
PYEOF
) || exit 1
  echo ""
  echo "  1. Open   $uri"
  echo "  2. Code   $code"
  echo "  3. Sign in AS ${AIOPS_UPN:-the aiops service account} (creds + TOTP from Hudu — never a personal account)"
  echo ""
  local waited=0 err
  while :; do
    sleep "$interval"; waited=$((waited + interval))
    curl -s -X POST "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" \
      -d "client_id=$ENTRA_CLIENT_ID" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      -d "device_code=$device_code" > "$TMP"
    err="$(py "$TMP" <<'PYEOF'
import json,sys
print(json.load(open(sys.argv[1])).get("error",""))
PYEOF
)"
    case "$err" in
      "") cache_put < "$TMP" || exit 1; break ;;
      authorization_pending) [ "$waited" -ge 900 ] && die "sign-in not completed in 15 min — run login again" ;;
      *) die "$(py "$TMP" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("error","?")+": "+d.get("error_description","")[:200])
PYEOF
)" ;;
    esac
  done
  # identity guard: the mail channel must be aiops, never whoever happened to sign in
  local upn
  gcurl GET '/me?$select=userPrincipalName' > "$TMP"
  upn="$(py "$TMP" <<'PYEOF'
import json,sys
print(json.load(open(sys.argv[1])).get("userPrincipalName",""))
PYEOF
)"
  [ -n "$upn" ] || { rm -f "$CACHE"; die "sign-in landed but /me failed — token dropped, try again"; }
  if [ -n "${AIOPS_UPN:-}" ] && [ "$(echo "$upn" | tr '[:upper:]' '[:lower:]')" != "$(echo "$AIOPS_UPN" | tr '[:upper:]' '[:lower:]')" ]; then
    rm -f "$CACHE"
    die "signed in as $upn, expected $AIOPS_UPN — token DROPPED (the mail channel acts only as aiops)"
  fi
  py "$CACHE" "$upn" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1])); d["upn"]=sys.argv[2]; json.dump(d,open(sys.argv[1],"w"))
PYEOF
  echo "- **PASS** — logged in as \`$upn\` (token cached 0600, renews with use)"
}

cmd_whoami() {
  gcurl GET '/me?$select=userPrincipalName,displayName' > "$TMP"; graph_ok
  py "$TMP" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
print(f'{d.get("displayName","?")} <{d.get("userPrincipalName","?")}>')
PYEOF
}

cmd_send() {
  local subject="" body="" body_file="" ctype="Text" quiet="${AIOPS_MAIL_QUIET:-}"; local -a to=() cc=() attach=()
  while [ $# -gt 0 ]; do case "$1" in
    --to) to+=("$2"); shift 2 ;;
    --cc) cc+=("$2"); shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --html) ctype="HTML"; shift ;;
    --attach) attach+=("$2"); shift 2 ;;
    *) die "send: unknown arg $1" ;;
  esac; done
  [ ${#to[@]} -gt 0 ] || die "send: at least one --to"
  [ -n "$subject" ] || die "send: --subject required"
  if [ -n "$body_file" ]; then [ -f "$body_file" ] || die "no such file: $body_file"; body="$(cat "$body_file")"; fi
  [ -n "$body" ] || die "send: --body or --body-file required"
  local f
  for f in ${attach[@]+"${attach[@]}"}; do
    [ -f "$f" ] || die "no such attachment: $f"
    [ "$(wc -c < "$f")" -le "$MAX_ATTACH" ] || die "attachment $f exceeds 3MB — share a link instead (sendMail JSON cap)"
  done
  SUBJECT="$subject" BODY="$body" CTYPE="$ctype" TO="$(IFS=,; echo "${to[*]}")" \
    CC="$(IFS=,; echo "${cc[*]-}")" py ${attach[@]+"${attach[@]}"} > "$TMP" <<'PYEOF'
import json,sys,os,base64
rcpt=lambda s:[{"emailAddress":{"address":a.strip()}} for a in s.split(",") if a.strip()]
msg={"subject":os.environ["SUBJECT"],
     "body":{"contentType":os.environ["CTYPE"],"content":os.environ["BODY"]},
     "toRecipients":rcpt(os.environ["TO"])}
if os.environ.get("CC"): msg["ccRecipients"]=rcpt(os.environ["CC"])
atts=[{"@odata.type":"#microsoft.graph.fileAttachment","name":os.path.basename(f),
       "contentBytes":base64.b64encode(open(f,"rb").read()).decode()} for f in sys.argv[1:]]
if atts: msg["attachments"]=atts
print(json.dumps({"message":msg,"saveToSentItems":True}))
PYEOF
  local http body_out; body_out="$TMP.resp"
  http="$(curl -s -o "$body_out" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
    --data-binary "@$TMP" "$GRAPH/me/sendMail")"
  if [ "$http" = 202 ]; then
    [ -n "$quiet" ] || echo "sent: \"$subject\" → ${to[*]}${cc[0]+ (cc: ${cc[*]})}${attach[0]+ [+${#attach[@]} attachment(s)]}"
    rm -f "$body_out"
  else
    echo "send FAILED (HTTP $http):" >&2; cat "$body_out" >&2; rm -f "$body_out"; exit 1
  fi
}

cmd_list() {
  local top=15; local -a extra=()
  while [ $# -gt 0 ]; do case "$1" in
    --top) top="$2"; shift 2 ;;
    --unread) extra+=(--data-urlencode '$filter=isRead eq false'); shift ;;
    *) die "list: unknown arg $1" ;;
  esac; done
  gcurl GET "/me/mailFolders/inbox/messages" -G \
    --data-urlencode "\$top=$top" \
    --data-urlencode '$orderby=receivedDateTime desc' \
    --data-urlencode '$select=id,subject,from,receivedDateTime,isRead,hasAttachments' \
    ${extra[@]+"${extra[@]}"} > "$TMP"
  graph_ok
  py "$TMP" "$LAST_LIST" <<'PYEOF'
import json,sys
rows=json.load(open(sys.argv[1])).get("value",[])
json.dump([{"id":m["id"]} for m in rows],open(sys.argv[2],"w"))
if not rows: print("(inbox empty for this query)")
for i,m in enumerate(rows,1):
    flag=" " if m.get("isRead") else "●"
    att="+" if m.get("hasAttachments") else " "
    frm=(m.get("from") or {}).get("emailAddress",{}).get("address","?")
    print(f'{i:>3}. {flag}{att} {m.get("receivedDateTime","")[:16]}  {frm:<32}  {(m.get("subject") or "(no subject)")[:70]}')
PYEOF
}

cmd_read() {
  local target="" save_dir=""
  while [ $# -gt 0 ]; do case "$1" in
    --save-attachments) save_dir="$2"; shift 2 ;;
    *) target="$1"; shift ;;
  esac; done
  [ -n "$target" ] || die "read: message number or id required"
  local id; id="$(resolve_id "$target")" || exit 1
  gcurl GET "/me/messages/$(urlq "$id")" -G \
    --data-urlencode '$select=subject,from,toRecipients,ccRecipients,receivedDateTime,body,hasAttachments' \
    -H 'Prefer: outlook.body-content-type="text"' > "$TMP"
  graph_ok
  py "$TMP" <<'PYEOF'
import json,sys
d=json.load(open(sys.argv[1]))
addr=lambda r:(r or {}).get("emailAddress",{}).get("address","?")
print(f'From:    {addr(d.get("from"))}')
print(f'To:      {", ".join(addr(x) for x in d.get("toRecipients",[]))}')
cc=d.get("ccRecipients",[])
if cc: print(f'Cc:      {", ".join(addr(x) for x in cc)}')
print(f'Date:    {d.get("receivedDateTime","")}')
print(f'Subject: {d.get("subject","")}')
if d.get("hasAttachments"): print("(has attachments — aiops-mail.sh read <n> --save-attachments DIR)")
print("---")
print(d.get("body",{}).get("content","").strip())
PYEOF
  if [ -n "$save_dir" ]; then
    mkdir -p "$save_dir"
    gcurl GET "/me/messages/$(urlq "$id")/attachments" > "$TMP"
    graph_ok
    py "$TMP" "$save_dir" <<'PYEOF'
import json,sys,os,base64
for a in json.load(open(sys.argv[1])).get("value",[]):
    if a.get("@odata.type")=="#microsoft.graph.fileAttachment":
        p=os.path.join(sys.argv[2],os.path.basename(a["name"]))
        open(p,"wb").write(base64.b64decode(a["contentBytes"]))
        print(f'saved: {p} ({a.get("size","?")} bytes)')
    else:
        print(f'skipped (not a file attachment): {a.get("name","?")} [{a.get("@odata.type","")}]')
PYEOF
  fi
}

cmd_mark_read() {
  [ $# -ge 1 ] || die "mark-read: message number or id required"
  local id; id="$(resolve_id "$1")" || exit 1
  gcurl PATCH "/me/messages/$(urlq "$id")" -d '{"isRead":true}' > "$TMP"
  graph_ok && echo "marked read."
}

cmd_verify() {
  local upn stamp subj found=""
  upn="$(cache_get upn || true)"
  if [ -z "$upn" ]; then upn="$(cmd_whoami | sed 's/.*<\(.*\)>/\1/')" || die "verify: cannot resolve own UPN"; fi
  stamp="$$-$(date +%s)"; subj="aiops-mail self-probe $stamp"
  if AIOPS_MAIL_QUIET=1 cmd_send --to "$upn" --subject "$subj" \
       --body "Round-trip probe from this terminal. Deleted by the probe itself."; then
    echo "- **PASS** — sendMail accepted (202) as \`$upn\`"
  else
    echo "- **FAIL** — sendMail refused"; exit 1
  fi
  for _ in $(seq 1 18); do
    sleep 5
    gcurl GET "/me/messages" -G \
      --data-urlencode "\$filter=subject eq '$subj'" --data-urlencode '$select=id' > "$TMP"
    found="$(py "$TMP" <<'PYEOF'
import json,sys
v=json.load(open(sys.argv[1])).get("value",[])
print(v[0]["id"] if v else "")
PYEOF
)"
    [ -n "$found" ] && break
  done
  if [ -n "$found" ]; then
    echo "- **PASS** — probe mail arrived in the aiops mailbox (round trip proven)"
    local dhttp
    dhttp="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer $(token)" "$GRAPH/me/messages/$(urlq "$found")")"
    if [ "$dhttp" = 204 ]; then
      echo "- **PASS** — probe mail deleted (cleanup confirmed, 204)"
    else
      echo "- **FAIL** — probe cleanup HTTP $dhttp (\"$subj\" may remain — delete by hand)"
    fi
  else
    echo "- **FAIL** — probe mail not seen within 90s (send accepted — check the mailbox / try again)"
    exit 1
  fi
}

cmd_logout() { rm -f "$CACHE" "$LAST_LIST"; echo "token cache dropped — this terminal's mail channel is closed until the next login."; }

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }

CMD="${1:-help}"; shift || true
case "$CMD" in
  login)     load_env; cmd_login "$@" ;;
  whoami)    load_env; cmd_whoami "$@" ;;
  send)      load_env; cmd_send "$@" ;;
  list)      load_env; cmd_list "$@" ;;
  read)      load_env; cmd_read "$@" ;;
  mark-read) load_env; cmd_mark_read "$@" ;;
  verify)    load_env; cmd_verify "$@" ;;
  logout)    cmd_logout ;;
  help|--help|-h) usage ;;
  *) die "unknown command '$CMD' (try: aiops-mail.sh help)" ;;
esac
