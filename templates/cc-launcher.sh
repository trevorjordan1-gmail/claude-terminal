#!/usr/bin/env bash
# cc — Claude Code Terminal launcher (replaces the plain `cc` alias).
# A small purpose-built TUI over ~/Projects so every session starts in the
# right context with the right CLAUDE.md loaded — and so returning to earlier
# work never requires knowing cd or claude's flags. Designed to lift
# non-technical users to a power user's session workflow:
#
#   <code>.tools   client apps & platform (one per client code, e.g. acme.tools)
#   <project>      any folder under ~/Projects (major work; create via the menu)
#   os-changes     THIS machine: settings, troubleshooting, local system work
#   misc           small research & everything else (one subfolder per topic)
#
# Session recall & hygiene:
#   - "↩ Pick up where you left off" — recent sessions across every workspace
#     (last CC_RECALL_DAYS days, default 5) as cards: gist, exchanges,
#     duration, context fill. Picking one resumes that exact session.
#   - context ≥ CC_CTX_FULL (85) shows RED as FULL: the launcher steers to
#     "⚑ Wrap up & hand off" — it resumes the session with a pre-typed prompt
#     that has Claude write HANDOFF.md, and the next visit to that folder
#     offers "⇥ New session from hand-off" which reads it. The hygiene loop
#     closes itself.
#   - folders whose newest session is FULL carry a red "⚠ full session" flag
#     on the main menu.
#   - a one-time 3-screen tour (workspaces → sessions → context) runs on a
#     user's first `cc`; `?` shows contextual help on any screen.
#
# UI: arrow keys + Enter (numbers jump), Esc or "← Back" walks back one
# screen, ? for help, q quits — on a real terminal; falls back to a plain
# numbered prompt when stdin/stdout is not a TTY, so scripts and tests drive
# it the same way as ever. Redraws repaint in place (no clear = no flicker).
#
# Direct shortcut: `cc <folder>` skips the menu (e.g. `cc acme.tools`).
# Extra args pass through to claude: `cc acme.tools --resume`.
#
# Ships in claude-terminal templates/; the SETUP run installs it as
# ~/.local/bin/cc-launcher and points the cc/phonecc aliases at it.
#
# <code>.tools is the one workspace this launcher discovers but does not
# create: it is stood up by the SETUP flow (templates/SETUP.md), which stamps
# CLAUDE.md/STATE.md, moves the credential pack home and creates the repo. A
# bare mkdir would produce a workspace that LOOKS provisioned and carries none
# of that — worse than its absence (#9). So on a terminal that knows its
# engagement code (ASP_BACKUP_CLIENT in /etc/asp-terminal.env — build boxes
# and customer deployments) and has no <code>.tools yet, the menu leads with
# "+ set up <code>.tools", which runs that real SETUP flow with nothing to
# ask: the code is known, the pack path is known. Terminals without a code
# just get told what creates one.
set -uo pipefail

PROJECTS="$HOME/Projects"
PACK="$PROJECTS/.env"            # the staged credential pack SETUP.md consumes
KIT="$HOME/claude-terminal"
CLAUDE_ARGS=(--dangerously-skip-permissions)
mkdir -p "$PROJECTS"

