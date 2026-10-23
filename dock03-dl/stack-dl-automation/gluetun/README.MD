KEY=$(docker run --rm qmcgaw/gluetun:v3.41.3 genkey)
install -d -m 700 /etc/dl-reconcile && printf '%s' "$KEY" > /etc/dl-reconcile/gluetun.apikey && chmod 600 /etc/dl-reconcile/gluetun.apikey
install -d /docker/gluetun/auth && sed "s/KJJoMJQtJEjZ8JhTVmik78/" config.toml > /docker/gluetun/auth/config.toml
install -m 750 dl-pf-reconcile.sh /usr/local/sbin/
cp dl-pf-reconcile.{service,timer} /etc/systemd/system/
# redéployer la stack (Portainer), puis :
systemctl daemon-reload && systemctl enable --now dl-pf-reconcile.timer
# désactiver l'ancien cron restart-dl-stack-if-unhealthy.sh et supprimer reset_qbt_port.sh
journalctl -t dl-reconcile -f