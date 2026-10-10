#!/usr/bin/env bash
# plex-empty-trash.sh — vide la corbeille des bibliothèques Plex, uniquement si :
#   - Plex tourne et répond
#   - tous les partages SMB sont montés sur l'hôte, non vides, et visibles dans le conteneur
#   - la bibliothèque n'est pas en cours d'analyse
#   - le nombre d'éléments en corbeille reste sous un seuil (sinon : anomalie probable)
#
# Test sans rien supprimer :  sudo DRY_RUN=1 /usr/local/sbin/plex-empty-trash.sh
# Dépendances : curl, jq
#
# Codes retour : 0 = OK, 1 = abandon (voir journal)

set -uo pipefail

# --- Configuration -----------------------------------------------------------
CONTAINER="${CONTAINER:-plex}"
PLEX_URL="${PLEX_URL:-http://127.0.0.1:32400}"
PREFS="/srv/plex/config/Library/Application Support/Plex Media Server/Preferences.xml"

# Même fichier de maintenance que le watchdog
DISABLE_FLAG="${DISABLE_FLAG:-/etc/plex-watchdog.disable}"

# Montages requis : "chemin_hôte:chemin_dans_le_conteneur"
MOUNT_MAP=(
    "/mnt/media/videoblackbox:/media/videoblackbox"
    "/mnt/media/videopriveblackbox:/media/videopriveblackbox"
    "/mnt/media/musicblackbox:/media/musicblackbox"
    "/mnt/media/ebooksblackbox:/media/ebooksblackbox"
)

# Au-delà de ce nombre d'éléments en corbeille dans une bibliothèque, on ne vide pas
# (0 = pas de limite). À ajuster selon ton rythme de ménage.
MAX_TRASH="${MAX_TRASH:-100}"

DRY_RUN="${DRY_RUN:-0}"

# Verrou partagé avec le watchdog : pas de vidage pendant un (re)démarrage de Plex
LOCK_FILE=/run/plex-watchdog.lock
# -----------------------------------------------------------------------------

if [[ -n "${JOURNAL_STREAM:-}" ]]; then
    info() { echo "<6>$*"; }
    warn() { echo "<4>$*"; }
    err()  { echo "<3>$*"; }
else
    info() { echo "[INFO] $*"; }
    warn() { echo "[WARN] $*" >&2; }
    err()  { echo "[ERR]  $*" >&2; }
fi

for cmd in curl jq docker; do
    command -v "$cmd" >/dev/null 2>&1 || { err "Commande manquante : $cmd"; exit 1; }
done

exec 9>"$LOCK_FILE"
flock -w 300 9 || { err "Verrou occupé depuis 5 min (watchdog bloqué ?), abandon."; exit 1; }

if [[ -e "$DISABLE_FLAG" ]]; then
    info "Mode maintenance ($DISABLE_FLAG présent), rien à faire."
    exit 0
fi

# --- 1. Plex tourne et répond ------------------------------------------------
if [[ "$(docker container inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" != "running" ]]; then
    err "'$CONTAINER' ne tourne pas, abandon."
    exit 1
fi
if ! curl -fsS --max-time 10 "$PLEX_URL/identity" >/dev/null; then
    err "Plex ne répond pas sur $PLEX_URL, abandon."
    exit 1
fi

TOKEN=$(grep -oP 'PlexOnlineToken="\K[^"]+' "$PREFS" 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
    err "Token introuvable dans $PREFS, abandon."
    exit 1
fi

api() {
    curl -fsS --max-time 60 \
        -H "Accept: application/json" \
        -H "X-Plex-Token: $TOKEN" "$@"
}

# --- 2. Partages montés, non vides, visibles dans le conteneur ---------------
verified=()
for pair in "${MOUNT_MAP[@]}"; do
    host=${pair%%:*}
    ctr=${pair#*:}

    if ! mountpoint -q "$host"; then
        err "$host n'est pas monté, abandon complet."
        exit 1
    fi
    if [[ -z "$(timeout 30 find "$host" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        err "$host est monté mais vide (ou injoignable), abandon complet."
        exit 1
    fi
    hdev=$(timeout 20 stat -c %d "$host" 2>/dev/null)
    cdev=$(timeout 20 docker exec "$CONTAINER" stat -c %d "$ctr" 2>/dev/null)
    if [[ -z "$hdev" || "$hdev" != "$cdev" ]]; then
        err "$ctr dans le conteneur ne correspond pas au partage monté sur l'hôte, abandon complet."
        exit 1
    fi
    verified+=("$ctr")
done

# Vrai si le chemin (vu par Plex) est sous un des partages vérifiés
path_verified() {
    local p v
    p=${1%/}
    for v in "${verified[@]}"; do
        [[ "$p" == "$v" || "$p" == "$v"/* ]] && return 0
    done
    return 1
}

# --- 3. Parcours des bibliothèques -------------------------------------------
if ! sections=$(api "$PLEX_URL/library/sections"); then
    err "Impossible de lister les bibliothèques, abandon."
    exit 1
fi

rc=0
while IFS=$'\t' read -r key title type refreshing locations; do
    [[ -z "$key" ]] && continue

    if [[ "$refreshing" == "true" ]]; then
        warn "[$title] analyse en cours, ignorée."
        continue
    fi

    ok=1
    IFS='|' read -r -a locs <<< "$locations"
    for loc in "${locs[@]}"; do
        if ! path_verified "$loc"; then
            warn "[$title] emplacement non surveillé ($loc), ignorée."
            ok=0
            break
        fi
    done
    (( ok )) || continue

    # Niveau de comptage : films, épisodes, pistes ; défaut pour les autres types
    case "$type" in
        movie)  ptype=1 ;;
        show)   ptype=4 ;;
        artist) ptype=10 ;;
        *)      ptype="" ;;
    esac

    count=$(api "$PLEX_URL/library/sections/$key/all?trash=1${ptype:+&type=$ptype}&X-Plex-Container-Start=0&X-Plex-Container-Size=0" \
            | jq -r '.MediaContainer.totalSize // .MediaContainer.size // empty' 2>/dev/null)
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        warn "[$title] impossible de compter la corbeille, ignorée."
        rc=1
        continue
    fi

    if (( count == 0 )); then
        info "[$title] corbeille vide."
        continue
    fi

    if (( MAX_TRASH > 0 && count > MAX_TRASH )); then
        warn "[$title] $count éléments en corbeille (> $MAX_TRASH) : anomalie possible, à vérifier et vider à la main."
        rc=1
        continue
    fi

    if (( DRY_RUN )); then
        info "[$title] DRY_RUN : $count élément(s) seraient supprimés de la corbeille."
        continue
    fi

    if api -X PUT "$PLEX_URL/library/sections/$key/emptyTrash" >/dev/null; then
        info "[$title] corbeille vidée ($count élément(s))."
    else
        err "[$title] échec du vidage de la corbeille."
        rc=1
    fi
done < <(jq -r '.MediaContainer.Directory[]?
        | [ .key, .title, .type, (.refreshing // false | tostring),
            ([.Location[]?.path] | join("|")) ]
        | @tsv' <<< "$sections")

exit $rc
