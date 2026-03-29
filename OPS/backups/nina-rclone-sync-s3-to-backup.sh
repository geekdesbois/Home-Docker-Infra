#!/bin/bash
exec 9>/run/lock/rclone-s3-to-backup.lock
flock -n 9 || exit 0

set -uo pipefail

LOG="/var/log/rclone-s3-to-backup.log"
REMOTE="spaceslibretimemedias:libretimemediasnina/monbucket"

DEST_MEDIAS="/srv/backup/libretime_medias"
DEST_BACKUP="/srv/backup/nina_dbs_uploads"

MAX_DELETES=300
DRY_RUN=0

TMP_REMOTE_LIST="$(mktemp)"
TMP_LOCAL_LIST="$(mktemp)"
TMP_DELETE_LIST="$(mktemp)"

usage() {
  cat <<'EOF'
Usage: rclone-sync-s3-to-backup.sh [--dry-run]

Options:
  --dry-run   Simule les opérations sans rien modifier
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$DEST_MEDIAS" "$DEST_BACKUP"

cleanup() {
  rm -f "$TMP_REMOTE_LIST" "$TMP_LOCAL_LIST" "$TMP_DELETE_LIST"
}
trap cleanup EXIT

exec >>"$LOG" 2>&1

echo "==== $(date -Is) START ===="

RCLONE_OPTS=(
  --fast-list
  --use-server-modtime
  --transfers=4
  --checkers=4
  --buffer-size=32M
  --retries=5
  --retries-sleep=30s
  --log-level INFO
)

if [ "$DRY_RUN" -eq 1 ]; then
  RCLONE_OPTS+=(--dry-run)
  echo "INFO: DRY_RUN enabled"
fi

GLOBAL_STATUS=0

########################################
# 1) MEDIAS = miroir natif
########################################

echo "INFO: Sync medias..."
if ! /usr/bin/rclone sync \
  "${REMOTE}/medias" \
  "$DEST_MEDIAS" \
  "${RCLONE_OPTS[@]}"
then
  echo "ERROR: medias sync failed"
  GLOBAL_STATUS=1
fi

########################################
# 2) BACKUP = copy incrémental
########################################

echo "INFO: Copy backup..."
if ! /usr/bin/rclone copy \
  "${REMOTE}/backup" \
  "$DEST_BACKUP" \
  "${RCLONE_OPTS[@]}"
then
  echo "ERROR: backup copy failed"
  GLOBAL_STATUS=1
fi

########################################
# 3) LISTE SOURCE backup
########################################

echo "INFO: Build remote file list..."
if ! /usr/bin/rclone lsf \
  "${REMOTE}/backup" \
  --recursive \
  --files-only \
  | grep -E '\.(dump|sql)$' \
  | sort > "$TMP_REMOTE_LIST"
then
  echo "ERROR: unable to build remote file list"
  echo "==== $(date -Is) END ===="
  exit 1
fi

########################################
# 4) LISTE LOCALE backup
########################################

echo "INFO: Build local file list..."
if ! (
  cd "$DEST_BACKUP" &&
  find . -type f \( -name "*.dump" -o -name "*.sql" \) \
    | sed 's|^\./||' \
    | sort
) > "$TMP_LOCAL_LIST"
then
  echo "ERROR: unable to build local file list"
  echo "==== $(date -Is) END ===="
  exit 1
fi

########################################
# 5) CALCUL SUPPRESSIONS
########################################

echo "INFO: Compute prune candidate list..."
comm -23 "$TMP_LOCAL_LIST" "$TMP_REMOTE_LIST" > "$TMP_DELETE_LIST"

DELETE_COUNT="$(wc -l < "$TMP_DELETE_LIST")"
DELETE_COUNT="${DELETE_COUNT//[[:space:]]/}"

if [ "$DELETE_COUNT" -gt "$MAX_DELETES" ]; then
  echo "ERROR: refusing to delete $DELETE_COUNT files (threshold: $MAX_DELETES)"
  echo "WARN: pruning aborted for safety"
  echo "==== $(date -Is) END ===="
  exit 1
fi

########################################
# 6) PRUNING miroir filtré
########################################

echo "INFO: Prune local .dump/.sql absent from remote..."

while IFS= read -r file; do
  [ -z "$file" ] && continue

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN DELETE: $DEST_BACKUP/$file"
  else
    echo "DELETE: $DEST_BACKUP/$file"
    rm -f -- "$DEST_BACKUP/$file"
  fi
done < "$TMP_DELETE_LIST"

########################################
# 7) CLEANUP dossiers vides
########################################

if [ "$DRY_RUN" -eq 1 ]; then
  echo "INFO: DRY-RUN empty dir cleanup skipped"
else
  echo "INFO: Remove empty directories..."
  find "$DEST_BACKUP" -type d -empty -delete
fi

echo "INFO: Deleted files count: $DELETE_COUNT"

if [ "$GLOBAL_STATUS" -ne 0 ]; then
  echo "WARN: one or more rclone operations failed"
fi

echo "==== $(date -Is) END ===="
exit "$GLOBAL_STATUS"
