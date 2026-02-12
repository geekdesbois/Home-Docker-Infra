#!/bin/sh
# script local to esxi, to put on datastore to be persistent
# Restricted SSH controller for lwmd/LSA
# Allowed commands: start | stop | status

LOGTAG="lwmd-ssh"
CMD="$(echo "${SSH_ORIGINAL_COMMAND:-}" | awk '{print $1}')"

export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/lib/vmware/bin:/usr/lib/vmware/sbin"
umask 022

log() { logger -t "$LOGTAG" "$1"; }

run() {
  OUT="$("$@" 2>&1)"
  RC=$?
  log "cmd='$*' rc=$RC out='${OUT}'"
  return $RC
}

fw_on()  { run esxcli network firewall ruleset set -r lwmd -e true; }
fw_off() { run esxcli network firewall ruleset set -r lwmd -e false; }

case "$CMD" in
  start)
    log "requested: start"
    fw_on
    # restart-like pour éviter les états foireux
    run /etc/init.d/lwmd stop
    sleep 2
    run /etc/init.d/lwmd start
    ;;
  stop)
    log "requested: stop"
    run /etc/init.d/lwmd stop
    fw_off
    ;;
  status)
    run /etc/init.d/lwmd status
    # état firewall utile pour debug
    run esxcli network firewall ruleset list | awk '$1=="lwmd"{print}'
    ;;
  *)
    log "DENIED cmd='${SSH_ORIGINAL_COMMAND}'"
    echo "DENIED. Allowed commands: start | stop | status" >&2
    exit 1
    ;;
esac

exit 0
