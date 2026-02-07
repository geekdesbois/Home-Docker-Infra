# Vaultwarden (dock01) — Portainer Git Stack

Ce stack est déployé via **Portainer (Git repository)**.
Le repo contient uniquement :
- `compose.yaml`
- `.env.example`
- `README.md`

✅ **Aucun secret dans Git**.

## Runtime secrets (host-only)

Sur dock01, créer :

`/etc/portainer-env/vaultwarden.env`

Permissions recommandées :

```bash
sudo mkdir -p /etc/portainer-env
sudo chmod 700 /etc/portainer-env
sudo chown root:root /etc/portainer-env

sudo chmod 600 /etc/portainer-env/vaultwarden.env
sudo chown root:root /etc/portainer-env/vaultwarden.env
