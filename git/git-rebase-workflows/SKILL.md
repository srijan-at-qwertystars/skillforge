---
name: git-rebase-workflows
description: >
  Use when user asks about git rebase, interactive rebase, squashing commits, cleaning commit history,
  rebase vs merge, fixup commits, autosquash, rebase onto, or resolving rebase conflicts.
  Do NOT use for basic git add/commit/push, git branching strategy discussions, or GitHub PR workflows.
---

# Git Rebase Workflows

## When to Rebase vs Merge

**Use rebase when:**
- Working on a private/local feature branch nobody else has pulled
- Cleaning up commit history before opening a PR
- Updating a feature branch with latest changes from main
- Squashing WIP commits into logical units

**Use merge when:**
- Integrating shared/release branches
- Preserving full audit trail of when branches were combined
- Multiple developers collaborate on the same branch
- Regulated or open-source projects requiring traceability

**Decision tree:**
1. Has anyone else pulled this branch? → **merge**
2. Is this a public/shared branch (main, develop, release)? → **merge**
3. Is this your private feature branch? → **rebase**
4. Do you need to preserve the exact merge point? → **merge**
5. Do you want a clean linear history for review? → **rebase**

**Hybrid rule:** Rebase locally, merge when integrating into shared branches. "Rebase for yourself, merge for your team."

## Interactive Rebase

Start interactive rebase for the last N commits:
```sh
git rebase -i HEAD~N
```

Or rebase onto a branch:
```sh
git rebase -i main
```

### Commands in the todo list

| Command   | Short | Effect |
|-----------|-------|--------|
| `pick`    | `p`   | Keep commit as-is |
| `reword`  | `r`   | Keep commit, edit its message |
| `edit`    | `e`   | Pause after applying commit (amend content or split) |
| `squash`  | `s`   | Meld into previous commit, combine messages |
| `fixup`   | `f`   | Meld into previous commit, discard this message |
| `drop`    | `d`   | Remove commit entirely |
| `exec`    | `x`   | Run a shell command after the commit |

### Common interactive rebase scenarios

**Squash last 3 commits into one:**
```sh
git rebase -i HEAD~3
# Change "pick" to "squash" (or "s") for the 2nd and 3rd commits
# Save, then edit the combined commit message
```

**Reword a commit message:**
```sh
git rebase -i HEAD~5
# Change "pick" to "reword" for the target commit
# Save, then edit the message when prompted
```

**Reorder commits:**
```sh
git rebase -i HEAD~4
# Rearrange the lines in the editor to the desired order
```

**Split a commit into two:**
```sh
git rebase -i HEAD~3
# Change "pick" to "edit" for the target commit
# When rebase pauses:
git reset HEAD~1
git add file1.py
git commit -m "First logical change"
git add file2.py
git commit -m "Second logical change"
git rebase --continue
```

**Drop a commit:**
```sh
git rebase -i HEAD~5
# Delete the line or change "pick" to "drop"
```

## Autosquash with fixup!/squash! Commits

Create a fixup commit that auto-targets a previous commit:
```sh
git commit --fixup <commit-hash>
# Creates: "fixup! <original commit message>"
```

Create a squash commit (combines messages):
```sh
git commit --squash <commit-hash>
# Creates: "squash! <original commit message>"
```

Apply autosquash during interactive rebase:
```sh
git rebase -i --autosquash main
```
Git automatically reorders fixup!/squash! commits next to their targets and sets the correct action.

**Amend-style fixup (Git 2.32+):**
```sh
git commit --fixup=amend:<commit-hash>
# Replaces both content AND message of the target commit
```

**Enable autosquash by default:**
```sh
git config --global rebase.autoSquash true
```
With this set, `git rebase -i` always behaves as if `--autosquash` was passed.

### Typical fixup workflow

```sh
# 1. Make initial commits on feature branch
git commit -m "Add user validation"
git commit -m "Add user API endpoint"

# 2. Discover a bug in the validation commit
# Fix the bug, then:
git add src/validation.py
git commit --fixup <validation-commit-hash>

# 3. Clean up before PR
git rebase -i --autosquash main
# The fixup is auto-placed and folded into the original commit
```

## Rebase Onto (Changing Branch Base)

Move commits from one base to another:
```sh
git rebase --onto <new-base> <old-base> <branch>
```

**Move feature branch from develop to main:**
```sh
git rebase --onto main develop feature-branch
# Replays commits in develop..feature-branch onto main
```

**Remove a range of commits:**
```sh
# Remove commits between commitA and commitB
git rebase --onto commitA commitB
```

**Detach a sub-feature from its parent feature:**
```sh
# sub-feature was branched from feature, move it to main
git rebase --onto main feature sub-feature
```

## Conflict Resolution During Rebase

Rebase replays commits one at a time. Conflicts can occur at each step.

### Step-by-step resolution

