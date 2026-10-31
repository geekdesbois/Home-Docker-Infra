# 📘 Runbook – Persistance & supervision LSI Storage Authority (lwmd)

## 🎯 Objectif

Assurer la **persistance et la conformité** de la configuration des alertes mail de **Broadcom LSI Storage Authority** (`lwmd`) sur **ESXi 8**, malgré :

- la perte de configuration après reboot ESXi
    
- la consommation CPU excessive du service `lwmd`
    
- l’absence de mécanisme natif fiable de persistance
    

La solution repose sur :

- un **pilotage distant sécurisé** depuis une VM Debian
    
- des **scripts SSH ultra-restreints** côté ESXi
    
- des **vérifications périodiques + remédiation automatique**
    

---

## 🧱 Architecture retenue

- **ESXi**
    
    - héberge le contrôleur RAID + LSI Storage Authority
        
    - expose des wrappers SSH _forced-command_
        
    - n’exécute **aucune tâche planifiée**
        
- **VM Debian**
    
    - détient les clés SSH
        
    - exécute les scripts de contrôle
        
    - planifie via `cron`
        

---

## 🔐 Sécurité – principes clés

- Authentification SSH **par clés uniquement**
    
- 2 clés distinctes :
    
    - `lwmd` → start / stop / status
        
    - `lwmdcfg` → check / restore / show (config mail)
        
- Accès SSH :
    
    - **sans shell**
        
    - **sans forwarding**
        
    - **sans PTY**
        
    - **IP source restreinte**
        
- Aucun accès root interactif possible
    

---

# 🖥️ Partie ESXi

## 1️⃣ Script de gestion du service `lwmd`

### Chemin
```bash
/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdctl.sh
```
### Rôle

- Démarrer / arrêter `lwmd`
    
- Consulter son état
    
- Réduire la consommation CPU hors fenêtre de maintenance
    

_(script déjà documenté précédemment, non détaillé ici)_

---

## 2️⃣ Script de gestion de la configuration mail LSA

### Chemin
```bash
/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdcfgctl.sh
```
### Rôle

- Vérifier que le fichier :
    
```bash
/opt/lwmd/vital/config-current.json
``` 
    correspond **exactement** à la configuration attendue
    
- Restaurer automatiquement la configuration si divergence
    
- Fonctionnement par **comparaison SHA256 stricte**
    

### Commandes autorisées

- `check` → compare le hash actuel vs attendu
    
- `restore` → réécrit le fichier attendu (avec backup)
    
- `show` → affiche le fichier courant
    

### Script complet (version clean)

```bash
#!/bin/sh
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
          "sender": "megaraid9660-16i@terre-du-milieu.org",
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
```

### Permissions & persistance
```bash
chmod 755 /vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdcfgctl.sh
/sbin/auto-backup.sh
```
---

## 3️⃣ Clés SSH restreintes ESXi

### Fichier
```
/etc/ssh/keys-root/authorized_keys
```

### Ligne dédiée config mail
```
from="172.16.70.11",command="/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdcfgctl.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-rsa AAAA... lwmdcfg-control-esxi-fips
```

---

# 🐧 Partie Debian (VM de pilotage)

## 1️⃣ Génération de la clé SSH dédiée
```bash
ssh-keygen -t rsa -b 4096 -o -a 64 \
  -f /root/.ssh/esxi_lwmd_cfg_rsa \
  -C "lwmdcfg-control-esxi-fips"
```

---

## 2️⃣ Script de vérification / remédiation

### Chemin
```
/usr/local/sbin/lwmd-mailcfg-ensure.sh
```

### Script
```bash
#!/bin/bash
set -euo pipefail

ESXI_IP="172.16.70.8"
SSH_ID="/root/.ssh/esxi_lwmd_cfg_rsa"
SSH_OPTS=(-i "$SSH_ID" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10)

log() { echo "[$(date -Is)] $*"; }

set +e
OUT="$(ssh "${SSH_OPTS[@]}" root@"$ESXI_IP" check 2>&1)"
RC=$?
set -e

if [ $RC -eq 0 ] && [[ "$OUT" == "OK" ]]; then
  log "OK: config-current.json conforme"
  exit 0
fi

log "MISMATCH/ERROR: rc=$RC out=$OUT"
log "Restoring expected config..."

ssh "${SSH_OPTS[@]}" root@"$ESXI_IP" restore >/dev/null 2>&1 || {
  log "ERROR: restore failed"
  exit 1
}

OUT2="$(ssh "${SSH_OPTS[@]}" root@"$ESXI_IP" check 2>&1 || true)"
log "Post-restore check: $OUT2"
```

### Permissions
```
chmod +x /usr/local/sbin/lwmd-mailcfg-ensure.sh
```

---

## 3️⃣ Planification cron

### Crontab root (recommandé)
```bash
@reboot sleep 120 && /usr/local/sbin/lwmd-mailcfg-ensure.sh >> /var/log/lwmd-mailcfg-ensure.log 2>&1
5 3 * * * /usr/local/sbin/lwmd-mailcfg-ensure.sh >> /var/log/lwmd-mailcfg-ensure.log 2>&1
```
- ✔️ correction automatique après reboot ESXi
    
- ✔️ vérification quotidienne
    
- ✔️ journalisation complète
    

---

## ✅ Résultat final

- Configuration mail **toujours conforme**
    
- Détection stricte de toute dérive (commentaire, IP SMTP, etc.)
    
- Remédiation automatique
    
- Sécurité maximale (no shell, no exec arbitraire)
    
- Solution robuste, traçable, production-ready
