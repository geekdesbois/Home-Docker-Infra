#!/bin/bash
# Crée /usr/local/sbin/restart-dl-stack-if-unhealthy.sh sur host docker for DL
set -euo pipefail

QBT_CONTAINER="qbittorrent"
GLUETUN_CONTAINER="gluetun"
FIREFOX_CONTAINER="firefox-sandbox"
PROWLARR_CONTAINER="prowlarr"

STATE="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$QBT_CONTAINER" 2>/dev/null || echo missing)"

if [ "$STATE" = "unhealthy" ]; then
  logger -t dl-autoheal "qBittorrent unhealthy -> restarting gluetun then qbittorrent"
  docker restart "$GLUETUN_CONTAINER"
  sleep 10
  docker restart "$QBT_CONTAINER"
  docker restart "$FIREFOX_CONTAINER"
  docker restart "$PROWLARR_CONTAINER"
fi