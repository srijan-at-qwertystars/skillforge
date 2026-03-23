---
name: git-advanced-techniques
description: |
  Use when user asks about git bisect, git worktree, git rerere, git filter-repo, sparse checkout, git subtree, git stash advanced usage, git blame, git log advanced queries, or Git internals (objects, refs, packfiles).
  Do NOT use for basic git rebase/merge (use git-rebase-workflows skill), GitHub Actions CI (use github-actions-workflows skill), or git hooks (use git-hooks-automation skill).
---

# Advanced Git Techniques

## Git Bisect — Binary Search for Bugs

Start a bisect session by marking known good and bad commits:

```bash
git bisect start
git bisect bad HEAD
git bisect good v1.2.0
# Git checks out a midpoint commit. Test it, then:
git bisect good   # if this commit is clean
git bisect bad    # if this commit has the bug
# Repeat until Git identifies the first bad commit.
```

### Automated Bisect with a Test Script

Pass any command that exits 0 for good, non-zero for bad:

```bash
git bisect start HEAD v1.2.0
git bisect run ./test-for-bug.sh
# Output:
# running './test-for-bug.sh'
# Bisecting: 3 revisions left to test after this (roughly 2 steps)
# abc1234 is the first bad commit
```

### Bisect Skip

Skip untestable commits (e.g., broken build):

```bash
git bisect skip                  # skip current commit
git bisect skip abc1234 def5678  # skip specific commits
```

Reset when finished:

```bash
git bisect reset
```

## Git Worktree — Multiple Working Trees

Check out a branch in a separate directory without cloning again:

```bash
git worktree add ../hotfix-branch hotfix/urgent
# Creates ../hotfix-branch linked to the same repo

git worktree list
# /home/user/project         abc1234 [main]
# /home/user/hotfix-branch   def5678 [hotfix/urgent]
```

### Create a New Branch in a Worktree

```bash
git worktree add -b feature/new-api ../new-api
```

### Remove a Worktree

```bash
git worktree remove ../hotfix-branch
git worktree prune  # clean up stale worktree references
```

Use cases: review PRs while keeping your working tree intact, run tests on one branch while developing on another, compare behavior across branches side-by-side.

## Git Rerere — Reuse Recorded Resolution

Enable rerere globally:

```bash
git config --global rerere.enabled true
```

When you resolve a merge conflict, Git records the resolution. Next time the same conflict appears (e.g., rebasing the same branch), Git applies it automatically:

```bash
git merge feature-branch
# CONFLICT in file.txt — resolve manually, then:
git add file.txt
git commit
# rerere records this resolution

# Later, same conflict during rebase:
git rebase main
# Resolved 'file.txt' using previous resolution.
```

### Manage Recorded Resolutions

```bash
git rerere status       # show files with recorded resolutions
git rerere diff         # show what rerere would apply
git rerere forget <file>  # forget a specific resolution
git rerere gc           # prune old resolutions (default: 60 days unused, 15 days used)
```

## Git Filter-Repo — History Rewriting

`git filter-repo` replaces `git filter-branch`. Install it separately (`pip install git-filter-repo`). Always operate on a fresh clone.

### Remove a File from All History

```bash
git clone --bare https://github.com/org/repo.git
cd repo.git
git filter-repo --path secrets.env --invert-paths
# All commits rewritten. secrets.env removed from every commit.
```

### Rename Paths Across History

```bash
git filter-repo --path-rename old-dir/:new-dir/
```

### Rewrite Author Info with Mailmap

Create a mailmap file:

```
Correct Name <correct@example.com> <old@example.com>
```

```bash
git filter-repo --mailmap my-mailmap
```

### Extract a Subdirectory into Its Own Repo

```bash
git filter-repo --subdirectory-filter src/component/
# src/component/ becomes the repo root. All other paths removed.
```

### Replace Sensitive Strings in Content

Create `replacements.txt`:

```
PASSWORD123==>***REDACTED***
```

```bash
git filter-repo --replace-text replacements.txt
```

After rewriting: run `git gc --prune=now --aggressive`, force-push, and have all collaborators reclone.

## Sparse Checkout — Work with Part of a Monorepo

### Set Up Sparse Checkout with Partial Clone

