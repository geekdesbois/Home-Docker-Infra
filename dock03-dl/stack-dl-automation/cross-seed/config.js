module.exports = {
  // Connexion qBittorrent
  torrentClients: [
    "qbittorrent:http://127.0.0.1:8888"
  ],
  // Prowlarr (l'api key est celle de prowlarr, pas des trackers)
  torznab: [
    "http://127.0.0.1:9696/1/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx",  // C411
    "http://127.0.0.1:9696/15/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // G3MINI
    "http://127.0.0.1:9696/14/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // Nostradamus
    "http://127.0.0.1:9696/17/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // YGGreborn
    "http://127.0.0.1:9696/18/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // TR4KER
//  "http://127.0.0.1:9696/19/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // Les Rescapés
    "http://127.0.0.1:9696/20/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // CrazySpirits
    "http://127.0.0.1:9696/21/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // Memphis
    "http://127.0.0.1:9696/22/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // Draupnir
    "http://127.0.0.1:9696/23/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // V3X
    "http://127.0.0.1:9696/24/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // AstraTorrent
    "http://127.0.0.1:9696/25/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // TeamFlix

  ],

  // Dossiers
  dataDirs: ["/data/downloads"],
  torrentDir: "/qbt-config/qBittorrent/BT_backup",

  // Mode sécurisé
  action: "inject",   // inject direct dans qB
  linkCategory: "cross-seed",

  // IMPORTANT pour toi (private trackers)
  includeSingleEpisodes: false,
  includeNonVideos: false,

  // éviter les erreurs
  matchMode: "strict",

  // limite pour pas spam
  maxRequests: 3,

  // délai entre scans
  delay: 60,

  flatLinking: false,
  skipRecheck: false,

  // logs
  logLevel: "info"
};
