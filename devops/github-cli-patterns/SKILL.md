---
name: github-cli-patterns
description:
  positive: "Use when user works with GitHub CLI (gh), asks about gh pr, gh issue, gh workflow, gh api, gh extensions, or automating GitHub tasks from the terminal."
  negative: "Do NOT use for GitHub Actions YAML (use github-actions-workflows skill), GitHub REST API without CLI context, or git CLI commands (use git-advanced-techniques skill)."
---

# GitHub CLI (gh) Patterns and Automation

## Authentication and Configuration

Authenticate before using any gh command:

```bash
gh auth login                          # interactive login (browser or token)
gh auth login --with-token < token.txt # non-interactive, CI-friendly
gh auth status                         # verify current auth state
gh auth token                          # print current token
gh auth switch                         # switch between accounts
```

Configure defaults:

```bash
gh config set editor vim
gh config set prompt disabled          # disable interactive prompts for scripting
gh config set git_protocol ssh         # prefer SSH over HTTPS
gh config set browser "firefox"
gh config list
```

Environment variables:

```bash
export GH_TOKEN="ghp_..."             # auth token (overrides gh auth)
export GH_REPO="owner/repo"          # default repo context
export GH_HOST="github.example.com"  # GitHub Enterprise host
export GH_PAGER="less -FRX"          # pager for output
export NO_COLOR=1                     # disable colored output
export GH_DEBUG=1                     # enable debug logging
```

## Pull Requests

### Create and manage PRs

```bash
# Create PR from current branch
gh pr create --title "Add auth module" --body "Implements JWT auth"
gh pr create --fill                    # auto-fill title/body from commits
gh pr create --draft                   # create as draft
gh pr create --base develop            # target a non-default branch
gh pr create --reviewer user1,user2 --assignee @me --label bug

# Checkout a PR locally
gh pr checkout 42
gh pr checkout https://github.com/owner/repo/pull/42

# Review and merge
gh pr review 42 --approve
gh pr review 42 --request-changes --body "Fix the failing test"
gh pr comment 42 --body "LGTM, ship it"
gh pr merge 42 --squash --delete-branch
gh pr merge 42 --rebase --auto         # auto-merge when checks pass

# Inspect
gh pr diff 42
gh pr view 42
gh pr view 42 --json state,mergeable,reviews
gh pr status                           # show PRs relevant to you
gh pr checks 42                        # show CI status
```

### List and filter PRs

```bash
gh pr list --state open --author @me
gh pr list --label "ready-for-review" --json number,title --jq '.[].title'
gh pr list --base main --limit 50
gh pr close 42 --comment "Superseded by #43"
gh pr reopen 42
```

## Issues

### Create and manage issues

```bash
gh issue create --title "Login fails on Safari" --body "Steps to reproduce..."
gh issue create --label bug,P1 --assignee @me
gh issue create --template bug_report.md
gh issue create --project "Sprint 12"

gh issue view 99
gh issue view 99 --json title,state,labels,assignees
gh issue close 99 --reason completed
gh issue close 99 --comment "Fixed in #101"
gh issue reopen 99
```

### List and filter issues

```bash
gh issue list --state open --assignee @me
gh issue list --label "help wanted" --limit 20
gh issue list --milestone "v2.0"
gh issue list --json number,title,labels --jq '.[] | select(.labels[].name == "bug")'

# Transfer and pin
gh issue transfer 99 owner/other-repo
gh issue pin 99
gh issue unpin 99
```

### Edit issues

```bash
gh issue edit 99 --add-label P0 --remove-label P2
gh issue edit 99 --add-assignee user1
gh issue edit 99 --title "Updated title" --body "New description"
gh issue edit 99 --milestone "v2.1"
```

## Workflows and Runs

### Trigger and monitor workflows

