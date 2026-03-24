#!/usr/bin/env bash
# ============================================================================
# backup-restore.sh — MongoDB Backup & Restore Wrapper
# ============================================================================
# Wrapper around mongodump/mongorestore with compression, timestamped backups,
# and MongoDB Atlas support.
#
# Usage:
#   Backup:
#     ./backup-restore.sh backup                              # local, all DBs
#     ./backup-restore.sh backup --db myapp                   # single database
#     ./backup-restore.sh backup --uri "mongodb+srv://..."    # Atlas
#     ./backup-restore.sh backup --db myapp --collection users
#     ./backup-restore.sh backup --gzip --out /backups        # compressed
#
#   Restore:
#     ./backup-restore.sh restore --from /backups/2024-06-01_120000
#     ./backup-restore.sh restore --from backup.archive --db myapp
#     ./backup-restore.sh restore --from dump/ --drop         # drop before restore
#     ./backup-restore.sh restore --uri "mongodb+srv://..." --from backup.gz
#
#   List:
#     ./backup-restore.sh list                                # list backups
#     ./backup-restore.sh list --out /backups                 # custom dir
#
# Options:
#   --uri             MongoDB connection URI
#   --host            MongoDB host (default: localhost)
#   --port            MongoDB port (default: 27017)
#   -u, --user        MongoDB username
#   -p, --password    MongoDB password
#   --authdb          Auth database (default: admin)
#   --db              Database name (all databases if omitted)
#   --collection      Collection name (requires --db)
#   --out             Backup output directory (default: ./mongo-backups)
#   --from            Restore source (directory or archive file)
#   --gzip            Enable gzip compression
#   --archive         Use single-file archive format
#   --drop            Drop collections before restoring
#   --oplog           Include oplog for point-in-time backup (replica set)
#   --query           Query filter for backup (JSON string)
#   --parallel        Parallelism for restore (default: 4)
#   --dry-run         Show commands without executing
#   --retention       Number of backups to keep (default: 10)
#   --help            Show this help
# ============================================================================

set -euo pipefail

# Defaults
ACTION=""
URI=""
HOST="localhost"
PORT="27017"
USER=""
PASS=""
AUTHDB="admin"
DB=""
COLLECTION=""
OUT_DIR="./mongo-backups"
FROM=""
GZIP=false
ARCHIVE=false
DROP=false
OPLOG=false
QUERY=""
PARALLEL=4
DRY_RUN=false
RETENTION=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  head -40 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

# Parse args
[[ $# -eq 0 ]] && usage

ACTION="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri)         URI="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    -u|--user)     USER="$2"; shift 2 ;;
    -p|--password) PASS="$2"; shift 2 ;;
    --authdb)      AUTHDB="$2"; shift 2 ;;
    --db)          DB="$2"; shift 2 ;;
    --collection)  COLLECTION="$2"; shift 2 ;;
    --out)         OUT_DIR="$2"; shift 2 ;;
    --from)        FROM="$2"; shift 2 ;;
    --gzip)        GZIP=true; shift ;;
    --archive)     ARCHIVE=true; shift ;;
    --drop)        DROP=true; shift ;;
    --oplog)       OPLOG=true; shift ;;
    --query)       QUERY="$2"; shift 2 ;;
    --parallel)    PARALLEL="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --retention)   RETENTION="$2"; shift 2 ;;
    --help)        usage ;;
    *) log_err "Unknown option: $1"; usage ;;
  esac
done

# Build connection args
build_conn_args() {
  local args=""
  if [[ -n "$URI" ]]; then
    args="--uri=\"$URI\""
  else
    args="--host=$HOST --port=$PORT"
    [[ -n "$USER" ]] && args="$args --username=$USER"
    [[ -n "$PASS" ]] && args="$args --password=$PASS"
    [[ -n "$USER" ]] && args="$args --authenticationDatabase=$AUTHDB"
  fi
  echo "$args"
}

run_cmd() {
  local cmd="$1"
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN]${NC} $cmd"
  else
    log "Running: $cmd"
    eval "$cmd"
  fi
}