```bash
git clone --filter=blob:none --sparse https://github.com/org/monorepo.git
cd monorepo
git sparse-checkout init --cone --sparse-index
git sparse-checkout set frontend/ libs/shared/
# Only frontend/ and libs/shared/ appear in working tree
```

### Modify Checked-Out Directories

```bash
git sparse-checkout add backend/api/
git sparse-checkout set docs/        # replaces previous set
git sparse-checkout list
# frontend
# libs/shared
```

### Disable Sparse Checkout

```bash
git sparse-checkout disable  # restores full working tree
```

Cone mode (default) restricts patterns to directories only — faster index operations. Sparse-index keeps the index small, improving `git status`, `git add`, and `git commit` performance on repos with millions of files.

## Git Subtree — Embed Repos Without Submodules

### Add a Subtree

```bash
git subtree add --prefix=vendor/lib https://github.com/org/lib.git main --squash
# Pulls lib's main branch into vendor/lib/ as a single squashed commit
```

### Pull Updates

```bash
git subtree pull --prefix=vendor/lib https://github.com/org/lib.git main --squash
```

### Push Changes Back Upstream

```bash
git subtree push --prefix=vendor/lib https://github.com/org/lib.git contrib-branch
```

### Split a Subdirectory into Its Own History

```bash
git subtree split --prefix=src/component -b component-standalone
# Creates a new branch with only src/component history
```

Subtree vs submodules: subtrees embed code directly (no `.gitmodules`, no separate clone step), making CI simpler. Submodules keep a pointer to an external commit — better for large, independently versioned dependencies.

## Advanced Stash

### Stash Specific Files (Partial Stash)

```bash
git stash push -p              # interactively select hunks to stash
git stash push -m "wip: auth refactor" -- src/auth/
# Stash only files in src/auth/ with a descriptive message
```

### List and Inspect Stashes

```bash
git stash list
# stash@{0}: On main: wip: auth refactor
# stash@{1}: WIP on main: abc1234 fix typo

git stash show -p stash@{1}   # show diff of a specific stash
```

### Apply vs Pop

```bash
git stash apply stash@{0}  # apply but keep in stash list
git stash pop stash@{0}    # apply and remove from stash list
```

### Create a Branch from a Stash

```bash
git stash branch feature/auth-wip stash@{0}
# Creates a new branch at the stash's parent commit, applies the stash, drops it
```

### Drop and Clear

```bash
git stash drop stash@{2}   # remove a specific stash
git stash clear             # remove ALL stashes (irreversible)
```

## Git Blame and Log Forensics

### Blame with Noise Reduction

```bash
git blame -w -C -C -M file.txt
# -w  ignore whitespace changes
# -C  detect code moved from other files in the same commit
# -C -C  detect code copied from other files in any commit
# -M  detect moved lines within the file
```

### Blame a Specific Line Range

```bash
git blame -L 50,70 src/main.py
```

### Pickaxe Search — Find When a String Was Added/Removed

```bash
git log -S 'calculateTotal' --oneline
# Lists commits that changed the number of occurrences of 'calculateTotal'

git log -G 'def\s+process_' --oneline
# Lists commits where a line matching the regex was added or removed
```

### Follow File Renames

```bash
git log --follow --oneline -- src/utils/helpers.ts
# Tracks history across renames
```

### Advanced Log Formatting

```bash
git log --all --oneline --graph --decorate
git log --author='alice' --since='2025-01-01' --until='2025-06-01' --stat
git log --diff-filter=D --summary  # show only commits that deleted files
```

## Reflog Mastery — Recovering Lost Commits

The reflog records every HEAD movement locally:

```bash
git reflog
# abc1234 HEAD@{0}: commit: add feature
# def5678 HEAD@{1}: reset: moving to HEAD~3
# 789abcd HEAD@{2}: commit: important work (now "lost")
```

### Recover a Lost Commit

```bash
git checkout -b recovery-branch HEAD@{2}
# or
git cherry-pick 789abcd
```

### Recover After a Bad Reset

```bash
git reset --hard HEAD@{1}  # undo the reset by going back one reflog entry
```

### Reflog Expiration

