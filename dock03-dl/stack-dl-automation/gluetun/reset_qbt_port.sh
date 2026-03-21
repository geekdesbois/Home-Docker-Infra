#!/bin/sh
set -eu

wget -qO- \
  --header="Referer: http://127.0.0.1:8888" \
  --header="Origin: http://127.0.0.1:8888" \
  --post-data="json={\"listen_port\":0,\"current_network_interface\":\"lo\"}" \
  http://127.0.0.1:8888/api/v2/app/setPreferences >/dev/null
