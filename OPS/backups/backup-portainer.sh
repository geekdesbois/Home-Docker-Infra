#!/usr/bin/env bash
set -euo pipefail

DEST="/docker/portainer/backup"
TS="$(date +%F_%H-%M-%S)"
VOLUME="portainer_portainer_data"

mkdir -p "$DEST"

echo "Stopping Portainer..."
docker stop portainer >/dev/null

echo "Backing up volume ${VOLUME}..."
docker run --rm \
  -v ${VOLUME}:/volume:ro \
  -v ${DEST}:/backup \
  alpine \
  tar czf /backup/portainer_data_${TS}.tgz -C /volume .

echo "Starting Portainer..."
docker start portainer >/dev/null

# rotation 14 jours
find "$DEST" -type f -name "portainer_data_*.tgz" -mtime +14 -delete

echo "OK: backup -> ${DEST}/portainer_data_${TS}.tgz"
