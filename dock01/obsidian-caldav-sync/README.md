# Obsidian → CalDAV Sync (dock01)

Déploiement via Portainer Git Stack.
L’image est buildée/pushée via le repo applicatif (GHCR).

## Secrets / config runtime (host-only)

Créer sur dock01 :

`/etc/portainer-env/obsidian-caldav.env`

Permissions :
```bash
sudo chmod 600 /etc/portainer-env/obsidian-caldav.env
sudo chown root:root /etc/portainer-env/obsidian-caldav.env
