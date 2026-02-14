#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/plex/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
DEST="/docker/plex/backup/db-dumps"
TS="$(date +%F_%H-%M-%S)"

mkdir -p "$DEST"

docker stop plex >/dev/null

tar -czf "$DEST/plex_db_$TS.tgz" -C "$BASE" .

docker start plex >/dev/null

find "$DEST" -type f -mtime +3 -delete
