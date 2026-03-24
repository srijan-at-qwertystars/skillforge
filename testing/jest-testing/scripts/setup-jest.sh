#!/usr/bin/env bash
#
# setup-jest.sh — Configure Jest for a TypeScript project
#
# Usage: ./setup-jest.sh [--swc|--ts-jest] [--react]
#   --swc       Use @swc/jest transformer (default, fastest)
#   --ts-jest   Use ts-jest transformer (type-checking)
#   --react     Add React Testing Library setup
#
# Installs dependencies, generates jest.config.ts, and creates setup files.

set -euo pipefail

TRANSFORMER="swc"
REACT=false

for arg in "$@"; do
  case "$arg" in
    --swc)      TRANSFORMER="swc" ;;
    --ts-jest)  TRANSFORMER="ts-jest" ;;
    --react)    REACT=true ;;
    -h|--help)
      head -10 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

echo "🔧 Setting up Jest with $TRANSFORMER transformer..."

# Check for package manager
if [ -f "pnpm-lock.yaml" ]; then
  PM="pnpm"
  INSTALL="pnpm add -D"
elif [ -f "yarn.lock" ]; then
  PM="yarn"
  INSTALL="yarn add -D"
else
  PM="npm"
  INSTALL="npm install -D"
fi

echo "📦 Using $PM as package manager"

# Core dependencies
DEPS="jest @types/jest"

if [ "$TRANSFORMER" = "swc" ]; then
  DEPS="$DEPS @swc/core @swc/jest"
else
  DEPS="$DEPS ts-jest"
fi

if [ "$REACT" = true ]; then
  DEPS="$DEPS @testing-library/react @testing-library/jest-dom @testing-library/user-event jest-environment-jsdom"
fi

echo "📥 Installing: $DEPS"
$INSTALL $DEPS

# Determine test environment
TEST_ENV="node"
if [ "$REACT" = true ]; then
  TEST_ENV="jsdom"
fi

# Generate jest.config.ts
cat > jest.config.ts << JESTCONFIG
import type { Config } from 'jest';

const config: Config = {
  testEnvironment: '${TEST_ENV}',
  roots: ['<rootDir>/src'],
  testMatch: ['**/__tests__/**/*.test.ts(x)?', '**/*.test.ts(x)?'],
JESTCONFIG

if [ "$TRANSFORMER" = "swc" ]; then
  cat >> jest.config.ts << 'JESTCONFIG'
  transform: {
    '^.+\\.tsx?$': '@swc/jest',
  },
JESTCONFIG
else
  cat >> jest.config.ts << 'JESTCONFIG'
  transform: {
    '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }],
  },
JESTCONFIG
fi

cat >> jest.config.ts << 'JESTCONFIG'
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
    '\\.(css|less|scss|sass)$': 'identity-obj-proxy',
    '\\.(jpg|jpeg|png|gif|webp|svg)$': '<rootDir>/__mocks__/fileMock.js',
  },
  setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
  collectCoverageFrom: [
    'src/**/*.{ts,tsx}',
    '!src/**/*.d.ts',
    '!src/**/index.ts',
    '!src/**/*.stories.{ts,tsx}',
  ],
  coverageThreshold: {
    global: { branches: 80, functions: 80, lines: 80, statements: 80 },
  },
  coverageReporters: ['text', 'text-summary', 'lcov'],
  clearMocks: true,
  restoreMocks: true,
};

export default config;
JESTCONFIG

echo "✅ Created jest.config.ts"

# Generate jest.setup.ts
if [ "$REACT" = true ]; then
  cat > jest.setup.ts << 'SETUP'
import '@testing-library/jest-dom';
SETUP
else
  cat > jest.setup.ts << 'SETUP'
// Jest setup file — add custom matchers and global config here
SETUP
fi

echo "✅ Created jest.setup.ts"

# Create file mock
mkdir -p __mocks__
echo "module.exports = 'test-file-stub';" > __mocks__/fileMock.js
echo "✅ Created __mocks__/fileMock.js"

# Add test script to package.json if not present
if command -v node &> /dev/null; then
  node -e "
    const pkg = require('./package.json');
    if (!pkg.scripts) pkg.scripts = {};
    if (!pkg.scripts.test || pkg.scripts.test === 'echo \"Error: no test specified\" && exit 1') {
      pkg.scripts.test = 'jest';
    }
    if (!pkg.scripts['test:watch']) pkg.scripts['test:watch'] = 'jest --watch';
    if (!pkg.scripts['test:coverage']) pkg.scripts['test:coverage'] = 'jest --coverage';
    require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
  " 2>/dev/null && echo "✅ Updated package.json scripts" || echo "⚠️  Could not update package.json scripts"
fi

echo ""
echo "🎉 Jest setup complete!"
echo "   Run tests:     $PM test"
echo "   Watch mode:     $PM test -- --watch"
echo "   Coverage:       $PM test -- --coverage"
