#!/usr/bin/env bash
# workspace-status.sh — the "nothing lingers" sweep.
#
# Checks every git repo in the client workspace for work that never finished
# its full chain (edit → commit → push → CI green → deploy):
#   · dirty working tree (uncommitted changes)
#   · unpushed commits (local ahead of origin/main)
#   · latest GitHub Actions run not green (needs gh + GH_TOKEN)
#
# Run by Claude at every session START and CLOSE (platform CLAUDE.md rule),
# and available to humans any time. Exit 0 = all clean; exit 1 = findings.
#
# Repos scanned: ~/Projects/<code>.tools itself + every app repo nested one
# level under it (each app is its own repo — parent gitignores them).
set -uo pipefail

PROJECTS="$HOME/Projects"
FINDINGS=0

# Load the platform .env if present (GH_TOKEN for CI checks) — per-invocation,
# never persisted, same rule as everywhere else on this terminal.
for envfile in "$PROJECTS"/*.tools/.env; do
  # shellcheck source=/dev/null
  [ -f "$envfile" ] && { set -a; . "$envfile"; set +a; break; }
done

check_repo() {
  local dir="$1" name issues=""
  name=$(basename "$dir")
  [ -d "$dir/.git" ] || return 0

  # dirty tree
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    issues+="  · UNCOMMITTED changes\n"
  fi
  # unpushed commits (only meaningful when an upstream exists)
  if git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    local ahead
    ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    [ "$ahead" -gt 0 ] && issues+="  · $ahead UNPUSHED commit(s)\n"
  else
    issues+="  · no upstream configured (never pushed?)\n"
  fi
  # latest CI run on default branch
  if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
    local repo run
    repo=$(git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
    if [ -n "$repo" ]; then
      run=$(gh run list -R "$repo" --branch main --limit 1 \
              --json status,conclusion,displayTitle \
              --jq '.[0] | "\(.status)/\(.conclusion // "-")/\(.displayTitle)"' 2>/dev/null || true)
      case "$run" in
        "") ;;                                  # no workflows yet — fine
        completed/success/*) ;;                 # green
        *) issues+="  · CI NOT GREEN: $run\n" ;;
      esac
    fi
  fi

  if [ -n "$issues" ]; then
    printf '⚠ %s\n%b' "$name" "$issues"
    FINDINGS=1
  fi
}

for tools_dir in "$PROJECTS"/*.tools; do
  [ -d "$tools_dir" ] || continue
  check_repo "$tools_dir"
  for app in "$tools_dir"/*/; do
    check_repo "${app%/}"
  done
done

if [ "$FINDINGS" -eq 0 ]; then
  echo "✅ workspace clean — nothing uncommitted, unpushed, or red."
else
  echo ""
  echo "Resolve the above BEFORE new work: finish the chain (commit → push →"
  echo "CI green → deploy) or revert — nothing lingers."
fi
exit "$FINDINGS"
