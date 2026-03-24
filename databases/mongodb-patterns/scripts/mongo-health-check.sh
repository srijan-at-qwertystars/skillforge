#!/usr/bin/env bash
# ============================================================================
# mongo-health-check.sh — MongoDB Health Check Script
# ============================================================================
# Checks replica set status, connection count, oplog window, and disk usage
# for a MongoDB deployment.
#
# Usage:
#   ./mongo-health-check.sh                          # localhost:27017, no auth
#   ./mongo-health-check.sh -u admin -p pass          # with authentication
#   ./mongo-health-check.sh --uri "mongodb+srv://..."  # connection string
#   ./mongo-health-check.sh --json                    # JSON output
#
# Requirements: mongosh (or mongo shell), df, awk
#
# Options:
#   -u, --user        MongoDB username
#   -p, --password    MongoDB password
#   -h, --host        MongoDB host (default: localhost)
#   -P, --port        MongoDB port (default: 27017)
#   --uri             Full MongoDB connection URI
#   --authdb          Authentication database (default: admin)
#   --json            Output results as JSON
#   --warn-conn       Connection count warning threshold (default: 500)
#   --warn-oplog      Oplog hours warning threshold (default: 24)
#   --warn-disk       Disk usage percentage warning (default: 80)
#   --help            Show this help message
# ============================================================================

set -euo pipefail

# Defaults
HOST="localhost"
PORT="27017"
USER=""
PASS=""
URI=""
AUTHDB="admin"
JSON_OUTPUT=false
WARN_CONN=500
WARN_OPLOG=24
WARN_DISK=80

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  head -30 "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }
log_info() { echo -e "  ${BLUE}ℹ${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)     USER="$2"; shift 2 ;;
    -p|--password) PASS="$2"; shift 2 ;;
    -h|--host)     HOST="$2"; shift 2 ;;
    -P|--port)     PORT="$2"; shift 2 ;;
    --uri)         URI="$2"; shift 2 ;;
    --authdb)      AUTHDB="$2"; shift 2 ;;
    --json)        JSON_OUTPUT=true; shift ;;
    --warn-conn)   WARN_CONN="$2"; shift 2 ;;
    --warn-oplog)  WARN_OPLOG="$2"; shift 2 ;;
    --warn-disk)   WARN_DISK="$2"; shift 2 ;;
    --help)        usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Build mongosh command
MONGOSH="mongosh --quiet --norc"
if [[ -n "$URI" ]]; then
  MONGOSH="$MONGOSH \"$URI\""
elif [[ -n "$USER" && -n "$PASS" ]]; then
  MONGOSH="$MONGOSH --host $HOST --port $PORT -u $USER -p $PASS --authenticationDatabase $AUTHDB"
else
  MONGOSH="$MONGOSH --host $HOST --port $PORT"
fi

run_mongo() {
  eval "$MONGOSH --eval '$1'" 2>/dev/null
}

echo ""
echo "═══════════════════════════════════════════════════"
echo "  MongoDB Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════"

