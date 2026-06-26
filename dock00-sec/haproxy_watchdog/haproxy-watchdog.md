# HAProxy Watchdog

## Contexte

Sur l'hôte Debian 13 hébergeant la stack `dock00-sec`, les **unattended-upgrades** déclenchent des redémarrages automatiques. Après reboot, le conteneur `haproxy` se retrouve régulièrement en **exit code 128** (race condition : Docker démarre haproxy avant que le réseau ou `syslog` soit prêt, les échecs consécutifs épuisent la politique `restart: unless-stopped`).

La stack est gérée par **Portainer** depuis le dépôt Git — le fichier `compose.yml` n'est pas présent en local sur l'hôte.

## Solution

Un watchdog systemd (service + timer) qui :

1. Vérifie toutes les **5 minutes** que le conteneur `haproxy` est en état `running`
2. Si non, attend que `syslog` soit prêt (dépendance `depends_on` du compose)
3. Relance via `docker start haproxy` — le conteneur existe déjà, Portainer l'a créé avec toute sa configuration

Le `OnBootSec=2min` couvre la race condition principale : Docker démarre haproxy trop tôt, il échoue, et le watchdog le relance proprement 2 minutes après le boot quand tout est stable.

## Fichiers

| Fichier | Destination sur l'hôte |
| --- | --- |
| `haproxy-watchdog.sh` | `/usr/local/sbin/haproxy-watchdog.sh` |
| `haproxy-watchdog.service` | `/etc/systemd/system/haproxy-watchdog.service` |
| `haproxy-watchdog.timer` | `/etc/systemd/system/haproxy-watchdog.timer` |

## Déploiement

```bash
# Copier les fichiers
sudo cp haproxy-watchdog.sh /usr/local/sbin/
sudo chmod 750 /usr/local/sbin/haproxy-watchdog.sh
sudo cp haproxy-watchdog.service haproxy-watchdog.timer /etc/systemd/system/

# Activer et démarrer le timer
sudo systemctl daemon-reload
sudo systemctl enable --now haproxy-watchdog.timer
```

## Vérification

```bash
# État du timer
sudo systemctl list-timers haproxy-watchdog.timer

# Logs du watchdog
sudo journalctl -t haproxy-watchdog -n 30

# Test manuel (stopper haproxy puis déclencher le watchdog)
sudo docker stop haproxy
sudo systemctl start haproxy-watchdog.service
sudo journalctl -t haproxy-watchdog -n 10
```