```bash
# List available workflows
gh workflow list
gh workflow view deploy.yml

# Trigger a workflow (requires workflow_dispatch event)
gh workflow run deploy.yml
gh workflow run deploy.yml --ref release/v2 -f environment=staging -f debug=true

# List and inspect runs
gh run list
gh run list --workflow=ci.yml --branch main --limit 10
gh run list --status failure --json databaseId,conclusion,name

# Watch a run in real-time
gh run watch                           # interactive selection
gh run watch 12345                     # specific run ID

# View run details and logs
gh run view 12345
gh run view 12345 --log
gh run view 12345 --log-failed         # only failed job logs

# Rerun and download artifacts
gh run rerun 12345
gh run rerun 12345 --failed            # rerun only failed jobs
gh run download 12345                  # download all artifacts
gh run download 12345 -n "build-output"
gh run cancel 12345
```

### Script: wait for workflow completion

```bash
gh workflow run deploy.yml -f env=prod
sleep 5
RUN_ID=$(gh run list --workflow=deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status && echo "Deploy succeeded" || echo "Deploy failed"
```

## Repository Management

```bash
gh repo create my-project --public --clone
gh repo create my-org/service --private --template owner/template-repo
gh repo create --source . --remote upstream --push  # from existing local dir
gh repo clone owner/repo -- --depth 1              # shallow clone
gh repo fork owner/repo --clone
gh repo sync --branch main                          # sync fork with upstream
gh repo archive owner/repo && gh repo unarchive owner/repo
gh repo rename new-name
gh repo edit --visibility private --default-branch main
gh repo delete owner/repo --yes
gh repo view owner/repo --json name,description,stargazerCount
gh repo list my-org --limit 100 --json name,isArchived --jq '.[] | select(.isArchived == false)'
```

## gh api — REST and GraphQL

### REST API calls

```bash
# GET requests
gh api repos/owner/repo
gh api repos/owner/repo/issues --jq '.[].title'
gh api repos/owner/repo/pulls?state=open --jq 'length'

# POST/PATCH/DELETE
gh api repos/owner/repo/issues -f title="API issue" -f body="Created via API"
gh api repos/owner/repo/issues/42 -X PATCH -f state=closed
gh api repos/owner/repo/issues/42/labels -f "labels[]=bug" -f "labels[]=P1"

# Pagination — fetch ALL pages automatically
gh api repos/owner/repo/issues --paginate --jq '.[].number'

# Template output
gh api repos/owner/repo --template '{{.full_name}} ⭐ {{.stargazers_count}}'
```

### GraphQL queries

```bash
# Inline query
gh api graphql -f query='{ viewer { login name } }' --jq '.data.viewer.login'

# Query with variables
gh api graphql -f query='
  query($owner: String!, $repo: String!) {
    repository(owner: $owner, name: $repo) {
      issues(first: 10, states: OPEN) { nodes { number title } }
    }
  }' -f owner=cli -f repo=cli --jq '.data.repository.issues.nodes[]'

# Paginated GraphQL — loop with cursor
cursor=""
while true; do
  result=$(gh api graphql -f query='
    query($cursor: String) {
      viewer { repositories(first: 100, after: $cursor) {
        nodes { nameWithOwner }
        pageInfo { hasNextPage endCursor }
      }}
    }' -f cursor="$cursor")
  echo "$result" | jq -r '.data.viewer.repositories.nodes[].nameWithOwner'
  has_next=$(echo "$result" | jq -r '.data.viewer.repositories.pageInfo.hasNextPage')
  [ "$has_next" = "true" ] || break
  cursor=$(echo "$result" | jq -r '.data.viewer.repositories.pageInfo.endCursor')
done
```

### jq filtering patterns

```bash
# Extract specific fields
gh api repos/owner/repo/pulls --jq '.[] | {number, title, user: .user.login}'

# Filter by condition
gh api repos/owner/repo/issues --jq '[.[] | select(.labels[].name == "bug")] | length'

# Tab-separated output for scripting
gh api repos/owner/repo/issues --jq '.[] | [.number, .title] | @tsv'

# CSV output
gh api repos/owner/repo/pulls --jq '.[] | [.number, .title, .state] | @csv'
```

