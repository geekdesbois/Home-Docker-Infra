Pour éviter un vidage non voulu si les points de montage de médias sont absents au démarrage de Plex.
Dans Plex WebUI -> Réglages -> Bibliothèque -> décocher "Vider la corbeille automatiquement après chaque scan"

Installation:

sudo apt install jq
sudo install -m 0755 plex-empty-trash.sh /usr/local/sbin/
sudo install -m 0644 plex-empty-trash.service plex-empty-trash.timer /etc/systemd/system/
sudo systemctl daemon-reload

# Premier essai sans rien supprimer
sudo DRY_RUN=1 /usr/local/sbin/plex-empty-trash.sh

# Si les chiffres sont cohérents avec la corbeille affichée dans Plex :
sudo systemctl enable --now plex-empty-trash.timer

