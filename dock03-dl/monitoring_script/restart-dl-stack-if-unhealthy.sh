#!/bin/bash
# /usr/local/sbin/restart-dl-stack-if-unhealthy.sh
set -u

QBT_CONTAINER="qbittorrent"
GLUETUN_CONTAINER="gluetun"
FIREFOX_CONTAINER="firefox-sandbox"
PROWLARR_CONTAINER="prowlarr"

LOG_TAG="dl-autoheal"

log() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
  logger -t "$LOG_TAG" -- "$msg"
}

get_health() {
  local container="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "missing"
}

restart_container() {
  local container="$1"

  if docker restart "$container" >/dev/null 2>&1; then
    log "restart OK: $container"
    return 0
  else
    log "restart FAILED: $container"
    return 1
  fi
}

STATE="$(get_health "$QBT_CONTAINER")"
log "detected health status for $QBT_CONTAINER: $STATE"

case "$STATE" in
  healthy)
    log "no action needed: $QBT_CONTAINER is healthy"
    ;;
  unhealthy)
    log "action: $QBT_CONTAINER unhealthy -> restarting $GLUETUN_CONTAINER, then dependent containers"

    restart_container "$GLUETUN_CONTAINER"
    sleep 10
    restart_container "$QBT_CONTAINER"
    restart_container "$FIREFOX_CONTAINER"
    restart_container "$PROWLARR_CONTAINER"

    NEW_STATE="$(get_health "$QBT_CONTAINER")"
    log "post-restart health status for $QBT_CONTAINER: $NEW_STATE"
    ;;
  none)
    log "warning: $QBT_CONTAINER has no Docker healthcheck configured"
    ;;
  missing)
    log "error: $QBT_CONTAINER container not found"
    ;;
  *)
    log "warning: unexpected health state for $QBT_CONTAINER: $STATE"
    ;;
esac

exit 0