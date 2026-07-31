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
# Ships in claude-terminal templates/; bootstrap installs it as ~/.local/bin/cc
# and keeps the tmux variant working: phonecc attaches to the same picker.
set -uo pipefail

PROJECTS="$HOME/Projects"
CLAUDE_ARGS=(--dangerously-skip-permissions)
mkdir -p "$PROJECTS"

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

# ── build the top-level menu ────────────────────────────────────────────────
mapfile -t TOOLS_DIRS < <(find "$PROJECTS" -maxdepth 1 -mindepth 1 -type d -name '*.tools' | sort)
declare -a PATHS LABELS
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
    printf "  %d) %-14s %s\n" "$((i+1))" "$name" "$desc"
  done
  read -rp "> " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#PATHS[@]}" ] || { echo "Invalid choice."; exit 1; }
  TARGET="${PATHS[$((pick-1))]}"
fi

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