# ---------- 1. Server Connectivity ----------
echo ""
echo "▸ Server Connectivity"
SERVER_INFO=$(run_mongo '
  const s = db.serverStatus();
  const info = {
    version: s.version,
    uptime: Math.floor(s.uptime / 3600),
    host: s.host,
    process: s.process,
    pid: s.pid
  };
  JSON.stringify(info);
' 2>&1) || { log_err "Cannot connect to MongoDB"; exit 1; }

VERSION=$(echo "$SERVER_INFO" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
UPTIME=$(echo "$SERVER_INFO" | grep -o '"uptime":[0-9]*' | cut -d: -f2)

log_ok "Connected — MongoDB v${VERSION}, uptime: ${UPTIME}h"

# ---------- 2. Replica Set Status ----------
echo ""
echo "▸ Replica Set Status"
RS_STATUS=$(run_mongo '
  try {
    const rs_stat = rs.status();
    const members = rs_stat.members.map(m => ({
      name: m.name,
      state: m.stateStr,
      health: m.health,
      optimeDate: m.optimeDate,
      lag: m.stateStr === "SECONDARY"
        ? Math.floor((rs_stat.members.find(x => x.stateStr === "PRIMARY").optimeDate - m.optimeDate) / 1000)
        : 0
    }));
    JSON.stringify({ set: rs_stat.set, members });
  } catch (e) {
    JSON.stringify({ error: "standalone" });
  }
' 2>&1)

if echo "$RS_STATUS" | grep -q '"error"'; then
  log_info "Standalone instance (no replica set)"
else
  RS_NAME=$(echo "$RS_STATUS" | grep -o '"set":"[^"]*"' | cut -d'"' -f4)
  log_ok "Replica set: $RS_NAME"
  # Parse members
  echo "$RS_STATUS" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read().strip().split('\n')[-1])
    for m in data.get('members', []):
        state = m['state']
        health = '✓' if m['health'] == 1 else '✗'
        lag = f\", lag: {m['lag']}s\" if m['state'] == 'SECONDARY' else ''
        status = 'OK' if m['health'] == 1 else 'DOWN'
        print(f\"    {health} {m['name']} — {state} ({status}{lag})\")
except: pass
" 2>/dev/null || log_info "Could not parse member details"
fi

# ---------- 3. Connection Count ----------
echo ""
echo "▸ Connections"
CONN_INFO=$(run_mongo '
  const c = db.serverStatus().connections;
  JSON.stringify({ current: c.current, available: c.available, total: c.totalCreated });
' 2>&1)

CURRENT_CONN=$(echo "$CONN_INFO" | grep -o '"current":[0-9]*' | cut -d: -f2)
AVAIL_CONN=$(echo "$CONN_INFO" | grep -o '"available":[0-9]*' | cut -d: -f2)

if [[ -n "$CURRENT_CONN" ]]; then
  if [[ "$CURRENT_CONN" -gt "$WARN_CONN" ]]; then
    log_warn "Current: $CURRENT_CONN (threshold: $WARN_CONN), Available: $AVAIL_CONN"
  else
    log_ok "Current: $CURRENT_CONN, Available: $AVAIL_CONN"
  fi
fi

# ---------- 4. Oplog Window ----------
echo ""
echo "▸ Oplog Window"
OPLOG_INFO=$(run_mongo '
  try {
    const ol = db.getSiblingDB("local").oplog.rs.stats();
    const first = db.getSiblingDB("local").oplog.rs.find().sort({$natural:1}).limit(1).next();
    const last = db.getSiblingDB("local").oplog.rs.find().sort({$natural:-1}).limit(1).next();
    const windowSecs = (last.ts.getTime() - first.ts.getTime());
    const hours = Math.floor(windowSecs / 3600);
    const sizeMB = Math.floor(ol.size / 1048576);
    const maxMB = Math.floor(ol.maxSize / 1048576);
    JSON.stringify({ hours, sizeMB, maxMB });
  } catch(e) {
    JSON.stringify({ error: e.message });
  }
' 2>&1)

if echo "$OPLOG_INFO" | grep -q '"error"'; then
  log_info "Oplog not available (standalone or insufficient permissions)"
else
  OPLOG_HOURS=$(echo "$OPLOG_INFO" | grep -o '"hours":[0-9]*' | cut -d: -f2)
  OPLOG_SIZE=$(echo "$OPLOG_INFO" | grep -o '"sizeMB":[0-9]*' | cut -d: -f2)
  OPLOG_MAX=$(echo "$OPLOG_INFO" | grep -o '"maxMB":[0-9]*' | cut -d: -f2)

  if [[ -n "$OPLOG_HOURS" ]]; then
    if [[ "$OPLOG_HOURS" -lt "$WARN_OPLOG" ]]; then
      log_warn "Window: ${OPLOG_HOURS}h (below ${WARN_OPLOG}h threshold), Size: ${OPLOG_SIZE}MB / ${OPLOG_MAX}MB"
    else
      log_ok "Window: ${OPLOG_HOURS}h, Size: ${OPLOG_SIZE}MB / ${OPLOG_MAX}MB"
    fi
  fi
fi

# ---------- 5. Database Sizes ----------
echo ""
echo "▸ Database Sizes"
run_mongo '
  const dbs = db.adminCommand({ listDatabases: 1 });
  dbs.databases
    .sort((a, b) => b.sizeOnDisk - a.sizeOnDisk)
    .slice(0, 10)
    .forEach(d => {
      const mb = (d.sizeOnDisk / 1048576).toFixed(1);
      print("    " + d.name.padEnd(25) + mb.padStart(10) + " MB");
    });
' 2>/dev/null || log_info "Cannot list databases (insufficient permissions)"

# ---------- 6. Disk Usage ----------
echo ""
echo "▸ Disk Usage"
DBPATH=$(run_mongo '
  try { print(db.serverCmdLineOpts().parsed.storage.dbPath); }
  catch(e) { print("/data/db"); }
' 2>/dev/null)

DBPATH=${DBPATH:-/data/db}

if command -v df &>/dev/null; then
  DISK_USAGE=$(df -h "$DBPATH" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
  DISK_TOTAL=$(df -h "$DBPATH" 2>/dev/null | tail -1 | awk '{print $2}')
  DISK_AVAIL=$(df -h "$DBPATH" 2>/dev/null | tail -1 | awk '{print $4}')

  if [[ -n "$DISK_USAGE" ]]; then
    if [[ "$DISK_USAGE" -gt "$WARN_DISK" ]]; then
      log_warn "Disk: ${DISK_USAGE}% used (Total: ${DISK_TOTAL}, Free: ${DISK_AVAIL})"
    else
      log_ok "Disk: ${DISK_USAGE}% used (Total: ${DISK_TOTAL}, Free: ${DISK_AVAIL})"
    fi
  fi
else
  log_info "df command not available"
fi

# ---------- 7. WiredTiger Cache ----------
echo ""
echo "▸ WiredTiger Cache"
run_mongo '
  const wt = db.serverStatus().wiredTiger.cache;
  const maxGB = (wt["maximum bytes configured"] / 1073741824).toFixed(2);
  const usedGB = (wt["bytes currently in the cache"] / 1073741824).toFixed(2);
  const dirtyMB = (wt["tracked dirty bytes in the cache"] / 1048576).toFixed(1);
  const pct = ((wt["bytes currently in the cache"] / wt["maximum bytes configured"]) * 100).toFixed(1);
  const appEvict = wt["pages evicted by application threads"] || 0;
  print("    Cache: " + usedGB + "GB / " + maxGB + "GB (" + pct + "%)");
  print("    Dirty: " + dirtyMB + "MB");
  if (appEvict > 0) {
    print("    ⚠ App-thread evictions: " + appEvict + " (cache too small!)");
  }
' 2>/dev/null || log_info "Cannot read WiredTiger stats"

# ---------- 8. Slow Operations ----------
echo ""
echo "▸ Current Operations (>5s)"
SLOW_OPS=$(run_mongo '
  const ops = db.currentOp({ active: true, secs_running: { $gte: 5 } }).inprog;
  if (ops.length === 0) { print("    None"); }
  else {
    ops.slice(0, 5).forEach(op => {
      print("    opid=" + op.opid + " " + op.op + " " + (op.ns || "?") +
            " running " + op.secs_running + "s");
    });
    if (ops.length > 5) print("    ... and " + (ops.length - 5) + " more");
  }
' 2>/dev/null) || SLOW_OPS="    Could not check (insufficient permissions)"
echo "$SLOW_OPS"

# ---------- Summary ----------
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Health check complete"
echo "═══════════════════════════════════════════════════"
echo ""
