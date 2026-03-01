#!/usr/bin/env bash
# Script pour reconstruire les .pem à partir des fullchain/key et recharger HAProxy si besoin
# script a créér sur l'hôte pas dans le conteneur
set -euo pipefail

CERT_DIR="/docker/haproxy/certs"
DOMAINS=("nina.fm" "zonelibre.live")   # ajoute ici d’autres domaines si besoin

HAPROXY_CONTAINER="haproxy"            # nom docker du conteneur
CRT_LIST="/docker/haproxy/crt-list.txt" # si tu l’utilises déjà

log() { echo "[$(date -Is)] $*"; }

need_update() {
  local out="$1" full="$2" key="$3"
  [[ ! -f "$out" ]] && return 0
  [[ "$full" -nt "$out" ]] && return 0
  [[ "$key"  -nt "$out" ]] && return 0
  return 1
}

build_pem() {
  local d="$1"
  local full="${CERT_DIR}/${d}.fullchain.pem"
  local key="${CERT_DIR}/${d}.key.pem"
  local out="${CERT_DIR}/${d}.pem"
  local tmp="${out}.tmp"

  if [[ ! -f "$full" || ! -f "$key" ]]; then
    log "SKIP $d: missing fullchain/key"
    return 0
  fi

  if need_update "$out" "$full" "$key"; then
    log "BUILD $d -> ${out}"
    cat "$full" "$key" > "$tmp"
    chmod 0644 "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$out"
  else
    log "OK $d (up-to-date)"
  fi
}

reload_haproxy() {
  # Option A (simple): reload conteneur via signal / graceful
  # docker kill -s HUP haproxy  (marche si haproxy PID1 dans le conteneur)
  # Option B: restart (moins clean)
  # Option C: docker exec haproxy -sf ...
  #
  # Ici je fais: validation config + HUP si possible, sinon reload container.

  log "VALIDATE haproxy config"
  if ! docker exec "$HAPROXY_CONTAINER" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
    log "ERROR: haproxy config invalid, not reloading"
    return 1
  fi

  log "RELOAD haproxy (HUP)"
  if docker kill -s HUP "$HAPROXY_CONTAINER" >/dev/null 2>&1; then
    log "RELOAD OK (HUP sent)"
  else
    log "HUP failed, doing container restart"
    docker restart "$HAPROXY_CONTAINER" >/dev/null
    log "RESTART OK"
  fi
}

main() {
  cd "$CERT_DIR"
  local changed=0

  for d in "${DOMAINS[@]}"; do
    local out="${CERT_DIR}/${d}.pem"
    local full="${CERT_DIR}/${d}.fullchain.pem"
    local key="${CERT_DIR}/${d}.key.pem"

    # snapshot mtime before
    local before=""
    [[ -f "$out" ]] && before="$(stat -c %Y "$out")" || before="0"

    build_pem "$d"

    local after=""
    [[ -f "$out" ]] && after="$(stat -c %Y "$out")" || after="0"
    if [[ "$after" != "$before" ]]; then
      changed=1
    fi
  done

  # Optionnel: s'assurer que crt-list pointe bien sur les .pem root-owned
  if [[ -f "$CRT_LIST" ]]; then
    log "crt-list present: $CRT_LIST (not modifying)"
  fi

  if [[ "$changed" -eq 1 ]]; then
    reload_haproxy
  else
    log "No changes, no reload"
  fi
}

main "$@"