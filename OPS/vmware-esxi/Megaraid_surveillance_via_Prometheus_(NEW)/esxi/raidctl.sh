#!/bin/sh
# Restricted SSH controller : état RAID en LECTURE SEULE via storcli2
# Commande autorisée : status
# Appelé uniquement par la clé "raidstatus-esxi-fips" (forced command, IP DOCK01)

S="/opt/storcli2/bin/storcli2"
LOGTAG="raidstatus-ssh"
CMD="$(echo "${SSH_ORIGINAL_COMMAND:-}" | awk '{print $1}')"

case "$CMD" in
  status)
    # Les marqueurs ### délimitent les 3 sorties JSON pour le collecteur.
    # Le "echo" vide garantit qu'un marqueur commence une ligne
    # (storcli2 ne termine pas toujours sa sortie par un saut de ligne).
    echo "### C0"; "$S" /c0 show J
    echo; echo "### VD"; "$S" /c0/vall show all J
    echo; echo "### PD"; "$S" /c0/eall/sall show all J
    ;;
  *)
    logger -t "$LOGTAG" "DENIED cmd='${SSH_ORIGINAL_COMMAND}'"
    echo "DENIED. Allowed command: status" >&2
    exit 1
    ;;
esac
exit 0
