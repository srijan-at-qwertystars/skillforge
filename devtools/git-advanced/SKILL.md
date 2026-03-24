---
name: git-advanced
description: >
  Advanced Git operations skill for expert-level version control workflows.
  Use when user needs advanced git operations, interactive rebasing, fixup,
  squash, reorder commits, git bisect for bug hunting, reflog for recovery,
  worktrees for parallel development, sparse checkout, subtree and submodule
  patterns, git hooks (pre-commit, pre-push, commit-msg), advanced merge
  strategies (ours, theirs, octopus), cherry-pick ranges, stash management,
  git filter-repo for history rewriting, git blame and log archaeology,
  .gitattributes for LFS and diff drivers, signing commits with GPG or SSH.
  NOT for basic git add/commit/push, NOT for GitHub-specific features like
  PRs/Actions/Issues, NOT for initial git setup or git config basics.
---

# Advanced Git Techniques

## Interactive Rebase

Rewrite, reorder, squash, and fixup commits on feature branches before merging.

### Squash and Fixup

```bash
git rebase -i HEAD~5
```

Editor opens. Change `pick` to action keyword:

```
pick   a1b2c3d Add user model
squash d4e5f6a Add validation        # merge into previous, edit message
fixup  g7h8i9j Fix typo              # merge into previous, discard message
pick   j0k1l2m Add API endpoint
reword n3o4p5q Add tests             # keep commit, edit message
```

### Autosquash Workflow

```bash
git commit --fixup=a1b2c3d           # mark as fixup for target SHA
git rebase -i --autosquash HEAD~5    # auto-reorder fixups below targets
```

### Reorder, Abort, Continue

Cut/paste lines in editor to reorder (applies top-to-bottom).

```bash
git rebase --abort                   # cancel, restore original state
git rebase --continue                # after resolving conflicts
git rebase --skip                    # skip current commit
```

**Never rebase commits already pushed to shared branches.**

---

## Git Bisect

Binary search to find the commit that introduced a bug.

### Manual Bisect

```bash
git bisect start
git bisect bad                       # current commit has the bug
git bisect good v2.1.0               # known good tag/SHA
# Git checks out midpoint. Test, then mark:
git bisect good                      # or: git bisect bad
# Repeat. Output: "a1b2c3d is the first bad commit"
git bisect reset                     # return to original HEAD
```

### Automated Bisect

```bash
git bisect start HEAD v2.1.0
git bisect run ./test-script.sh      # exit 0=good, 1-124=bad, 125=skip
git bisect reset
```

### Scope to Path

```bash
git bisect start -- src/auth/        # limit to changes in src/auth/
```

---

## Reflog: Recovery and Undo

Reflog records every HEAD movement. Recover lost commits, undo resets, restore deleted branches.

```bash
git reflog
# a1b2c3d HEAD@{0}: reset: moving to HEAD~3
# f4e5d6c HEAD@{1}: commit: Add feature X

git reset --hard HEAD@{1}            # recover after accidental reset

# Restore deleted branch
git reflog | grep 'checkout: moving from feature-x'
git checkout -b feature-x HEAD@{4}

# Undo a rebase
git reset --hard HEAD@{5}            # entry before rebase started
```

Entries expire after 90 days (30 for unreachable).

---

## Worktrees

Work on multiple branches simultaneously without stashing or cloning.

```bash
git worktree add ../hotfix-dir hotfix/critical-bug
git worktree add -b experiment ../experiment main   # new branch from main
git worktree list
# /home/user/repo         a1b2c3d [main]
# /home/user/hotfix-dir   d4e5f6a [hotfix/critical-bug]
git worktree remove ../hotfix-dir
git worktree prune                   # clean stale references
```

Shares .git data—no disk duplication. Cannot checkout same branch in two worktrees.

---

## Sparse Checkout

Check out only specific directories. Essential for monorepos.

```bash
git clone --filter=blob:none --no-checkout <url> repo
cd repo
git sparse-checkout init --cone
git sparse-checkout set src/backend src/shared
git checkout main                    # only specified paths materialized
git sparse-checkout add docs/api     # add more paths
git sparse-checkout list             # show current patterns
git sparse-checkout disable          # restore full tree
```

---

## Subtree vs Submodule

### Submodule: External Dependency Pinning

```bash
git submodule add https://github.com/org/lib.git vendor/lib
git clone --recurse-submodules <url>
git submodule update --init --recursive
git submodule update --remote --merge  # update to latest upstream
```

### Subtree: Inline Integration

```bash
git subtree add --prefix=vendor/lib https://github.com/org/lib.git main --squash
git subtree pull --prefix=vendor/lib https://github.com/org/lib.git main --squash
git subtree push --prefix=vendor/lib https://github.com/org/lib.git main
```

