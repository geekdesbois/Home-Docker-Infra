# 📘 Runbook – Gestion planifiée du service lwmd (ESXi 8)


---

## Objectif

Réduire la consommation CPU excessive du service **lwmd (LSI Storage Authority)** sur un hôte **ESXi 8**, en :

- laissant le service arrêté par défaut
    
- le démarrant automatiquement une fois par semaine
    
- le laissant tourner 15 minutes
    
- puis l’arrêtant automatiquement
    
- via une VM Debian
    
- avec un accès SSH sécurisé et restreint
    

---

## Contexte technique

- Hyperviseur : ESXi 8.0.3
    
- Contrôleur RAID : MegaRAID 9560-8i
    
- Service : lwmd (LSI Storage Authority)
    
- Problème : consommation CPU ~100 % d’un core
    
- Contrainte : ESXi en mode FIPS
    

---

## Architecture retenue

- Aucun cron sur ESXi
    
- Pilotage distant depuis une VM Debian
    
- SSH par clé RSA
    
- Clé ultra-restreinte (forced-command)
    
- Aucun shell root accessible
    

---

## Principe de sécurité

- Clé SSH dédiée, sans passphrase
    
- Autorise uniquement :
    
    - start
        
    - stop
        
    - status
        
- Toute autre commande est refusée
    
- Accès limité à l’IP de la VM Debian
    
- Aucune possibilité de shell ou forwarding
    

---

## Configuration ESXi

### Script de contrôle lwmd

Chemin :
```
	/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdctl.sh
```

Contenu :
```bash
#!/bin/sh
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
```

Permissions :
```
chmod 755 /vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdctl.sh
```
---

### Clé SSH restreinte (ESXi)

Fichier :
```
/etc/ssh/keys-root/authorized_keys
```
Contenu (une seule ligne) :
```
from="172.16.70.11",command="/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/lwmdctl.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-rsa AAAA... lwmd-control-esxi-fips
```
Permissions :
```
chmod 600 /etc/ssh/keys-root/authorized_keys
```
Persistance ESXi :
```
/sbin/auto-backup.sh
```
---

## Configuration Debian (VM de pilotage)

### Clé SSH

- Type : RSA 4096 bits
    
- Sans passphrase
    
- Usage exclusif : pilotage lwmd
    

Chemins :
```
/root/.ssh/esxi_lwmd_rsa
/root/.ssh/esxi_lwmd_rsa.pub
```
## Génération de la paire de clés SSH **RSA 4096** (Debian)

À exécuter sur la VM Debian (en root) :
```bash
ssh-keygen -t rsa -b 4096 -o -a 64 \
-f /root/.ssh/esxi_lwmd_rsa \
-C "lwmd-control-esxi-fips"
```

### Détails

- `-t rsa` : clé RSA (compatible FIPS)
    
- `-b 4096` : taille de clé
    
- `-o` : format OpenSSH moderne
    
- `-a 64` : KDF renforcé (même sans passphrase)
    
- `-f` : chemin de la clé privée
    
- `-C` : commentaire (facultatif, utile pour l’identification)
    

➡️ Fichiers générés :

- Clé privée :
 ```   
/root/.ssh/esxi_lwmd_rsa
```

- Clé publique :
```    
/root/.ssh/esxi_lwmd_rsa.pub
```
---

### Script de pilotage hebdomadaire

Chemin :
```
/usr/local/sbin/lwmd-weekly.sh
```
Contenu :
```bash
#!/bin/bash
set -euo pipefail

SSH="ssh -i /root/.ssh/esxi_lwmd_rsa -o IdentitiesOnly=yes root@172.16.70.8"

echo "[$(date)] lwmd start"
$SSH start

sleep 900

echo "[$(date)] lwmd stop"
$SSH stop
```

Permissions :
```
chmod +x /usr/local/sbin/lwmd-weekly.sh
```
---

### Planification cron

Crontab root :
```
crontab -e
```
```
0 0 * * 0 /usr/local/sbin/lwmd-weekly.sh >> /var/log/lwmd-weekly.log 2>&1
```

- Exécution : dimanche à 00:00
    
- Durée : 15 minutes
    
- Logs : /var/log/lwmd-weekly.log
    

---

## Vérifications

Test fonctionnel :
```bash
ssh -i /root/.ssh/esxi_lwmd_rsa root@ESXI_IP start
ssh -i /root/.ssh/esxi_lwmd_rsa root@ESXI_IP stop
```
Test sécurité :
```
ssh -i /root/.ssh/esxi_lwmd_rsa root@ESXI_IP "ls"
```
Résultat attendu :

- Commande refusée
    
- Aucun shell
    

---

## Résultat final

- lwmd arrêté 99,9 % du temps
    
- CPU ESXi libéré
    
- Alertes LSI toujours actives
    
- Automatisation sécurisée, traçable
    
- Compatible FIPS / production
    

---

## Notes

Toute modification côté ESXi doit être suivie de :
```
/sbin/auto-backup.sh
```