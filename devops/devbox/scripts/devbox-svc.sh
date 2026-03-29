#!/bin/bash
# Devbox Service Manager Helper
# Simplifies common service operations

set -euo pipefail

COMMAND="${1:-help}"
SERVICE="${2:-}"

case "$COMMAND" in
    up|start)
        if [ -n "$SERVICE" ]; then
            echo "🚀 Starting service: $SERVICE"
            devbox services up "$SERVICE"
        else
            echo "🚀 Starting all services..."
            devbox services up -b
            echo "✅ Services started in background"
            echo "Run 'devbox services attach' to view logs"
        fi
        ;;

    down|stop)
        if [ -n "$SERVICE" ]; then
            echo "🛑 Stopping service: $SERVICE"
            devbox services stop "$SERVICE"
        else
            echo "🛑 Stopping all services..."
            devbox services stop
        fi
        ;;

    restart)
        if [ -n "$SERVICE" ]; then
            echo "🔄 Restarting service: $SERVICE"
            devbox services stop "$SERVICE" 2>/dev/null || true
            sleep 1
            devbox services up "$SERVICE"
        else
            echo "🔄 Restarting all services..."
            devbox services stop 2>/dev/null || true
            sleep 1
            devbox services up -b
        fi
        ;;

    status|ls)
        echo "📋 Service Status:"
        devbox services ls
        ;;

    logs|attach)
        echo "📜 Attaching to service logs (Ctrl+C to detach)..."
        devbox services attach
        ;;

    psql)
        if devbox services ls 2>/dev/null | grep -q postgresql; then
            echo "🐘 Connecting to PostgreSQL..."
            devbox shell -- psql "${SERVICE:-postgres://localhost:5432/postgres}"
        else
            echo "❌ PostgreSQL service not running"
            echo "Run: devbox services up postgresql"
            exit 1
        fi
        ;;

    redis)
        if devbox services ls 2>/dev/null | grep -q redis; then
            echo "🔴 Connecting to Redis..."
            devbox shell -- redis-cli
        else
            echo "❌ Redis service not running"
            echo "Run: devbox services up redis"
            exit 1
        fi
        ;;

    mysql)
        if devbox services ls 2>/dev/null | grep -q mysql; then
            echo "🐬 Connecting to MySQL..."
            devbox shell -- mysql -u root -p
        else
            echo "❌ MySQL service not running"
            echo "Run: devbox services up mysql"
            exit 1
        fi
        ;;

    help|*)
        cat << 'EOF'
Devbox Service Manager

Usage: devbox-svc <command> [service]

Commands:
  up [service]       Start services (background if no service specified)
  down [service]     Stop services
  restart [service]  Restart services
  status, ls         List services and their status
  logs, attach       Attach to service logs
  psql [url]         Connect to PostgreSQL (if running)
  redis              Connect to Redis CLI (if running)
  mysql              Connect to MySQL (if running)
  help               Show this help message

Examples:
  devbox-svc up                    # Start all services in background
  devbox-svc up postgresql         # Start only PostgreSQL
  devbox-svc restart               # Restart all services
  devbox-svc psql                  # Connect to default postgres db
  devbox-svc psql postgres://localhost:5432/myapp  # Connect to specific db
EOF
        ;;
esac
