#!/bin/bash
# Migrate from Webpack to Rspack
# Usage: ./scripts/migrate-from-webpack.sh

set -e

echo "=== Webpack to Rspack Migration Script ==="
echo ""

# Check for webpack config
if [ -f "webpack.config.js" ]; then
    echo "Found webpack.config.js"
    read -p "Rename to rspack.config.js? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mv webpack.config.js rspack.config.js
        echo "Renamed to rspack.config.js"
    fi
fi

# Check for package.json
if [ ! -f "package.json" ]; then
    echo "Error: package.json not found"
    exit 1
fi

echo ""
echo "=== Installing Rspack dependencies ==="
npm install -D @rspack/core @rspack/cli

echo ""
echo "=== Removing webpack dependencies ==="
npm uninstall webpack webpack-cli webpack-dev-server babel-loader 2>/dev/null || true

echo ""
echo "=== Migration Checklist ==="
echo "[ ] Replace babel-loader with builtin:swc-loader"
echo "[ ] Replace HtmlWebpackPlugin with HtmlRspackPlugin"
echo "[ ] Replace MiniCssExtractPlugin with CssExtractRspackPlugin"
echo "[ ] Update any webpack-specific plugins"
echo "[ ] Test build: npx rspack build"
echo "[ ] Test dev server: npx rspack serve"
echo ""
echo "See https://rspack.dev/guide/migration/webpack for detailed guide"
