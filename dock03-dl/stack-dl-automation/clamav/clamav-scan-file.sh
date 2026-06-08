#!/bin/bash
# /usr/local/sbin/clamav-scan-file.sh
set -uo pipefail

CONTAINER="clamav"
HOST_ROOT="/srv/downloads/qbittorrent"
CONTAINER_ROOT="/scan"
HOST_QUARANTINE="/srv/downloads/quarantine"
LOG="/var/log/clamav-dl-scan.log"
ALERT_EMAIL="tonmail@example.com"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
  logger -t clamav-dl-scan -- "$*"
}

HOST_FILE="$1"
CONTAINER_FILE="${HOST_FILE/$HOST_ROOT/$CONTAINER_ROOT}"

[ -f "$HOST_FILE" ] || { log "Fichier disparu avant scan : $HOST_FILE"; exit 0; }

log "Scan unitaire : $HOST_FILE"

set +e
OUTPUT="$(docker exec "$CONTAINER" clamdscan \
  --infected --no-summary \
  --move=/quarantine \
  "$CONTAINER_FILE" 2>&1)"
RC=$?
set -e

echo "$OUTPUT" >> "$LOG"

case "$RC" in
  0) log "OK : $HOST_FILE" ;;
  1)
    log "ALERTE : infecté → $HOST_FILE"
    [ -x /usr/sbin/sendmail ] && {
      printf "To: %s\nSubject: [ALERTE] ClamAV infecté\n\n%s\n" \
        "$ALERT_EMAIL" "$OUTPUT" | /usr/sbin/sendmail -t
    }
    ;;
  *) log "WARNING : code $RC pour $HOST_FILE" ;;
esac