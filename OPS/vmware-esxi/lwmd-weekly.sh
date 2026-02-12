#!/bin/bash
set -euo pipefail

SSH="ssh -i /root/.ssh/esxi_lwmd_rsa -o IdentitiesOnly=yes root@172.16.70.8"

echo "[$(date)] lwmd start"
$SSH start

sleep 300

echo "[$(date)] lwmd stop"
$SSH stop
