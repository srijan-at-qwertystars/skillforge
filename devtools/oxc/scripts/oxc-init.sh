#!/bin/bash
# Initialize OXC in a project
# Usage: ./oxc-init.sh

if [ -f ".oxlintrc.json" ]; then
    echo "⚠️  .oxlintrc.json already exists"
    exit 1
fi

cat > .oxlintrc.json << 'EOF'
{
  "rules": {
    "eqeqeq": "error",
    "no-console": "warn",
    "no-debugger": "error",
    "no-unused-vars": "error"
  },
  "env": {
    "browser": true,
    "es2021": true,
    "node": true
  },
  "ignorePatterns": [
    "dist/**",
    "node_modules/**",
    "*.config.js",
    "*.config.ts"
  ]
}
EOF

echo "✅ Created .oxlintrc.json"
echo "📦 Installing oxlint..."
npm install -D oxlint

echo ""
echo "🎉 OXC initialized! Run 'npx oxlint .' to start linting"