Choose submodule for strict version pinning. Choose subtree for simpler workflows where code lives inline.

---

## Git Hooks

Store hooks in `.githooks/` and configure: `git config core.hooksPath .githooks`

### pre-commit: Lint Staged Files

```bash
#!/bin/bash
STAGED=$(git diff --cached --name-only --diff-filter=ACM)
JS_FILES=$(echo "$STAGED" | grep -E '\.(js|ts|tsx)$')
if [ -n "$JS_FILES" ]; then
  npx eslint --fix $JS_FILES || exit 1
  git add $JS_FILES
fi
```

### commit-msg: Enforce Conventional Commits

```bash
#!/bin/bash
PATTERN='^(feat|fix|docs|style|refactor|test|chore|ci|perf)(\(.+\))?: .{1,72}'
if ! grep -qE "$PATTERN" "$1"; then
  echo "ERROR: Must match type(scope): description"
  exit 1
fi
```

### pre-push: Run Tests

```bash
#!/bin/bash
npm test || { echo "Tests failed. Push aborted."; exit 1; }
```

Keep hooks fast. Run only against staged/changed files. Bypass with `--no-verify`.

---

## Advanced Merge Strategies

```bash
# Ours strategy: keep current branch, discard theirs entirely
git merge -s ours legacy-branch

# Recursive with theirs: prefer incoming on conflict
git merge -X theirs feature-branch

# Recursive with ours: prefer current on conflict
git merge -X ours feature-branch

# Octopus: merge multiple branches at once (no conflict resolution)
git merge branch-a branch-b branch-c
```

### Rerere: Reuse Recorded Resolution

```bash
git config rerere.enabled true       # remember conflict resolutions
git rerere status                    # show recorded resolutions
git rerere diff                      # show what rerere would apply
```

---

## Cherry-Pick

```bash
git cherry-pick a1b2c3d                   # single commit
git cherry-pick a1b2c3d^..d4e5f6a         # range (a1b exclusive, d4e inclusive)
git cherry-pick --no-commit a1b2c3d       # stage only, don't commit
git cherry-pick -x a1b2c3d               # append "(cherry picked from ...)"
git cherry-pick --continue                # after resolving conflicts
git cherry-pick --abort                   # cancel
```

---

## Stash Management

```bash
git stash push -m "WIP: auth refactor"    # stash with message
git stash push --staged -m "staged only"  # stash only staged changes
git stash push -m "config" -- src/cfg.ts  # stash specific files
git stash push -p                         # interactive hunk selection
git stash push -u -m "with untracked"     # include untracked files
git stash list                            # list all stashes
git stash show -p stash@{0}               # show stash diff
git stash apply stash@{1}                 # apply, keep in list
git stash pop stash@{0}                   # apply and remove
git stash branch new-feature stash@{0}    # create branch from stash
git stash drop stash@{1}                  # drop specific stash
git stash clear                           # drop all stashes
```

---

## Git Filter-Repo

Supersedes `filter-branch`. Install: `pip install git-filter-repo`. Always use on a fresh clone.

```bash
# Remove file from entire history (leaked secret)
git filter-repo --invert-paths --path secrets.env

# Remove directory from history
git filter-repo --invert-paths --path vendor/old-lib/

# Rename directory across all history
git filter-repo --path-rename old-name/:new-name/

# Move contents into subdirectory (monorepo prep)
git filter-repo --to-subdirectory-filter services/auth

# Extract subdirectory into own repo
git filter-repo --subdirectory-filter src/lib

# Replace text across history
git filter-repo --replace-text expressions.txt
# Format: literal:old==>new  OR  regex:pattern==>replacement

# Strip large blobs
git filter-repo --strip-blobs-bigger-than 10M
```

Force-push required after rewriting. Coordinate with all contributors.

---

## Git Blame and Log Archaeology

### Blame

```bash
git blame src/auth/login.ts              # full file blame
git blame -L 42,60 src/auth/login.ts     # specific line range
git blame -w src/auth/login.ts           # ignore whitespace
git blame -C -C -C src/auth/login.ts     # detect cross-file movement

# Ignore bulk-formatting commits
echo "a1b2c3d4  # prettier" >> .git-blame-ignore-revs
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

### Log Archaeology

```bash
# Pickaxe: find when string was added/removed
git log -S "API_SECRET" --oneline

# Regex pickaxe
git log -G "def\s+authenticate" --oneline

# Changes to specific function
git log -L :authenticate:src/auth.py

# Search commit messages
git log --grep="JIRA-1234" --oneline

