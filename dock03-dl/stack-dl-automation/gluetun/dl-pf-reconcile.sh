#!/bin/bash
# /usr/local/sbin/dl-pf-reconcile.sh
# Réconciliation port forwarding Gluetun <-> qBittorrent avec escalade graduée.
#   Niveau 0 : dépendants orphelins (gluetun redémarré => netns recréé) -> restart des seuls dépendants
#   Niveau 1 : port gluetun != port qBit                                -> resync via API qBit (aucun restart)
#   Niveau 2 : aucun port forwardé depuis NOPORT_GRACE passages          -> restart du TUNNEL via control server
#              (le conteneur ne redémarre pas, le netns est conservé, les dépendants ne bougent pas)
#   Niveau 3 : niveau 2 échoue VPN_RESTART_MAX fois / gluetun unhealthy prolongé -> restart complet
# Prévu pour être lancé chaque minute par un timer systemd (pas de chevauchement possible).
set -u

GLUETUN="gluetun"
QBT="qbittorrent"
DEPENDENTS=(qbittorrent prowlarr cross-seed firefox-sandbox)

PF_FILE="/docker/gluetun/forwarded_port"     # = VPN_PORT_FORWARDING_STATUS_FILE=/gluetun/forwarded_port
CTRL_URL="http://127.0.0.1:8010"             # control server gluetun publié en 127.0.0.1 uniquement
API_KEY_FILE="/etc/dl-reconcile/gluetun.apikey"
QBT_URL="http://127.0.0.1:8888"
VPN_IFACE="tun0"                             # interface gluetun (tun0 par défaut, OpenVPN comme WireGuard)

STATE_DIR="/run/dl-reconcile"
NOPORT_GRACE=5        # passages (~minutes) sans port avant de relancer le tunnel
VPN_RESTART_MAX=2     # relances de tunnel infructueuses avant restart complet
UNHEALTHY_GRACE=10    # passages avec gluetun non healthy avant restart complet
QBT_DOWN_GRACE=5      # passages avec API qBit injoignable avant restart de qBit
LOG_TAG="dl-reconcile"

mkdir -p "$STATE_DIR"

log() { logger -t "$LOG_TAG" -- "$1"; [ -t 1 ] && echo "[$(date '+%F %T')] $1"; return 0; }
get() { cat "$STATE_DIR/$1" 2>/dev/null || echo 0; }
put() { echo "$2" > "$STATE_DIR/$1"; }

cstate()  { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }
chealth() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo missing; }
netns() {
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return 1
  [ "${pid:-0}" -gt 0 ] || return 1
  readlink "/proc/$pid/ns/net"
}

# Appels qBit exécutés DANS le netns de gluetun => vus comme localhost par qBit (bypass auth localhost)
qbt_get() { docker exec "$GLUETUN" wget -qO- -T 5 "$QBT_URL/api/v2/$1" 2>/dev/null; }
qbt_post() {
  docker exec "$GLUETUN" wget -qO- -T 5 \
    --header="Referer: $QBT_URL" --header="Origin: $QBT_URL" \
    --post-data="$2" "$QBT_URL/api/v2/$1" >/dev/null 2>&1
}

ctrl_vpn() {  # $1 = stopped | running
  curl -fsS -m 15 -X PUT \
    -H "X-API-Key: $(cat "$API_KEY_FILE")" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"$1\"}" \
    "$CTRL_URL/v1/vpn/status" >/dev/null
}

restart() { docker restart "$1" >/dev/null 2>&1 && log "restart OK: $1" || log "restart FAILED: $1"; }

wait_healthy() {  # $1 conteneur, $2 timeout (s)
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ "$(chealth "$1")" = "healthy" ] && return 0
    sleep 5; i=$((i + 5))
  done
  return 1
}

full_restart() {
  log "ESCALADE 3: $1 -> restart complet gluetun + dépendants"
  restart "$GLUETUN"
  wait_healthy "$GLUETUN" 180 || log "gluetun pas healthy après 180s, dépendants redémarrés quand même"
  for c in "${DEPENDENTS[@]}"; do restart "$c"; done
  put noport 0; put vpnrestart 0; put unhealthy 0; put qbtdown 0
}

# --- Gluetun doit tourner ---------------------------------------------------
GSTATE=$(cstate "$GLUETUN")
if [ "$GSTATE" != "running" ]; then
  log "gluetun $GSTATE - on laisse la restart policy Docker gérer"
  exit 0
