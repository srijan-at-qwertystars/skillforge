# Advanced Git Patterns

> Deep-dive reference for interactive rebase workflows, merge strategies,
> cherry-pick techniques, and filter-repo recipes.

---

## Table of Contents

- [Interactive Rebase Workflows](#interactive-rebase-workflows)
  - [Fixup Chains](#fixup-chains)
  - [Autosquash Workflow](#autosquash-workflow)
  - [Splitting Commits](#splitting-commits)
  - [Reordering and Dropping](#reordering-and-dropping)
  - [Exec Steps in Rebase](#exec-steps-in-rebase)
- [Complex Merge Strategies](#complex-merge-strategies)
  - [Recursive (ort) Strategy Options](#recursive-ort-strategy-options)
  - [Octopus Merge](#octopus-merge)
  - [Ours Strategy vs Ours Option](#ours-strategy-vs-ours-option)
  - [Subtree Merge Strategy](#subtree-merge-strategy)
  - [Rerere — Reuse Recorded Resolution](#rerere--reuse-recorded-resolution)
- [Advanced Cherry-Pick](#advanced-cherry-pick)
  - [Ranges and Sequences](#ranges-and-sequences)
  - [Tracking with -x](#tracking-with--x)
  - [Cherry-Pick without Committing](#cherry-pick-without-committing)
  - [Handling Conflicts](#handling-conflicts)
- [filter-repo Cookbook](#filter-repo-cookbook)
  - [Remove Files from History](#remove-files-from-history)
  - [Rewrite Author Emails](#rewrite-author-emails)
  - [Extract Subdirectory into New Repo](#extract-subdirectory-into-new-repo)
  - [Move Repo into Subdirectory](#move-repo-into-subdirectory)
  - [Strip Large Blobs](#strip-large-blobs)
  - [Replace Text Across History](#replace-text-across-history)
  - [Combine Repos (Monorepo)](#combine-repos-monorepo)

---

## Interactive Rebase Workflows

### Fixup Chains

Create targeted fixup commits during development, then collapse them automatically.

```bash
# 1. During development, fix issues in earlier commits
git commit --fixup=<target-sha>       # silent merge (discard message)
git commit --squash=<target-sha>      # merge and edit combined message

# 2. Multiple fixups can target the same commit
#    History looks like:
#      abc1234 feat: add user model
#      def5678 fixup! feat: add user model
#      ghi9012 fixup! feat: add user model
#      jkl3456 feat: add API routes

# 3. Collapse everything
git rebase -i --autosquash main
```

**Amend-style fixup (Git 2.32+):**

```bash
git commit --fixup=amend:<sha>    # replace the original commit message
git commit --fixup=reword:<sha>   # reword only, no content changes
```

**Best practice:** Enable autosquash globally so you never forget the flag:

```bash
git config --global rebase.autoSquash true
```

### Autosquash Workflow

Step-by-step team workflow for clean PRs:

```bash
# 1. Work on feature branch with frequent commits
git checkout -b feature/user-auth

# 2. Initial implementation
git commit -m "feat: add JWT authentication"   # a1b2c3d

# 3. Review feedback — fix without new logical commit
git commit --fixup=a1b2c3d                      # fix auth logic
git commit --fixup=a1b2c3d                      # fix tests

# 4. More feature work
git commit -m "feat: add refresh token support" # d4e5f6a
git commit --fixup=d4e5f6a                      # fix token expiry

# 5. Before merge, collapse all fixups
git rebase -i --autosquash main

# Result: clean 2-commit history
#   feat: add JWT authentication
#   feat: add refresh token support
```

### Splitting Commits

Break a large commit into smaller logical units:

```bash
git rebase -i HEAD~3
# Mark the target commit as "edit"

# Git pauses at that commit
git reset HEAD~1                        # unstage, keep working tree

# Create smaller commits
git add src/model.ts
git commit -m "feat: add user data model"

git add src/validation.ts
git commit -m "feat: add input validation"

git add src/tests/
git commit -m "test: add model unit tests"

git rebase --continue
```

### Reordering and Dropping

```bash
git rebase -i HEAD~5
# In editor, cut/paste lines to reorder (applied top to bottom)
# Delete a line entirely to drop that commit
# Use "drop" keyword for explicit dropping (safer, visible in todo)

# Example todo:
pick a1b2c3d feat: add auth module
drop d4e5f6a WIP: debugging            # remove debug commit
pick g7h8i9j feat: add API endpoint
pick j0k1l2m test: add integration tests
```

### Exec Steps in Rebase

Run commands between rebase steps to verify each commit builds/passes:

```bash
git rebase -i HEAD~10 --exec "npm test"
# Inserts "exec npm test" after every pick
# Rebase stops if any exec fails

# Or manually in the todo:
pick a1b2c3d feat: add module
exec npm run build && npm test
pick d4e5f6a feat: next feature
exec npm run build && npm test
```

**Verify every commit compiles (great before force-push):**

```bash
git rebase -i main --exec "make build"
```

---

## Complex Merge Strategies

### Recursive (ort) Strategy Options

The default merge strategy (`ort` in Git 2.33+, previously `recursive`) accepts options:

```bash
# Favor their changes on conflict
git merge -X theirs feature-branch

# Favor our changes on conflict
git merge -X ours feature-branch

# Detect renames more aggressively (threshold 0-100, default 50)
git merge -X rename-threshold=25 feature-branch

# Increase rename detection limit for large repos
git merge -X diff-algorithm=histogram feature-branch

# Combine options
git merge -X theirs -X rename-threshold=30 feature-branch
```

**Important distinction:**
- `-s ours` (strategy) → ignores their entire branch content
- `-X ours` (strategy option) → only prefers ours on conflicting hunks

### Octopus Merge

Merge multiple branches in a single commit with multiple parents:

```bash
# Merge three feature branches at once
git checkout main
git merge feature-a feature-b feature-c

# Explicit strategy
git merge -s octopus feature-a feature-b feature-c
```

**Constraints:**
- Cannot resolve conflicts — aborts if any arise
- All branches must merge cleanly
- Best for integrating non-overlapping feature branches
- Cannot use with `-X` strategy options

**Use case:** Release branch integrating multiple independent features:

```bash
git checkout release/2.0
git merge --no-ff feature/auth feature/billing feature/notifications
```

### Ours Strategy vs Ours Option

```bash
# STRATEGY: Record merge, but keep our tree EXACTLY as-is
# Completely discards all changes from the other branch
git merge -s ours legacy-branch
# Use case: mark legacy branch as "merged" without taking any changes

# OPTION: Normal merge, but on conflict prefer our version
git merge -X ours feature-branch
# Use case: mostly want their changes, but our version wins on conflicts
```

**Theirs — no strategy equivalent:**

There is no `-s theirs` strategy. To achieve it:

```bash
# Method 1: merge ours in reverse
git checkout feature-branch
git merge -s ours main
git checkout main
git merge feature-branch

# Method 2: merge with theirs option (only resolves conflicts)
git merge -X theirs feature-branch
```

### Subtree Merge Strategy

Merge one repo into a subdirectory of another:

```bash
# Add the external repo as remote
git remote add library https://github.com/org/library.git
git fetch library

# Merge into subdirectory
git merge -s subtree --allow-unrelated-histories library/main

# Or with explicit prefix
git read-tree --prefix=vendor/library/ -u library/main
git commit -m "chore: import library into vendor/"
```

### Rerere — Reuse Recorded Resolution

Automatically replay conflict resolutions you've already done:

```bash
# Enable globally
git config --global rerere.enabled true

# How it works:
# 1. Git records your conflict resolution during merge/rebase
# 2. If the same conflict appears again, rerere auto-applies your fix
# 3. You still need to stage and commit

# Check recorded resolutions
git rerere status

# See what rerere would apply
git rerere diff

# Forget a bad resolution
git rerere forget <pathspec>

# Clear all recorded resolutions
rm -rf .git/rr-cache
```

**Team workflow with rerere:**

```bash
# Scenario: repeatedly rebasing a long-lived branch onto main

# First time: resolve conflicts manually
git rebase main
# ...resolve conflicts...
git add .
git rebase --continue
# rerere records the resolution

# Next time: rerere auto-resolves the same conflicts
git rebase main
# "Resolved 'src/auth.ts' using previous resolution."
git add .
git rebase --continue
```

**Train rerere from merge commits:**

```bash
# Teach rerere from existing merge history
git rerere-train.sh           # community script
# Or manually replay merges to build resolution cache
```

---

## Advanced Cherry-Pick

### Ranges and Sequences

```bash
# Single commit
git cherry-pick abc1234

# Range: commits AFTER A, up to and including D
git cherry-pick A..D

# Include A itself (use parent syntax)
git cherry-pick A^..D
# Equivalent: A~1..D

# Multiple individual commits
git cherry-pick abc1234 def5678 ghi9012

# From another branch (last 3 commits)
git cherry-pick feature~3..feature
```

**Careful with ranges:**
- `A..B` means "commits reachable from B but not from A"
- A must be an ancestor of B
- Commits are applied in chronological order

### Tracking with -x

Append provenance information to the commit message:

```bash
git cherry-pick -x abc1234
# Appends: "(cherry picked from commit abc1234...)"

# Essential for:
# - Tracking which commits have been backported
# - Auditing release branches
# - Finding the original commit for a fix
```

**With sign-off:**

```bash
git cherry-pick -x -s abc1234
# Adds both cherry-pick tracking and Signed-off-by line
```

### Cherry-Pick without Committing

Stage changes without creating a commit (useful for combining multiple picks):

```bash
# Stage but don't commit
git cherry-pick --no-commit abc1234
git cherry-pick --no-commit def5678

# Review combined changes
git diff --cached

# Create a single commit
git commit -m "feat: backport auth fixes from main"
```

### Handling Conflicts

```bash
# During conflict
git cherry-pick abc1234
# CONFLICT in src/auth.ts

# Option 1: Resolve and continue
git mergetool                    # or edit manually
git add src/auth.ts
git cherry-pick --continue

# Option 2: Skip this commit
git cherry-pick --skip

# Option 3: Abort entire operation
git cherry-pick --abort

# Option 4: Quit (keep already-picked commits, stop here)
git cherry-pick --quit           # Git 2.19+
```

**Scripted cherry-pick with conflict handling:**

```bash
#!/bin/bash
commits=$(git rev-list --reverse A^..D)
for commit in $commits; do
    if ! git cherry-pick "$commit"; then
        echo "Conflict on $commit — resolve and run: git cherry-pick --continue"
        exit 1
    fi
done
echo "All commits cherry-picked successfully"
```

---

## filter-repo Cookbook

> **Prerequisites:** `pip install git-filter-repo`
> **Always work on a fresh clone.** filter-repo refuses to run on repos with remotes by default.

```bash
git clone --no-local original-repo filtered-repo
cd filtered-repo
```

### Remove Files from History

```bash
# Remove a single file (e.g., leaked secret)
git filter-repo --invert-paths --path secrets.env

# Remove multiple files
git filter-repo --invert-paths --path secrets.env --path .env.production

# Remove by glob pattern
git filter-repo --invert-paths --path-glob '*.pem'
git filter-repo --invert-paths --path-glob 'config/credentials*'

# Remove entire directory
git filter-repo --invert-paths --path vendor/legacy/

# Remove files matching regex
git filter-repo --invert-paths --path-regex '^test/fixtures/large_.*\.bin$'
```

### Rewrite Author Emails

Create a mailmap file:

```
# mailmap-file
Correct Name <correct@example.com> <old-email@example.com>
New Name <new@company.com> <contractor@freelance.com>
```

```bash
git filter-repo --mailmap mailmap-file
```

**Rewrite all commits by a specific author:**

```bash
git filter-repo --commit-callback '
    if commit.author_email == b"old@email.com":
        commit.author_email = b"new@email.com"
        commit.author_name = b"Correct Name"
    if commit.committer_email == b"old@email.com":
        commit.committer_email = b"new@email.com"
        commit.committer_name = b"Correct Name"
'
```

### Extract Subdirectory into New Repo

```bash
# Extract src/auth/ — becomes the new repo root
git filter-repo --subdirectory-filter src/auth

# Result:
#   src/auth/login.ts  →  login.ts
#   src/auth/utils.ts  →  utils.ts
```

**Keep the subdirectory path but remove everything else:**

```bash
git filter-repo --path src/auth/
# Result: src/auth/ stays at src/auth/, everything else removed
```

### Move Repo into Subdirectory

Prepare a repo for monorepo integration:

```bash
# Move everything into services/auth/
git filter-repo --to-subdirectory-filter services/auth

# Result:
#   README.md  →  services/auth/README.md
#   src/       →  services/auth/src/
```

### Strip Large Blobs

```bash
# Remove blobs larger than 10MB from all history
git filter-repo --strip-blobs-bigger-than 10M

# Identify large objects first
git rev-list --objects --all \
  | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
  | awk '/^blob/ {print $3, $4, $1}' \
  | sort -rn \
  | head -20
```

### Replace Text Across History

Create `expressions.txt`:

```
# Literal replacements
literal:oldcompany.com==>newcompany.com
literal:ACME Corp==>NewCo Inc

# Regex replacements
regex:api-key-[a-f0-9]{32}==>REDACTED
regex:password\s*=\s*"[^"]*"==>password="REDACTED"
```

```bash
git filter-repo --replace-text expressions.txt
```

### Combine Repos (Monorepo)

```bash
# In the target monorepo
git remote add auth-service ../auth-service
git fetch auth-service

# In auth-service (separately, first move into subdir)
cd ../auth-service
git filter-repo --to-subdirectory-filter services/auth

# Back in monorepo — merge with unrelated histories
cd ../monorepo
git merge --allow-unrelated-histories auth-service/main

# Repeat for other repos
git remote add billing ../billing-service
git fetch billing
# (after billing has been filter-repo'd into services/billing/)
git merge --allow-unrelated-histories billing/main
```

**After any filter-repo operation:**

```bash
# Re-add remote
git remote add origin <url>

# Force-push (coordinate with team!)
git push --force-with-lease origin --all
git push --force-with-lease origin --tags
```

---

## Quick Reference

| Task | Command |
|---|---|
| Enable autosquash globally | `git config --global rebase.autoSquash true` |
| Create fixup commit | `git commit --fixup=<sha>` |
| Autosquash rebase | `git rebase -i --autosquash main` |
| Verify commits build | `git rebase -i main --exec "make test"` |
| Merge favoring theirs | `git merge -X theirs branch` |
| Octopus merge | `git merge branch-a branch-b branch-c` |
| Enable rerere | `git config --global rerere.enabled true` |
| Cherry-pick range | `git cherry-pick A^..D` |
| Cherry-pick with tracking | `git cherry-pick -x <sha>` |
| Remove file from history | `git filter-repo --invert-paths --path file` |
| Rewrite emails | `git filter-repo --mailmap mailmap-file` |
| Extract subdirectory | `git filter-repo --subdirectory-filter path/` |