# ---------- BACKUP ----------
do_backup() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d_%H%M%S')
  local conn
  conn=$(build_conn_args)

  mkdir -p "$OUT_DIR"

  local cmd="mongodump $conn"

  # Database/collection
  [[ -n "$DB" ]] && cmd="$cmd --db=$DB"
  [[ -n "$COLLECTION" ]] && cmd="$cmd --collection=$COLLECTION"

  # Compression
  $GZIP && cmd="$cmd --gzip"

  # Oplog (point-in-time for replica set)
  $OPLOG && cmd="$cmd --oplog"

  # Query filter
  [[ -n "$QUERY" ]] && cmd="$cmd --query='$QUERY'"

  # Output format
  if $ARCHIVE; then
    local archive_name="${OUT_DIR}/backup_${timestamp}"
    [[ -n "$DB" ]] && archive_name="${OUT_DIR}/${DB}_${timestamp}"
    $GZIP && archive_name="${archive_name}.archive.gz" || archive_name="${archive_name}.archive"
    cmd="$cmd --archive=$archive_name"
    log "Backing up to archive: $archive_name"
  else
    local dump_dir="${OUT_DIR}/${timestamp}"
    [[ -n "$DB" ]] && dump_dir="${OUT_DIR}/${DB}_${timestamp}"
    cmd="$cmd --out=$dump_dir"
    log "Backing up to directory: $dump_dir"
  fi

  local start_time=$SECONDS
  run_cmd "$cmd"
  local duration=$((SECONDS - start_time))

  if ! $DRY_RUN; then
    log_ok "Backup completed in ${duration}s"

    # Show backup size
    if $ARCHIVE; then
      local size
      size=$(du -sh "$archive_name" 2>/dev/null | cut -f1)
      log "Backup size: $size"
    else
      local size
      size=$(du -sh "$dump_dir" 2>/dev/null | cut -f1)
      log "Backup size: $size"
    fi

    # Retention: remove old backups
    cleanup_old_backups
  fi
}

# ---------- RESTORE ----------
do_restore() {
  if [[ -z "$FROM" ]]; then
    log_err "--from is required for restore"
    exit 1
  fi

  if [[ ! -e "$FROM" ]]; then
    log_err "Restore source not found: $FROM"
    exit 1
  fi

  local conn
  conn=$(build_conn_args)
  local cmd="mongorestore $conn"

  # Database
  [[ -n "$DB" ]] && cmd="$cmd --db=$DB"
  [[ -n "$COLLECTION" ]] && cmd="$cmd --collection=$COLLECTION"

  # Drop before restore
  $DROP && cmd="$cmd --drop"

  # Compression
  $GZIP && cmd="$cmd --gzip"

  # Parallelism
  cmd="$cmd --numParallelCollections=$PARALLEL"

  # Oplog replay
  $OPLOG && cmd="$cmd --oplogReplay"

  # Source format
  if [[ "$FROM" == *.archive* ]]; then
    cmd="$cmd --archive=$FROM"
  else
    cmd="$cmd $FROM"
  fi

  log "Restoring from: $FROM"
  $DROP && log_warn "Collections will be dropped before restore"

  local start_time=$SECONDS
  run_cmd "$cmd"
  local duration=$((SECONDS - start_time))

  $DRY_RUN || log_ok "Restore completed in ${duration}s"
}

# ---------- LIST ----------
do_list() {
  log "Backups in: $OUT_DIR"
  echo ""
  if [[ -d "$OUT_DIR" ]]; then
    local count=0
    for entry in "$OUT_DIR"/*/; do
      [[ -d "$entry" ]] || continue
      local size
      size=$(du -sh "$entry" 2>/dev/null | cut -f1)
      local name
      name=$(basename "$entry")
      printf "  %-35s %s\n" "$name/" "$size"
      ((count++))
    done
    for entry in "$OUT_DIR"/*.archive*; do
      [[ -f "$entry" ]] || continue
      local size
      size=$(du -sh "$entry" 2>/dev/null | cut -f1)
      local name
      name=$(basename "$entry")
      printf "  %-35s %s\n" "$name" "$size"
      ((count++))
    done
    echo ""
    log "Total backups: $count"
  else
    log_warn "Backup directory not found: $OUT_DIR"
  fi
}

# ---------- CLEANUP ----------
cleanup_old_backups() {
  if [[ ! -d "$OUT_DIR" ]]; then return; fi

  local backups=()
  while IFS= read -r -d '' entry; do
    backups+=("$entry")
  done < <(find "$OUT_DIR" -maxdepth 1 \( -type d -o -name "*.archive*" \) ! -path "$OUT_DIR" -print0 | sort -z)

  local count=${#backups[@]}
  if [[ $count -gt $RETENTION ]]; then
    local to_remove=$((count - RETENTION))
    log "Cleaning up $to_remove old backup(s) (retention: $RETENTION)"
    for ((i = 0; i < to_remove; i++)); do
      local target="${backups[$i]}"
      if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would remove: $target"
      else
        rm -rf "$target"
        log "Removed: $(basename "$target")"
      fi
    done
  fi
}

# ---------- MAIN ----------
case "$ACTION" in
  backup)  do_backup ;;
  restore) do_restore ;;
  list)    do_list ;;
  *)       log_err "Unknown action: $ACTION (use backup, restore, or list)"; usage ;;
esac
