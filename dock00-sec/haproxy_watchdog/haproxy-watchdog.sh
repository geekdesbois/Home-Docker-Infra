#!/usr/bin/env bash
# =============================================================================
# haproxy-watchdog.sh — Surveille les conteneurs de la stack DMZ (HAProxy, …)
# et les (re)démarre s'ils sont arrêtés, unhealthy ou ne répondent plus.
#
# Lancé par haproxy-watchdog.timer.     Logs : journalctl -u haproxy-watchdog
# Pause (maintenance, redeploy Portainer) : touch /etc/haproxy-watchdog.pause
# Config locale (optionnelle)            : /etc/default/haproxy-watchdog
# =============================================================================
set -uo pipefail
export LC_ALL=C

# ---- Valeurs par défaut (surchargeables dans /etc/default/haproxy-watchdog) --
CONTAINERS="haproxy"                 # liste séparée par des espaces
STATE_DIR="/var/lib/haproxy-watchdog"
PAUSE_FILE="/etc/haproxy-watchdog.pause"
GRACE=60               # s : un conteneur arrêté depuis moins longtemps est ignoré (redeploy en cours)
MAX_RESTARTS=3         # nb max de relances…
RESTART_WINDOW=1800    # …sur cette fenêtre glissante (s), ensuite abandon + alerte
HEALTH_WAIT=150        # s : attente max d'un état sain après relance
PROBE_FAILS=2          # échecs consécutifs de la sonde HTTP avant d'agir
MISSING_FAILS=2        # passages consécutifs "introuvable" avant d'alerter
MAIL_TO=""             # vide = pas de mail, journal uniquement
MAIL_FROM="watchdog@$(hostname -f 2>/dev/null || hostname)"

# Sonde HTTP depuis l'hôte (vérifie aussi la publication des ports) — nécessite curl
declare -A PROBE_URL=(    [haproxy]="http://127.0.0.1:8404/healthz" )
# Validation exécutée DANS le conteneur avant un restart (jamais de restart sur config cassée)
declare -A VALIDATE_CMD=( [haproxy]="haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg" )

CONF="/etc/default/haproxy-watchdog"
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"

HOST=$(hostname -s)

# ---- Logs : préfixe de priorité compris par journald ------------------------
if [[ -t 1 ]]; then
  info() { echo "[INFO] $*"; }; warn() { echo "[WARN] $*"; }; err() { echo "[ERR ] $*"; }
else
  info() { echo "<6>$*"; };     warn() { echo "<4>$*"; };     err() { echo "<3>$*"; }
fi

# ---- Alertes mail (via sendmail : dma ou msmtp-mta vers le relais Synology) --
alert() {  # alert <conteneur> <sujet ASCII> [détail]
  local c=$1 subject="[$HOST] watchdog $1: $2" detail=${3:-} state="" logs=""
  [[ -n $MAIL_TO ]] || return 0
  if ! command -v sendmail >/dev/null 2>&1; then
    warn "MAIL_TO défini mais pas de sendmail (apt install dma ou msmtp-mta)"; return 0
  fi
  if docker inspect "$c" >/dev/null 2>&1; then
    state=$(docker inspect -f 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} exit={{.State.ExitCode}} finished={{.State.FinishedAt}} error={{.State.Error}}' "$c" 2>&1)
    logs=$(docker logs --tail 40 "$c" 2>&1)
  fi
  {
    printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\n' "$MAIL_FROM" "$MAIL_TO" "$subject" "$(date -R)"
    printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n'
    printf '%s\n' "$2"
    [[ -n $detail ]] && printf '\n%s\n' "$detail"
    [[ -n $state  ]] && printf '\nÉtat : %s\n' "$state"
    [[ -n $logs   ]] && printf '\n--- docker logs --tail 40 %s ---\n%s\n' "$c" "$logs"
  } | sendmail -odi -t || warn "échec d'envoi du mail d'alerte"
}

