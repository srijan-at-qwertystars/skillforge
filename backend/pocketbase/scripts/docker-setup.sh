#!/bin/bash
# PocketBase Docker Setup Script
# Creates Docker Compose configuration for PocketBase

set -e

PROJECT_NAME="${1:-pocketbase-app}"
HTTP_PORT="${2:-8090}"
HTTPS_PORT="${3:-8091}"

echo "Setting up PocketBase Docker project: $PROJECT_NAME"

# Create project directory
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Create directories
mkdir -p pb_data pb_public pb_hooks pb_migrations

# Create docker-compose.yml
cat > docker-compose.yml << 'EOF'
services:
  pocketbase:
    image: ghcr.io/m/pocketbase:latest
    container_name: pocketbase
    restart: unless-stopped
    ports:
      - "${HTTP_PORT:-8090}:8090"
      - "${HTTPS_PORT:-8091}:8091"
    volumes:
      - ./pb_data:/pb/pb_data
      - ./pb_public:/pb/pb_public
      - ./pb_hooks:/pb/pb_hooks
      - ./pb_migrations:/pb/pb_migrations
    environment:
      - PB_ENCRYPTION_KEY=${PB_ENCRYPTION_KEY:-}
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8090/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    command: serve --http=0.0.0.0:8090 --https=0.0.0.0:8091

  # Optional: Litestream for backups
  litestream:
    image: litestream/litestream:latest
    container_name: litestream
    restart: unless-stopped
    volumes:
      - ./pb_data:/data
      - ./litestream.yml:/etc/litestream.yml
    command: replicate -config /etc/litestream.yml
    depends_on:
      - pocketbase
    profiles:
      - backup
EOF

# Create .env file
cat > .env << EOF
# PocketBase Configuration
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT

# Optional: Set encryption key for sensitive data
# PB_ENCRYPTION_KEY=$(openssl rand -hex 32)
EOF

# Create litestream config template
cat > litestream.yml << 'EOF'
dbs:
  - path: /data/data.db
    replicas:
      # Uncomment and configure your backup destination
      # - url: s3://mybucket/pocketbase-backup
      # - path: /backup/pocketbase
EOF

# Create README
cat > README.md << EOF
# $PROJECT_NAME - PocketBase Setup

## Quick Start

\`\`\`bash
# Start PocketBase
docker-compose up -d

# View logs
docker-compose logs -f pocketbase

# Stop
docker-compose down
\`\`\`

## Access

- Admin UI: http://localhost:$HTTP_PORT/_/
- API: http://localhost:$HTTP_PORT/api/

## Directories

- \`pb_data/\` - SQLite database and application data
- \`pb_public/\` - Static files served at root
- \`pb_hooks/\` - JavaScript/Go hook files
- \`pb_migrations/\` - Database migration files

## Backup (with Litestream)

\`\`\`bash
# Start with backup enabled
docker-compose --profile backup up -d
\`\`\`

Edit \`litestream.yml\` to configure your backup destination (S3, GCS, Azure, local).
EOF

echo ""
echo "Docker setup complete in: $PROJECT_NAME/"
echo ""
echo "To start:"
echo "  cd $PROJECT_NAME"
echo "  docker-compose up -d"
echo ""
echo "Admin UI will be available at: http://localhost:$HTTP_PORT/_/"