```bash
git reflog expire --expire=90.days.ago --all
git gc --prune=now
# Default: unreachable entries expire after 30 days, reachable after 90 days
```

## Git Internals — Objects, Refs, Packfiles

### The Four Object Types

```bash
git cat-file -t abc1234    # blob, tree, commit, or tag
git cat-file -p abc1234    # pretty-print object contents
```

- **blob**: file content (no filename, no permissions)
- **tree**: directory listing — maps names to blob/tree SHAs and modes
- **commit**: points to a tree, parent commit(s), author, committer, message
- **tag** (annotated): points to a commit with tagger info and message

### Inspect Refs

```bash
git show-ref               # list all refs and their SHAs
git for-each-ref --format='%(refname) %(objectname:short)' refs/heads/
# refs/heads/main abc1234
# refs/heads/feature def5678
```

### Packfiles and Garbage Collection

```bash
git count-objects -vH
# count: 42
# size: 1.2 MiB
# packs: 3
# size-pack: 45.8 MiB

git gc                     # pack loose objects, remove unreachable objects
git repack -a -d --depth=250 --window=250   # aggressive repack
git verify-pack -v .git/objects/pack/pack-*.idx | head -20
```

### Fsck — Check Repository Integrity

```bash
git fsck --full --no-dangling
# Checking object directories: 100% done.
# Checking objects: 100% done.
```

## Advanced Cherry-Pick

### Cherry-Pick a Range of Commits

```bash
git cherry-pick A..B       # apply commits after A up to and including B
git cherry-pick A^..B      # include commit A itself
```

### Record the Source Commit

```bash
git cherry-pick -x abc1234
# Appends "(cherry picked from commit abc1234)" to the commit message
```

### Handle Conflicts During Cherry-Pick

```bash
git cherry-pick abc1234
# CONFLICT — resolve manually, then:
git add .
git cherry-pick --continue
# or abort:
git cherry-pick --abort
```

## Patch Workflows

### Create Patches

```bash
git format-patch -3 HEAD         # last 3 commits as .patch files
git format-patch main..feature   # all commits on feature not in main
# Output: 0001-first-change.patch, 0002-second-change.patch, ...
```

### Apply Patches

```bash
git am 0001-first-change.patch          # apply and create commit
git am --3way *.patch                   # use 3-way merge for conflicts
git apply --check 0001-first-change.patch  # dry-run, check if it applies cleanly
```

## Performance Optimization

### Shallow Clone

```bash
git clone --depth=1 https://github.com/org/repo.git
git fetch --deepen=10   # fetch 10 more commits of history
git fetch --unshallow    # convert to full clone
```

### Partial Clone (Blobless / Treeless)

```bash
git clone --filter=blob:none https://github.com/org/repo.git   # fetch blobs on demand
git clone --filter=tree:0 https://github.com/org/repo.git      # fetch trees on demand too
```

### Commit-Graph and Multi-Pack-Index

```bash
git commit-graph write --reachable --changed-paths
# Speeds up log, merge-base, and pathspec-limited log queries

git multi-pack-index write
git multi-pack-index verify
# Indexes multiple packfiles for faster object lookup
```

### Filesystem Monitor

```bash
git config core.fsmonitor true    # use OS filesystem events (watchman/fsmonitor--daemon)
git config core.untrackedcache true
# Dramatically speeds up git status on large repos
```

## Anti-Patterns to Avoid

### Force Push Without Lease

```bash
# BAD — overwrites remote unconditionally:
git push --force

# GOOD — fails if someone else pushed since your last fetch:
git push --force-with-lease
```

### Rewriting Shared History

Never rebase, amend, or filter-repo on commits already pushed to a shared branch. If you must:

1. Coordinate with all collaborators.
2. Have everyone `git fetch && git reset --hard origin/main`.
3. Delete and re-push all affected branches/tags.

### Giant Binary Files in Git

Do not commit large binaries directly. Use Git LFS:

```bash
git lfs install
git lfs track "*.psd"
git add .gitattributes
```

### Ignoring Reflog Before Destructive Operations

Always check `git reflog` before `git reset --hard` or `git branch -D`. The reflog is your safety net — it expires, so recover lost work promptly (default 30 days for unreachable entries).
