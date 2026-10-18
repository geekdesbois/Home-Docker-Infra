module.exports = {
  apiKey: undefined,

  torznab: [
    "http://127.0.0.1:9696/1/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx",  // C411
    "http://127.0.0.1:9696/15/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // G3MINI
//  "http://127.0.0.1:9696/14/api?apikey=xxxxxxxxxxxxxxxxxxxxxxxxx", // Nostradamus
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

  // Recherche par ID (IP LAN de l'hôte Docker + clé API de chaque *arr)
  sonarr: ["http://172.16.40.10:8989/?apikey=xxxxxxxxxxxxxxxxxxxxxxxxxx"],
  radarr: ["http://172.16.40.10:7878/?apikey=xxxxxxxxxxxxxxxxxxxxxxxxxx"],

  host: "0.0.0.0",
  port: 2468,
  notificationWebhookUrls: [],

  torrentClients: ["qbittorrent:http://127.0.0.1:8888"],

  // Source des torrents : API qBit (remplace BT_backup)
  useClientTorrents: true,
  torrentDir: null,
  dataDirs: [],
  maxDataDepth: 2,
  outputDir: null,

  // Linking
  linkDirs: ["/data/cross-seed-links"],
  linkType: "hardlink",
  linkCategory: "cross-seed-link",
  flatLinking: false,
  duplicateCategories: false,

  // Matching
  matchMode: "partial",
  skipRecheck: true,
  autoResumeMaxDownload: 52428800,   // 50 Mio max à compléter pour relance auto
  ignoreNonRelevantFilesToResume: false,
  seasonFromEpisodes: 1,             // assemble tes épisodes en saison complète si tu as 100 %
  fuzzySizeThreshold: 0.02,
  includeSingleEpisodes: false,
  includeNonVideos: false,
  blockList: [],

  // Charge sur les trackers
  delay: 60,
  searchLimit: 200,
  excludeOlder: "30 weeks",
  excludeRecentSearch: "3 days",
  rssCadence: "30 minutes",
  searchCadence: "1 day",
  snatchTimeout: "30 seconds",
  searchTimeout: "2 minutes",

  action: "inject",
};