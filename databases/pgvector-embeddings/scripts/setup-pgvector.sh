#!/usr/bin/env bash
#
# setup-pgvector.sh — Install pgvector extension and create a sample schema
#
# Usage:
#   ./setup-pgvector.sh                    # Uses defaults (localhost, postgres user)
#   ./setup-pgvector.sh -h HOST -p PORT -U USER -d DBNAME
#   PGPASSWORD=secret ./setup-pgvector.sh -h myhost -d mydb
#
# Prerequisites:
#   - PostgreSQL 15+ server running
#   - psql client installed
#   - Superuser or rds_superuser access (for CREATE EXTENSION)
#   - For source install: build-essential, postgresql-server-dev-XX
#
# What this script does:
#   1. Checks PostgreSQL version (requires 15+)
#   2. Installs pgvector extension if not present (from source or package)
#   3. Creates a sample table with vector, halfvec, and sparsevec columns
#   4. Creates HNSW and IVFFlat indexes
#   5. Inserts sample data and runs a test query
#
set -euo pipefail

# Defaults
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
INSTALL_FROM_SOURCE=false

usage() {
    echo "Usage: $0 [-h HOST] [-p PORT] [-U USER] [-d DBNAME] [--source]"
    echo ""
    echo "Options:"
    echo "  -h HOST     PostgreSQL host (default: localhost)"
    echo "  -p PORT     PostgreSQL port (default: 5432)"
    echo "  -U USER     PostgreSQL user (default: postgres)"
    echo "  -d DBNAME   Database name (default: postgres)"
    echo "  --source    Install pgvector from source (for non-package systems)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h) PGHOST="$2"; shift 2 ;;
        -p) PGPORT="$2"; shift 2 ;;
        -U) PGUSER="$2"; shift 2 ;;
        -d) PGDATABASE="$2"; shift 2 ;;
        --source) INSTALL_FROM_SOURCE=true; shift ;;
        --help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

PSQL="psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -v ON_ERROR_STOP=1"

log() { echo "[pgvector-setup] $*"; }
err() { echo "[pgvector-setup] ERROR: $*" >&2; exit 1; }

# --- 1. Check PostgreSQL version ---
log "Checking PostgreSQL version..."
PG_VERSION=$($PSQL -t -A -c "SHOW server_version_num;" 2>/dev/null) || err "Cannot connect to PostgreSQL at $PGHOST:$PGPORT"
PG_MAJOR=$((PG_VERSION / 10000))

if [[ $PG_MAJOR -lt 15 ]]; then
    err "PostgreSQL $PG_MAJOR detected. pgvector setup requires PostgreSQL 15+."
fi
log "PostgreSQL version: $PG_MAJOR (server_version_num=$PG_VERSION)"

# --- 2. Check/install pgvector extension ---
EXTENSION_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM pg_available_extensions WHERE name = 'vector';")

if [[ "$EXTENSION_EXISTS" -eq 0 ]]; then
    log "pgvector not found. Attempting installation..."

    if [[ "$INSTALL_FROM_SOURCE" == "true" ]]; then
        log "Installing pgvector from source..."
        PG_CONFIG=$(command -v pg_config) || err "pg_config not found. Install postgresql-server-dev-$PG_MAJOR"

        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT

        cd "$TMPDIR"
        git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
        cd pgvector
        make PG_CONFIG="$PG_CONFIG"
        sudo make install PG_CONFIG="$PG_CONFIG"
        log "pgvector installed from source."
    else
        # Try apt (Debian/Ubuntu)
        if command -v apt-get &>/dev/null; then
            log "Installing via apt: postgresql-$PG_MAJOR-pgvector..."
            sudo apt-get update -qq
            sudo apt-get install -y -qq "postgresql-$PG_MAJOR-pgvector"
        # Try yum/dnf (RHEL/Fedora)
        elif command -v dnf &>/dev/null; then
            log "Installing via dnf: pgvector_$PG_MAJOR..."
            sudo dnf install -y "pgvector_$PG_MAJOR"
        elif command -v yum &>/dev/null; then
            log "Installing via yum: pgvector_$PG_MAJOR..."
            sudo yum install -y "pgvector_$PG_MAJOR"
        else
            err "No package manager found. Use --source flag to install from source."
        fi
    fi
else
    log "pgvector is available."
fi

# --- 3. Create extension ---
log "Creating pgvector extension..."
$PSQL -c "CREATE EXTENSION IF NOT EXISTS vector;"

PGVECTOR_VERSION=$($PSQL -t -A -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';")
log "pgvector version: $PGVECTOR_VERSION"

# --- 4. Create sample schema ---
log "Creating sample table and indexes..."
$PSQL <<'SQL'
-- Sample table with all pgvector column types
CREATE TABLE IF NOT EXISTS sample_embeddings (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    embedding vector(1536),
    embedding_half halfvec(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- HNSW index (recommended for production)
CREATE INDEX IF NOT EXISTS idx_sample_hnsw
ON sample_embeddings USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- Full-text search support
ALTER TABLE sample_embeddings
ADD COLUMN IF NOT EXISTS search_vector tsvector
GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;

CREATE INDEX IF NOT EXISTS idx_sample_fts
ON sample_embeddings USING gin (search_vector);

SQL
log "Schema created."

# --- 5. Insert sample data and test ---
log "Inserting sample data..."
$PSQL <<'SQL'
-- Insert a few sample rows (random 4-dim vectors for testing)
INSERT INTO sample_embeddings (content, embedding)
SELECT
    'Sample document ' || i,
    ('[' || array_to_string(ARRAY(
        SELECT round(random()::numeric, 4)
        FROM generate_series(1, 1536)
    ), ',') || ']')::vector(1536)
FROM generate_series(1, 5) AS i
ON CONFLICT DO NOTHING;

-- Test nearest neighbor query
SELECT id, content, embedding <=> (
    SELECT embedding FROM sample_embeddings LIMIT 1
) AS distance
FROM sample_embeddings
ORDER BY embedding <=> (
    SELECT embedding FROM sample_embeddings LIMIT 1
)
LIMIT 3;
SQL

log "Setup complete!"
log ""
log "Summary:"
log "  Host:      $PGHOST:$PGPORT"
log "  Database:  $PGDATABASE"
log "  Extension: pgvector $PGVECTOR_VERSION"
log "  Table:     sample_embeddings (vector, halfvec, tsvector)"
log "  Indexes:   HNSW (cosine), GIN (full-text)"
log ""
log "Next steps:"
log "  1. Insert your embeddings into the 'embedding' column"
log "  2. Query: SELECT * FROM sample_embeddings ORDER BY embedding <=> \$1 LIMIT 10;"
log "  3. Tune: SET hnsw.ef_search = 100;"
