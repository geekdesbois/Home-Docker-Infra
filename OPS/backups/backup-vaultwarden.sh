#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/docker/vaultwarden/data"
BACKUP_DIR="/docker/vaultwarden/backup"

DATE="$(date +%F_%H-%M-%S)"
TMP="${BACKUP_DIR}/db_${DATE}.sqlite3.tmp"
FINAL="${BACKUP_DIR}/db_${DATE}.sqlite3"

# Pré-checks
command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: sqlite3 not installed"; exit 1; }
test -f "${DATA_DIR}/db.sqlite3" || { echo "ERROR: ${DATA_DIR}/db.sqlite3 not found"; exit 1; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR" || true

# Backup SQLite consistant (API .backup)
cd "$DATA_DIR"
sqlite3 db.sqlite3 ".backup '$TMP'"

# Finalize + compress
mv "$TMP" "$FINAL"
gzip -f "$FINAL"

# Rotation (14 jours)
find "$BACKUP_DIR" -type f -name "db_*.sqlite3.gz" -mtime +14 -delete

echo "OK: Vaultwarden backup -> ${FINAL}.gz"
