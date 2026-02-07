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
