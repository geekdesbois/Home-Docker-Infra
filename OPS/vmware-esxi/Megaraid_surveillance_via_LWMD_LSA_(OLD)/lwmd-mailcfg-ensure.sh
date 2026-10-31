#!/bin/bash
# script remote from esxi

set -euo pipefail

ESXI_IP="172.16.70.8"
SSH_ID="/root/.ssh/esxi_lwmd_cfg_rsa"
SSH_OPTS=(-i "$SSH_ID" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)

log() { echo "[$(date -Is)] $*"; }

# 1) Check
set +e
OUT="$(ssh "${SSH_OPTS[@]}" root@"$ESXI_IP" check 2>&1)"
RC=$?
set -e

if [ $RC -eq 0 ] && [[ "$OUT" == "OK" ]]; then
  log "OK: config-current.json conforme"
  exit 0
fi

log "MISMATCH: $OUT"
log "Restoring expected config..."

# 2) Restore
ssh "${SSH_OPTS[@]}" root@"$ESXI_IP" restore >/dev/null 2>&1 || {
  log "ERROR: restore failed"
  exit 1
}

# 3) Re-check
OUT2="$(ssh "${SSH_OPTS[@]}" root@"$ESXI_IP" check 2>&1 || true)"
log "Post-restore check: $OUT2"

exit 0