## Releases

```bash
gh release create v1.0.0 --title "v1.0.0" --notes "First stable release"
gh release create v1.0.0 --generate-notes     # auto-generate from commits
gh release create v1.0.0 --draft --prerelease
gh release create v1.0.0 ./dist/*.tar.gz       # upload assets at creation
gh release upload v1.0.0 ./build/app.zip --clobber
gh release download v1.0.0 --pattern "*.tar.gz" --dir ./downloads
gh release edit v1.0.0 --draft=false           # publish a draft
gh release delete v1.0.0 --yes
gh release list
gh release view --latest --json tagName,publishedAt
```

### Script: automated release

```bash
#!/bin/bash
PREV_TAG=$(gh release view --json tagName --jq '.tagName')
VERSION=$(cat VERSION)
gh release create "v${VERSION}" --title "Release ${VERSION}" \
  --generate-notes ./dist/*.tar.gz ./dist/*.zip
```

## Gists

```bash
gh gist create script.sh                       # create public gist
gh gist create --public script.sh README.md    # multi-file gist
gh gist create -d "Helper functions" utils.sh  # with description
echo "quick note" | gh gist create -           # from stdin
gh gist list && gh gist view GIST_ID && gh gist edit GIST_ID
gh gist clone GIST_ID && gh gist delete GIST_ID
```

## Extensions

```bash
gh extension install dlvhdr/gh-dash           # install from repo
gh extension list                              # list installed
gh extension upgrade --all                     # update all
gh extension remove gh-dash
gh extension create my-ext                     # scaffold new extension
gh extension create --precompiled=go my-ext    # Go-based extension
gh search repos --topic gh-extension --sort stars --limit 20
```

Notable extensions: `gh-dash` (PR/issue dashboard), `gh-poi` (branch cleanup),
`gh-markdown-preview` (render markdown), `gh-s` (fuzzy repo search),
`gh-skyline` (3D contribution graph).

## Codespaces

```bash
gh codespace create --repo owner/repo --branch feature
gh codespace list
gh codespace ssh -c CODESPACE_NAME
gh codespace code -c CODESPACE_NAME            # open in VS Code
gh codespace ports forward 8080:8080 -c CODESPACE_NAME
gh codespace stop -c CODESPACE_NAME
gh codespace delete -c CODESPACE_NAME
```

## Search

```bash
# Repositories
gh search repos "machine learning" --language=python --stars=">500"
gh search repos --owner=microsoft --visibility=public --sort=stars

# Code
gh search code "func main" --language=go --repo=owner/repo

# Issues and PRs
gh search issues "is:open label:bug" --repo=owner/repo
gh search issues "no:assignee label:good-first-issue" --limit 50
gh search prs "is:open review:required author:@me"
gh search prs "is:merged merged:>2025-01-01" --repo=owner/repo

# Commits
gh search commits "fix typo" --author=username --author-date=">2025-01-01"

# Use -- to pass exclusion qualifiers
gh search issues -- "is:open -label:wontfix"
```

## Automation Scripts

### Batch close stale issues

```bash
#!/bin/bash
gh issue list --state open --label stale --json number --jq '.[].number' | while read -r num; do
  gh issue close "$num" --comment "Closing stale issue. Reopen if still relevant."
done
```

### Bulk label PRs by file path

```bash
#!/bin/bash
for pr_num in $(gh pr list --state open --json number --jq '.[].number'); do
  files=$(gh pr view "$pr_num" --json files --jq '.files[].path')
  if echo "$files" | grep -q "^docs/"; then
    gh pr edit "$pr_num" --add-label documentation
  fi
  if echo "$files" | grep -q "^src/api/"; then
    gh pr edit "$pr_num" --add-label api-change
  fi
done
```

### Auto-merge dependabot PRs

