#!/usr/bin/env bash
# Watchdog pour le conteneur haproxy — relance si arrêté après reboot/update
# Déploiement : cp haproxy-watchdog.sh /usr/local/sbin/ && chmod 750 /usr/local/sbin/haproxy-watchdog.sh

set -euo pipefail

CONTAINER="haproxy"
DEPENDS_ON="syslog"
MAX_WAIT_SECS=30   # attente max pour que syslog soit prêt avant de lancer haproxy

log() { logger -t "haproxy-watchdog" -- "$*"; }

container_status() {
    docker inspect --format='{{.State.Status}}' "$1" 2>/dev/null || echo "absent"
}

# --- vérification haproxy ---
STATUS=$(container_status "$CONTAINER")

if [[ "$STATUS" == "running" ]]; then
    exit 0
fi

log "haproxy est '$STATUS' — tentative de démarrage"

# --- s'assurer que syslog est prêt (depends_on) ---
WAITED=0
while [[ "$(container_status "$DEPENDS_ON")" != "running" ]]; do
    if (( WAITED >= MAX_WAIT_SECS )); then
        log "ERREUR : $DEPENDS_ON toujours absent après ${MAX_WAIT_SECS}s — abandon"
        exit 1
    fi
    log "En attente de $DEPENDS_ON (${WAITED}s)..."
    sleep 5
    (( WAITED += 5 ))
done

# --- démarrage direct du conteneur existant (créé par Portainer) ---
if docker start "$CONTAINER" 2>&1 | logger -t "haproxy-watchdog"; then
    log "haproxy démarré avec succès"
else
    log "ERREUR : échec du démarrage de haproxy (voir logs docker)"
    exit 1
fi
