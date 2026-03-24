#!/usr/bin/env bash
#
# migrate-to-jest.sh — Help migrate from Mocha/Jasmine to Jest
#
# Usage: ./migrate-to-jest.sh [--from mocha|jasmine] [--dry-run] [--dir src]
#   --from       Source framework (auto-detected if omitted)
#   --dry-run    Show what would change without modifying files
#   --dir        Directory to scan (default: src)
#
# Performs: dependency swap, config generation, syntax transformations,
# and prints manual migration steps.

set -euo pipefail

FROM=""
DRY_RUN=false
DIR="src"

for arg in "$@"; do
  case "$arg" in
    --from)     shift; FROM="$1" ;;
    --dry-run)  DRY_RUN=true ;;
    --dir)      shift; DIR="$1" ;;
    -h|--help)  head -12 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
  esac
  shift 2>/dev/null || true
done

# Auto-detect source framework
if [ -z "$FROM" ]; then
  if [ -f ".mocharc.yml" ] || [ -f ".mocharc.js" ] || [ -f ".mocharc.json" ]; then
    FROM="mocha"
  elif grep -rq "jasmine" package.json 2>/dev/null; then
    FROM="jasmine"
  elif grep -rq "mocha" package.json 2>/dev/null; then
    FROM="mocha"
  else
    echo "❌ Could not detect test framework. Use --from mocha|jasmine"
    exit 1
  fi
fi

echo "🔄 Migrating from $FROM to Jest"
echo "   Directory: $DIR"
echo "   Dry run:   $DRY_RUN"
echo ""

