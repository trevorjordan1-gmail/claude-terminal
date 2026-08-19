#!/usr/bin/env bash
# cc — Claude Code Terminal launcher (replaces the plain `cc` alias).
# Presents a folder picker over ~/Projects so every session starts in the right
# context with the right CLAUDE.md loaded. The three standing workspaces:
#
#   <code>.tools   client apps & platform (one per client code, e.g. acme.tools)
#   os-changes     THIS machine: settings, troubleshooting, local system work
#   misc           research & everything else (one subfolder per project)
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

stamp_misc_project() { # $1 = new project dir
  cat > "$1/CLAUDE.md" <<EOF
# CLAUDE.md — $(basename "$1") (misc project)

Started $(date +%F). LOCAL ONLY unless deliberately promoted to a repo.

- First session: ask what this project is for and record it here under
  "## What this is" — every later session reads it.
- Platform ground rules apply (never commit secrets; plain-language results).
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

# ── build the top-level menu ────────────────────────────────────────────────
mapfile -t TOOLS_DIRS < <(find "$PROJECTS" -maxdepth 1 -mindepth 1 -type d -name '*.tools' | sort)
declare -a PATHS LABELS
SETUP_ENTRY=0
if [ -n "$TOOLS_NAME" ] && [ ! -d "$PROJECTS/$TOOLS_NAME" ]; then
  # first, and prefilled: on an engagement terminal this IS the workspace
  PATHS+=("@setup"); LABELS+=("+ set up $TOOLS_NAME|this engagement's workspace (runs the SETUP flow)"); SETUP_ENTRY=1
fi
for d in "${TOOLS_DIRS[@]}"; do
  PATHS+=("$d"); LABELS+=("$(basename "$d")|client apps & platform")
done
PATHS+=("$PROJECTS/os-changes"); LABELS+=("os-changes|this machine: settings & troubleshooting")
PATHS+=("$PROJECTS/misc");       LABELS+=("misc|research & everything else")

# direct shortcut: cc <folder> [claude args…]
TARGET=""
if [ $# -ge 1 ] && [ -d "$PROJECTS/$1" ]; then
  TARGET="$PROJECTS/$1"; shift
elif [ $# -ge 1 ] && [ "${1:0:1}" != "-" ]; then
  echo "No such workspace: ~/Projects/$1"; exit 1
fi

if [ -z "$TARGET" ]; then
  echo "Where are you working?"
  for i in "${!PATHS[@]}"; do
    IFS='|' read -r name desc <<< "${LABELS[$i]}"
    printf "  %d) %-20s %s\n" "$((i+1))" "$name" "$desc"
  done
  if [ "$SETUP_ENTRY" = 0 ] && [ "${#TOOLS_DIRS[@]}" -eq 0 ]; then
    # no engagement code on this box and no workspace: say so instead of
    # leaving the absence unexplained (the SETUP flow is still what makes one)
    echo "  (no <code>.tools workspace here yet — the SETUP flow creates one: ~/claude-terminal/templates/SETUP.md)"
  fi
  read -rp "> " pick
  if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#PATHS[@]}" ]; then
    echo "Invalid choice."; exit 1
  fi
  TARGET="${PATHS[$((pick-1))]}"
fi

[ "$TARGET" = "@setup" ] && run_setup "$@"

# ── misc: continue an existing project or start a new one ──────────────────
if [ "$(basename "$TARGET")" = "misc" ]; then
  mkdir -p "$TARGET"
  mapfile -t SUBS < <(find "$TARGET" -maxdepth 1 -mindepth 1 -type d | sort)
  echo "misc — which project?"
  for i in "${!SUBS[@]}"; do printf "  %d) %s\n" "$((i+1))" "$(basename "${SUBS[$i]}")"; done
  printf "  %d) + new project…\n" "$(( ${#SUBS[@]} + 1 ))"
  read -rp "> " pick
  if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#SUBS[@]}" ]; then
    TARGET="${SUBS[$((pick-1))]}"
  elif [ "$pick" = "$(( ${#SUBS[@]} + 1 ))" ]; then
    read -rp "Project name: " raw
    name=$(echo "$raw" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' )
    [ -n "$name" ] || { echo "Need a name."; exit 1; }
    TARGET="$PROJECTS/misc/$name"
    mkdir -p "$TARGET"
    stamp_misc_project "$TARGET"
    echo "Created misc/$name"
  else
    echo "Invalid choice."; exit 1
  fi
fi

[ "$(basename "$TARGET")" = "os-changes" ] && ensure_os_changes

cd "$TARGET" || exit 1
echo "→ $(basename "$TARGET")"
exec claude "${CLAUDE_ARGS[@]}" "$@"
