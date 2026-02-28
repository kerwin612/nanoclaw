#!/usr/bin/env bash
# sync-main.sh — Rebuild origin/main from upstream/main + selected PR branches.
#
# Usage:
#   ./sync-main.sh                     # auto-detect all eligible origin branches
#   ./sync-main.sh branch1 [branch2 ...]   # explicit branch list
#   ./sync-main.sh --continue              # resume after resolving a conflict
#   ./sync-main.sh --abort                 # discard and clean up
#
# What it does:
#   1. Ensures 'upstream' remote exists (auto-adds if missing)
#   2. Fetches upstream/main and origin
#   3. In an isolated git worktree, squash-merges each given branch on top of
#      upstream/main (one commit per branch, conflict-resolved if needed)
#   4. Copies this script into the worktree so it persists on origin/main
#   5. Force-pushes the result to origin/main
#
# The current working directory is never touched — all git operations happen
# inside .git/sync-main-worktree/ so this script cannot be "deleted mid-run".

set -euo pipefail

UPSTREAM_URL="https://github.com/qwibitai/nanoclaw.git"
WORKTREE_DIR=".git/sync-main-worktree"
TMP_BRANCH="_sync-main-tmp"
STATE_FILE=".git/SYNC_MAIN_STATE"

# Branches whose names start with this prefix are excluded from auto-detection.
# Override via environment: SYNC_EXCLUDE_PREFIX=skip_ ./sync-main.sh
EXCLUDE_PREFIX="${SYNC_EXCLUDE_PREFIX:-no_pr}"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[sync]${NC} $*"; }
ok()      { echo -e "${GREEN}[sync]${NC} $*"; }
warn()    { echo -e "${YELLOW}[sync]${NC} $*"; }
die()     { echo -e "${RED}[sync] ERROR:${NC} $*" >&2; exit 1; }

# ── State helpers ─────────────────────────────────────────────────────────────
save_state() {
  local idx="$1"; shift
  printf 'BRANCH_IDX=%s\nBRANCHES=%s\n' "$idx" "$*" > "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "No sync in progress (state file missing). Nothing to continue."
  # shellcheck source=/dev/null
  source "$STATE_FILE"
}

# ── Setup / teardown ──────────────────────────────────────────────────────────
ensure_upstream() {
  if ! git remote get-url upstream &>/dev/null; then
    info "Remote 'upstream' not found — adding: $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
    ok "Added upstream remote."
  fi
}

setup_worktree() {
  if git worktree list | grep -qF "$WORKTREE_DIR"; then
    warn "Stale worktree found at $WORKTREE_DIR — removing."
    git worktree remove --force "$WORKTREE_DIR"
  fi
  git branch -D "$TMP_BRANCH" 2>/dev/null || true
  info "Creating worktree from upstream/main..."
  git worktree add "$WORKTREE_DIR" -b "$TMP_BRANCH" upstream/main
}

cleanup() {
  info "Cleaning up worktree..."
  git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
  git branch -D "$TMP_BRANCH" 2>/dev/null || true
  rm -f "$STATE_FILE"
}

# ── Core logic ────────────────────────────────────────────────────────────────

# List all origin branches eligible for auto-sync:
#   - excludes 'main' and 'HEAD'
#   - excludes branches starting with $EXCLUDE_PREFIX
auto_branches() {
  info "[DEBUG] Fetching/pruning all origin branches..." >&2
  git fetch origin --prune >&2
  git fetch origin 'refs/heads/*:refs/remotes/origin/*' >&2
  info "[DEBUG] Listing all remote branches:" >&2
  git branch -r >&2
  info "[DEBUG] Filtering eligible branches..." >&2
  git branch -r \
    | grep '^  origin/' \
    | sed 's|  origin/||' \
    | grep -v '^HEAD' \
    | grep -v '^main$' \
    | grep -v "^${EXCLUDE_PREFIX}" \
    | tr -d ' '
}

# Get the one-line subject of the most recent commit on $branch that is NOT
# already in upstream/main (i.e. the branch's own work, not inherited history).
# Falls back to the branch name if no such commit exists.
branch_subject() {
  local branch="$1"
  local subject
  subject=$(git log "origin/${branch}" --no-merges -1 --not upstream/main --format="%s")
  echo "${subject:-"merge ${branch}"}"
}

apply_branch() {
  local branch="$1"
  local subject
  subject=$(branch_subject "$branch")
  info "  merge --squash origin/${branch}  ${BOLD}${subject}${NC}"
  git -C "$WORKTREE_DIR" merge --squash "origin/${branch}"
  git -C "$WORKTREE_DIR" commit -m "${subject}"
}

