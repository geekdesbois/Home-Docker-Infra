#!/bin/sh
# script local to esxi, to put on datastore to be persistent
# Restricted SSH controller for LSA mail alert config JSON
# Allowed commands: check | restore | show

TARGET="/opt/lwmd/vital/config-current.json"
DIR="/opt/lwmd/vital"
LOGTAG="lwmdcfg-ssh"

CMD="$(echo "${SSH_ORIGINAL_COMMAND:-}" | awk '{print $1}')"

log() { logger -t "$LOGTAG" "$1"; }

hash_file() {
  f="$1"
  if [ ! -f "$f" ]; then
    echo "MISSING"
    return 0
  fi
  /bin/sha256sum "$f" | awk '{print $1}'
}

expected_to_tmp() {
  tmp="$1"
  umask 077
  cat > "$tmp" <<'JSONEOF'
{
  "alertConfiguration": {
    "properties": {
      "global": [
        { "severity": "INFO", "actions": ["systemlog","eventmessage"] },
        { "severity": "WARNING", "actions": ["systemlog","eventmessage"] },
        { "severity": "CRITICAL", "actions": ["systemlog","systemmessage","eventmessage"] },
        { "severity": "FATAL", "actions": ["email","systemlog","systemmessage","eventmessage"] },
        { "severity": "DEAD", "actions": ["email","systemlog","systemmessage","eventmessage"] },
        { "severity": "FAULT", "actions": ["email","systemlog","systemmessage","eventmessage"] }
      ],
      "actions": [
        {
          "authentication": { "type": "NONE" },
          "isActive": true,
          "useLegacy": false,
          "useSSL": false,
          "port": 25,
          "host": "blackbox.leahparnal.org",
          "name": "email",
          "protocol": "SMTP",
          "sender": "megaraid9560-8i@terre-du-milieu.org",
          "type": "EMAIL",
          "to": ["geekdesbois@zonelibre.live"]
        },
        { "isActive": true, "name": "systemlog", "type": "SYSTEMLOG" },
        { "isActive": true, "name": "systemmessage", "type": "SYSTEMMESSAGE" },
        { "isActive": true, "name": "eventmessage", "type": "EVENTMESSAGE" }
      ],
      "events": { "gen7": [], "gen8": [] }
    }
  }
}
JSONEOF
}

do_check() {
  tmp="/tmp/expected-config.$$"
  expected_to_tmp "$tmp"
  exp="$(hash_file "$tmp")"
  rm -f "$tmp" >/dev/null 2>&1 || true

  cur="$(hash_file "$TARGET")"

  if [ "$cur" = "$exp" ] && [ "$cur" != "MISSING" ]; then
    log "check: OK (sha=$cur)"
    echo "OK"
    exit 0
  fi

  log "check: MISMATCH (cur=$cur exp=$exp)"
  echo "MISMATCH cur=$cur exp=$exp"
  exit 2
}

do_restore() {
  mkdir -p "$DIR" >/dev/null 2>&1 || true

  if [ -f "$TARGET" ]; then
    cp -p "$TARGET" "${TARGET}.bak.$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
  fi

  tmp="/tmp/config-current.json.$$"
  expected_to_tmp "$tmp"
  mv -f "$tmp" "$TARGET" || exit 1

  log "restore: DONE"
  echo "RESTORED"
  exit 0
}

case "$CMD" in
  check)   do_check ;;
  restore) do_restore ;;
  show)    cat "$TARGET" ;;
  *)
    log "DENIED cmd='${SSH_ORIGINAL_COMMAND}'"
    echo "DENIED. Allowed commands: check | restore | show" >&2
    exit 1
    ;;
esac
