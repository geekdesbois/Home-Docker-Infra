module.exports = {
  // Connexion qBittorrent
  qbittorrentUrl: "http://127.0.0.1:8888",
//qbittorrentUsername: "admin",     (auth bypass on localhost enabled on qBittorrent)
//qbittorrentPassword: "TON_PASSWORD",     (auth bypass on localhost enabled on qBittorrent)

  // Prowlarr (l'api key est celle de prowlarr, pas des trackers)
  torznab: [
    "http://127.0.0.1:9696/1/api?apikey=XXX"
    "http://127.0.0.1:9696/15/api?apikey=XXX"
    "http://127.0.0.1:9696/14/api?apikey=XXX"
    "http://127.0.0.1:9696/2/api?apikey=XXX"
],

  // Dossiers
  dataDirs: ["/data"],

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
  delay: 30,

  // logs
  logLevel: "info"
};