#!/bin/bash
# Secret management helper for Encore

set -e

COMMAND=${1:-help}
ENVIRONMENT=${2:-local}
KEY=${3:-}
VALUE=${4:-}

case "$COMMAND" in
    set)
        if [ -z "$KEY" ] || [ -z "$VALUE" ]; then
            echo "Usage: $0 set <environment> <key> <value>"
            echo "Example: $0 set local API_KEY mysecretvalue"
            exit 1
        fi
        echo "🔐 Setting secret: $KEY (env: $ENVIRONMENT)"
        encore secret set --$ENVIRONMENT "$KEY" "$VALUE"
        ;;
    list)
        echo "📋 Listing secrets for $ENVIRONMENT environment..."
        encore secret list --$ENVIRONMENT 2>/dev/null || echo "No secrets found or command not available"
        ;;
    help|*)
        echo "Encore Secret Helper"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  set <env> <key> <value>   - Set a secret"
        echo "  list <env>                - List secrets (if available)"
        echo ""
        echo "Environments: local, dev, prod"
        echo ""
        echo "Examples:"
        echo "  $0 set local STRIPE_KEY sk_test_..."
        echo "  $0 set prod DATABASE_URL postgres://..."
        ;;
esac
