# Surveillance RAID MegaRAID 9660-16i → Prometheus

```
superesxi8 (ESXi)                 DOCK01 (172.16.70.11)                     dock02-pwr
storcli2, lecture seule   ◄─SSH── megaraid-textfile.py (timer 2 min)  ◄──  Prometheus (job dock01)
raidctl.sh (forced cmd)           → /var/lib/node_exporter/textfile/        → alertes + Grafana
```

## 1. ESXi : le wrapper

```sh
D=/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts
# copier esxi/raidctl.sh dans $D (scp depuis ton poste), puis :
chmod 755 $D/raidctl.sh
SSH_ORIGINAL_COMMAND=status sh $D/raidctl.sh | grep '###'   # doit afficher ### C0, ### VD, ### PD
```

## 2. DOCK01 : clé dédiée (RSA 4096, comme les autres, pour le mode FIPS)

```bash
ssh-keygen -t rsa -b 4096 -o -a 64 -N "" -f /root/.ssh/esxi_raidstatus_rsa -C "raidstatus-esxi-fips"
cat /root/.ssh/esxi_raidstatus_rsa.pub
```

Sur l'ESXi, ajouter **une ligne** à `/etc/ssh/keys-root/authorized_keys` :

```
from="172.16.70.11",command="/vmfs/volumes/699036ed-669767af-f4fb-7cc2554e5d1a/ssh-scripts/raidctl.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-rsa AAAA...(clé publique)... raidstatus-esxi-fips
```

puis `/sbin/auto-backup.sh` pour la persistance.

Tests depuis DOCK01 :

```bash
K="ssh -i /root/.ssh/esxi_raidstatus_rsa -o IdentitiesOnly=yes root@172.16.70.8"
$K status | grep '###'     # ### C0 / ### VD / ### PD
$K ls                      # doit répondre DENIED
```

## 3. DOCK01 : collecteur

À lancer depuis le dossier où l'archive a été extraite (les chemins `dock01/...` sont relatifs).

```bash
python3 --version || apt install -y python3
install -m 700 dock01/megaraid-textfile.py /usr/local/sbin/megaraid-textfile.py
mkdir -p /var/lib/node_exporter/textfile
/usr/local/sbin/megaraid-textfile.py && head -3 /var/lib/node_exporter/textfile/megaraid.prom
cat /var/lib/node_exporter/textfile/megaraid_collector.prom   # megaraid_collector_success 1

install -m 644 dock01/megaraid-textfile.service dock01/megaraid-textfile.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now megaraid-textfile.timer
systemctl list-timers megaraid-textfile.timer
```

## 4. DOCK01 : node_exporter lit le dossier

La racine de DOCK01 est déjà montée en `/host` : une seule option à ajouter, pas de volume.

```yaml
services:
  node_exporter:
    image: prom/node-exporter:v1.8.2
    pid: host
    command:
      - "--path.rootfs=/host"
      - "--collector.textfile.directory=/host/var/lib/node_exporter/textfile"
    ports:
      - "9100:9100"
    volumes:
      - "/:/host:ro,rslave"
    restart: unless-stopped
```

Vérifier : `curl -s http://172.16.70.11:9100/metrics | grep -c '^megaraid_'` → 103
(9 disques, 2 volumes). Si 0 : regarder `node_textfile_scrape_error` (1 = fichier illisible).

## 5. dock02 : alertes et dashboard

```bash
cp prometheus/megaraid.yml /docker/monitoring/prometheus/rules/
docker kill -s HUP prometheus
cp grafana/esxi-raid-megaraid.json /docker/monitoring/grafana/provisioning/dashboards/json/Virtualisation/
```

## 6. Une fois validé : retirer l'ancien dispositif LSA

Sur DOCK01, commenter dans `crontab -e` :
- `lwmd-weekly.sh` (démarrage hebdomadaire de LSA)
- `lwmd-mailcfg-ensure.sh` (persistance de la config mail)

Laisser lwmd arrêté : `ssh -i /root/.ssh/esxi_lwmd_rsa root@172.16.70.8 stop`.
Garder la clé `lwmd` pour lancer l'interface LSA à la demande ; la clé `lwmdcfg` et son
script peuvent être supprimés (puis `/sbin/auto-backup.sh`).