# engagement code, if this terminal carries one (platform-written; never asked)
asp_env() {
  sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1=//p" /etc/asp-terminal.env 2>/dev/null \
    | head -1 | tr -d '\r' | sed -E "s/^[[:space:]]*[\"']?//; s/[\"']?[[:space:]]*\$//"
}
CODE=$(asp_env ASP_BACKUP_CLIENT)
# the pack knows the exact workspace name (CLIENT_DOMAIN); fall back to <code>.tools
pack_val() { sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1=//p" "$PACK" 2>/dev/null | head -1 | tr -d "\"'"; }
TOOLS_NAME=""
if [ -n "$CODE" ]; then
  TOOLS_NAME=$(pack_val CLIENT_DOMAIN); TOOLS_NAME=${TOOLS_NAME:-$CODE.tools}
fi

# the two prompts that close the hygiene loop
WRAPUP_PROMPT='This session'\''s context is nearly full, so let'\''s wrap up. Write a hand-off into HANDOFF.md in this folder (create or overwrite it): what we are working on, what is done, what is in progress, the exact next steps, and the key files, decisions and gotchas a fresh session needs. If CLAUDE.md'\''s "What this is" is stale, update it too. Be complete but concise. When finished, tell me to close this session and start a new one from the launcher — it will offer "New session from hand-off".'
HANDOFF_PROMPT='Read HANDOFF.md in this folder and continue the work from where the previous session left off. Summarize the plan in one short paragraph and then get going.'

# ── UI toolkit ──────────────────────────────────────────────────────────────
# Fancy mode only on a real terminal; otherwise the plain numbered prompt
# (pipes, scripts and tests keep driving this exactly as before).
FANCY=0
if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then FANCY=1; fi
C0=$'\e[0m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; ACC=$'\e[36m'; WARN=$'\e[33m'; RED=$'\e[31m'; INV=$'\e[7m'
[ "$FANCY" = 1 ] || { C0=""; DIM=""; BOLD=""; ACC=""; WARN=""; RED=""; INV=""; }
COLS=$(tput cols 2>/dev/null || echo 100)

UI_OPEN=0
ui_open()  { [ "$FANCY" = 1 ] && [ "$UI_OPEN" = 0 ] && { printf '\e[?1049h\e[?25l'; UI_OPEN=1; }; }
ui_close() { [ "$UI_OPEN" = 1 ] && { printf '\e[?25h\e[?1049l'; UI_OPEN=0; }; }
trap 'ui_close' INT TERM EXIT   # exec replaces the process, so exec paths call ui_close themselves

# every header/menu line ends in \e[K (erase to end-of-line): redraws repaint
# over the previous frame instead of clearing the screen — no flicker
ui_header() { # $1 = subtitle
  local host; host=$(hostname -s 2>/dev/null || echo terminal)
  printf '\e[K\n  %s%sCLAUDE CODE TERMINAL%s  %s%s%s\e[K\n' "$BOLD" "$ACC" "$C0" "$DIM" "$host${1:+ · $1}" "$C0"
  printf '  %s%s%s\e[K\n\e[K\n' "$DIM" "$(printf '─%.0s' $(seq 1 $((COLS > 78 ? 74 : COLS - 4))))" "$C0"
}

ui_text_page() { # $1 = subtitle, $2 = body (multi-line), $3 = footer
  printf '\e[H\e[J'; ui_header "$1"
  while IFS= read -r l; do printf '  %s\e[K\n' "$l"; done <<< "$2"
  printf '\n  %s%s%s\e[K\n' "$DIM" "$3" "$C0"
}

# pick MENU_NAME[] MENU_DESC[] (+ optional MENU_META[] newline-joined card
# lines under a row, MENU_WARN[] nonempty = critical row) -> sets PICKED.
# Returns 1 on quit (q / EOF), 2 on back (bare Esc). Fancy: arrows/jk move,
# Enter opens, 1-9 jump, ? help. Plain: numbered read (invalid input = quit).
PICK_HINT=""; PICK_HELP=""
pick() { # $1 = subtitle for the header, $2 = prompt for plain mode
  local n=${#MENU_NAME[@]} cur=0 i key rest name desc num meta ml warn dmax mcol
  if [ "$FANCY" != 1 ]; then
    echo "${2:-Where are you working?}"
    for i in "${!MENU_NAME[@]}"; do
      printf "  %d) %-22s %s\n" "$((i+1))" "${MENU_NAME[$i]}" "${MENU_DESC[$i]}"
      meta="${MENU_META[$i]:-}"
      [ -n "$meta" ] && while IFS= read -r ml; do printf "      %s\n" "$ml"; done <<< "$meta"
    done
    read -rp "> " key
    if ! [[ "$key" =~ ^[0-9]+$ ]] || [ "$key" -lt 1 ] || [ "$key" -gt "$n" ]; then
      echo "Invalid choice."; return 1
    fi
    PICKED=$((key-1)); return 0
  fi
  ui_open
  while :; do
    printf '\e[H'
    ui_header "${1:-}"
    for i in "${!MENU_NAME[@]}"; do
      name="${MENU_NAME[$i]}"; desc="${MENU_DESC[$i]}"; num=$((i+1))
      meta="${MENU_META[$i]:-}"; warn="${MENU_WARN[$i]:-}"
      # truncate the text BEFORE styling — cutting a styled string can lose
      # the reset code and bleed dim/inverse into the rest of the screen
      dmax=$((COLS - 36)); [ "$dmax" -lt 10 ] && dmax=10
      [ "${#desc}" -gt "$dmax" ] && desc="${desc:0:$((dmax-1))}…"
      if [ "$i" -eq "$cur" ]; then
        printf '  %s▸ %s%2d  %-24s %s %s\e[K\n' "$ACC" "$INV" "$num" "$name" "$desc" "$C0"
      elif [ -n "$warn" ]; then
        printf '    %2d  %s%-24s%s %s%s%s\e[K\n' "$num" "$BOLD" "$name" "$C0" "$RED" "$desc" "$C0"
      else
        printf '    %2d  %s%-24s%s %s%s%s\e[K\n' "$num" "$BOLD" "$name" "$C0" "$DIM" "$desc" "$C0"
      fi
      if [ -n "$meta" ]; then
        while IFS= read -r ml; do
          [ "${#ml}" -gt $((COLS-12)) ] && ml="${ml:0:$((COLS-13))}…"
          mcol="$DIM"; [ "${ml:0:1}" = "⚠" ] && mcol="$RED"
          if [ "$i" -eq "$cur" ]; then
            printf '  %s▍%s     %s%s%s\e[K\n' "$ACC" "$C0" "$mcol" "$ml" "$C0"
          else
            printf '        %s%s%s\e[K\n' "$mcol" "$ml" "$C0"
          fi
        done <<< "$meta"
        printf '\e[K\n'
      fi
    done
    [ -n "$PICK_HINT" ] && printf '\e[K\n  %s%s%s\e[K\n' "$DIM" "$PICK_HINT" "$C0"
    printf '\e[K\n  %s↑↓ move · Enter open · 1-9 jump · Esc back%s · q quit%s\e[K\n\e[J' \
      "$DIM" "${PICK_HELP:+ · ? help}" "$C0"
    IFS= read -rsn1 key || { ui_close; return 1; }
    if [ "$key" = $'\e' ]; then IFS= read -rsn2 -t 0.1 rest || rest=""; key="$key$rest"; fi
    case "$key" in
      $'\e[A'|k) [ "$cur" -gt 0 ] && cur=$((cur-1)) || cur=$((n-1)) ;;
      $'\e[B'|j) [ "$cur" -lt $((n-1)) ] && cur=$((cur+1)) || cur=0 ;;
      $'\e')     return 2 ;;                       # bare Esc = back one screen
      "")        PICKED=$cur; return 0 ;;
      q|Q)       ui_close; return 1 ;;
      "?")       if [ -n "$PICK_HELP" ]; then
                   ui_text_page "help" "$PICK_HELP" "Press any key to go back"
                   IFS= read -rsn1 _ || true
                   printf '\e[H\e[J'
                 fi ;;
      [1-9])     [ "$key" -le "$n" ] && { PICKED=$((key-1)); return 0; } ;;
    esac
  done
}

