#!/bin/bash
exec 9>/run/lock/rclone-s3-to-backup.lock
flock -n 9 || exit 0

set -euo pipefail

LOG="/var/log/rclone-s3-to-backup.log"
REMOTE="spaceslibretimemedias:libretimemediasnina/monbucket"

DEST_MEDIAS="/srv/backup/libretime_medias"
DEST_BACKUP="/srv/backup/nina_dbs_uploads"

mkdir -p "$DEST_MEDIAS" "$DEST_BACKUP"


echo "==== $(date -Is) START ====" >> "$LOG"

RCLONE_OPTS=(
  --fast-list
  --use-server-modtime
  --transfers=4
  --checkers=4
  --buffer-size=32M
  --retries=5
  --retries-sleep=30s
  --log-file "$LOG"
  --log-level INFO

  # IMPORTANT: évite rename temp -> final (source de ton erreur "incompatible remotes")
# --inplace

  # optionnel mais utile: suffix des fichiers en cours d'écriture
# --partial-suffix .partial
)

# 1) Medias LibreTime
/usr/bin/rclone sync \
  "${REMOTE}/medias" \
  "$DEST_MEDIAS" \
  "${RCLONE_OPTS[@]}"

# 2) Dumps DB + uploads
/usr/bin/rclone sync \
  "${REMOTE}/backup" \
  "$DEST_BACKUP" \
  "${RCLONE_OPTS[@]}"

echo "==== $(date -Is) END ====" >> "$LOG"
