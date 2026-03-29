#!/bin/bash
# Deployment helpers for Encore

set -e

ENVIRONMENT=${1:-dev}
COMMAND=${2:-deploy}

case "$COMMAND" in
    deploy)
        echo "🚀 Deploying to Encore Cloud ($ENVIRONMENT)..."
        encore cloud deploy --env="$ENVIRONMENT"
        ;;
    logs)
        echo "📜 Showing logs for $ENVIRONMENT..."
        encore cloud logs --env="$ENVIRONMENT"
        ;;
    status)
        echo "📊 Checking deployment status..."
        encore cloud apps list
        ;;
    build-docker)
        TAG=${3:-my-app:latest}
        echo "🐳 Building Docker image: $TAG"
        encore build docker "$TAG"
        ;;
    build-k8s)
        OUTPUT_DIR=${3:-./k8s}
        echo "☸️  Building Kubernetes manifests to: $OUTPUT_DIR"
        encore build k8s --env="$ENVIRONMENT" "$OUTPUT_DIR"
        ;;
    login)
        echo "🔑 Logging into Encore Cloud..."
        encore cloud login
        ;;
    help|*)
        echo "Encore Deployment Helper"
        echo ""
        echo "Usage: $0 <environment> <command> [options]"
        echo ""
        echo "Environments: dev, staging, prod"
        echo ""
        echo "Commands:"
        echo "  deploy                    - Deploy to Encore Cloud"
        echo "  logs                      - Show deployment logs"
        echo "  status                    - Show app status"
        echo "  build-docker <tag>        - Build Docker image"
        echo "  build-k8s <output-dir>    - Build Kubernetes manifests"
        echo "  login                     - Login to Encore Cloud"
        echo ""
        echo "Examples:"
        echo "  $0 prod deploy"
        echo "  $0 dev build-docker myapp:v1.0"
        echo "  $0 prod logs"
        ;;
esac