```bash
#!/bin/bash
gh pr list --author "app/dependabot" --json number,title --jq '.[].number' | while read -r num; do
  gh pr review "$num" --approve
  gh pr merge "$num" --squash --auto --delete-branch
done
```

### Export issues to CSV

```bash
gh issue list --state all --limit 500 --json number,title,state,labels,createdAt \
  --jq '.[] | [.number, .title, .state, ([.labels[].name] | join(";")), .createdAt] | @csv' > issues.csv
```

### Create release with changelog

```bash
#!/bin/bash
PREV_TAG=$(gh release view --json tagName --jq '.tagName')
NEW_TAG="v$(date +%Y.%m.%d)"
CHANGELOG=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s (%an)" --no-merges)
gh release create "$NEW_TAG" --title "$NEW_TAG" --notes "$CHANGELOG"
```

## Aliases and Shell Integration

### Define aliases

```bash
gh alias set prs 'pr list --author @me'
gh alias set review 'pr list --search "review-requested:@me"'
gh alias set bugs 'issue list --label bug --state open'
gh alias set co 'pr checkout'
gh alias set web 'repo view --web'
# Shell-command aliases (prefix with !)
gh alias set --shell igrep 'gh issue list --json number,title | jq -r ".[] | \"#\(.number) \(.title)\"" | grep -i "$1"'
gh alias list && gh alias delete prs
```

### Shell completion

```bash
eval "$(gh completion -s bash)"          # Bash
eval "$(gh completion -s zsh)"           # Zsh
gh completion -s fish | source           # Fish
echo 'eval "$(gh completion -s bash)"' >> ~/.bashrc  # persist
```

### Scripting patterns

Use `--json` with `--jq` for machine-readable output:

```bash
SHA=$(gh pr view 42 --json mergeCommit --jq '.mergeCommit.oid')
MERGEABLE=$(gh pr view 42 --json mergeable --jq '.mergeable')
[ "$MERGEABLE" = "MERGEABLE" ] && gh pr merge 42 --squash

# Count open issues by label
gh issue list --state open --json labels \
  --jq '[.[].labels[].name] | group_by(.) | map({label: .[0], count: length}) | sort_by(-.count)'

# Conditional logic on CI status
STATUS=$(gh pr checks 42 --json state --jq '.[] | select(.state != "SUCCESS") | .state' | head -1)
[ -z "$STATUS" ] && echo "All checks passed"
```

Use `GH_REPO` to avoid `-R` on every call:

```bash
export GH_REPO="owner/repo"
gh issue list && gh pr list && gh release list
```

## Anti-Patterns

### Avoid hardcoded tokens

```bash
# BAD — token in script
gh api -H "Authorization: token ghp_abc123" repos/owner/repo
# GOOD — use gh auth or GH_TOKEN env var
gh api repos/owner/repo
```

### Always use --json for scripting

```bash
# BAD — parsing human-readable output (fragile)
gh pr list | grep "OPEN" | awk '{print $1}'
# GOOD — structured output
gh pr list --json number --jq '.[].number'
```

### Handle pagination

```bash
# BAD — assumes <30 results
gh api repos/owner/repo/issues --jq '.[].title'
# GOOD — paginate for complete results
gh api repos/owner/repo/issues --paginate --jq '.[].title'
```

### Use --exit-status for CI scripts

```bash
# BAD — ignores workflow failure exit code
gh run watch "$RUN_ID"
# GOOD — propagate failure to calling script
gh run watch "$RUN_ID" --exit-status
```

### Avoid interactive prompts in CI

```bash
# BAD — blocks in non-interactive environments
gh pr create
# GOOD — provide all required fields
gh pr create --fill
gh pr create --title "Fix" --body "Description" --base main
```

### Rate limit awareness

```bash
gh api rate_limit --jq '.resources.core | "Remaining: \(.remaining)"'
# Add delay in bulk scripts
for num in $(gh issue list --json number --jq '.[].number'); do
  gh issue edit "$num" --add-label "triaged"
  sleep 0.5
done
```

<!-- tested: pass -->
