# Review: git-advanced

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **Cherry-pick range comment is wrong (SKILL.md line 240):**
   `git cherry-pick a1b2c3d^..d4e5f6a  # range (a1b exclusive, d4e inclusive)`
   The `^` makes `a1b2c3d` *inclusive*, not exclusive. The comment should read
   "(a1b inclusive, d4e inclusive)". The references/advanced-patterns.md handles
   this correctly ("Include A itself (use parent syntax)"), but the primary
   SKILL.md has the error. An AI following this comment could cherry-pick the
   wrong range.

2. **Missing version annotation for `git stash push --staged` (SKILL.md line 253):**
   This flag requires Git 2.35+. Other version-gated features (SSH signing 2.34+,
   `--fixup=amend` 2.32+) are annotated but this one is not.

3. **Pre-commit hook gotcha not mentioned (SKILL.md lines 179-186):**
   The example runs `npx eslint --fix $JS_FILES && git add $JS_FILES`. If a file
   has both staged and unstaged changes, `git add` re-stages the entire file,
   including unstaged work. Should note: use `git add --patch` or lint against
   `git show :<file>` to avoid this. The production hook in assets/hooks/pre-commit
   avoids `--fix` but the inline SKILL.md example does not warn about this.

## Structure Check

- [x] YAML frontmatter has `name` and `description`
- [x] Description includes positive triggers (interactive rebase, bisect, reflog, worktrees, etc.)
- [x] Description includes negative triggers (NOT basic git, NOT GitHub PRs/Actions/Issues, NOT git config basics)
- [x] Body under 500 lines (448 lines)
- [x] Imperative voice, no filler
- [x] Examples with runnable commands throughout
- [x] references/ properly linked from SKILL.md (3 files, all exist)
- [x] scripts/ properly linked from SKILL.md (3 files, all exist)
- [x] assets/ properly linked from SKILL.md (4 entries, all exist)

## Content Verification

- [x] Bisect exit codes correct (0=good, 1-124=bad, 125=skip) — verified against git docs
- [x] `-s ours` vs `-X ours` distinction correct — verified against git-scm.com
- [x] `--fixup=amend`/`--fixup=reword` version (Git 2.32+) correct — verified
- [x] Cherry-pick `A..D` semantics correct in references (exclusive of A, inclusive of D)
- [x] filter-repo syntax and flags correct
- [x] Reflog expiry defaults correct (90 days reachable, 30 unreachable)
- [x] SSH signing requires Git 2.34+ — correctly noted
- [x] Sparse checkout `--cone` mode and `--filter=blob:none` usage correct
- [x] Worktree constraint (can't checkout same branch twice) correctly noted
- [x] Recovery quick reference table — all commands verified correct
- [x] Scripts are well-structured with error handling, usage, cleanup traps
- [x] Hook templates are production-quality with proper shebang, set -euo pipefail

## Trigger Check

- Description is comprehensive — would trigger for: interactive rebase, bisect, reflog,
  worktrees, sparse checkout, subtree/submodule, hooks, merge strategies, cherry-pick,
  stash management, filter-repo, blame/log archaeology, gitattributes/LFS, commit signing
- Negative triggers properly exclude: basic git, GitHub PRs/Actions/Issues, initial setup
- Low false-positive risk: specific enough to avoid triggering on basic git or GitHub features
- Minor gap: doesn't explicitly exclude "git branching strategy" or "gitflow" which could
  cause borderline triggers, but these are arguably advanced topics anyway

## Summary

Excellent skill. Comprehensive coverage of advanced Git operations with accurate,
runnable examples. Supporting references provide deep-dives, scripts are production-ready
with proper error handling, and asset templates are thorough. One factual error in the
cherry-pick range comment needs fixing. Two minor documentation gaps (version annotation,
hook gotcha) would improve completeness for edge cases.
