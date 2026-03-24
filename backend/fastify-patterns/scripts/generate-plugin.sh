#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# generate-plugin.sh — Generate a Fastify plugin with TypeScript typing
#
# Usage:
#   ./generate-plugin.sh <plugin-name> [--encapsulated]
#   ./generate-plugin.sh database
#   ./generate-plugin.sh auth-jwt
#   ./generate-plugin.sh admin-routes --encapsulated
#
# By default, generates a shared plugin (wrapped with fastify-plugin).
# Use --encapsulated for scoped plugins (routes with local hooks).
#
# Output: src/plugins/<plugin-name>.ts (or current directory if no src/plugins)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PLUGIN_NAME="${1:?Usage: $0 <plugin-name> [--encapsulated]}"
ENCAPSULATED=false

if [ "${2:-}" = "--encapsulated" ]; then
  ENCAPSULATED=true
fi

# Convert kebab-case to PascalCase for interface name
PASCAL_NAME=$(echo "$PLUGIN_NAME" | sed -r 's/(^|-)(\w)/\U\2/g')

# Determine output directory
if [ -d "src/plugins" ]; then
  OUTPUT_DIR="src/plugins"
elif [ -d "plugins" ]; then
  OUTPUT_DIR="plugins"
else
  OUTPUT_DIR="."
fi

OUTPUT_FILE="$OUTPUT_DIR/$PLUGIN_NAME.ts"

if [ -f "$OUTPUT_FILE" ]; then
  echo "Error: $OUTPUT_FILE already exists."
  exit 1
fi

if [ "$ENCAPSULATED" = true ]; then
  # ── Encapsulated Plugin (scoped routes + hooks) ──────────────────────────
  cat > "$OUTPUT_FILE" <<PLUGIN
import { FastifyPluginAsync } from 'fastify';

/**
 * ${PASCAL_NAME} plugin — encapsulated scope.
 * Routes, hooks, and decorators here are NOT visible to parent/siblings.
 */

interface ${PASCAL_NAME}Options {
  prefix?: string;
}

const ${PLUGIN_NAME//-/}Plugin: FastifyPluginAsync<${PASCAL_NAME}Options> = async (fastify, opts) => {
  // Scoped hooks — only apply to routes in this plugin
  fastify.addHook('onRequest', async (request, reply) => {
    request.log.info('${PLUGIN_NAME} plugin: request received');
  });

  // Routes
  fastify.get('/', {
    schema: {
      response: {
        200: {
          type: 'object',
          properties: {
            plugin: { type: 'string' },
            status: { type: 'string' },
          },
        },
      },
    },
  }, async () => ({
    plugin: '${PLUGIN_NAME}',
    status: 'ok',
  }));

  // Add more routes here
};

export default ${PLUGIN_NAME//-/}Plugin;
PLUGIN
else
  # ── Shared Plugin (with fastify-plugin) ────────────────────────────────────
  cat > "$OUTPUT_FILE" <<PLUGIN
import fp from 'fastify-plugin';
import { FastifyInstance } from 'fastify';

/**
 * ${PASCAL_NAME} plugin — shared scope (visible to parent and siblings).
 * Decorators added here are accessible throughout the application.
 */

export interface ${PASCAL_NAME}Options {
  // Define plugin configuration options here
  enabled?: boolean;
}

export default fp<${PASCAL_NAME}Options>(
  async (fastify: FastifyInstance, opts) => {
    const { enabled = true } = opts;

    if (!enabled) {
      fastify.log.info('${PLUGIN_NAME} plugin disabled');
      return;
    }

    // Add instance decorator
    // fastify.decorate('${PLUGIN_NAME//-/}', serviceInstance);

    // Add request decorator (set per-request in hook)
    // fastify.decorateRequest('${PLUGIN_NAME//-/}Data', null);

    // Cleanup on server close
    fastify.addHook('onClose', async () => {
      fastify.log.info('${PLUGIN_NAME} plugin: cleaning up');
      // Close connections, flush buffers, etc.
    });

    fastify.log.info('${PLUGIN_NAME} plugin loaded');
  },
  {
    name: '${PLUGIN_NAME}',
    // dependencies: ['config'],  // Uncomment to declare plugin dependencies
  },
);

// TypeScript: extend Fastify interfaces for decorators
// declare module 'fastify' {
//   interface FastifyInstance {
//     ${PLUGIN_NAME//-/}: YourServiceType;
//   }
// }
PLUGIN
fi

echo "✅ Plugin generated: $OUTPUT_FILE"
echo ""
if [ "$ENCAPSULATED" = true ]; then
  echo "   Type: Encapsulated (scoped routes + hooks)"
  echo "   Register with: app.register(import('./$OUTPUT_FILE'), { prefix: '/prefix' })"
else
  echo "   Type: Shared (fastify-plugin wrapped)"
  echo "   Register with: app.register(import('./$OUTPUT_FILE'), { /* opts */ })"
  echo "   Don't forget to add declaration merging in src/types/fastify.d.ts"
fi
