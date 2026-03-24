#!/usr/bin/env bash
# check-async-issues.sh — Static analysis helper for common async anti-patterns
#
# Usage: ./check-async-issues.sh <project-dir>
#
# Checks for:
#   - Blocking calls in async context (std::fs, std::net, thread::sleep)
#   - Lock held across .await (MutexGuard patterns)
#   - Missing spawn_blocking for CPU-heavy ops
#   - Unbounded channel usage (OOM risk)
#   - Forgotten JoinHandles (fire-and-forget spawns)
#   - Common tokio misuse patterns
#
# Exit codes: 0 = clean, 1 = issues found, 2 = usage error

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <project-dir>"
    echo "Example: $0 ./my-rust-project"
    exit 2
fi

PROJECT_DIR="$1"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: '$PROJECT_DIR' is not a directory"
    exit 2
fi

if [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
    echo "Warning: No Cargo.toml found in '$PROJECT_DIR'. Scanning anyway."
fi

ISSUES=0
WARNINGS=0

check_pattern() {
    local severity="$1"   # ERROR or WARN
    local label="$2"
    local pattern="$3"
    local explanation="$4"
    local extra_grep_args="${5:---include=*.rs}"

    local matches
    matches=$(grep -rn $extra_grep_args "$pattern" "$PROJECT_DIR/src" 2>/dev/null || true)

    if [ -n "$matches" ]; then
        if [ "$severity" = "ERROR" ]; then
            ISSUES=$((ISSUES + 1))
            echo "❌ $label"
        else
            WARNINGS=$((WARNINGS + 1))
            echo "⚠️  $label"
        fi
        echo "   $explanation"
        echo "$matches" | head -10 | sed 's/^/   /'
        local count
        count=$(echo "$matches" | wc -l)
        if [ "$count" -gt 10 ]; then
            echo "   ... and $((count - 10)) more"
        fi
        echo ""
    fi
}

echo "=== Async Anti-Pattern Checker ==="
echo "Scanning: $PROJECT_DIR"
echo ""

# --- Blocking I/O in async context ---
check_pattern "ERROR" \
    "Blocking file I/O (std::fs)" \
    'std::fs::' \
    "Use tokio::fs:: instead, or wrap in spawn_blocking."

check_pattern "ERROR" \
    "Blocking network I/O (std::net)" \
    'std::net::TcpStream\|std::net::TcpListener\|std::net::UdpSocket' \
    "Use tokio::net:: for async networking."

check_pattern "ERROR" \
    "Thread::sleep in async code" \
    'std::thread::sleep\|thread::sleep(' \
    "Use tokio::time::sleep().await instead."

check_pattern "WARN" \
    "Blocking HTTP client (ureq/reqwest::blocking)" \
    'ureq::\|reqwest::blocking' \
    "Use async reqwest::Client in async context."

# --- Lock across await ---
check_pattern "ERROR" \
    "Potential std::sync::Mutex held across .await" \
    '\.lock()\.unwrap()' \
    "If this guard is held across an .await point, it blocks the runtime. Scope the guard or use tokio::sync::Mutex."

# Check for the specific pattern: lock then await on nearby lines
if grep -rn --include='*.rs' -A3 '\.lock()' "$PROJECT_DIR/src" 2>/dev/null | grep -q '\.await'; then
    WARNINGS=$((WARNINGS + 1))
    echo "⚠️  Lock guard possibly held across .await"
    echo "   A .lock() call has an .await within 3 lines. Verify the guard is dropped before .await."
    grep -rn --include='*.rs' -A3 '\.lock()' "$PROJECT_DIR/src" 2>/dev/null | grep -B1 '\.await' | head -10 | sed 's/^/   /'
    echo ""
fi

# --- Unbounded channels ---
check_pattern "WARN" \
    "Unbounded channel (OOM risk under load)" \
    'unbounded_channel\|mpsc::unbounded' \
    "Use bounded channels with backpressure in production. Unbounded channels can cause OOM."

# --- Forgotten JoinHandles ---
# Look for tokio::spawn not assigned to a variable or JoinSet
if grep -rn --include='*.rs' 'tokio::spawn(' "$PROJECT_DIR/src" 2>/dev/null | grep -v 'let \|set\.spawn\|handles\.\|\.push(' | grep -v '^\s*//' > /tmp/async-check-spawn.$$ 2>/dev/null; then
    if [ -s /tmp/async-check-spawn.$$ ]; then
        WARNINGS=$((WARNINGS + 1))
        echo "⚠️  Potentially forgotten JoinHandle (fire-and-forget spawn)"
        echo "   tokio::spawn() result not stored. Panics will be silent. Use JoinSet or store the handle."
        head -10 /tmp/async-check-spawn.$$ | sed 's/^/   /'
        echo ""
    fi
fi
rm -f /tmp/async-check-spawn.$$

# --- Missing spawn_blocking ---
check_pattern "WARN" \
    "CPU-heavy crate used without spawn_blocking" \
    'argon2\|bcrypt\|scrypt\|pbkdf2\|image::open\|zip::read\|flate2' \
    "CPU-heavy operations should be wrapped in tokio::task::spawn_blocking()."

# --- Recursive async without Box::pin ---
if grep -rn --include='*.rs' 'async fn' "$PROJECT_DIR/src" 2>/dev/null | while read -r line; do
    file=$(echo "$line" | cut -d: -f1)
    fn_name=$(echo "$line" | grep -oP 'async fn \K\w+' || true)
    if [ -n "$fn_name" ] && grep -q "$fn_name(" "$file" 2>/dev/null; then
        # Check if function calls itself (potential recursive async)
        if grep -c "$fn_name(" "$file" 2>/dev/null | grep -q '^[2-9]'; then
            echo "$line"
        fi
    fi
done | head -5 | grep -q .; then
    WARNINGS=$((WARNINGS + 1))
    echo "⚠️  Possible recursive async function"
    echo "   Recursive async functions need Box::pin() to avoid stack overflow."
    echo ""
fi

# --- .await in Drop ---
check_pattern "ERROR" \
    ".await used in Drop impl" \
    'impl.*Drop.*\|fn drop.*' \
    "Rust doesn't support async drop. Use explicit cleanup methods or spawn a cleanup task."

# --- Blocking in async test ---
if grep -rn --include='*.rs' -A5 '#\[tokio::test\]' "$PROJECT_DIR/src" 2>/dev/null | grep -q 'std::thread::sleep\|std::fs::'; then
    WARNINGS=$((WARNINGS + 1))
    echo "⚠️  Blocking call in async test"
    echo "   Tests with #[tokio::test] should use async alternatives."
    echo ""
fi

# --- Summary ---
echo "================================"
echo "Scan complete."
echo "  Errors:   $ISSUES"
echo "  Warnings: $WARNINGS"

if [ "$ISSUES" -gt 0 ]; then
    echo ""
    echo "Fix errors before shipping. Warnings are advisory."
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    echo ""
    echo "No errors. Review warnings for potential improvements."
    exit 0
else
    echo "  ✅ No issues found!"
    exit 0
fi
