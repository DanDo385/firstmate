#!/usr/bin/env bash
# Prune merged worktrees: remove local+remote branches and worktree directories.
# Usage: fm-worktree-prune.sh [--dry-run] [<project>...]
#   --dry-run       print what would be removed without doing it
#   <project>...    one or more project directory names under ~/Code/;
#                   default: every registered project in data/projects.md
#
# For each registered project, scans ~/Code/worktrees/<project>/ for git worktrees
# whose branch is fully merged into the project's default branch (origin/main or
# origin/master). When that is the case:
#   1. Delete the remote branch if it exists on origin (git push origin --delete)
#   2. Delete the local branch (git branch -D)
#   3. Remove the worktree directory (git worktree remove)
#   4. Run git worktree prune on the project repo
#
# A worktree that contains uncommitted changes or is on a branch NOT merged into
# the default branch is never touched.
#
# Designed to run as a cron job or as a Firstmate heartbeat task (2x/day).
# No force-delete: if git worktree remove refuses, the worktree stays.
set -euo pipefail

DRY_RUN=0
PROJECTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) PROJECTS+=("$1"); shift ;;
  esac
done

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKTREE_BASE="$HOME/Code/worktrees"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
dry()  { [ "$DRY_RUN" -eq 1 ] && printf '[DRY RUN] %s\n' "$*" || "$@"; }

resolve_default_branch() {
  local project=$1
  local remote branch
  # Prefer origin; fall back to first remote; if no remote, use local main/master
  if git -C "$project" remote show 2>/dev/null | grep -qx 'origin'; then
    remote=origin
  else
    remote=$(git -C "$project" remote show 2>/dev/null | head -1) || true
  fi
  if [ -n "$remote" ]; then
    branch=$(git -C "$project" symbolic-ref "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s|refs/remotes/$remote/||") || true
  fi
  if [ -z "$branch" ]; then
    # No remote or no remote HEAD: guess from local branches
    if git -C "$project" rev-parse --verify main >/dev/null 2>&1; then
      branch=main
    elif git -C "$project" rev-parse --verify master >/dev/null 2>&1; then
      branch=master
    else
      return 1
    fi
  fi
  printf '%s\n' "$branch"
}

# Resolve registered projects from data/projects.md.
# Output: tab-separated name\tpath
resolve_registered_projects() {
  local projects_file="$FM_ROOT/data/projects.md"
  [ -f "$projects_file" ] || return 1
  # Parse lines like: "- name [mode] - local copy ~/path (added ...)"
  # or: "- name [mode] - private owner/repo at ~/path"
  while IFS= read -r line; do
    local name path
    name=$(printf '%s' "$line" | sed -n 's/^- \([^ ]*\) .*/\1/p')
    [ -n "$name" ] || continue
    path=$(printf '%s' "$line" | sed -n 's|.* at \(~/[-a-zA-Z0-9_/]*\).*|\1|p')
    # Fall back: "local copy ~/path"
    [ -n "$path" ] || path=$(printf '%s' "$line" | sed -n 's|.*local copy \(~/[-a-zA-Z0-9_/]*\).*|\1|p')
    # Last resort: first ~/path in the line
    [ -n "$path" ] || path=$(printf '%s' "$line" | sed -n 's|.*\(~/[-a-zA-Z0-9_/]*\).*|\1|p')
    [ -n "$path" ] || continue
    # Expand ~ to $HOME
    path="${path/#\~/$HOME}"
    [ -d "$path/.git" ] || [ -f "$path/.git" ] || continue
    printf '%s\t%s\n' "$name" "$path"
  done < "$projects_file"
}

