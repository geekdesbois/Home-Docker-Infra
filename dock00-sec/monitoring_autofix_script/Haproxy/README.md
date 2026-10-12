Installation:
apt install curl                      # si absent (pour la sonde HTTP)
install -m 0755 haproxy-watchdog.sh      /usr/local/sbin/
install -m 0644 haproxy-watchdog.service haproxy-watchdog.timer /etc/systemd/system/
install -m 0644 haproxy-watchdog.default /etc/default/haproxy-watchdog
systemctl daemon-reload
systemctl enable --now haproxy-watchdog.timer

Test:
docker stop haproxy
sleep 65 && systemctl start haproxy-watchdog.service   # 60 s de grâce après un arrêt
journalctl -u haproxy-watchdog -n 20

Comportement
Toutes les 2 min, et 3 min après le boot.
Ne fait rien pendant un unattended-upgrade ou un apt/dpkg en cours, ni si docker.service est inactif (dans ce cas il alerte).
Arrêté depuis moins de 60 s : il attend, pour ne pas interférer avec un redeploy Portainer.
Anti-boucle : 3 relances maximum par fenêtre de 30 min, puis abandon et une alerte.
Pause pour maintenance : touch /etc/haproxy-watchdog.pause, et tu supprimes le fichier ensuite.
Diagnostic : chaque relance logue ExitCode, State.Error et l’heure d’arrêt. Ça devrait révéler la vraie cause après les upgrades.
Mails (optionnels) : renseigne MAIL_TO dans /etc/default/haproxy-watchdog, avec apt install dma configuré sur ton Synology en smarthost. Chaque mail contient les 40 dernières lignes de docker logs.

Pour surveiller aussi CrowdSec et syslog, mets CONTAINERS="haproxy crowdsec syslog" dans le fichier /etc/default/haproxy-watchdog. Ils n’ont pas de healthcheck, donc seul l’état running/exited compte pour eux.