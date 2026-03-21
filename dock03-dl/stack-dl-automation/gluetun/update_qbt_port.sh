#!/bin/sh
set -u

PORT="${1:?missing port}"
IFACE="${2:?missing interface}"

echo "[qbt-pf] start PORT=$PORT IFACE=$IFACE"

i=0
while [ "$i" -lt 60 ]; do
  if wget -qO- http://127.0.0.1:8888/api/v2/app/preferences >/dev/null 2>&1; then
    echo "[qbt-pf] qB API ready after ${i}s"
    break
  fi
  i=$((i + 1))
  sleep 1
done

if [ "$i" -ge 60 ]; then
  echo "[qbt-pf] qB API not ready after 60s"
  exit 1
fi

echo "[qbt-pf] applying port/interface"

POST_OUTPUT="$(
  wget -S -O- \
    --header="Referer: http://127.0.0.1:8888" \
    --header="Origin: http://127.0.0.1:8888" \
    --post-data="json={\"listen_port\":${PORT},\"current_network_interface\":\"${IFACE}\",\"random_port\":false,\"upnp\":false}" \
    http://127.0.0.1:8888/api/v2/app/setPreferences 2>&1
)"
POST_RC=$?

echo "[qbt-pf] POST rc=${POST_RC}"
echo "$POST_OUTPUT"

i=0
while [ "$i" -lt 15 ]; do
  PREFS="$(wget -qO- http://127.0.0.1:8888/api/v2/app/preferences 2>/dev/null || true)"
  CURRENT_PORT="$(printf '%s' "$PREFS" | grep -o '"listen_port":[0-9]*' | cut -d: -f2 || true)"
  CURRENT_IFACE="$(printf '%s' "$PREFS" | grep -o '"current_network_interface":"[^"]*"' | cut -d'"' -f4 || true)"

  echo "[qbt-pf] check #$i CURRENT_PORT=${CURRENT_PORT:-<empty>} CURRENT_IFACE=${CURRENT_IFACE:-<empty>}"

  if [ "$CURRENT_PORT" = "$PORT" ] && [ "$CURRENT_IFACE" = "$IFACE" ]; then
    echo "[qbt-pf] success"
    exit 0
  fi

  sleep 1
  i=$((i + 1))
done

echo "[qbt-pf] failed to apply port/interface"
exit 1