```sh
# 1. Start rebase
git rebase main

# 2. Conflict occurs — git pauses and reports conflicted files
git status
# Shows files with conflicts under "Unmerged paths"

# 3. Open each conflicted file, resolve the conflict markers
#    <<<<<<< HEAD
#    (content from the base)
#    =======
#    (content from your commit)
#    >>>>>>> commit-message

# 4. Stage resolved files
git add <resolved-file>

# 5. Continue rebase
git rebase --continue

# 6. Repeat steps 2-5 for each conflicting commit
```

### Escape hatches

```sh
# Skip the current commit entirely
git rebase --skip

# Abort and return to pre-rebase state
git rebase --abort
```

### Use a merge tool

```sh
git mergetool
# Opens configured merge tool for each conflict
git rebase --continue
```

## Rebase with --exec (Run Tests Per Commit)

Run a command after each commit is applied:
```sh
git rebase -i main --exec "make test"
```

If any command fails, the rebase pauses. Fix the issue, then continue:
```sh
git rebase --continue
```

**Run linter and tests on each commit:**
```sh
git rebase -i main --exec "npm run lint && npm test"
```

**Ensure every commit compiles:**
```sh
git rebase -i HEAD~10 --exec "cargo build"
```

**Auto-retry failed exec on continue (Git 2.21+):**
```sh
git config --global rebase.rescheduleFailedExec true
```
With this set, the failed `--exec` command re-runs automatically after `git rebase --continue`.

## Recovering from Rebase Mistakes

### Use reflog to undo a rebase

```sh
# 1. View reflog to find the pre-rebase state
git reflog
# Look for the entry just before "rebase (start)"
# Example output:
#   a1b2c3d HEAD@{0}: rebase (finish): returning to refs/heads/feature
#   5e6f7g8 HEAD@{1}: rebase (pick): Add feature
#   9h0i1j2 HEAD@{2}: rebase (start): checkout main
#   abc1234 HEAD@{3}: commit: My last commit before rebase  <-- this one

# 2. Reset to the pre-rebase state
git reset --hard HEAD@{3}
```

### Use ORIG_HEAD (if no other operations since rebase)

```sh
git reset --hard ORIG_HEAD
```

### Create a safety branch before risky rebase

```sh
git branch backup-before-rebase
git rebase -i main
# If something goes wrong:
git reset --hard backup-before-rebase
```

### Create a safety tag

```sh
git tag pre-rebase-backup
git rebase -i main
# Recovery:
git reset --hard pre-rebase-backup
git tag -d pre-rebase-backup
```

## Golden Rules

1. **Never rebase public/shared branches.** Rebasing rewrites commit hashes. If others based work on those commits, their history breaks.
2. **Only rebase commits that have not been pushed.** If already pushed, only rebase if you are the sole contributor to that branch.
3. **Use `--force-with-lease` after rebasing a pushed branch.** Never use bare `--force`:
   ```sh
   git push --force-with-lease origin feature-branch
   ```
4. **Communicate with your team** if you must force-push a rebased branch.
5. **Make a backup** before complex rebases — a branch or tag costs nothing.
6. **Keep rebases small.** Rebase frequently against the target branch to minimize conflict surface.
7. **Test after rebasing.** Rebase can silently introduce logical conflicts that compile but behave incorrectly.

## Common Scenarios

### Update feature branch with latest main

```sh
git checkout feature-branch
git fetch origin
git rebase origin/main
# Resolve any conflicts, then:
git push --force-with-lease origin feature-branch
```

### Clean up a messy feature branch before PR

```sh
git checkout feature-branch
git rebase -i main
# Squash WIP commits, reword messages, drop debugging commits
git push --force-with-lease origin feature-branch
```

### Rebase pull with auto-stash

```sh
git pull --rebase --autostash
# Stashes local changes, pulls with rebase, re-applies stash
```

### Rebase preserving merge commits

```sh
git rebase --rebase-merges main
# Recreates the merge topology instead of linearizing
```

### Absorb changes into prior commits automatically

```sh
# Using git-absorb (install separately)
git absorb --and-rebase
# Automatically creates fixup commits and runs autosquash
```

## Configuration Options

### Recommended global config

```sh
# Always rebase on pull instead of merge
git config --global pull.rebase true

# Auto-stash before rebase, re-apply after
git config --global rebase.autoStash true

# Enable autosquash by default for interactive rebase
git config --global rebase.autoSquash true

# Retry failed --exec commands after continue
git config --global rebase.rescheduleFailedExec true

# Warn if commits are accidentally dropped during interactive rebase
git config --global rebase.missingCommitsCheck warn

# Remember conflict resolutions for reuse
git config --global rerere.enabled true

# Use abbreviated commands in interactive rebase todo
git config --global rebase.abbreviateCommands true
```

### rerere (Reuse Recorded Resolution)

Enable rerere to auto-resolve repeated conflicts:
```sh
git config --global rerere.enabled true
```

When you resolve a conflict, Git records the resolution. On future rebases with the same conflict, Git applies the recorded fix automatically.

Manage recorded resolutions:
```sh
# List recorded resolutions
git rerere status

# Forget a specific resolution
git rerere forget <pathspec>

# Clear all recorded resolutions
git rerere gc
```

### Check current rebase-related config

```sh
git config --global --get-regexp 'rebase\|rerere\|pull\.rebase'
```
