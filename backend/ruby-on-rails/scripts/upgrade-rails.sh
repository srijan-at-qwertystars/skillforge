#!/usr/bin/env bash
# upgrade-rails.sh — Automated Rails version upgrade checklist and dependency updates
#
# Usage:
#   ./upgrade-rails.sh [target_version]
#
# Examples:
#   ./upgrade-rails.sh           # upgrade to latest Rails
#   ./upgrade-rails.sh 8.0       # upgrade to Rails 8.0.x
#   ./upgrade-rails.sh 7.2       # upgrade to Rails 7.2.x
#
# What it does:
#   1. Checks current Rails version and Ruby compatibility
#   2. Audits gem compatibility
#   3. Runs deprecation checks
#   4. Updates Gemfile and runs bundle update
#   5. Runs rails app:update
#   6. Validates autoloading (Zeitwerk)
#   7. Runs test suite
#   8. Generates upgrade report

set -euo pipefail

TARGET="${1:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────
red()    { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }

step()   { echo ""; bold "── Step $1: $2"; }
pass()   { green "  ✓ $*"; }
fail()   { red "  ✗ $*"; }
warn()   { yellow "  ⚠ $*"; }
info()   { echo "  ℹ $*"; }

REPORT_FILE="tmp/upgrade-report-$(date +%Y%m%d-%H%M%S).md"

# ── Validate Rails project ───────────────────────────────────────────────────
if [[ ! -f "Gemfile" ]] || ! grep -q "rails" Gemfile; then
  red "Error: Not a Rails project (no Gemfile with rails gem)"
  exit 1
fi

mkdir -p tmp

echo ""
bold "═══════════════════════════════════════════════════════"
bold " Rails Upgrade Assistant"
bold "═══════════════════════════════════════════════════════"

