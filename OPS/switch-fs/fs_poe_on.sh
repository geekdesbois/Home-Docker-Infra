#!/bin/bash
set -euo pipefail

SW="fs-s3100"
LOG="/var/log/fs_poe.log"

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') | PoE ON start ====="

  ssh -tt -oBatchMode=yes -oConnectTimeout=5 \
      -oServerAliveInterval=10 -oServerAliveCountMax=2 \
      "$SW" <<'EOF'
configure terminal
interface GigabitEthernet 0/4
 poe enable
exit
interface GigabitEthernet 0/5
 poe enable
exit
end

show poe interface GigabitEthernet 0/4
show poe interface GigabitEthernet 0/5

exit
EOF

  echo "===== $(date '+%Y-%m-%d %H:%M:%S') | PoE ON done ====="
  echo
} >> "$LOG" 2>&1
