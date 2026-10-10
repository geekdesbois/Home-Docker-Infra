Installation:

sudo install -m 0755 plex-watchdog.sh /usr/local/sbin/
sudo install -m 0644 plex-watchdog.service plex-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now plex-watchdog.timer

# Test immédiat + logs
sudo systemctl start plex-watchdog.service
journalctl -u plex-watchdog -n 30
systemctl list-timers plex-watchdog.timer


Ce que fait le script

Si le conteneur est running, le script s’arrête sans rien écrire, donc le journal n’est pas pollué toutes les 15 minutes.
S’il est exited, created ou dead, il note d’abord le code de sortie et l’erreur Docker du dernier arrêt. Il vérifie ensuite les périphériques NVIDIA : s’ils manquent, il tente de les créer avec nvidia-modprobe. Puis il lance docker start et vérifie 15 s plus tard que le conteneur tourne toujours.
Pour une maintenance, sudo touch /etc/plex-watchdog.disable met le watchdog en pause. Sinon il redémarrerait un Plex que tu as arrêté exprès.
Si /mnt/media est un montage réseau ou un disque séparé, renseigne REQUIRED_MOUNTS en haut du script. Plex ne démarrera alors pas avec des bibliothèques vides.