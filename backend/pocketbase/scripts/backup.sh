#!/bin/bash
# PocketBase Backup Script
# Creates timestamped backups of PocketBase SQLite database

set -e

PB_DATA_DIR="${1:-./pb_data}"
BACKUP_DIR="${2:-./backups}"
RETENTION_DAYS="${3:-7}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="pb_backup_${TIMESTAMP}.db"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Check if data directory exists
if [ ! -d "$PB_DATA_DIR" ]; then
    echo "Error: Data directory not found: $PB_DATA_DIR"
    exit 1
fi

# Check if database exists
if [ ! -f "$PB_DATA_DIR/data.db" ]; then
    echo "Error: Database not found at $PB_DATA_DIR/data.db"
    exit 1
fi

echo "Creating backup: $BACKUP_FILE"

# Create backup using SQLite (ensures consistency)
if command -v sqlite3 &> /dev/null; then
    sqlite3 "$PB_DATA_DIR/data.db" ".backup '$BACKUP_DIR/$BACKUP_FILE'"
    echo "Backup created: $BACKUP_DIR/$BACKUP_FILE"
else
    # Fallback to simple copy
    cp "$PB_DATA_DIR/data.db" "$BACKUP_DIR/$BACKUP_FILE"
    echo "Backup created (file copy): $BACKUP_DIR/$BACKUP_FILE"
fi

# Compress backup
gzip "$BACKUP_DIR/$BACKUP_FILE"
echo "Compressed: $BACKUP_DIR/${BACKUP_FILE}.gz"

# Clean up old backups
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "pb_backup_*.db.gz" -mtime +$RETENTION_DAYS -delete

echo "Backup complete!"
