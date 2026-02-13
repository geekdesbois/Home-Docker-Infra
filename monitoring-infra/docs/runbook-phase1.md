```text
PHASE 1 - Monitoring Hub sur DOCK02-PWR (172.16.70.12)

Objectif critique :
- Alerte mail quand DOCK01 (172.16.70.11) est DOWN > 5 min
  => probable reboot + LVM/LUKS à déverrouiller au boot.

Déploiement (ordre recommandé)

1) Sur DOCK02-PWR : déployer le HUB
- Portainer -> Stack -> Git repo -> stack-monitoring/docker-compose.yml
- Définir variables:
  - GRAFANA_ADMIN_USER
  - GRAFANA_ADMIN_PASSWORD

2) Sur DOCK01 / DOCK02 / DOCK04 : node_exporter
- Déployer agents-linux/node-exporter-compose.yml
- Vérifier depuis DOCK02 : curl http://IP:9100/metrics

3) Promtail (optionnel mais conseillé)
- Sur chaque host, copier la bonne conf :
  - promtail-dock01.yml -> promtail.yml
  - promtail-dock02.yml -> promtail.yml
  - promtail-dock04.yml -> promtail.yml
- Déployer agents-linux/promtail-compose.yml
- Vérifier dans Grafana -> Explore -> Loki

Test alerte DOCK01
- Stopper node_exporter sur DOCK01 :
  docker stop node_exporter
- Attendre 5 minutes
- Vérifier réception mail : "[CRITIQUE] DOCK01 reboot/bloqué – unlock LVM requis"
- Relancer node_exporter :
  docker start node_exporter
- Vérifier mail "resolved"

Firewall minimal (SRV)
- Autoriser DOCK02 (172.16.70.12) -> DOCK01 (172.16.70.11) TCP 9100
- Autoriser DOCK01/DOCK04 -> DOCK02 TCP 3100 (si promtail utilisé)
- UI:
  - Grafana TCP 3000 (restreindre aux IP admin)
  - Uptime Kuma TCP 3001 (restreindre aux IP admin)
```
