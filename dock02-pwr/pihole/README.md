# Pi-hole (dock02-pwr)

DNS sinkhole local pour l’infrastructure.

Déployé via Docker + Portainer Git Stack.

## Ports exposés

| Port | Usage |
|-------|----------------|
| 53 TCP/UDP | DNS |
| 8001 | Web HTTP |
| 8003 | Web HTTPS |

---

## Données persistantes

| Chemin hôte | Rôle |
|-----------|------|
| /docker/pihole/etc-pihole | config + gravity.db |
| /docker/pihole/etc-dnsmasq.d | règles DNS |

Ces deux dossiers suffisent pour un restore complet.

---

## Password UI

Option 1 (recommandé)
```bash
docker exec -it pihole pihole setpassword 'xxxx'
```

Option 2 (automatique)
```
FTLCONF_webserver_api_password=xxxx
```
dans `/etc/portainer-env/pihole.env`

---

## Backup strategy

Aucun script spécifique requis.

Pourquoi :
- Pi-hole écrit peu
- SQLite safe
- Hôte sauvegardé quotidiennement par Veeam

Les bind mounts sont donc déjà protégés.

---

## Restore

```bash
docker stop pihole
restore dossiers etc-pihole + etc-dnsmasq.d
docker start pihole
```

---

## Variables runtime

Voir :

```
/etc/portainer-env/pihole.env
```