ask() { # $1 = prompt -> REPLY (works in both modes, cursor restored in fancy)
  [ "$UI_OPEN" = 1 ] && printf '\e[?25h'
  read -rp "  ${BOLD}$1${C0} " REPLY
  [ "$UI_OPEN" = 1 ] && printf '\e[?25l'
}

# ── first-run tour: 30 seconds, once ────────────────────────────────────────
TOUR_MARK="$HOME/.local/state/cc-launcher/tour-done"
show_tour() {
  [ "$FANCY" = 1 ] || return 0
  [ -f "$TOUR_MARK" ] && return 0
  ui_open
  local pages=(
"WORKSPACES                                            (1 of 3)

Your work lives in folders under ~/Projects, and this menu lists them.

  <client>.tools   the client's apps & platform work
  projects         anything big enough for its own folder
  misc             small research & one-off questions
  os-changes       fixes and settings on THIS machine

Claude reads a folder's CLAUDE.md when it starts there — so starting
in the right folder means Claude already knows the right things."
"SESSIONS                                              (2 of 3)

Every conversation with Claude is a session, saved with its folder.
Closing the window loses nothing. To get back to one:

  ↩ Pick up where you left off    your recent sessions, newest first
  ↩ Continue the last session     same conversation, same memory
  ☰ Pick an earlier session       that folder's full history

Starting a new session gives Claude a clean slate in that folder."
"CONTEXT — Claude's working memory                     (3 of 3)

Each session has a limited working memory, called context. The bar at
the bottom of Claude shows how full it is; so do the cards here.

When a session shows red ⚠ FULL, don't keep working in it:

  1. ⚑ Wrap up & hand off — Claude writes the state to HANDOFF.md
  2. ⇥ New session from hand-off — a fresh session picks it right up

That's the whole habit. The launcher will point the way."
  )
  local p
  for p in "${pages[@]}"; do
    ui_text_page "welcome — a 30-second tour" "$p" "Press any key to continue…"
    IFS= read -rsn1 _ || break
  done
  mkdir -p "$(dirname "$TOUR_MARK")" && touch "$TOUR_MARK"
}

