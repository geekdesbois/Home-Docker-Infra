#!/usr/bin/env bash
# plex-watchdog.sh — surveille le conteneur Plex :
#   - le démarre s'il est arrêté (après vérification des montages SMB et du GPU)
#   - le redémarre s'il tourne mais ne voit pas les montages SMB (monté avant eux)
# Lancé par plex-watchdog.timer (systemd). Peut aussi être lancé à la main.
#
# Codes retour : 0 = OK / rien à faire / corrigé, 1 = problème (voir journal)

set -uo pipefail

# --- Configuration -----------------------------------------------------------
CONTAINER="${CONTAINER:-plex}"

# Si ce fichier existe, le watchdog ne touche à rien (maintenance, arrêt volontaire)
DISABLE_FLAG="${DISABLE_FLAG:-/etc/plex-watchdog.disable}"

# Montages requis : "chemin_hôte:chemin_dans_le_conteneur"
MOUNT_MAP=(
    "/mnt/media/videoblackbox:/media/videoblackbox"
    "/mnt/media/videopriveblackbox:/media/videopriveblackbox"
    "/mnt/media/musicblackbox:/media/musicblackbox"
    "/mnt/media/ebooksblackbox:/media/ebooksblackbox"
)

# Redémarrer Plex s'il tourne mais voit un dossier local vide à la place du partage SMB
RESTART_ON_STALE_MOUNT=1

# Périphériques NVIDIA déclarés dans le compose (laisser vide pour ne pas vérifier)
NVIDIA_DEVICES=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools)

# Secondes d'attente après start/restart avant de vérifier que le conteneur tient
SETTLE_DELAY=15

LOCK_FILE=/run/plex-watchdog.lock
# -----------------------------------------------------------------------------

# Sous systemd, les préfixes <N> fixent la priorité dans le journal
if [[ -n "${JOURNAL_STREAM:-}" ]]; then
    info() { echo "<6>$*"; }
    warn() { echo "<4>$*"; }
    err()  { echo "<3>$*"; }
else
    info() { echo "[INFO] $*"; }
    warn() { echo "[WARN] $*" >&2; }
    err()  { echo "[ERR]  $*" >&2; }
fi

ctr_status() { docker container inspect -f '{{.State.Status}}' "$CONTAINER"; }

# Vérifie que le conteneur tourne toujours SETTLE_DELAY secondes après une action
verify_running() {
    sleep "$SETTLE_DELAY"
    local s
    s=$(ctr_status)
    if [[ "$s" == "running" ]]; then
        info "'$CONTAINER' $1 avec succès."
        return 0
    fi
    err "'$CONTAINER' est '$s' ${SETTLE_DELAY}s après l'opération. Dernières lignes de log :"
    docker logs --tail 20 "$CONTAINER" 2>&1 | while IFS= read -r line; do err "  $line"; done
    return 1
}

# Renvoie 1 si un des montages SMB est absent côté hôte
host_mounts_ok() {
    local pair host ok=0
    for pair in "${MOUNT_MAP[@]}"; do
        host=${pair%%:*}
        if ! mountpoint -q "$host"; then
            warn "$host n'est pas monté sur l'hôte (NAS injoignable ?)."
            ok=1
        fi
    done
    return $ok
}

# Conteneur en marche : vérifie qu'il voit bien les partages SMB et pas le dossier local
check_running_mounts() {
    local pair host ctr hdev cdev stale=()
    for pair in "${MOUNT_MAP[@]}"; do
        host=${pair%%:*}
        ctr=${pair#*:}
        # Partage absent côté hôte : redémarrer Plex n'y changerait rien
        mountpoint -q "$host" || { warn "$host non monté sur l'hôte : Plex voit un dossier vide."; continue; }
        hdev=$(timeout 20 stat -c %d "$host" 2>/dev/null) || continue
        cdev=$(timeout 20 docker exec "$CONTAINER" stat -c %d "$ctr" 2>/dev/null) || continue
        [[ "$hdev" == "$cdev" ]] || stale+=("$ctr")
    done

    (( ${#stale[@]} == 0 )) && return 0

    warn "'$CONTAINER' ne voit pas les partages SMB montés après son démarrage : ${stale[*]}"
    if (( RESTART_ON_STALE_MOUNT )); then
        warn "Redémarrage de '$CONTAINER' pour prendre en compte les montages."
        if ! out=$(docker restart "$CONTAINER" 2>&1); then
            err "Échec de 'docker restart $CONTAINER' : $out"
            return 1
        fi
        verify_running "redémarré"
        return $?
    fi
    return 1
}

# Évite deux exécutions simultanées
exec 9>"$LOCK_FILE"
flock -n 9 || { info "Une autre instance tourne déjà, sortie."; exit 0; }

if [[ -e "$DISABLE_FLAG" ]]; then
    info "Mode maintenance ($DISABLE_FLAG présent), rien à faire."
    exit 0
fi

if ! systemctl is-active --quiet docker; then
    err "Le service docker n'est pas actif."
    exit 1
fi

if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    err "Conteneur '$CONTAINER' introuvable."
    exit 1
fi

status=$(ctr_status)

case "$status" in
    running)
        check_running_mounts
        exit $?
        ;;
    restarting)
        info "'$CONTAINER' est en cours de redémarrage par Docker, on laisse faire."
        exit 0
        ;;
    paused)
        info "'$CONTAINER' est en pause, on n'y touche pas."
        exit 0
        ;;
    created|exited|dead)
        ;;
    *)
        warn "État inattendu pour '$CONTAINER' : $status"
        exit 1
        ;;
esac

# --- Conteneur arrêté : on tente de le démarrer ------------------------------

# Trace de l'arrêt précédent, utile pour trouver la cause
prev=$(docker container inspect \
    -f 'code={{.State.ExitCode}} fin={{.State.FinishedAt}} erreur="{{.State.Error}}"' "$CONTAINER")
warn "'$CONTAINER' est '$status' ($prev) — tentative de démarrage."

if ! host_mounts_ok; then
    err "Montages SMB incomplets, démarrage reporté au prochain passage."
    exit 1
fi

# Périphériques NVIDIA : on tente de les créer s'ils manquent
missing=()
for d in "${NVIDIA_DEVICES[@]}"; do
    [[ -e "$d" ]] || missing+=("$d")
done
if (( ${#missing[@]} > 0 )); then
    warn "Périphériques NVIDIA absents : ${missing[*]} — tentative avec nvidia-modprobe."
    if command -v nvidia-modprobe >/dev/null 2>&1; then
        nvidia-modprobe -u -c 0 >/dev/null 2>&1 || true   # nvidia-uvm + /dev/nvidia0
        nvidia-modprobe -m      >/dev/null 2>&1 || true   # nvidia-modeset
    fi
    still=()
    for d in "${missing[@]}"; do
        [[ -e "$d" ]] || still+=("$d")
    done
    if (( ${#still[@]} > 0 )); then
        err "Toujours absents : ${still[*]}. Module NVIDIA non chargé ? (vérifier 'nvidia-smi' et 'dkms status')"
        exit 1
    fi
    info "Périphériques NVIDIA créés."
fi

if ! out=$(docker start "$CONTAINER" 2>&1); then
    err "Échec de 'docker start $CONTAINER' : $out"
    exit 1
fi

verify_running "démarré"
exit $?