fi

# --- Gluetun non healthy : il se répare seul (HEALTH_RESTART_VPN), on n'escalade qu'à la longue
GHEALTH=$(chealth "$GLUETUN")
if [ "$GHEALTH" != "healthy" ] && [ "$GHEALTH" != "none" ]; then
  n=$(( $(get unhealthy) + 1 )); put unhealthy "$n"
  log "gluetun $GHEALTH ($n/$UNHEALTHY_GRACE)"
  [ "$n" -ge "$UNHEALTHY_GRACE" ] && full_restart "gluetun $GHEALTH depuis $n passages"
  exit 0
fi
put unhealthy 0

# --- Niveau 0 : dépendants orphelins -----------------------------------------
GNS=$(netns "$GLUETUN") || GNS=""
orphan=0
if [ -n "$GNS" ]; then
  for c in "${DEPENDENTS[@]}"; do
    [ "$(cstate "$c")" = "running" ] || continue
    CNS=$(netns "$c") || continue
    if [ "$CNS" != "$GNS" ]; then
      log "NIVEAU 0: $c orphelin (netns $CNS != gluetun $GNS)"
      restart "$c"
      orphan=1
    fi
  done
fi
[ "$orphan" -eq 1 ] && exit 0   # on laisse qBit démarrer, la resync se fera au passage suivant

# --- Port forwardé côté gluetun ----------------------------------------------
# Le fichier contient soit le port seul, soit du JSON selon la version : on prend le 1er nombre.
PORT=$(grep -o '[0-9]\+' "$PF_FILE" 2>/dev/null | head -n1)
if [ -z "$PORT" ] || [ "$PORT" = "0" ]; then
  n=$(( $(get noport) + 1 )); put noport "$n"
  log "aucun port forwardé ($n/$NOPORT_GRACE)"
  [ "$n" -lt "$NOPORT_GRACE" ] && exit 0

  r=$(get vpnrestart)
  if [ "$r" -lt "$VPN_RESTART_MAX" ]; then
    log "NIVEAU 2: relance du tunnel via control server ($((r + 1))/$VPN_RESTART_MAX)"
    if ctrl_vpn stopped && sleep 3 && ctrl_vpn running; then
      log "tunnel relancé"
    else
      log "échec appel control server (clé API ? port 8000 publié ?)"
    fi
    put vpnrestart $((r + 1)); put noport 0
  else
    full_restart "pas de port après $VPN_RESTART_MAX relances du tunnel"
  fi
  exit 0
fi
put noport 0; put vpnrestart 0

# --- Niveau 1 : aligner qBittorrent ------------------------------------------
PREFS=$(qbt_get app/preferences)
if [ -z "$PREFS" ]; then
  n=$(( $(get qbtdown) + 1 )); put qbtdown "$n"
  log "API qBittorrent injoignable ($n/$QBT_DOWN_GRACE)"
  if [ "$n" -ge "$QBT_DOWN_GRACE" ]; then
    restart "$QBT"; put qbtdown 0
  fi
  exit 0
fi
put qbtdown 0

QPORT=$(printf '%s' "$PREFS" | grep -o '"listen_port":[0-9]*' | cut -d: -f2)
QIFACE=$(printf '%s' "$PREFS" | grep -o '"current_network_interface":"[^"]*"' | cut -d'"' -f4)

if [ "$QPORT" = "$PORT" ] && [ "$QIFACE" = "$VPN_IFACE" ]; then
  exit 0   # tout est aligné, on ne loggue rien
fi

log "NIVEAU 1: désynchro qBit port=${QPORT:-?} iface=${QIFACE:-?} / gluetun port=$PORT -> correction"
qbt_post app/setPreferences \
  "json={\"listen_port\":$PORT,\"current_network_interface\":\"$VPN_IFACE\",\"random_port\":false,\"upnp\":false}"

sleep 2
QPORT=$(qbt_get app/preferences | grep -o '"listen_port":[0-9]*' | cut -d: -f2)
if [ "$QPORT" = "$PORT" ]; then
  log "qBit resynchronisé sur le port $PORT"
else
  log "resync qBit en échec (lu: ${QPORT:-?}), nouvel essai au prochain passage"
fi
exit 0
