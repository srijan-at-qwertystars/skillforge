#!/bin/bash
# Initialize new Rspack project
# Usage: ./scripts/init-project.sh [project-name]

set -e

PROJECT_NAME="${1:-my-rspack-app}"

echo "=== Initializing Rspack Project: $PROJECT_NAME ==="

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize package.json
cat > package.json << 'EOF'
{
  "name": "my-rspack-app",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "rspack serve",
    "build": "rspack build",
    "build:analyze": "rspack build --analyze",
    "preview": "rspack serve --mode=production"
  },
  "devDependencies": {
    "@rspack/core": "^1.0.0",
    "@rspack/cli": "^1.0.0",
    "@rspack/plugin-react-refresh": "^1.0.0"
  }
}
EOF

# Create rspack.config.js
cat > rspack.config.js << 'EOF'
const rspack = require('@rspack/core');
const path = require('path');

const isDev = process.env.NODE_ENV === 'development';

module.exports = {
  entry: './src/index.js',
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: '[name].[contenthash:8].js',
    clean: true
  },
  mode: isDev ? 'development' : 'production',
  module: {
    rules: [
      {
        test: /\.[jt]sx?$/,
        use: {
          loader: 'builtin:swc-loader',
          options: {
            jsc: {
              parser: { syntax: 'ecmascript', jsx: true },
              transform: {
                react: {
                  runtime: 'automatic',
                  development: isDev,
                  refresh: isDev
                }
              }
            }
          }
        }
      },
      {
        test: /\.css$/,
        use: ['style-loader', 'css-loader']
      }
    ]
  },
  plugins: [
    new rspack.HtmlRspackPlugin({
      template: './public/index.html'
    }),
    isDev && new rspack.ReactRefreshPlugin()
  ].filter(Boolean),
  devServer: {
    port: 3000,
    hot: true,
    open: true
  }
};
EOF

# Create directories
mkdir -p src public

# Create basic index.html
cat > public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Rspack App</title>
</head>
<body>
  <div id="root"></div>
</body>
</html>
EOF

# Create basic index.js
cat > src/index.js << 'EOF'
console.log('Hello from Rspack!');

const root = document.getElementById('root');
if (root) {
  root.innerHTML = '<h1>Welcome to Rspack!</h1>';
}
EOF

# Install dependencies
echo "Installing dependencies..."
npm install

echo ""
echo "=== Project initialized successfully! ==="
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm run dev"
echo ""