# ── session recall ──────────────────────────────────────────────────────────
# claude keys sessions by the cwd they ran in, munged into a dashed dir name
# under ~/.claude/projects/ — that mapping is what lets the launcher find them
sess_dir() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# newest session file for a workspace dir (empty if none)
last_session_file() {
  # shellcheck disable=SC2012  # names are session UUIDs; ls -t is the cheap
  # "newest by mtime" and find|sort would cost a subshell per menu repaint
  ls -t "$HOME/.claude/projects/$(sess_dir "$1")"/*.jsonl 2>/dev/null | head -1
}

# "today 14:02" / "yesterday 09:15" / "Aug 28" from a file's mtime
age_of() {
  local ts; ts=$(stat -c %Y "$1" 2>/dev/null) || { echo "?"; return; }
  case "$(date -d "@$ts" +%F)" in
    "$(date +%F)")              date -d "@$ts" "+today %H:%M" ;;
    "$(date -d yesterday +%F)") date -d "@$ts" "+yesterday %H:%M" ;;
    *)                          date -d "@$ts" "+%b %d" ;;
  esac
}

# one python pass over any number of session files; per file prints
#   ctx<TAB>msgs<TAB>mins<TAB>gist       ("-" = unknown, so fields never shift)
# Head is parsed as JSON (gist, first timestamp), the tail too (last usage →
# context, last timestamp), while the middle is only substring-scanned for
# the message count — big transcripts stay fast.
sess_meta_batch() {
  python3 - "$@" 2>/dev/null <<'PY'
import json, os, sys
from datetime import datetime

HEAD_LINES, TAIL_BYTES = 120, 262144

WIN_CACHE = os.path.expanduser("~/.local/state/cc-launcher/model-windows.json")


def window_for(model):
    """Context window for a model id, learned rather than guessed.

    A transcript records the model id and its token usage but NOT the window, so
    this cannot be derived from the file. Claude Code does tell the STATUSLINE
    the real window (context_window.context_window_size), and cc-statusline
    caches model_id -> window there, so a model with a bigger window teaches the
    cache the first time it is used -- no table here to go stale.

    The old test was `"1m" in model`, which never matched a real id
    (`claude-opus-5`), so every 1M session read 5x high and pinned at the cap
    (field-hit 2026-09-02). Returns None when the window is genuinely unknown --
    the caller then reports "-" rather than a number. Guessing a denominator is
    worse than admitting ignorance: our statusline is NOT installed when the user
    already has one of their own (10-claude-code.sh never clobbers it), so a
    guess would read 5x high on every 1M session forever, flag every folder FULL,
    and train people to ignore the one signal this feature exists to give."""
    try:
        with open(WIN_CACHE) as f:
            win = json.load(f).get(model or "")
        if win:
            return int(win)
    except Exception:
        pass
    return None

def ts_parse(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except Exception:
        return None

for path in sys.argv[1:]:
    gist = ""; msgs = 0; first_ts = None; last_ts = None
    usage = None; model = ""
    try:
        size = os.path.getsize(path)
        with open(path, errors="replace") as f:
            for i, line in enumerate(f):
                if i >= HEAD_LINES:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")
                if t == "summary" and d.get("summary") and not gist:
                    gist = d["summary"]
                if t in ("user", "assistant") and not first_ts:
                    first_ts = d.get("timestamp")
                if t == "user" and not gist:
                    c = (d.get("message") or {}).get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c
                                     if isinstance(x, dict) and x.get("type") == "text")
                    if isinstance(c, str):
                        s = " ".join(c.split())
                        if s and not s.startswith("<"):
                            gist = s
        with open(path, errors="replace") as f:
            if size > TAIL_BYTES:
                f.seek(size - TAIL_BYTES)
                f.readline()
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                t = d.get("type")
                if t in ("user", "assistant") and d.get("timestamp"):
                    last_ts = d["timestamp"]
                if t == "assistant":
                    m = d.get("message") or {}
                    u = m.get("usage")
                    if isinstance(u, dict) and u.get("input_tokens") is not None:
                        usage = u
                        model = m.get("model") or model
        with open(path, errors="replace") as f:
            for line in f:
                if '"type":"user"' in line or '"type":"assistant"' in line:
                    msgs += 1
    except Exception:
        pass
    ctx = ""
    if usage:
        used = ((usage.get("input_tokens") or 0)
                + (usage.get("cache_read_input_tokens") or 0)
                + (usage.get("cache_creation_input_tokens") or 0))
        win = os.environ.get("CC_CONTEXT_WINDOW") or window_for(model)
        if win:
            ctx = str(max(0, min(100, used * 100 // int(win))))
    mins = ""
    a, b = ts_parse(first_ts), ts_parse(last_ts)
    if a and b:
        mins = str(max(1, int((b - a).total_seconds() // 60)))
    gist = (gist or "(no summary)").replace("|", " ").replace("\t", " ")[:64]
    # "-" placeholders: bash `read` collapses empty tab-separated fields,
    # which would shift every later column
    print(f"{ctx or '-'}\t{msgs}\t{mins or '-'}\t{gist}")
PY
}

# single-file convenience -> SM_CTX SM_MSGS SM_MINS SM_GIST
sess_meta() {
  IFS=$'\t' read -r SM_CTX SM_MSGS SM_MINS SM_GIST < <(sess_meta_batch "$1")
  [ "$SM_CTX" = "-" ] && SM_CTX=""
  [ "$SM_MINS" = "-" ] && SM_MINS=""
}

fmt_dur() { # minutes -> "45m" / "2h 05m"
  local m="${1:-}"; [ -n "$m" ] || { echo ""; return; }
  if [ "$m" -ge 60 ]; then printf '%dh %02dm' "$((m/60))" "$((m%60))"; else printf '%dm' "$m"; fi
}

# above this fill, continuing gets the wrap-up reminder; at/above CTX_FULL the
# session shows RED in menus with a do-not-build-here note
CTX_NUDGE="${CC_CTX_NUDGE:-80}"
CTX_FULL="${CC_CTX_FULL:-85}"

# card lines from parsed meta -> CARD_META (newline-joined), CARD_WARN
card_from_meta() { # $1=ctx $2=msgs $3=mins $4=gist
  local l2="\"$4\"" l3="${2:-?} exchanges" dur; dur=$(fmt_dur "${3:-}")
  [ -n "$dur" ] && l3+=" · $dur"
  CARD_WARN=""
  if [ -n "$1" ]; then
    if [ "$1" -ge "$CTX_FULL" ]; then
      CARD_WARN=1
      l3+=$'\n'"⚠ context $1% — FULL: wrap up & hand off, don't build here"
    else
      l3+=" · context $1% used"
    fi
  fi
  CARD_META="$l2"$'\n'"$l3"
}

# one-line summary for compact rows (misc submenu): "gist" · age · context
sess_line() { # $1 = session file
  sess_meta "$1"
  printf '"%s" · %s%s' "$SM_GIST" "$(age_of "$1")" \
    "$( [ -n "$SM_CTX" ] && printf ' · context %s%%' "$SM_CTX" )"
}

ctx_nudge() { # $1 = percent — printed to the normal screen so it survives
  cat <<NUDGE

  ${WARN}⚠ That session's context is $1% used.${C0} Good hygiene: have Claude write
    the state down — what's done, what's next, where things live — into the
    project docs, then start a fresh session. ("Wrap up & hand off" in the
    launcher does exactly this.)

NUDGE
  sleep 2
}

# ── stamps ──────────────────────────────────────────────────────────────────
ensure_os_changes() {
  local d="$PROJECTS/os-changes"
  mkdir -p "$d"
  [ -f "$d/README.md" ] || cat > "$d/README.md" <<EOF
# OS Changes — $(hostname -s)

Local-system change log for this terminal. LOCAL ONLY — never pushed to GitHub
(restic covers it). Newest first. Every entry needs enough detail to undo it.

| Date | Category | Summary | Details |
|------|----------|---------|---------|
| $(date +%F) | Project | Initial setup of os-changes tracking | Created this file. |
EOF
  [ -f "$d/CLAUDE.md" ] || cat > "$d/CLAUDE.md" <<'EOF'
# CLAUDE.md — os-changes (this machine)

You are working on THIS terminal's local system: settings, packages,
troubleshooting, preferences. Not client apps — that work lives in the
<code>.tools workspace.

- **Log every OS-level change** as a new top row in README.md's table
  (Date | Category | Summary | Details). Details must include how to undo it.
- This folder is LOCAL ONLY: no git, no GitHub, ever. The nightly restic
  backup of the home directory is its safety net.
- Ground rules from the platform contract still apply (no secrets in files
  that leave this machine; verify changes; plain-language reporting).
EOF
}

stamp_project() { # $1 = new top-level project dir (a "major" project)
  cat > "$1/CLAUDE.md" <<EOF
# CLAUDE.md — $(basename "$1") (project)

Started $(date +%F).

- First session: ask what this project is for and record it here under
  "## What this is" — every later session reads it.
- Platform ground rules apply (never commit secrets; plain-language results).
- Session hygiene: when a session's context is getting full (watch the status
  bar), have Claude record durable state here — what's done, what's next,
  where things live — then start a fresh session. The launcher's "Wrap up &
  hand off" writes HANDOFF.md for exactly this.
- Apps/tools deployed FOR the client still belong in the <code>.tools
  workspace via its NEW-APP flow — this folder is for standalone major work.
- Small one-off research belongs in misc/, not here.

## What this is
_(to be filled in during the first working session)_
EOF
}

stamp_misc_project() { # $1 = new project dir
  cat > "$1/CLAUDE.md" <<EOF
# CLAUDE.md — $(basename "$1") (misc project)

Started $(date +%F). LOCAL ONLY unless deliberately promoted to a repo.

- First session: ask what this project is for and record it here under
  "## What this is" — every later session reads it.
- Platform ground rules apply (never commit secrets; plain-language results).
- Session hygiene: when a session's context is getting full (watch the status
  bar), have Claude record durable state here, then start a fresh session.
- If this grows into a real tool/app for the client, STOP and move it into
  the <code>.tools workspace via the NEW-APP flow — misc is not a home for
  deployed things.

## What this is
_(to be filled in during the first working session)_
EOF
}

# ── the SETUP flow: the only sanctioned way to create <code>.tools ──────────
run_setup() {
  if [ ! -s "$PACK" ]; then
    cat <<MSG
No $TOOLS_NAME yet. This terminal's engagement workspace is created by the SETUP
flow (~/claude-terminal/templates/SETUP.md), which needs the staged credential
pack at ~/Projects/.env — that is onboarding stage 2, the accounts pass. Stage
it (chmod 600), then run \`cc\` again and pick this entry.
MSG
    exit 1
  fi
  # shellcheck disable=SC2088  # tilde is display text; the test uses $KIT
  [ -d "$KIT" ] || { echo "~/claude-terminal is missing — run the get.sh bootstrap first."; exit 1; }
  cd "$PROJECTS" || exit 1
  echo "→ SETUP for $TOOLS_NAME (engagement code $CODE)"
  # SETUP.md derives everything from the pack and asks nothing; the code the
  # box carries is a cross-check that the RIGHT pack was staged here.
  exec claude "${CLAUDE_ARGS[@]}" "$@" \
    "Read ~/claude-terminal/templates/SETUP.md and set everything up. This terminal's engagement code is '$CODE' (from the platform, /etc/asp-terminal.env); the staged pack is ~/Projects/.env. First cross-check: if the pack's CLIENT_CODE is not '$CODE', STOP and say so — the wrong pack is staged on this terminal. Otherwise follow SETUP.md exactly."
}

# ── menus ───────────────────────────────────────────────────────────────────
# every real folder under ~/Projects: .tools workspaces first, then projects
mapfile -t ALL_DIRS < <(find "$PROJECTS" -maxdepth 1 -mindepth 1 -type d ! -name '.*' | sort)
declare -a TOOLS_DIRS=() PROJ_DIRS=()
for d in "${ALL_DIRS[@]}"; do
  case "$(basename "$d")" in
    *.tools) TOOLS_DIRS+=("$d") ;;
    os-changes|misc) ;;  # standing entries, appended below in fixed order
    *) PROJ_DIRS+=("$d") ;;
  esac
done

# recent sessions across every workspace (menu folders + misc subprojects),
# newest first, within the recall window — after a shutdown, "get me back to
# what I was doing" shouldn't require remembering which folder that was
RECALL_DAYS="${CC_RECALL_DAYS:-5}"
declare -a RECALL_DIRS=("${ALL_DIRS[@]}")
while IFS= read -r d; do RECALL_DIRS+=("$d"); done \
  < <(find "$PROJECTS/misc" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
declare -a R_ROWS=()   # "mtime<TAB>dir<TAB>file", newest first, capped at 8
build_recall() {
  local cutoff d f ts
  cutoff=$(( $(date +%s) - RECALL_DAYS * 86400 ))
  mapfile -t R_ROWS < <(
    for d in "${RECALL_DIRS[@]}"; do
      for f in "$HOME/.claude/projects/$(sess_dir "$d")"/*.jsonl; do
        [ -f "$f" ] || continue
        ts=$(stat -c %Y "$f" 2>/dev/null) || continue
        [ "$ts" -ge "$cutoff" ] && printf '%s\t%s\t%s\n' "$ts" "$d" "$f"
      done
    done | sort -rn | head -8)
}
build_recall

madd() { # menu row: path, name, desc [, meta [, warn]]
  PATHS+=("$1"); MENU_NAME+=("$2"); MENU_DESC+=("$3")
  MENU_META+=("${4:-}"); MENU_WARN+=("${5:-}")
}

load_main_menu() {
  PATHS=(); MENU_NAME=(); MENU_DESC=(); MENU_META=(); MENU_WARN=()
  if [ "${#R_ROWS[@]}" -gt 0 ]; then
    local ts d f
    IFS=$'\t' read -r ts d f <<< "${R_ROWS[0]}"
    madd "@recall" "↩ Pick up where you left off" \
      "${#R_ROWS[@]} recent session$( [ "${#R_ROWS[@]}" -gt 1 ] && echo s) · newest: $(basename "$d") · $(age_of "$f")"
  fi
  SETUP_ENTRY=0
  if [ -n "$TOOLS_NAME" ] && [ ! -d "$PROJECTS/$TOOLS_NAME" ]; then
    # first among the folders: on an engagement terminal this IS the workspace
    madd "@setup" "+ Set up $TOOLS_NAME" "this engagement's workspace (runs the SETUP flow)"
    SETUP_ENTRY=1
  fi
  local d
  for d in "${TOOLS_DIRS[@]}"; do madd "$d" "$(basename "$d")" "client apps & platform"; done
  for d in "${PROJ_DIRS[@]}"; do madd "$d" "$(basename "$d")" "project"; done
  madd "$PROJECTS/os-changes" "os-changes" "this machine: settings & troubleshooting"
  madd "$PROJECTS/misc"       "misc"       "small research & everything else"
  madd "@newproject"          "+ New project…" "major project at ~/Projects/<name> (small research goes in misc)"

  # red-flag folders whose newest session is FULL — the wrap-up habit should
  # start on the main screen, before the folder is even opened
  local -a HF=() HI=()
  local i f
  for i in "${!PATHS[@]}"; do
    case "${PATHS[$i]}" in @*) continue ;; esac
    f=$(last_session_file "${PATHS[$i]}")
    [ -n "$f" ] || continue
    HF+=("$f"); HI+=("$i")
  done
  if [ "${#HF[@]}" -gt 0 ]; then
    local -a HM=()
    mapfile -t HM < <(sess_meta_batch "${HF[@]}")
    local j hctx
    for j in "${!HF[@]}"; do
      hctx="${HM[$j]%%$'\t'*}"
      [ -n "$hctx" ] && [ "$hctx" != "-" ] || continue
      if [ "$hctx" -ge "$CTX_FULL" ]; then
        i="${HI[$j]}"
        MENU_DESC[i]="${MENU_DESC[i]} · ⚠ full session — wrap up"
        MENU_WARN[i]=1
      fi
    done
  fi
}

new_project_screen() { # $1 = "major" | "misc" -> sets TARGET, NEWPROJ_MSG; rc 1 = cancelled
  if [ "$UI_OPEN" = 1 ]; then
    printf '\e[H\e[J'; ui_header "new project"
    if [ "$1" = "major" ]; then
      printf '  Major work gets its own folder under ~/Projects.\n'
      printf '  %sSmall research belongs in misc — back out and pick misc for that.%s\n\n' "$DIM" "$C0"
    else
      printf '  A small research folder under misc/.\n\n'
    fi
  fi
  ask "Project name (Enter to cancel):"
  local name
  name=$(echo "$REPLY" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
  [ -n "$name" ] || return 1
  if [ "$1" = "major" ]; then
    case "$name" in
      # .tools is stood up by the SETUP flow only (#9); the standing folders
      # already exist as menu entries of their own
      *tools) ui_close; echo "Names ending in 'tools' are reserved for the SETUP flow."; exit 1 ;;
      os-changes|misc) return 1 ;;   # it's a standing menu entry — back out
    esac
    TARGET="$PROJECTS/$name"
  else
    TARGET="$PROJECTS/misc/$name"
  fi
  if [ -d "$TARGET" ]; then
    NEWPROJ_MSG="$name already exists — opening it."
  else
    mkdir -p "$TARGET"
    if [ "$1" = "major" ]; then stamp_project "$TARGET"; else stamp_misc_project "$TARGET"; fi
    NEWPROJ_MSG="Created ${TARGET#"$PROJECTS"/} (under ~/Projects)"
  fi
}

MAIN_HELP="This menu is where every Claude session starts.

Pick a folder to work in — Claude reads that folder's CLAUDE.md and
knows the right project. \"Pick up where you left off\" lists your
recent conversations so you can continue one.

  + New project…   makes a folder for major work
  misc             small research and one-off questions
  os-changes       settings and fixes on this machine itself

A red \"⚠ full session\" flag means that folder's last conversation ran
its working memory out — open the folder and pick \"Wrap up & hand off\"."

RECALL_HELP="Each card is one saved conversation (a \"session\").

  \"…\" line        what the conversation was about
  exchanges        how many back-and-forths it holds
  context          how full that conversation's working memory is

A red ⚠ FULL session can't take in much more. Reopen it only to save
its state: \"Wrap up & hand off\" has Claude write HANDOFF.md, and a
fresh session then picks up from that file with a clean memory."

SESSION_HELP="  ↩ Continue the last session   reopen the same conversation, same memory
  ⊕ Start a new session         clean slate here (CLAUDE.md still loads)
  ⇥ New session from hand-off   clean slate that first reads HANDOFF.md
  ☰ Pick an earlier session     this folder's full history
  ⚑ Wrap up & hand off          Claude saves state to HANDOFF.md so a
                                fresh session can take over

Rule of thumb: continue while context is healthy; once it runs red,
wrap up and start fresh from the hand-off."

# ── navigation loop ─────────────────────────────────────────────────────────
# Esc or "← Back" walks back one screen in every submenu; q quits.
# direct shortcut: cc <folder> [claude args…] skips the menu entirely.
TARGET=""
if [ $# -ge 1 ] && [ -d "$PROJECTS/$1" ]; then
  TARGET="$PROJECTS/$1"; shift
elif [ $# -ge 1 ] && [ "${1:0:1}" != "-" ]; then
  echo "No such workspace: ~/Projects/$1"; exit 1
fi
[ -z "$TARGET" ] && show_tour

MODE="new"; RESUME_ID=""; NEWPROJ_MSG=""; PCT=""; LAUNCH=0
while [ "$LAUNCH" = 0 ]; do
  if [ -z "$TARGET" ]; then
    load_main_menu
    if [ "$SETUP_ENTRY" = 0 ] && [ "${#TOOLS_DIRS[@]}" -eq 0 ] && [ "$FANCY" != 1 ]; then
      # no engagement code on this box and no workspace: say so instead of
      # leaving the absence unexplained (the SETUP flow is still what makes one)
      echo "  (no <code>.tools workspace here yet — the SETUP flow creates one: ~/claude-terminal/templates/SETUP.md)"
    fi
    PICK_HELP="$MAIN_HELP"
    pick "where are you working?" "Where are you working?" || { ui_close; exit 0; }
    PICK_HELP=""
    TARGET="${PATHS[$PICKED]}"
  fi

  case "$TARGET" in
    @recall)
      # card view: one python pass gathers gist/messages/duration/context
      # for every recent session, newest first
      declare -a R_FILES=() R_DIRS=()
      for row in "${R_ROWS[@]}"; do
        IFS=$'\t' read -r ts d f <<< "$row"
        R_DIRS+=("$d"); R_FILES+=("$f")
      done
      mapfile -t METAS < <(sess_meta_batch "${R_FILES[@]}")
      PATHS=(); MENU_NAME=(); MENU_DESC=(); MENU_META=(); MENU_WARN=()
      for i in "${!R_FILES[@]}"; do
        IFS=$'\t' read -r mctx mmsgs mmins mgist <<< "${METAS[$i]:-}"
        [ "$mctx" = "-" ] && mctx=""
        [ "$mmins" = "-" ] && mmins=""
        card_from_meta "$mctx" "$mmsgs" "$mmins" "$mgist"
        madd "${R_DIRS[$i]}"$'\t'"${R_FILES[$i]}"$'\t'"$mctx" \
             "$(basename "${R_DIRS[$i]}")" "$(age_of "${R_FILES[$i]}")" "$CARD_META" "$CARD_WARN"
      done
      madd "@back" "← Back" ""
      PICK_HINT="context = how full that conversation's working memory is; a FULL one is only good for a wrap-up"
      PICK_HELP="$RECALL_HELP"
      rc=0; pick "recent sessions (last $RECALL_DAYS days) — pick one to continue" "Recent sessions (last $RECALL_DAYS days):" || rc=$?
      PICK_HINT=""; PICK_HELP=""
      if [ "$rc" != 0 ] || [ "${PATHS[$PICKED]}" = "@back" ]; then
        [ "$rc" = 1 ] && { ui_close; exit 0; }
        TARGET=""; continue
      fi
      IFS=$'\t' read -r TARGET RES_FILE PCT <<< "${PATHS[$PICKED]}"
      RESUME_ID="$(basename "$RES_FILE" .jsonl)"
      MODE="resume-id"
      # a filling session: steer to the wrap-up before just reopening it
      if [ -n "$PCT" ] && [ "$PCT" -ge "$CTX_NUDGE" ]; then
        PATHS=(wrapup-id resume-id back); MENU_META=("" "" ""); MENU_WARN=("" "" "")
        MENU_NAME=("⚑ Wrap up & hand off" "↩ Just continue it" "← Back")
        MENU_DESC=("recommended: Claude saves the state to HANDOFF.md, then you start fresh" "reopen it as-is" "")
        rc=0; pick "that session is ${PCT}% full — wrap it up?" "Session is ${PCT}% full — 1 = wrap up & hand off · 2 = just continue · 3 = back:" || rc=$?
        if [ "$rc" != 0 ] || [ "${PATHS[$PICKED]}" = "back" ]; then
          [ "$rc" = 1 ] && { ui_close; exit 0; }
          TARGET="@recall"; continue
        fi
        MODE="${PATHS[$PICKED]}"
      fi
      LAUNCH=1
      ;;
    @setup)
      ui_close; run_setup "$@"
      ;;
    @newproject)
      if new_project_screen major; then MODE="new"; LAUNCH=1; else TARGET=""; fi
      ;;
    "$PROJECTS/misc")
      mkdir -p "$TARGET"
      mapfile -t SUBS < <(find "$TARGET" -maxdepth 1 -mindepth 1 -type d | sort)
      PATHS=(); MENU_NAME=(); MENU_DESC=(); MENU_META=(); MENU_WARN=()
      for s in "${SUBS[@]}"; do
        lf=$(last_session_file "$s")
        if [ -n "$lf" ]; then madd "$s" "$(basename "$s")" "$(sess_line "$lf")"
        else madd "$s" "$(basename "$s")" ""; fi
      done
      madd "@newmisc" "+ New project…" "a small research folder under misc/"
      madd "@back" "← Back" ""
      rc=0; pick "misc — which project?" "misc — which project?" || rc=$?
      if [ "$rc" != 0 ] || [ "${PATHS[$PICKED]}" = "@back" ]; then
        [ "$rc" = 1 ] && { ui_close; exit 0; }
        TARGET=""; continue
      fi
      TARGET="${PATHS[$PICKED]}"
      if [ "$TARGET" = "@newmisc" ]; then
        if new_project_screen misc; then MODE="new"; LAUNCH=1; else TARGET="$PROJECTS/misc"; fi
      fi
      # a picked subfolder loops back into the default branch for the
      # continue/new/resume choice
      ;;
    *)
      if [ $# -eq 0 ]; then
        LSF=$(last_session_file "$TARGET")
        if [ -n "$LSF" ]; then
          sess_meta "$LSF"
          card_from_meta "$SM_CTX" "$SM_MSGS" "$SM_MINS" "$SM_GIST"
          PCT="$SM_CTX"
          HANDOFF=""; [ -f "$TARGET/HANDOFF.md" ] && HANDOFF=1
          PATHS=(); MENU_NAME=(); MENU_DESC=(); MENU_META=(); MENU_WARN=()
          if [ -n "$PCT" ] && [ "$PCT" -ge "$CTX_FULL" ]; then
            madd wrapup "⚑ Wrap up & hand off" "recommended — the last session is ${PCT}% full"
          fi
          madd continue "↩ Continue the last session" "$(age_of "$LSF")" "$CARD_META" "$CARD_WARN"
          [ -n "$HANDOFF" ] && madd handoff "⇥ New session from hand-off" "fresh start that first reads HANDOFF.md"
          madd new "⊕ Start a new session" "fresh context in $(basename "$TARGET")"
          if [ -n "$PCT" ] && [ "$PCT" -ge "$CTX_NUDGE" ] && [ "$PCT" -lt "$CTX_FULL" ]; then
            madd wrapup "⚑ Wrap up & hand off" "context ${PCT}% — save state before it fills"
          fi
          madd resume "☰ Pick an earlier session" "browse this folder's history (claude --resume)"
          madd back "← Back" ""
          if [ "$FANCY" = 1 ]; then
            PICK_HELP="$SESSION_HELP"
            rc=0; pick "$(basename "$TARGET") — start or continue?" "" || rc=$?
            PICK_HELP=""
            if [ "$rc" != 0 ] || [ "${PATHS[$PICKED]}" = "back" ]; then
              [ "$rc" = 1 ] && { ui_close; exit 0; }
              TARGET=""; continue
            fi
            MODE="${PATHS[$PICKED]}"
          else
            echo "  Last session here: \"$SM_GIST\" · $(age_of "$LSF")${SM_CTX:+ · context ${SM_CTX}%}"
            opts="Enter = continue it · n = new session · p = pick an earlier one"
            [ -n "$PCT" ] && [ "$PCT" -ge "$CTX_NUDGE" ] && opts+=" · w = wrap up & hand off"
            [ -n "$HANDOFF" ] && opts+=" · h = new from hand-off"
            read -rp "  $opts · b = back: " how
            case "$how" in
              n|N) MODE="new" ;;
              p|P) MODE="resume" ;;
              w|W) MODE="wrapup" ;;
              h|H) [ -n "$HANDOFF" ] && MODE="handoff" || MODE="continue" ;;
              b|B) TARGET=""; continue ;;
              *)   MODE="continue" ;;
            esac
          fi
        else
          MODE="new"
          [ -f "$TARGET/HANDOFF.md" ] && MODE="handoff"
        fi
      fi
      LAUNCH=1
      ;;
  esac
done

[ "$(basename "$TARGET")" = "os-changes" ] && ensure_os_changes

# ── launch ──────────────────────────────────────────────────────────────────
ui_close
[ -n "$NEWPROJ_MSG" ] && echo "$NEWPROJ_MSG"
cd "$TARGET" || exit 1
case "$MODE" in
  resume-id)
    echo "→ $(basename "$TARGET") — continuing your session"
    [ -n "$PCT" ] && [ "$PCT" -ge "$CTX_NUDGE" ] && ctx_nudge "$PCT"
    exec claude "${CLAUDE_ARGS[@]}" --resume "$RESUME_ID" "$@"
    ;;
  wrapup-id)
    echo "→ $(basename "$TARGET") — wrapping up the session (Claude writes HANDOFF.md)"
    exec claude "${CLAUDE_ARGS[@]}" --resume "$RESUME_ID" "$@" "$WRAPUP_PROMPT"
    ;;
  wrapup)
    echo "→ $(basename "$TARGET") — wrapping up the last session (Claude writes HANDOFF.md)"
    exec claude "${CLAUDE_ARGS[@]}" --continue "$@" "$WRAPUP_PROMPT"
    ;;
  handoff)
    echo "→ $(basename "$TARGET") — new session, picking up from HANDOFF.md"
    exec claude "${CLAUDE_ARGS[@]}" "$@" "$HANDOFF_PROMPT"
    ;;
  continue)
    echo "→ $(basename "$TARGET")"
    [ -n "$PCT" ] && [ "$PCT" -ge "$CTX_NUDGE" ] && ctx_nudge "$PCT"
    exec claude "${CLAUDE_ARGS[@]}" --continue "$@"
    ;;
  resume)
    echo "→ $(basename "$TARGET")"
    exec claude "${CLAUDE_ARGS[@]}" --resume "$@"
    ;;
  *)
    echo "→ $(basename "$TARGET")"
    exec claude "${CLAUDE_ARGS[@]}" "$@"
    ;;
esac