# Step 1: Identify test files
echo "📂 Scanning for test files..."
TEST_FILES=$(find "$DIR" -type f \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" \) 2>/dev/null || true)
TEST_COUNT=$(echo "$TEST_FILES" | grep -c '.' 2>/dev/null || echo "0")
echo "   Found $TEST_COUNT test files"
echo ""

# Step 2: Show syntax transformations needed
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 SYNTAX TRANSFORMATIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FROM" = "mocha" ]; then
  cat << 'EOF'

Mocha → Jest changes:
  ✓ describe/it/before/after — identical, no changes needed
  ✗ require('chai').expect    → remove, use Jest's expect (global)
  ✗ require('sinon')          → use jest.fn(), jest.spyOn()
  ✗ sinon.stub(obj, 'method') → jest.spyOn(obj, 'method').mockReturnValue(...)
  ✗ sinon.spy(fn)             → jest.fn(fn)
  ✗ stub.calledOnce           → expect(fn).toHaveBeenCalledTimes(1)
  ✗ stub.calledWith(a, b)     → expect(fn).toHaveBeenCalledWith(a, b)
  ✗ expect(x).to.equal(y)     → expect(x).toBe(y)
  ✗ expect(x).to.deep.equal   → expect(x).toEqual(y)
  ✗ expect(x).to.be.true      → expect(x).toBe(true)
  ✗ expect(x).to.include(y)   → expect(x).toContain(y)
  ✗ expect(x).to.throw()      → expect(() => x()).toThrow()
  ✗ expect(x).to.have.length  → expect(x).toHaveLength(n)
  ✗ this.timeout(ms)          → jest.setTimeout(ms) or test('...', fn, ms)
EOF

elif [ "$FROM" = "jasmine" ]; then
  cat << 'EOF'

Jasmine → Jest changes (most syntax is compatible):
  ✓ describe/it/beforeEach/afterEach — identical
  ✓ expect(x).toBe(y)        — identical
  ✓ expect(x).toEqual(y)     — identical
  ✗ jasmine.createSpy()       → jest.fn()
  ✗ jasmine.createSpyObj()    → object with jest.fn() values
  ✗ spyOn(obj, 'method')      → jest.spyOn(obj, 'method') (mostly compatible)
  ✗ spy.and.returnValue(v)    → spy.mockReturnValue(v)
  ✗ spy.and.callFake(fn)      → spy.mockImplementation(fn)
  ✗ spy.calls.count()         → spy.mock.calls.length
  ✗ jasmine.clock().install() → jest.useFakeTimers()
  ✗ jasmine.clock().tick(ms)  → jest.advanceTimersByTime(ms)
  ✗ jasmine.any(Type)         → expect.any(Type)
EOF
fi

# Step 3: Scan for patterns that need changing
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 SCANNING FOR PATTERNS TO MIGRATE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$FROM" = "mocha" ]; then
  PATTERNS=("require.*chai" "require.*sinon" "sinon\." "\.to\.equal" "\.to\.deep\.equal" "\.to\.be\." "\.to\.have\." "\.to\.include" "\.to\.throw" "this\.timeout")
elif [ "$FROM" = "jasmine" ]; then
  PATTERNS=("jasmine\.createSpy" "jasmine\.createSpyObj" "\.and\.returnValue" "\.and\.callFake" "\.calls\.count" "jasmine\.clock" "jasmine\.any")
fi

for pattern in "${PATTERNS[@]}"; do
  MATCHES=$(grep -rl "$pattern" "$DIR" 2>/dev/null | head -20 || true)
  if [ -n "$MATCHES" ]; then
    COUNT=$(echo "$MATCHES" | wc -l)
    echo "  ⚠️  $pattern — found in $COUNT file(s)"
    echo "$MATCHES" | head -3 | sed 's/^/       /'
    if [ "$COUNT" -gt 3 ]; then
      echo "       ... and $((COUNT - 3)) more"
    fi
    echo ""
  fi
done

# Step 4: Dependency instructions
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 DEPENDENCY CHANGES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$FROM" = "mocha" ]; then
  echo "  Remove: mocha chai sinon @types/mocha @types/chai @types/sinon nyc c8"
  echo "  Add:    jest @types/jest ts-jest (or @swc/jest)"
elif [ "$FROM" = "jasmine" ]; then
  echo "  Remove: jasmine jasmine-core @types/jasmine karma karma-* istanbul"
  echo "  Add:    jest @types/jest ts-jest (or @swc/jest)"
fi

echo ""
echo "  Commands:"
if [ "$FROM" = "mocha" ]; then
  echo "    npm uninstall mocha chai sinon @types/mocha @types/chai @types/sinon"
else
  echo "    npm uninstall jasmine jasmine-core @types/jasmine"
fi
echo "    npm install -D jest @types/jest @swc/core @swc/jest"

# Step 5: Config migration
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  CONFIG MIGRATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$FROM" = "mocha" ]; then
  echo "  Remove: .mocharc.yml / .mocharc.js / .mocharc.json"
  echo "  Remove: .nycrc / .nycrc.json (coverage config)"
fi
if [ "$FROM" = "jasmine" ]; then
  echo "  Remove: jasmine.json / karma.conf.js"
fi

echo "  Create: jest.config.ts (run setup-jest.sh or see assets/jest.config.ts)"
echo "  Update: package.json scripts — change 'test' to 'jest'"

if [ "$DRY_RUN" = false ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🛠️  AUTOMATED TRANSFORMS"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [ "$FROM" = "mocha" ]; then
    # Remove chai/sinon imports
    find "$DIR" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) \
      -exec grep -l "require.*chai\|require.*sinon\|from 'chai'\|from 'sinon'" {} \; 2>/dev/null | while read -r file; do
      echo "  ✏️  Removing chai/sinon imports from $file"
      sed -i.bak \
        -e "/require.*['\"]chai['\"]/d" \
        -e "/require.*['\"]sinon['\"]/d" \
        -e "/from ['\"]chai['\"]/d" \
        -e "/from ['\"]sinon['\"]/d" \
        "$file"
      rm -f "${file}.bak"
    done
  fi

  echo ""
  echo "  ℹ️  Automated transforms are conservative. Review all changes manually."
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Migration analysis complete."
echo "   Run with --dry-run to preview without changes."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