# Follow file renames
git log --follow --oneline -- src/auth/login.ts

# Find deleted file
git log --diff-filter=D --name-only -- "**/old-module*"
```

---

## .gitattributes: LFS and Diff Drivers

### Git LFS

```gitattributes
*.psd filter=lfs diff=lfs merge=lfs -text
*.png filter=lfs diff=lfs merge=lfs -text
*.zip filter=lfs diff=lfs merge=lfs -text
```

```bash
git lfs install
git lfs track "*.psd"
git lfs ls-files
git lfs migrate import --include="*.psd"  # migrate existing files
```

### Custom Diff and Merge Drivers

```gitattributes
*.json diff=json
*.csv diff=csv
*.min.js -diff                             # suppress diffs for minified
package-lock.json merge=ours               # keep ours on conflict
*.generated.ts -merge                      # force manual resolve
vendor/** linguist-vendored                # exclude from language stats
```

```bash
git config diff.json.textconv "python -m json.tool"
git config diff.csv.textconv "column -t -s,"
```

---

## Signing Commits

### GPG Signing

```bash
gpg --list-secret-keys --keyid-format=long
git config --global user.signingkey ABCDEF1234567890
git config --global commit.gpgsign true
git commit -S -m "feat: signed commit"
git tag -s v1.0.0 -m "Release 1.0.0"
git log --show-signature -1
```

### SSH Signing (Git 2.34+)

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
echo "user@example.com $(cat ~/.ssh/id_ed25519.pub)" >> ~/.ssh/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
git log --show-signature -1
```

SSH signing is simpler than GPG. Use for teams already using SSH authentication.

---

## Recovery Quick Reference

| Mistake | Recovery |
|---|---|
| Accidental `reset --hard` | `git reflog` → `git reset --hard HEAD@{n}` |
| Deleted branch | `git reflog` → `git checkout -b name HEAD@{n}` |
| Bad rebase | `git reflog` → `git reset --hard HEAD@{n}` |
| Wrong branch commit | `git stash` → checkout correct → `git stash pop` |
| Pushed secrets | `git filter-repo --invert-paths --path file` + rotate creds |
| Lost stash | `git fsck --unreachable \| grep commit` → `git show <sha>` |

---

## References

In-depth guides in `references/` for deep dives beyond this quick-reference:

| File | Topics |
|---|---|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Interactive rebase workflows (fixup chains, autosquash, splitting commits, exec steps), merge strategies (octopus, ours/theirs, subtree, rerere), cherry-pick ranges and tracking, filter-repo cookbook (remove files, rewrite emails, extract/combine repos) |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Detached HEAD recovery, force-push recovery, rebase conflict resolution, corrupted repo repair, lost commits via reflog, merge vs rebase decision tree, submodule sync issues, common errors reference |
| [`references/hooks-reference.md`](references/hooks-reference.md) | All Git hook types (client and server-side), practical examples for each hook, hook managers (Husky, Lefthook, pre-commit framework), comparison table, best practices |

---

## Scripts

Executable utilities in `scripts/` — run directly or add to your PATH:

| Script | Purpose | Usage |
|---|---|---|
| [`scripts/git-cleanup.sh`](scripts/git-cleanup.sh) | Prune stale remote branches, remove merged local branches, gc/prune, report space savings | `./git-cleanup.sh [-n] [-a]` |
| [`scripts/git-bisect-helper.sh`](scripts/git-bisect-helper.sh) | Automated bisect runner — provide a test command, find the first bad commit automatically | `./git-bisect-helper.sh -g v1.0 "npm test"` |
| [`scripts/git-stats.sh`](scripts/git-stats.sh) | Repository statistics — contributors, file churn, commit frequency, largest files, branch age | `./git-stats.sh [-s section]` |

---

## Assets

Copy-paste ready templates in `assets/`:

| File | Description |
|---|---|
| [`assets/gitconfig-advanced.ini`](assets/gitconfig-advanced.ini) | Advanced `.gitconfig` with aliases, diff tools, merge tools, rebase settings, performance tweaks. Include via `[include] path = ...` |
| [`assets/hooks/pre-commit`](assets/hooks/pre-commit) | Production pre-commit hook: lint staged files, format check, secrets detection, large file check, debug statement detection |
| [`assets/hooks/commit-msg`](assets/hooks/commit-msg) | Conventional Commits enforcement hook: validates type(scope): description format, subject length, blank line separator |
| [`assets/gitattributes-template`](assets/gitattributes-template) | `.gitattributes` template with LFS patterns, custom diff drivers, merge strategies for lock files, export-ignore, linguist overrides |

<!-- tested: pass -->
