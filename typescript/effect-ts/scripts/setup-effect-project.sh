#!/usr/bin/env bash
# setup-effect-project.sh — Scaffold a new Effect-TS project
#
# Usage:
#   ./setup-effect-project.sh <project-name> [--with-platform] [--with-sql]
#
# Options:
#   --with-platform   Install @effect/platform and @effect/platform-node
#   --with-sql        Install @effect/sql and @effect/sql-pg
#
# Examples:
#   ./setup-effect-project.sh my-app
#   ./setup-effect-project.sh my-api --with-platform
#   ./setup-effect-project.sh my-api --with-platform --with-sql

set -euo pipefail

PROJECT_NAME="${1:-}"
WITH_PLATFORM=false
WITH_SQL=false

if [ -z "$PROJECT_NAME" ]; then
  echo "Usage: $0 <project-name> [--with-platform] [--with-sql]"
  exit 1
fi

shift
for arg in "$@"; do
  case "$arg" in
    --with-platform) WITH_PLATFORM=true ;;
    --with-sql) WITH_SQL=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

echo "🔧 Creating Effect project: $PROJECT_NAME"

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize package.json
npm init -y --silent

# Install core dependencies
echo "📦 Installing effect..."
npm install effect

# Install optional platform packages
if [ "$WITH_PLATFORM" = true ]; then
  echo "📦 Installing @effect/platform..."
  npm install @effect/platform @effect/platform-node
fi

if [ "$WITH_SQL" = true ]; then
  echo "📦 Installing @effect/sql..."
  npm install @effect/sql @effect/sql-pg
fi

# Install dev dependencies
echo "📦 Installing dev dependencies..."
npm install -D typescript @types/node tsx vitest

# Create tsconfig.json
cat > tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "exactOptionalPropertyTypes": true,
    "noUncheckedIndexedAccess": true,
    "noEmitOnError": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "incremental": true
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# Create directory structure
mkdir -p src/{services,errors,schemas,layers}

# Create sample tagged error
cat > src/errors/index.ts << 'ERRORS'
import { Data } from "effect"

export class NotFoundError extends Data.TaggedError("NotFoundError")<{
  entity: string
  id: string
}> {}

export class ValidationError extends Data.TaggedError("ValidationError")<{
  field: string
  reason: string
}> {}
ERRORS

# Create sample service
cat > src/services/greeting.ts << 'SERVICE'
import { Context, Effect, Layer } from "effect"

export class GreetingService extends Context.Tag("GreetingService")<
  GreetingService,
  {
    readonly greet: (name: string) => Effect.Effect<string>
  }
>() {}

export const GreetingServiceLive = Layer.succeed(GreetingService, {
  greet: (name) => Effect.succeed(`Hello, ${name}!`),
})
SERVICE

# Create main entry point
cat > src/main.ts << 'MAIN'
import { Effect } from "effect"
import { GreetingService, GreetingServiceLive } from "./services/greeting.js"

const program = Effect.gen(function* () {
  const greeting = yield* GreetingService
  const message = yield* greeting.greet("Effect")
  yield* Effect.log(message)
})

const runnable = program.pipe(Effect.provide(GreetingServiceLive))

Effect.runPromise(runnable).catch(console.error)
MAIN

# Add scripts to package.json
npx --yes json -I -f package.json \
  -e 'this.type = "module"' \
  -e 'this.scripts.dev = "tsx src/main.ts"' \
  -e 'this.scripts.build = "tsc"' \
  -e 'this.scripts.start = "node dist/main.js"' \
  -e 'this.scripts.test = "vitest run"' \
  -e 'this.scripts["test:watch"] = "vitest"' \
  2>/dev/null || {
    # Fallback: manually edit if json CLI not available
    node -e "
      const pkg = require('./package.json');
      pkg.type = 'module';
      pkg.scripts = {
        ...pkg.scripts,
        dev: 'tsx src/main.ts',
        build: 'tsc',
        start: 'node dist/main.js',
        test: 'vitest run',
        'test:watch': 'vitest',
      };
      require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
    "
  }

# Create .gitignore
cat > .gitignore << 'GITIGNORE'
node_modules/
dist/
*.tsbuildinfo
.env
GITIGNORE

echo ""
echo "✅ Effect project '$PROJECT_NAME' created!"
echo ""
echo "  cd $PROJECT_NAME"
echo "  npm run dev     # run with tsx"
echo "  npm run build   # compile TypeScript"
echo "  npm test        # run tests"
