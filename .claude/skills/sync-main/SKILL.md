````skill
---
name: sync-main
description: "Rebuild origin/main from upstream/main + selected personal PR branches via squash-merge. Runs fully automatically when no branches are specified — auto-detects all eligible origin branches. Triggers on 'sync main', 'sync origin/main', 'rebuild main', 'sync PR branches', 'sync-main'."
---

# Sync Main

Rebuild `origin/main` as `upstream/main` + a chosen set of personal PR branches, each squash-merged in order. All git work happens in an isolated worktree — the current directory is never modified mid-run.

## Phase 1: Pre-flight

### Check if already applied

```bash
test -f sync-main.sh && echo "SCRIPT=exists" || echo "SCRIPT=missing"
```

- `SCRIPT=exists` → skip Phase 2.
- `SCRIPT=missing` → proceed to Phase 2.

## Phase 2: Apply Code Changes

Run the skills engine to deploy `sync-main.sh` to the project root:

```bash
npx tsx scripts/apply-skill.ts sync-main
chmod +x sync-main.sh
```

Confirm the file is executable:

```bash
test -x sync-main.sh && echo "OK" || echo "FAIL"
```

## Phase 3: Gather Branches (optional)

If the user specified explicit branches, pass them directly to the script in Phase 4.

If no branches were specified, the script auto-detects them — **no user input needed**. It fetches all `origin/` branches and excludes:
- `main`
- `HEAD`
- Any branch whose name starts with the exclusion prefix (default: `no_pr`, overridable via `SYNC_EXCLUDE_PREFIX` env var)

The user controls exclusions simply by naming branches with the prefix. Example:
- `no_pr_old-experiment` → excluded
- `feat/my-feature` → included

If the user wants to check what would be auto-detected before running:

```bash
git fetch origin
git branch -r | grep '^  origin/' | sed 's|  origin/||' | grep -v '^HEAD' | grep -v '^main$' | grep -v '^no_pr'
```

Also check for stale worktree artifacts:

```bash
git worktree list | grep sync-main-worktree || echo "CLEAN"
```

If a stale worktree exists, offer to clean it:

```bash
git worktree remove --force .git/sync-main-worktree 2>/dev/null || true
git branch -D _sync-main-tmp 2>/dev/null || true
```

## Phase 4: Run Sync

Without arguments (fully automatic — auto-detects all eligible branches):

```bash
./sync-main.sh
```

With explicit branches (manual control over order and selection):

```bash
./sync-main.sh branch1 branch2 ...
```

Watch the output carefully:

- **Success** ends with `Done. origin/main is up to date` → Phase 5.
- **Conflict** shows the red conflict box → Phase 4a.

### Phase 4a: Conflict Resolution

The script stops and prints the conflicting files and the worktree path (`.git/sync-main-worktree/`). Guide the user:

1. Open conflicting files inside `.git/sync-main-worktree/` and resolve markers.
2. Stage resolved files:
   ```bash
   git -C .git/sync-main-worktree add <file>
   ```
3. Resume:
   ```bash
   ./sync-main.sh --continue
   ```

If the user wants to give up:

```bash
./sync-main.sh --abort
```

Repeat Phase 4a until all branches are processed or the user aborts.

## Phase 5: Verify

```bash
git log origin/main --oneline -8
```

Show the user the top commits. The expected sequence (newest first) is:

1. `chore: update sync-main.sh [skip ci]` — script self-update (if changed)
2. `chore: reapply personal customizations [skip ci]` — personal layer (skills, local tools, etc.)
3. One squash commit per PR branch (in the order provided)
4. `upstream/main` HEAD commit

The personal layer commit (#2) captures everything that was on `origin/main` but not in `upstream/main` or the PR branches — skills-applied file changes (`src/channels/telegram.ts`, `src/index.ts`, etc.), local tools, or any other non-upstreamed edits. This ensures they survive every sync automatically.

Confirm success and remind the user that `git pull origin main` will now work cleanly (local `main` ref was already advanced by the script).

## Troubleshooting

### "untracked file would be overwritten" on git pull
This should not happen after the script runs — it advances the local `main` ref automatically via `git update-ref`. If it still occurs, the fix is:

```bash
git fetch origin main
git update-ref refs/heads/main FETCH_HEAD
git pull origin main
```

### Branch subject shows upstream commit message
The branch has no commits of its own beyond `upstream/main`. Check:

```bash
git log origin/<branch> --no-merges --not upstream/main --oneline
```

If empty, the branch is fully merged into upstream. It can be removed from the list.

### Personal layer patch did not apply cleanly
This happens when a PR branch modified the same lines that a personal customization also touched. Inspect the diff:

```bash
git diff _sync-main-tmp origin/main
```

Options:
1. Re-apply the affected skill manually in the worktree:
   ```bash
   cd .git/sync-main-worktree
   npx tsx ../../scripts/apply-skill.ts <skill-name>
   git add -A && git commit -m "chore: reapply personal customizations [skip ci]"
   cd ../..
   ./sync-main.sh --continue   # not applicable here — push directly:
   git -C .git/sync-main-worktree push origin HEAD:main --force
   git fetch origin main && git update-ref refs/heads/main FETCH_HEAD
   ```
2. Or abort and fix the personal layer by committing the desired state to `origin/main` before re-running sync.

### Stale worktree from a previous aborted run
```bash
git worktree remove --force .git/sync-main-worktree
git branch -D _sync-main-tmp
rm -f .git/SYNC_MAIN_STATE
```
Then re-run `./sync-main.sh $BRANCHES`.
````