prune_worktree() {
  local wt_dir=$1 project=$2 default_branch=$3
  local branch

  branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    warn "cannot resolve branch for $wt_dir; skipping"
    return 1
  }

  # Safety: never touch the default branch itself
  if [ "$branch" = "$default_branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    return 0
  fi

  # Check merged status: try origin/<branch> first, then local <branch>
  local base_commit merge_base
  base_commit=$(git -C "$project" rev-parse "refs/remotes/origin/$default_branch" 2>/dev/null) || \
  base_commit=$(git -C "$project" rev-parse "$default_branch" 2>/dev/null) || {
    warn "cannot resolve $default_branch for $project; skipping $wt_dir"
    return 1
  }
  merge_base=$(git -C "$project" merge-base "$base_commit" "$branch" 2>/dev/null) || {
    warn "cannot compute merge-base for $branch in $project; skipping $wt_dir"
    return 1
  }
  branch_tip=$(git -C "$project" rev-parse "$branch" 2>/dev/null) || {
    warn "branch $branch no longer exists in $project; removing stale worktree"
    dry git -C "$project" worktree remove "$wt_dir" 2>/dev/null || true
    dry git -C "$project" worktree prune 2>/dev/null || true
    return 0
  }

  if [ "$branch_tip" != "$merge_base" ]; then
    # Branch tip != merge base means branch has commits not in default branch
    return 0
  fi

  log "pruning $branch (merged into $default_branch)"

  # 1. Delete remote branch if it exists
  if git -C "$project" ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch"; then
    log "  deleting remote origin/$branch"
    dry git -C "$project" push origin --delete "$branch" 2>/dev/null || \
      warn "  failed to delete remote origin/$branch"
  fi

  # 2. Remove the worktree (this also cleans git's worktree metadata)
  if [ -d "$wt_dir" ]; then
    log "  removing worktree $wt_dir"
    dry git -C "$project" worktree remove "$wt_dir" 2>/dev/null || {
      warn "  worktree remove failed for $wt_dir; trying force"
      dry git -C "$project" worktree remove --force "$wt_dir" 2>/dev/null || \
        warn "  force remove also failed for $wt_dir"
    }
  fi

  # 3. Delete the local branch (git worktree remove may have done this;
  #    explicit delete as safety net)
  if git -C "$project" rev-parse --verify "$branch" >/dev/null 2>&1; then
    log "  deleting local branch $branch"
    dry git -C "$project" branch -D "$branch" 2>/dev/null || \
      warn "  failed to delete local branch $branch"
  fi

  # 4. Prune stale worktree admin files
  dry git -C "$project" worktree prune 2>/dev/null || true

  return 0
}

prune_project() {
  local name=$1 project_dir=$2
  local default_branch wt_dir

  default_branch=$(resolve_default_branch "$project_dir" 2>/dev/null) || {
    warn "cannot resolve default branch for $project_dir; skipping"
    return 0
  }

  wt_dir="$WORKTREE_BASE/$name"
  [ -d "$wt_dir" ] || return 0

  for child in "$wt_dir"/*/; do
    [ -d "$child" ] || continue
    [ -d "$child/.git" ] || [ -f "$child/.git" ] || continue
    prune_worktree "$child" "$project_dir" "$default_branch" && TOTAL_REMOVED=$((TOTAL_REMOVED + 1)) || true
  done
}

# ---- main ----

TOTAL_REMOVED=0

if [ ${#PROJECTS[@]} -gt 0 ]; then
  # Explicit projects given: resolve each by name from the registry
  while IFS=$'\t' read -r reg_name reg_path; do
    for wanted in "${PROJECTS[@]}"; do
      if [ "$reg_name" = "$wanted" ]; then
        prune_project "$reg_name" "$reg_path" || true
      fi
    done
  done < <(resolve_registered_projects 2>/dev/null || true)
else
  # No args: prune every registered project
  while IFS=$'\t' read -r reg_name reg_path; do
    [ -n "$reg_name" ] || continue
    prune_project "$reg_name" "$reg_path" || true
  done < <(resolve_registered_projects 2>/dev/null || true)
fi

log "done; $TOTAL_REMOVED worktree(s) processed"