{
echo "# Rails Upgrade Report"
echo "Date: $(date)"
echo ""

# ── Step 1: Current versions ─────────────────────────────────────────────────
step 1 "Current Environment"

CURRENT_RAILS=$(bundle exec rails -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
CURRENT_RUBY=$(ruby -v | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

info "Rails: $CURRENT_RAILS"
info "Ruby:  $CURRENT_RUBY"
info "Bundler: $(bundler -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' || echo 'unknown')"

echo "## Environment"
echo "- Rails: $CURRENT_RAILS"
echo "- Ruby: $CURRENT_RUBY"
echo ""

# ── Step 2: Ruby compatibility check ─────────────────────────────────────────
step 2 "Ruby Compatibility"

RUBY_MAJOR=$(echo "$CURRENT_RUBY" | cut -d. -f1)
RUBY_MINOR=$(echo "$CURRENT_RUBY" | cut -d. -f2)

echo "## Ruby Compatibility"

if [[ -n "$TARGET" ]] && [[ "${TARGET%%.*}" -ge 8 ]]; then
  if (( RUBY_MAJOR < 3 || (RUBY_MAJOR == 3 && RUBY_MINOR < 2) )); then
    fail "Rails 8 requires Ruby >= 3.2 (you have $CURRENT_RUBY)"
    echo "- ❌ Ruby $CURRENT_RUBY is too old for Rails 8 (need >= 3.2)" 
    echo ""
    echo "Upgrade Ruby before proceeding."
    exit 1
  else
    pass "Ruby $CURRENT_RUBY is compatible with Rails 8"
    echo "- ✅ Ruby $CURRENT_RUBY compatible"
  fi
elif (( RUBY_MAJOR < 3 )); then
  warn "Ruby $CURRENT_RUBY — consider upgrading to Ruby 3.2+"
  echo "- ⚠️ Consider Ruby upgrade"
else
  pass "Ruby $CURRENT_RUBY looks good"
  echo "- ✅ Ruby $CURRENT_RUBY compatible"
fi
echo ""

# ── Step 3: Security audit ───────────────────────────────────────────────────
step 3 "Security Audit"

echo "## Security Audit"

if command -v bundle-audit &>/dev/null || gem list -i bundler-audit &>/dev/null; then
  info "Running bundler-audit..."
  if bundle exec bundle-audit check --update 2>/dev/null; then
    pass "No known vulnerabilities"
    echo "- ✅ No known vulnerabilities"
  else
    warn "Vulnerabilities found — review output above"
    echo "- ⚠️ Vulnerabilities detected (fix before upgrading)"
  fi
else
  warn "bundler-audit not installed — gem install bundler-audit"
  echo "- ⚠️ bundler-audit not available"
fi
echo ""

# ── Step 4: Check for deprecation warnings ───────────────────────────────────
step 4 "Deprecation Warnings"

echo "## Deprecation Warnings"

info "Checking for deprecation warnings in code..."
DEPRECATION_COUNT=0

# Check for deprecated patterns
patterns=(
  "params\.require.*\.permit"   # Rails 8 prefers params.expect
  "before_filter\b"            # Use before_action
  "after_filter\b"             # Use after_action
  "render :text"               # Use render plain:
  "render nothing:"            # Use head :ok
  "update_attributes"          # Use update
  "find_all_by_"               # Use where
  "find_by_sql.*select"        # Consider Active Record query
)

descriptions=(
  "params.require.permit → use params.expect (Rails 8)"
  "before_filter → use before_action"
  "after_filter → use after_action"
  "render :text → use render plain:"
  "render nothing: → use head :ok"
  "update_attributes → use update"
  "find_all_by_ dynamic finders → use where"
  "find_by_sql with select → consider AR query interface"
)

for i in "${!patterns[@]}"; do
  COUNT=$(grep -rEc "${patterns[$i]}" app/ config/ lib/ 2>/dev/null || echo 0)
  if [[ "$COUNT" -gt 0 ]]; then
    warn "$COUNT occurrence(s): ${descriptions[$i]}"
    echo "- ⚠️ ${descriptions[$i]} ($COUNT occurrences)"
    ((DEPRECATION_COUNT += COUNT))
  fi
done

if [[ $DEPRECATION_COUNT -eq 0 ]]; then
  pass "No common deprecation patterns found"
  echo "- ✅ No deprecated patterns detected"
fi
echo ""

# ── Step 5: Gem compatibility ────────────────────────────────────────────────
step 5 "Gem Compatibility Check"

echo "## Outdated Gems"
echo '```'

info "Checking for outdated gems..."
bundle outdated --only-explicit 2>/dev/null | head -30 || warn "Could not check outdated gems"

echo '```'
echo ""

# ── Step 6: Zeitwerk check ───────────────────────────────────────────────────
step 6 "Zeitwerk Autoloading Check"

echo "## Zeitwerk Compatibility"

info "Running zeitwerk:check..."
if bin/rails zeitwerk:check 2>/dev/null; then
  pass "Zeitwerk autoloading is valid"
  echo "- ✅ All files pass Zeitwerk check"
else
  fail "Zeitwerk issues found — fix before upgrading"
  echo "- ❌ Zeitwerk check failed"
fi
echo ""

# ── Step 7: Update Rails gem ─────────────────────────────────────────────────
step 7 "Update Rails Version"

echo "## Rails Update"

if [[ -n "$TARGET" ]]; then
  info "Target: Rails ~> $TARGET"
  echo ""
  echo "To proceed with the upgrade, run:"
  echo ""
  echo '```bash'
  echo "# 1. Update Gemfile:"
  echo "# gem \"rails\", \"~> $TARGET\""
  echo ""
  echo "# 2. Bundle update:"
  echo "bundle update rails"
  echo ""
  echo "# 3. Run update task (review each file change):"
  echo "bin/rails app:update"
  echo ""
  echo "# 4. Update framework defaults:"
  echo "# config.load_defaults $TARGET"
  echo ""
  echo "# 5. Run tests:"
  echo "bin/rails test    # or: bundle exec rspec"
  echo ""
  echo "# 6. Check for remaining deprecations:"
  echo "grep -ri 'DEPRECATION' log/test.log"
  echo '```'
else
  info "No target version specified. Run with a version argument to get specific guidance."
  echo "- No target version specified"
fi
echo ""

# ── Step 8: Rails 7→8 specific checks ────────────────────────────────────────
if [[ -n "$TARGET" ]] && [[ "${TARGET%%.*}" -ge 8 ]]; then
  step 8 "Rails 8 Specific Checks"
  
  echo "## Rails 8 Migration Checklist"
  echo ""

  # Sprockets → Propshaft
  if grep -q "sprockets" Gemfile 2>/dev/null; then
    warn "Sprockets detected — Rails 8 defaults to Propshaft"
    echo "- [ ] Migrate from Sprockets to Propshaft (or keep Sprockets explicitly)"
    info "  Options: migrate to propshaft, or keep gem 'sprockets-rails' in Gemfile"
  else
    pass "No Sprockets dependency"
    echo "- [x] No Sprockets migration needed"
  fi

  # Sidekiq → Solid Queue
  if grep -q "sidekiq" Gemfile 2>/dev/null; then
    info "Sidekiq detected — Rails 8 includes Solid Queue as default"
    echo "- [ ] Evaluate Solid Queue vs keeping Sidekiq"
  fi

  # Redis cache → Solid Cache
  if grep -rq "redis" Gemfile config/ 2>/dev/null; then
    info "Redis detected — Rails 8 offers Solid Cache/Cable (no Redis needed)"
    echo "- [ ] Evaluate Solid Cache/Cable vs keeping Redis"
  fi

  # params.require.permit → params.expect
  PARAMS_COUNT=$(grep -rc 'params\.require' app/controllers/ 2>/dev/null | awk -F: '{s+=$2}END{print s}')
  if [[ "${PARAMS_COUNT:-0}" -gt 0 ]]; then
    warn "$PARAMS_COUNT uses of params.require — migrate to params.expect"
    echo "- [ ] Migrate $PARAMS_COUNT params.require calls to params.expect"
  else
    pass "No params.require calls to migrate"
    echo "- [x] Already using params.expect or no strong params"
  fi

  echo ""
fi

# ── Step 9: Test suite ───────────────────────────────────────────────────────
step 9 "Test Suite"

echo "## Test Results"

info "Running test suite..."
if [[ -f ".rspec" ]] || [[ -d "spec" ]]; then
  if bundle exec rspec --format documentation 2>/dev/null; then
    pass "RSpec tests pass"
    echo "- ✅ All RSpec tests pass"
  else
    fail "RSpec tests have failures — fix before upgrading"
    echo "- ❌ RSpec test failures detected"
  fi
elif [[ -d "test" ]]; then
  if bin/rails test 2>/dev/null; then
    pass "Minitest tests pass"
    echo "- ✅ All Minitest tests pass"
  else
    fail "Tests have failures — fix before upgrading"
    echo "- ❌ Test failures detected"
  fi
else
  warn "No test suite found"
  echo "- ⚠️ No test suite found"
fi

} 2>&1 | tee "$REPORT_FILE"

echo ""
bold "═══════════════════════════════════════════════════════"
green " Report saved to: $REPORT_FILE"
bold "═══════════════════════════════════════════════════════"
