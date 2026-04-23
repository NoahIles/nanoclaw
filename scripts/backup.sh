#!/bin/bash
# backup.sh — SQLite .backup for NanoClaw and MemPalace databases.
# Writes timestamped copies to BACKUP_DIR and rotates files older than BACKUP_RETAIN_DAYS.
#
# Environment (set in docker-compose.yml backup service, or export manually):
#   NANOCLAW_DATA     path to nanoclaw data dir    (default: /opt/nanoclaw/data)
#   MEMPALACE_DATA    path to mempalace volume      (default: /root/.mempalace)
#   BACKUP_DIR        where backups are written      (default: /opt/nanoclaw/backups)
#   BACKUP_RETAIN_DAYS  days to keep backups        (default: 30)

set -euo pipefail

NANOCLAW_DATA="${NANOCLAW_DATA:-/opt/nanoclaw/data}"
MEMPALACE_DATA="${MEMPALACE_DATA:-/root/.mempalace}"
BACKUP_DIR="${BACKUP_DIR:-/opt/nanoclaw/backups}"
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-30}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [backup] $*"; }

backup_db() {
  local src="$1"
  local dest="$2"

  if [[ ! -f "$src" ]]; then
    log "SKIP: $src not found"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  sqlite3 "$src" ".backup '$dest'"
  local size
  size="$(du -sh "$dest" | cut -f1)"
  log "OK: $(basename "$src") → $dest ($size)"
}

# ── Main ─────────────────────────────────────────────────────────────────────

mkdir -p "$BACKUP_DIR"
log "Starting backup (timestamp: $TIMESTAMP, retain: ${BACKUP_RETAIN_DAYS} days)"

# Central NanoClaw DB
backup_db \
  "${NANOCLAW_DATA}/v2.db" \
  "${BACKUP_DIR}/v2-${TIMESTAMP}.db"

# MemPalace knowledge graph (SQLite component)
# MemPalace stores its SQLite KG at ~/.mempalace/knowledge_graph.db
backup_db \
  "${MEMPALACE_DATA}/knowledge_graph.db" \
  "${BACKUP_DIR}/mempalace-kg-${TIMESTAMP}.db"

# ── Rotate old backups ────────────────────────────────────────────────────────

log "Rotating backups older than ${BACKUP_RETAIN_DAYS} days"
find "$BACKUP_DIR" -name "*.db" -mtime "+${BACKUP_RETAIN_DAYS}" -delete
remaining=$(find "$BACKUP_DIR" -name "*.db" | wc -l)
log "Rotation complete. $remaining backup file(s) retained."

log "Backup finished."
