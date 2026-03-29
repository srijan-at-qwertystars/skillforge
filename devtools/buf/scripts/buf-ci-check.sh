#!/bin/bash
# buf-ci-check.sh - CI-friendly Buf checks with JSON output
# Usage: ./buf-ci-check.sh [against-ref]

set -euo pipefail

AGAINST="${1:-.git#branch=main}"
EXIT_CODE=0

echo "{"
echo '  "checks": ['

# Format check
echo '    {'
echo '      "name": "format",'
echo -n '      "status": "'
if buf format --diff --exit-code > /dev/null 2>&1; then
    echo 'passed",'
    echo '      "issues": []'
else
    echo 'failed",'
    echo '      "issues": ["Proto files need formatting. Run: buf format -w"]'
    EXIT_CODE=1
fi
echo '    },'

# Lint check
echo '    {'
echo '      "name": "lint",'
echo -n '      "status": "'
if LINT_OUTPUT=$(buf lint --error-format=json 2>&1); then
    echo 'passed",'
    echo '      "issues": []'
else
    echo 'failed",'
    echo '      "issues": '
    echo "$LINT_OUTPUT" | jq -s '.' 2>/dev/null || echo '[]'
    EXIT_CODE=1
fi
echo '    },'

# Build check
echo '    {'
echo '      "name": "build",'
echo -n '      "status": "'
if buf build > /dev/null 2>&1; then
    echo 'passed",'
    echo '      "issues": []'
else
    echo 'failed",'
    echo '      "issues": ["Build failed - check proto syntax and imports"]'
    EXIT_CODE=1
fi
echo '    },'

# Breaking changes
echo '    {'
echo '      "name": "breaking",'
echo "      \"against\": \"$AGAINST\","
echo -n '      "status": "'
if BREAKING_OUTPUT=$(buf breaking --against "$AGAINST" --error-format=json 2>&1); then
    echo 'passed",'
    echo '      "issues": []'
else
    echo 'failed",'
    echo '      "issues": '
    echo "$BREAKING_OUTPUT" | jq -s '.' 2>/dev/null || echo '[]'
    EXIT_CODE=1
fi
echo '    }'

echo '  ],'
echo -n '  "overall": "'
if [ $EXIT_CODE -eq 0 ]; then
    echo 'passed"'
else
    echo 'failed"'
fi
echo "}"

exit $EXIT_CODE
