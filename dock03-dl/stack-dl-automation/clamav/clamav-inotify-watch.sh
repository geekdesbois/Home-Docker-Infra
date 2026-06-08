#!/bin/bash
# /usr/local/sbin/clamav-inotify-watch.sh
# Surveille les téléchargements terminés et déclenche un scan ClamAV unitaire.
# Écoute uniquement MOVED_TO : qBittorrent déplace le fichier depuis incomplete/
# vers downloads/ en fin de téléchargement → jamais de fichier partiel.
set -uo pipefail

HOST_ROOT="/srv/downloads/qbittorrent"
WATCH_DIR="$HOST_ROOT/downloads"
SCAN_SCRIPT="/usr/local/sbin/clamav-scan-file.sh"
LOG="/var/log/clamav-inotify.log"
BATCH_DELAY=15        # secondes : délai d'attente pour regrouper les événements en rafale
MAX_PARALLEL=4        # nombre de scans simultanés maximum

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG"
  logger -t clamav-inotify -- "$*"
}

# Vérifie les dépendances
for cmd in inotifywait docker; do
  command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: $cmd introuvable"; exit 1; }
done

[ -d "$WATCH_DIR" ] || { log "ERROR: répertoire $WATCH_DIR inexistant"; exit 1; }
[ -x "$SCAN_SCRIPT" ] || { log "ERROR: $SCAN_SCRIPT introuvable ou non exécutable"; exit 1; }

log "Watcher démarré — surveillance de $WATCH_DIR"

declare -a PENDING=()
LAST_EVENT_TS=0

flush_batch() {
  local count=${#PENDING[@]}
  [[ $count -eq 0 ]] && return

  log "Flush batch : $count fichier(s)"
  local running=0
  for f in "${PENDING[@]}"; do
    "$SCAN_SCRIPT" "$f" &
    (( running++ )) || true
    # Limite le parallélisme
    if (( running >= MAX_PARALLEL )); then
      wait -n 2>/dev/null || wait
      (( running-- )) || true
    fi
  done
  wait
  PENDING=()
}

# Boucle principale : lecture des événements inotifywait
while IFS= read -r filepath; do

  # Filtres défensifs (ne devraient jamais matcher avec MOVED_TO sur downloads/)
  [[ "$filepath" == */incomplete/* ]] && continue
  [[ "$filepath" == *.part ]]         && continue
  [[ "$filepath" == */.* ]]           && continue   # fichiers cachés

  log "Nouveau fichier : $filepath"
  PENDING+=("$filepath")
  LAST_EVENT_TS=$(date +%s)

  # Flush si le batch delay est écoulé depuis le dernier événement
  NOW=$(date +%s)
  if (( NOW - LAST_EVENT_TS >= BATCH_DELAY )); then
    flush_batch
  fi

done < <(
  inotifywait \
    --monitor \
    --recursive \
    --event moved_to \
    --format '%w%f' \
    "$WATCH_DIR" \
    2>/dev/null
)

# Flush final si inotifywait se termine (ne devrait pas arriver)
flush_batch
log "Watcher terminé de façon inattendue"
exit 1
