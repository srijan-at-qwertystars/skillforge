#!/bin/bash
# Validate WXT configuration and check for common issues
# Usage: ./validate-config.sh

set -e

echo "🔍 Validating WXT configuration..."

# Check if wxt.config.ts exists
if [ ! -f "wxt.config.ts" ]; then
    echo "❌ wxt.config.ts not found in current directory"
    exit 1
fi

echo "✅ wxt.config.ts found"

# Check for common configuration issues
echo ""
echo "📋 Checking configuration..."

# Check TypeScript types
echo "  - Running TypeScript check..."
npm run postinstall 2>/dev/null || echo "    ⚠️  Could not regenerate types"

# Check for required entrypoints
if [ ! -d "src/entrypoints" ]; then
    echo "  ⚠️  src/entrypoints directory not found"
else
    echo "  ✅ src/entrypoints directory found"
    ENTRYPOINTS=$(find src/entrypoints -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) | wc -l)
    echo "  📁 Found $ENTRYPOINTS entrypoint files"
fi

# Check manifest configuration
echo ""
echo "📄 Checking manifest configuration..."
if grep -q "manifest:" wxt.config.ts 2>/dev/null; then
    echo "  ✅ Manifest configuration found in wxt.config.ts"
else
    echo "  ⚠️  No manifest configuration found in wxt.config.ts"
fi

# Check for storage permissions if storage is used
if grep -r "browser.storage" src/ 2>/dev/null && ! grep -q "storage" wxt.config.ts 2>/dev/null; then
    echo "  ⚠️  Using browser.storage but 'storage' permission may not be declared"
fi

echo ""
echo "✅ Validation complete!"