alert_once() {  # alert_once <conteneur> <clé> <sujet> [détail] — une seule fois jusqu'au retour à la normale
  local f="$STATE_DIR/$1.alerted.$2"
  [[ -e $f ]] && return 0
  : >"$f"; alert "$1" "$3" "${4:-}"
}

# ---- Compteurs persistants ---------------------------------------------------
cnt_get()   { cat "$STATE_DIR/$1.$2" 2>/dev/null || echo 0; }
cnt_bump()  { local n=$(( $(cnt_get "$1" "$2") + 1 )); echo "$n" >"$STATE_DIR/$1.$2"; echo "$n"; }
cnt_reset() { rm -f "$STATE_DIR/$1.$2"; }

# Anti-boucle : au plus MAX_RESTARTS relances sur RESTART_WINDOW secondes
restart_budget_ok() {
  local f="$STATE_DIR/$1.restarts" now cutoff t recent=()
  now=$(date +%s); cutoff=$(( now - RESTART_WINDOW ))
  if [[ -f $f ]]; then
    while read -r t; do [[ $t =~ ^[0-9]+$ ]] && (( t > cutoff )) && recent+=("$t"); done <"$f"
  fi
  if (( ${#recent[@]} )); then printf '%s\n' "${recent[@]}" >"$f"; else : >"$f"; fi
  (( ${#recent[@]} >= MAX_RESTARTS )) && return 1
  echo "$now" >>"$f"
}

# ---- Sondes ------------------------------------------------------------------
read_state() {  # status|health|exitcode|finishedAt|error
  docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}|{{.State.FinishedAt}}|{{.State.Error}}' "$1" 2>/dev/null
}

probe() {  # 0 = OK (ou pas de sonde définie)
  local url=${PROBE_URL[$1]:-}
  [[ -z $url ]] && return 0
  if ! command -v curl >/dev/null 2>&1; then warn "curl absent : sonde HTTP de $1 ignorée"; return 0; fi
  curl -fsS -m 5 -o /dev/null "$url" 2>/dev/null
}

wait_healthy() {
  local c=$1 deadline=$(( $(date +%s) + HEALTH_WAIT )) s st h
  while (( $(date +%s) < deadline )); do
    sleep 5
    s=$(read_state "$c") || continue
    IFS='|' read -r st h _ <<<"$s"
    case "$st/$h" in
      running/healthy|running/none) probe "$c" && return 0 ;;
      exited/*|dead/*)              return 1 ;;   # retombé aussitôt
    esac
  done
  return 1
}

mark_healthy() {
  local c=$1
  cnt_reset "$c" probe; cnt_reset "$c" restarting
  if compgen -G "$STATE_DIR/$c.alerted.*" >/dev/null; then
    info "$c : de nouveau sain"
    rm -f -- "$STATE_DIR/$c".alerted.*
  fi
}

# ---- Vérification d'un conteneur ----------------------------------------------
check_container() {
  local c=$1 s st h code fin errm action="" reason="" n age out

  if ! s=$(read_state "$c"); then
    n=$(cnt_bump "$c" missing)
    warn "$c : conteneur introuvable ($n/$MISSING_FAILS) — stack supprimée ou en cours de redéploiement ?"
    (( n >= MISSING_FAILS )) && alert_once "$c" missing "conteneur introuvable" \
      "Le conteneur n'existe plus : redéployer la stack via Portainer."
    return 1
  fi
  cnt_reset "$c" missing
  IFS='|' read -r st h code fin errm <<<"$s"

  case "$st" in
    running)
      cnt_reset "$c" restarting
      case "$h" in
        starting)  info "$c : démarrage en cours (health=starting)"; return 0 ;;
        unhealthy) action=restart; reason="healthcheck Docker = unhealthy" ;;
        *)
          if probe "$c"; then mark_healthy "$c"; return 0; fi
          n=$(cnt_bump "$c" probe)
          warn "$c : sonde ${PROBE_URL[$c]} KO ($n/$PROBE_FAILS)"
          (( n < PROBE_FAILS )) && return 0
          action=restart; reason="sonde ${PROBE_URL[$c]} KO $n fois de suite" ;;
      esac ;;
    exited|created)
      age=$(( $(date +%s) - $(date -d "$fin" +%s 2>/dev/null || echo 0) ))
      if (( age < GRACE )); then
        info "$c : arrêté depuis ${age}s seulement, on attend (${GRACE}s de grâce)"; return 0
      fi
      action=start
      reason="état=$st exit=$code arrêté le $fin${errm:+ erreur=\"$errm\"}" ;;
    restarting)
      n=$(cnt_bump "$c" restarting)
      warn "$c : boucle de redémarrage Docker (exit=$code${errm:+, $errm}) — passage $n"
      (( n >= 3 )) && alert_once "$c" restarting "boucle de redemarrage Docker"
      return 1 ;;
    paused)
      info "$c : en pause (volontaire ?), pas d'action"; return 0 ;;
    *)
      err "$c : état '$st' non récupérable automatiquement"
      alert_once "$c" state "etat $st non recuperable"
      return 1 ;;
  esac

  warn "$c : $reason → $action"

  # Ne jamais tuer un HAProxy qui tourne pour le relancer sur une config cassée
  if [[ $action == restart && -n ${VALIDATE_CMD[$c]:-} ]]; then
    if ! out=$(docker exec "$c" sh -c "${VALIDATE_CMD[$c]}" 2>&1); then
      err "$c : config invalide, PAS de restart (le process en place garde l'ancienne config) : $out"
      alert_once "$c" badcfg "config invalide, restart annule" "$out"
      return 1
    fi
  fi

  if ! restart_budget_ok "$c"; then
    err "$c : déjà $MAX_RESTARTS relances en $(( RESTART_WINDOW / 60 )) min — abandon, intervention manuelle requise"
    alert_once "$c" gaveup "ABANDON apres $MAX_RESTARTS relances" "Raison du dernier échec : $reason"
    return 1
  fi

  if [[ $action == start ]]; then
    out=$(docker start "$c" 2>&1)
  else
    out=$(docker restart -t 15 "$c" 2>&1)
  fi
  # shellcheck disable=SC2181
  if (( $? != 0 )); then
    err "$c : échec de docker $action : $out"
    alert "$c" "ECHEC docker $action" "Raison : $reason"$'\n'"Sortie : $out"
    return 1
  fi

  if wait_healthy "$c"; then
    info "$c : relancé avec succès ($action)"
    mark_healthy "$c"
    alert "$c" "relance OK ($action)" "Raison : $reason"
    return 0
  fi
  err "$c : relancé mais toujours pas sain après ${HEALTH_WAIT}s"
  alert "$c" "ECHEC relance ($action)" "Raison : $reason"
  return 1
}

# ---- Main --------------------------------------------------------------------
main() {
  local rc=0 c
  mkdir -p "$STATE_DIR"
  exec 9>/run/lock/haproxy-watchdog.lock
  flock -n 9 || { info "une instance tourne déjà"; exit 0; }

  [[ -e $PAUSE_FILE ]] && { info "pause active ($PAUSE_FILE), rien à faire"; exit 0; }
  [[ $(systemctl is-system-running 2>/dev/null) == stopping ]] && exit 0

  if ! systemctl is-active --quiet docker; then
    warn "docker.service inactif — on repasse au prochain tour"
    alert_once docker down "docker.service inactif"
    exit 1
  fi
  rm -f -- "$STATE_DIR"/docker.alerted.*

  # Ne pas se battre avec une mise à jour en cours (cause n°1 du problème)
  if pgrep -f '/usr/bin/unattended-upgrade( |$)' >/dev/null || pgrep -x 'apt|apt-get|dpkg' >/dev/null; then
    info "mise à jour APT en cours, on repasse au prochain tour"; exit 0
  fi

  for c in $CONTAINERS; do check_container "$c" || rc=1; done
  exit "$rc"
}

main "$@"
