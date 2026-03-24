# Git Troubleshooting & Disaster Recovery

> Comprehensive guide for recovering from common Git disasters, resolving
> complex conflicts, and repairing corrupted repositories.

---

## Table of Contents

- [Detached HEAD Recovery](#detached-head-recovery)
- [Force-Push Recovery](#force-push-recovery)
- [Rebase Conflict Resolution](#rebase-conflict-resolution)
- [Corrupted Repository Repair](#corrupted-repository-repair)
- [Lost Commits via Reflog](#lost-commits-via-reflog)
- [Merge vs Rebase Decision Tree](#merge-vs-rebase-decision-tree)
- [Submodule Sync Issues](#submodule-sync-issues)
- [Common Errors Reference](#common-errors-reference)
- [Preventive Measures](#preventive-measures)

---

## Detached HEAD Recovery

A detached HEAD means HEAD points directly at a commit, not a branch. Any new
commits made in this state become "orphaned" when you switch branches.

### Diagnosis

```bash
git status
# HEAD detached at a1b2c3d

git log --oneline -5
# Shows commits made while detached
```

### Recovery: Save Commits

```bash
# Option 1: Create a new branch at current position
git checkout -b rescue-branch

# Option 2: Create branch then merge into target
git checkout -b temp-rescue
git checkout main
git merge temp-rescue
git branch -d temp-rescue

# Option 3: Cherry-pick commits onto existing branch
git log --oneline              # note the SHAs of commits to save
git checkout main
git cherry-pick abc1234 def5678
```

### Recovery: Discard and Return to Branch

```bash
git checkout main              # or any branch name
# WARNING: commits made while detached are now only in reflog
```

### Common Causes

| Cause | Prevention |
|---|---|
| `git checkout <sha>` | Use `git switch --detach <sha>` for intentional detach |
| `git checkout v1.0` (tag) | Use `git switch -c work-on-v1 v1.0` to create branch |
| Submodule checkout | Normal; submodules are always detached |
| Rebase in progress | Complete with `--continue` or `--abort` |

---

## Force-Push Recovery

Someone (maybe you) ran `git push --force` and overwrote shared history.

### Recovery from Local Machine (Pusher's Machine)

```bash
# The original commits still exist in local reflog
git reflog show origin/main
# a1b2c3d origin/main@{0}: update by push     ← new (forced)
# f4e5d6c origin/main@{1}: update by push     ← old (what was there)

# Reset remote-tracking branch to old state
git push --force-with-lease origin f4e5d6c:main
```

### Recovery from Another Developer's Machine

```bash
# Their local still has the old commits
git fetch origin

# Check what diverged
git log --oneline origin/main..main

# Force-push the correct history back
git push --force-with-lease origin main

# If their local is ahead, they can restore:
git push --force-with-lease origin HEAD:main
```

### Recovery from GitHub (if available)

```bash
# GitHub retains refs for ~30 days after force-push
# Check the "pushed" events in the activity feed
# Or use the API to find dangling commits

# If you know the SHA:
git fetch origin
git branch recovery <sha>
```

### Prevention

```bash
# Always use --force-with-lease instead of --force
git push --force-with-lease origin feature

# Protect branches on the server
# GitHub: Settings → Branches → Branch protection rules
# - Require pull request reviews
# - Restrict force pushes

# Alias for safety
git config --global alias.pushf "push --force-with-lease"
```

---

## Rebase Conflict Resolution

### Basic Conflict Resolution During Rebase

```bash
git rebase main
# CONFLICT in src/auth.ts

# 1. See which files have conflicts
git status
# both modified: src/auth.ts

# 2. Resolve conflicts
# Edit files, removing <<<<<<< / ======= / >>>>>>> markers
# Or use a merge tool:
git mergetool

# 3. Stage resolved files
git add src/auth.ts

# 4. Continue rebase
git rebase --continue

# At any point, abort to return to pre-rebase state:
git rebase --abort
```

### Complex Multi-Commit Rebase Conflicts

When many commits conflict, the same file may conflict repeatedly:

```bash
# Strategy 1: Resolve as you go
git rebase main
# Resolve conflict #1 in src/auth.ts
git add src/auth.ts && git rebase --continue
# Resolve conflict #2 in src/auth.ts (different commit)
git add src/auth.ts && git rebase --continue
# ...repeat

# Strategy 2: Use rerere to auto-resolve recurring conflicts
git config rerere.enabled true
# First rebase: resolve manually (rerere records)
# Future rebases: same conflicts auto-resolved
```

### Rebase onto with Precision

```bash
# Rebase only specific commits from feature onto main
# (when feature branched from develop, not main)
git rebase --onto main develop feature

# Visual:
# Before: main---develop---feature
# After:  main---feature (only feature's commits moved)
```

### Skip Problematic Commits

```bash
# If a commit is no longer needed (e.g., already merged via another path)
git rebase --continue   # after resolving as empty
# Or:
git rebase --skip       # skip this commit entirely
```

### Undo a Completed Rebase

```bash
# Immediately after rebase
git reflog
# abc1234 HEAD@{0}: rebase (finish): ...
# def5678 HEAD@{1}: rebase (start): ...
# ghi9012 HEAD@{2}: commit: my last real commit   ← want this

git reset --hard HEAD@{2}
# Or use the pre-rebase backup:
git reset --hard ORIG_HEAD
```

---

## Corrupted Repository Repair

### Diagnosis

```bash
# Full integrity check
git fsck --full --strict
# Reports: missing objects, dangling commits, broken links

# Quick check
git fsck --no-full

# Check specific ref
git rev-parse --verify HEAD
git rev-parse --verify main
```

### Step-by-Step Repair

```bash
# 1. BACKUP FIRST
cp -r .git .git-backup-$(date +%Y%m%d_%H%M%S)

# 2. Identify the problem
git fsck --full 2>&1 | tee fsck-report.txt

# 3. For missing objects — fetch from remote
git fetch origin
# This re-downloads objects the remote has

# 4. For broken refs — reset to known good state
git reflog                        # find last known good commit
git update-ref refs/heads/main <good-sha>

# 5. For corrupted pack files
cd .git/objects/pack
# Move corrupt .pack and .idx files aside
git unpack-objects < good-pack.pack   # if you have backups
# Or re-fetch:
git fetch --all

# 6. Re-pack and garbage collect
git repack -a -d
git gc --aggressive --prune=now

# 7. Verify repair
git fsck --full --strict
```

### Recover from a Completely Broken Repo

```bash
# Last resort: rebuild from remote
mv .git .git-broken
git init
git remote add origin <url>
git fetch origin
git checkout -b main origin/main

# Salvage local-only work from broken repo
# Look for loose objects in .git-broken/objects/
find .git-broken/objects -type f | head -20
```

### Corrupted Index

```bash
# Symptoms: "index file is corrupt", strange staging behavior
rm .git/index
git reset                # rebuilds index from HEAD
# Or:
git read-tree HEAD       # rebuild index from tree
```

### Repair Scenarios

| Symptom | Likely Cause | Fix |
|---|---|---|
| "fatal: bad object HEAD" | Corrupted HEAD ref | `git update-ref HEAD <sha>` from reflog |
| "error: object file is empty" | Disk corruption | Fetch from remote to re-download objects |
| "fatal: index file corrupt" | Interrupted write | `rm .git/index && git reset` |
| "error: packfile is truncated" | Incomplete transfer | `git repack -a -d` after fetching |
| "loose object is corrupt" | Disk errors | Remove file, fetch from remote |

---

## Lost Commits via Reflog

The reflog records every HEAD and branch movement for 90 days (30 for
unreachable commits).

### Find Lost Commits

```bash
# Show all HEAD movements
git reflog

# Show reflog for a specific branch
git reflog show feature-branch

# Search reflog entries by message
git reflog --grep-reflog="commit: feat: auth"

# Show with timestamps
git reflog --date=iso

# Show reflog for stash
git reflog show stash
```

### Recovery Scenarios

```bash
# After accidental `git reset --hard`
git reflog
# abc1234 HEAD@{0}: reset: moving to HEAD~3    ← this is the problem
# def5678 HEAD@{1}: commit: important work      ← this is what we lost
git reset --hard def5678

# After deleting a branch
git reflog | grep "checkout: moving from deleted-branch"
# Or:
git reflog --all | grep deleted-branch
git checkout -b deleted-branch <sha>

# After bad rebase
git reflog
# Find the entry just before "rebase (start)"
git reset --hard HEAD@{N}

# Lost stash
git fsck --unreachable | grep commit
git show <sha>                       # inspect each
git stash apply <sha>                # if it's your stash

# After gc removed a commit (within expire window)
git fsck --lost-found
# Creates .git/lost-found/commit/ with recovered commit SHAs
ls .git/lost-found/commit/
git show <sha>
```

### Extend Reflog Retention

```bash
# Keep reflog entries longer (default: 90 days reachable, 30 unreachable)
git config --global gc.reflogExpire "180 days"
git config --global gc.reflogExpireUnreachable "90 days"
```

---

## Merge vs Rebase Decision Tree

Use this decision tree to choose between merge and rebase:

```
Is this a shared/public branch (main, develop)?
├── YES → Always MERGE (never rebase shared branches)
│         git merge --no-ff feature-branch
└── NO (personal feature branch)
    │
    Has the branch been pushed and shared with others?
    ├── YES → MERGE (or coordinate rebase with team)
    │         git merge main           # bring in updates
    └── NO (local only)
        │
        Do you want a clean, linear history?
        ├── YES → REBASE
        │         git rebase main       # replay on top of main
        │         # Then merge with --no-ff for explicit merge commit
        └── NO → MERGE
                  git merge main        # preserve branch topology
```

### Comparison

| Aspect | Merge | Rebase |
|---|---|---|
| History | Preserves branch topology | Creates linear history |
| Conflicts | Resolve once | May resolve per-commit |
| Shared branches | Safe | **Dangerous** — rewrites history |
| Bisect | Harder (merge commits) | Easier (linear) |
| Revert | Easy (revert merge commit) | Harder (find range) |
| Audit trail | Complete | Altered (rewritten SHAs) |

### Team Policies

**Rebase-and-merge (common in open source):**

```bash
# Developer workflow:
git checkout feature
git rebase main                    # rebase onto latest main
git push --force-with-lease        # update PR branch
# Maintainer merges PR (fast-forward or squash)
```

**Merge-only (common in enterprise):**

```bash
# Developer workflow:
git checkout feature
git merge main                     # bring in updates
git push                           # update PR branch
# Maintainer merges PR (merge commit)
```

**Squash-and-merge (GitHub default):**

```bash
# All feature commits become one commit on main
# Simple, but loses granular history
# Good for small features, bad for large PRs
```

---

## Submodule Sync Issues

### Submodule Not Initialized

```bash
# After cloning a repo with submodules
git submodule update --init --recursive

# If specific submodule fails
git submodule init vendor/library
git submodule update vendor/library
```

### Submodule Points to Wrong Commit

```bash
# Check current state
git submodule status
# -abc1234 vendor/lib (v1.0-3-gabc1234)   ← minus means not initialized
# +def5678 vendor/lib (v1.1)               ← plus means different commit

# Reset to the commit recorded in parent repo
git submodule update --force vendor/lib

# Update to latest upstream
git submodule update --remote vendor/lib
git add vendor/lib
git commit -m "chore: update vendor/lib submodule"
```

### Submodule URL Changed

```bash
# Update URL in .gitmodules
git config -f .gitmodules submodule.vendor/lib.url https://new-url.git

# Sync the change
git submodule sync
git submodule update --init
```

### Detached HEAD in Submodule

This is normal — submodules always checkout a specific commit, not a branch.

```bash
# To work within a submodule on a branch:
cd vendor/lib
git checkout main
# Make changes, commit, push
cd ../..
git add vendor/lib
git commit -m "chore: update submodule to latest main"
```

### Submodule Conflicts During Merge

```bash
# Conflict shows different commit SHAs for the submodule
git diff vendor/lib
# Shows: <<<<<<< HEAD / abc1234 vs def5678

# Resolution: choose which commit the submodule should point to
cd vendor/lib
git checkout <desired-sha>
cd ../..
git add vendor/lib
git merge --continue
```

### Remove a Submodule Completely

```bash
# 1. Remove from .gitmodules
git config -f .gitmodules --remove-section submodule.vendor/lib

# 2. Remove from .git/config
git config --remove-section submodule.vendor/lib

# 3. Remove the submodule directory and cached entry
git rm --cached vendor/lib
rm -rf vendor/lib
rm -rf .git/modules/vendor/lib

# 4. Commit
git add .gitmodules
git commit -m "chore: remove vendor/lib submodule"
```

---

## Common Errors Reference

### "fatal: refusing to merge unrelated histories"

```bash
# When merging repos that share no common ancestor
git merge --allow-unrelated-histories other-branch

# Common with: monorepo migrations, importing external repos
```

### "error: failed to push some refs"

```bash
# Remote has commits you don't have locally
git pull --rebase origin main    # rebase local on top of remote
git push origin main

# Or if you know your version is correct:
git push --force-with-lease origin main
```

### "You have divergent branches"

```bash
# Git 2.27+ warns about pull strategy
# Set a default:
git config --global pull.rebase true    # rebase on pull
# Or:
git config --global pull.rebase false   # merge on pull (classic)
```

### "CONFLICT (modify/delete)"

```bash
# A file was modified in one branch and deleted in another
# To keep the file:
git add <file>
git merge --continue

# To accept the deletion:
git rm <file>
git merge --continue
```

### "error: Your local changes would be overwritten"

```bash
# Stash first
git stash push -m "WIP before merge"
git merge main
git stash pop

# Or commit your changes first
git add . && git commit -m "WIP"
git merge main
```

### "fatal: Not possible to fast-forward, aborting"

```bash
# When pull.ff=only is set but histories diverged
git pull --rebase origin main
# Or:
git pull --no-ff origin main
```

---

## Preventive Measures

### Safety Configuration

```bash
# Require --force-with-lease for all force pushes
git config --global alias.pushf "push --force-with-lease"

# Warn before pushing to main/master
# (Use a pre-push hook — see assets/hooks/pre-commit)

# Extend reflog retention
git config --global gc.reflogExpire "180 days"
git config --global gc.reflogExpireUnreachable "90 days"

# Default to rebase on pull (prevents accidental merge commits)
git config --global pull.rebase true

# Show diffstat on merge
git config --global merge.stat true

# Enable rerere
git config --global rerere.enabled true
```

### Backup Practices

```bash
# Before dangerous operations
git stash push -m "backup before rewrite"
git tag BACKUP-$(date +%Y%m%d) HEAD

# Backup .git directory before filter-repo
cp -r .git .git-backup-$(date +%Y%m%d_%H%M%S)

# Mirror clone for full backup
git clone --mirror <url> repo-backup.git
```

### Regular Maintenance

```bash
# Check repo health monthly
git fsck --full

# Optimize storage
git gc --auto
git maintenance start      # Git 2.29+ scheduled maintenance

# Clean stale remote branches
git fetch --prune origin
git remote prune origin
```
