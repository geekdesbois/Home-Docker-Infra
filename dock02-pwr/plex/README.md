# Plex (dock02-pwr)

Plex Media Server déployé via Docker + Portainer Git Stack.

## Spécificités de cette stack

- Mode réseau : `host` (meilleure découverte LAN / DLNA)
- GPU NVIDIA partagé (Tesla A2)
- DIUN activé (notifications image)
- Healthcheck intégré
- Données persistées via bind mounts

## Dossiers persistants

| Chemin hôte | Rôle |
|-----------|-------|
| /srv/plex/config | Config + DB Plex |
| /srv/plex/transcode | Cache transcode |
| /mnt/media/* | Médias |

Seul **/config** contient des données critiques.

Les médias sont déjà protégés par la stratégie de backup globale.

---

## GPU (standalone Docker)

Cette stack ne repose PAS sur `deploy:` (Swarm only).

Le GPU fonctionne via :

- nvidia-container-toolkit côté hôte
- variables :
  - NVIDIA_VISIBLE_DEVICES
  - NVIDIA_DRIVER_CAPABILITIES

Test :

```bash
docker exec plex nvidia-smi
```

---

## Healthcheck

```bash
curl http://127.0.0.1:32400/identity
```

Permet de détecter :

- freeze Plex
- crash webserver
- blocage GPU

Note : Docker ne redémarre pas automatiquement un conteneur unhealthy.
Ajouter autoheal uniquement si nécessaire.

---

## Backup strategy (recommandé)

L’hôte est déjà sauvegardé par Veeam (image-level).

On protège uniquement la DB Plex pour garantir la cohérence.

### Dump froid journalier (rapide)

Script :

```bash
/usr/local/bin/plex-db-dump.sh
```

Cron exemple :

```cron
30 3 * * * /usr/local/bin/plex-db-dump.sh
```

Le dump sera inclus automatiquement dans les sauvegardes Veeam.

---

## Restore DB uniquement

```bash
docker stop plex

tar -xzf plex_db_dump_xxx.tgz -C /srv/plex/config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases

docker start plex
```

---

## Variables runtime

Voir :

```
/etc/portainer-env/plex.env
```

Jamais commit dans Git.

## Fine Tuning service Docker pour attendre points de montage des medias via le réseau et le gpu Nvidia
sudo systemctl edit docker.service

ajouter en haut du fichier:

[Unit]
WantsMountsFor=/mnt/media/videoblackbox /mnt/media/videopriveblackbox /mnt/media/musicblackbox /mnt/media/ebooksblackbox

[Service]
# Crée les fichiers /dev/nvidia* avant que Docker ne relance les conteneurs
ExecStartPre=-/usr/bin/nvidia-modprobe -u -c 0
ExecStartPre=-/usr/bin/nvidia-modprobe -m
ExecStartPre=-/usr/bin/nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml
