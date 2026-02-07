# Diun – Docker image update notifier

Déployé via Portainer Git Stack (1 stack par host).

## Runtime local (non versionné)

Sur chaque hôte :

/docker/diun/
  diun.yml
  db/diun.db


## Bootstrap

mkdir -p /docker/diun/db
cp diun.yml.example /docker/diun/diun.yml
nano /docker/diun/diun.yml

## Vérifier

docker logs -f diun

## Rollback

docker compose up -d depuis un compose local si Portainer down