finalize() {
  # ── Step 1: Reapply personal customizations ──────────────────────────────
  # The diff between our freshly rebuilt base and the current origin/main is
  # exactly the "personal layer": skill file changes, local tools, any edits
  # that live on origin/main but will never be upstreamed.
  if git rev-parse --verify origin/main &>/dev/null; then
    personal_patch=$(git diff "${TMP_BRANCH}" origin/main 2>/dev/null || true)
    if [[ -n "$personal_patch" ]]; then
      info "Reapplying personal customizations from origin/main..."
      if echo "$personal_patch" | git -C "$WORKTREE_DIR" apply --allow-empty; then
        git -C "$WORKTREE_DIR" add -A
        git -C "$WORKTREE_DIR" diff --cached --quiet || \
          git -C "$WORKTREE_DIR" commit -m "chore: reapply personal customizations [skip ci]"
      else
        warn "Personal layer patch did not apply cleanly — skipping. Review manually:"
        warn "  git diff ${TMP_BRANCH} origin/main"
      fi
    else
      info "No personal customizations to reapply."
    fi
  fi

  # ── Step 2: Keep this script up to date ──────────────────────────────────
  # Always overwrite with the current working copy so edits to the script
  # propagate to origin/main on the next sync.
  local script_name
  script_name="$(basename "$0")"
  cp "$0" "$WORKTREE_DIR/$script_name"
  git -C "$WORKTREE_DIR" add "$script_name"
  git -C "$WORKTREE_DIR" diff --cached --quiet || \
    git -C "$WORKTREE_DIR" commit -m "chore: update ${script_name} [skip ci]"

  # ── Step 3: Push ─────────────────────────────────────────────────────────
  info "Force-pushing to origin/main..."
  git -C "$WORKTREE_DIR" push origin HEAD:main --force

  # Advance the local 'main' ref to match what we just pushed, without
  # touching the working tree.  This prevents "untracked file would be
  # overwritten" errors on the next 'git pull origin main'.
  git fetch origin main
  git update-ref refs/heads/main FETCH_HEAD
  ok "Done. origin/main is up to date (local main ref advanced)."
  cleanup
}

# Apply branches starting from index $start (0-based) out of the $branches array
apply_from() {
  local start="$1"; shift
  local branches=("$@")
  local total="${#branches[@]}"

  for (( i=start; i<total; i++ )); do
    local branch="${branches[$i]}"

    if ! apply_branch "$branch"; then
      # Conflict — persist state and guide the user
      save_state "$i" "${branches[@]}"

      local conflicted
      conflicted=$(git -C "$WORKTREE_DIR" diff --name-only --diff-filter=U | tr '\n' ' ')

      echo ""
      echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
      echo -e "${RED}║  CONFLICT — squash merge stopped at: ${branch}${NC}"
      echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "${YELLOW}Conflicting files:${NC} ${conflicted}"
      echo ""
      echo -e "${BOLD}Resolve, then:${NC}"
      echo -e "  1. Edit conflicting files inside:  ${BLUE}${WORKTREE_DIR}/${NC}"
      echo -e "  2. Stage them:  ${BLUE}git -C ${WORKTREE_DIR} add <file>${NC}"
      echo -e "  3. Continue:    ${BLUE}./$(basename "$0") --continue${NC}"
      echo ""
      echo -e "  To give up:     ${BLUE}./$(basename "$0") --abort${NC}"
      echo ""
      exit 1
    fi
  done

  finalize
}

# ── Entry point ───────────────────────────────────────────────────────────────
[[ -d ".git" ]] || die "Run this script from the repository root."

case "${1:-}" in

  --continue)
    load_state
    # shellcheck disable=SC2154
    IFS=' ' read -r -a all_branches <<< "$BRANCHES"
    # shellcheck disable=SC2154
    resume_idx="$BRANCH_IDX"

    [[ -d "$WORKTREE_DIR" ]] || die "Worktree missing at $WORKTREE_DIR — cannot continue. Run --abort and start over."

    info "Committing resolved merge for '${all_branches[$resume_idx]}'..."
    subject=$(branch_subject "${all_branches[$resume_idx]}")
    git -C "$WORKTREE_DIR" commit -m "${subject}"

    apply_from $(( resume_idx + 1 )) "${all_branches[@]}"
    ;;

  --abort)
    warn "Aborting..."
    if [[ -d "$WORKTREE_DIR" ]]; then
      git -C "$WORKTREE_DIR" reset --hard HEAD 2>/dev/null || true
      git -C "$WORKTREE_DIR" clean -fd 2>/dev/null || true
    fi
    cleanup
    ok "Aborted. Working tree is untouched."
    ;;

  --help|-h)
    grep '^#' "$0" | sed 's/^# \?//'
    ;;

  --*)
    die "Unknown option: $1"
    ;;

  "")
    info "No branches specified — auto-detecting from origin (excluding prefix '${EXCLUDE_PREFIX}')..."
    info "[DEBUG] Entry point: ensure_upstream"
    ensure_upstream

    info "[DEBUG] Entry point: fetch upstream"
    git fetch upstream
    info "[DEBUG] Entry point: fetch origin"
    git fetch origin

    info "[DEBUG] Entry point: call auto_branches"
    auto_list=$(auto_branches)
    info "[DEBUG] Entry point: after auto_branches, raw auto_list: '$auto_list'"
    echo "[DEBUG] Eligible branches (auto_list):"
    echo "$auto_list"
    if [[ -z "$auto_list" ]]; then
      info "[DEBUG] Entry point: auto_list is empty, about to die"
      die "No eligible branches found on origin (all are main, HEAD, or start with '${EXCLUDE_PREFIX}')."
    fi

    # Build array from newline-separated list
    info "[DEBUG] Entry point: build auto_arr from auto_list"
    auto_arr=()
    while IFS= read -r b; do
      [[ -n "$b" ]] && auto_arr+=("$b")
    done <<< "$auto_list"

    info "[DEBUG] Entry point: built auto_arr: '${auto_arr[*]}'"
    info "Auto-detected ${#auto_arr[@]} branch(es): ${BOLD}${auto_arr[*]}${NC}"
    setup_worktree
    info "Merging ${#auto_arr[@]} branch(es) via squash."
    apply_from 0 "${auto_arr[@]}"
    ;;

  *)
    ensure_upstream

    info "Fetching upstream and origin..."
    git fetch upstream
    git fetch origin

    setup_worktree

    info "Merging ${#@} branch(es) via squash."
    apply_from 0 "$@"
    ;;

esac
