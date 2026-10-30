# Sécurité périmétrique — HAProxy 3.4 + CrowdSec (WAF + bouncers)

> Infra @home — hôte `dock00-sec` (Debian 13), stack Portainer **DMZ** (réseau Docker `dmz-wan`, 172.31.90.0/24) + firewall **OPNsense** `CERBERE`
> État au **30/10/2026** — WAF **phase 1** en production, bouncer OPNsense **réellement actif** depuis le 30/10

---

## 1. Vue d'ensemble

```
Internet
   │
   ▼
OPNsense (CERBERE)
   ├─ règle "CrowdSec blocklist" (séq. 1, WAN01_FC / WAN02_5G / WAN03_DSL) : bans CrowdSec au niveau paquet
   ├─ géoblocage (séq. 51) + table SCANNERS (séq. 101)
   ├─ serveur WireGuard (172.16.111.0/24)
   │  NAT 443
   ▼
dock00-sec ─ stack DMZ (dmz-wan 172.31.90.0/24)
   ├─ haproxy        172.31.90.11  :80 :443 :8404 (stats + /metrics)
   │     │  SPOE (tcp/9000)
   │     ▼
   ├─ crowdsec-spoa  172.31.90.12  :9000 (interne)       bans dans HAProxy + relais WAF
   │     │  HTTP (7422)
   │     ▼
   ├─ crowdsec       LAPI :8080 (publiée 8888), métriques :6060, AppSec :7422 (interne)
   └─ syslog         172.31.90.10  :514                  → /docker/syslog/log/haproxy.log (lu par CrowdSec)

Supervision (dock02-pwr, 172.16.70.12) : Prometheus, Grafana, Loki (:3100), Alertmanager
```

### Couches de protection (ordre de traitement)

| # | Couche | Où | Effet |
|---|---|---|---|
| 1 | Bans CrowdSec | OPNsense, WAN, séq. 1 | IP bannies (scénarios locaux + blocklist communautaire, ~15 500 IP) bloquées avant tout |
| 2 | Géoblocage, table `SCANNERS` | OPNsense | Pays hors liste / scanners refusés |
| 3 | `strict-sni` + wildcard | HAProxy | Pas de réponse TLS sans SNI valide |
| 4 | Hosts internes | HAProxy (ACL) | `hosts_internal.lst` réservés LAN / serveurs / WireGuard |
| 5 | `/admin` Vaultwarden | HAProxy (ACL) | Bloqué hors réseaux de confiance |
| 6 | Bans CrowdSec | HAProxy (bouncer SPOA) | Mêmes décisions, appliquées à **toute** IP passant par HAProxy |
| 7 | WAF AppSec | CrowdSec via SPOA | Virtual patching + règles génériques en **blocage** (in-band) |
| 8 | En-têtes de sécurité | HAProxy | HSTS, X-Frame-Options, nosniff, Referrer-Policy |
| 9 | `default_backend BE_DENY_ALL` | HAProxy | Host inconnu → 403 |

### Services exposés directement (hors HAProxy)

Protégés par les couches 1 et 2 uniquement (pas de WAF ni de bouncer SPOA) :

| Service | Port | Remarque |
|---|---|---|
| Plex (dock02) | P_Plex | Exception géoblocage pour les serveurs de vérification Plex |
| SFTP Synology | P_SFTP_Syno | Source `GEO_ALLOWED` |
| Synology Drive client | 6690 | Source `GEO_ALLOWED` |
| WireGuard (OPNsense) | 51822/udp | — |

### Comportement selon la source

| Source | Requête malveillante | Ban | Mail | Loki |
|---|---|---|---|---|
| Internet | Bloquée par AppSec (403) | Oui, via scénarios : 12 h ×n (générique), 24 h ×n (`http-*`) — appliqué par OPNsense **et** HAProxy | Oui (bans) | Oui (tout) |
| LAN / serveurs / WireGuard | Bloquée par AppSec (403) | **Jamais** (exclusion des plages privées dans les profils + parser `whitelists`) | Oui, à chaque détection | Oui |
| Blocklist communautaire | — | Oui, via les deux bouncers | Non | Non |

> Une alerte WAF isolée a `Remediation: false` : la remédiation, c'est le blocage de la requête. Les bans viennent des **scénarios** (ex. `crowdsecurity/appsec-vpatch`) quand une IP accumule les détections.

---

## 2. Versions

| Composant | Version |
|---|---|
| HAProxy | `haproxy:3.4.7` |
| syslog-ng | `balabit/syslog-ng:4.11.0` (`@version: 4.11`) |
| CrowdSec | `crowdsecurity/crowdsec:v1.8.1` |
| Bouncer SPOA | `crowdsecurity/spoa-bouncer:v0.3.1` |
| Bouncer OPNsense | paquet FreeBSD `crowdsec-firewall-bouncer` v0.0.38 (bouncer `opnsense-fw@172.16.90.254`) |

> Les tags Docker CrowdSec prennent un **`v`** (`v1.8.1`, `v0.3.1`).

---

## 3. Arborescence des fichiers

| Hôte | Monté dans | Contenu |
|---|---|---|
| `/docker/haproxy/` | `/usr/local/etc/haproxy` (**ro, dossier entier**) | `haproxy.cfg`, `crowdsec.cfg`, `crt-list.txt`, `certs/`, `hosts_*.lst` |
| `/docker/crowdsec/config/` | `/etc/crowdsec` | `config.yaml`, `profiles.yaml`, `acquis.d/appsec.yaml`, `notifications/email.yaml`, `notifications/http_loki.yaml` |
| `/docker/crowdsec/config/acquis.yaml` | `/etc/crowdsec/acquis.yaml` (ro) | Acquisition de `/var/log/haproxy.log` |
| `/docker/crowdsec/data/` | `/var/lib/crowdsec/data` | Base CrowdSec |
| `/docker/crowdsec-spoa/crowdsec-spoa-bouncer.yaml` | `/etc/crowdsec/bouncers/…` (ro) | Config bouncer SPOA — **clé API, hors Git** (dossier `700`, fichier `644`) |
| `/docker/syslog/syslog-ng.conf` | `/etc/syslog-ng/syslog-ng.conf` (ro) | Config syslog-ng |
| `/docker/syslog/log/` | `/var/log` | `haproxy.log` |
| OPNsense `/usr/local/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` | — | Config bouncer firewall — **à sauvegarder** (hors sauvegarde de config OPNsense) |

> **Piège Docker** : un montage *fichier* d'un fichier inexistant crée un **dossier** ; une édition par `sed -i` (nouvel inode) n'est pas vue avant recréation du conteneur. D'où le montage du **dossier entier** pour HAProxy.

---

## 4. Configuration

### 4.1 Compose (extraits)

```yaml
  syslog:
    image: balabit/syslog-ng:4.11.0
    networks:
      dmzsec:
        ipv4_address: 172.31.90.10
    ports: ["514:514/udp", "514:514/tcp"]
    volumes:
      - /docker/syslog/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro
      - /docker/syslog/log:/var/log

  haproxy:
    image: haproxy:3.4.7
    restart: always
    stop_grace_period: 30s
    depends_on: [syslog, crowdsec-spoa]
    networks:
      dmzsec:
        ipv4_address: 172.31.90.11
    ports: ["80:80/tcp", "443:443/tcp", "8404:8404/tcp"]
    volumes:
      - /docker/haproxy:/usr/local/etc/haproxy:ro
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8404 && printf 'GET /healthz HTTP/1.0\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

  crowdsec:
    image: crowdsecurity/crowdsec:v1.8.1
    environment:
      - COLLECTIONS=crowdsecurity/haproxy crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules
    volumes:
      - /docker/crowdsec/data:/var/lib/crowdsec/data
      - /docker/crowdsec/config:/etc/crowdsec
      - /docker/crowdsec/config/acquis.yaml:/etc/crowdsec/acquis.yaml:ro
      - /docker/syslog/log:/var/log:ro
    ports:
      - "8888:8080/tcp"   # LAPI (bouncer OPNsense)
      - "6060:6060/tcp"   # métriques Prometheus
    # 7422 (AppSec) volontairement NON publié

  crowdsec-spoa:
    image: crowdsecurity/spoa-bouncer:v0.3.1
    restart: unless-stopped
    depends_on: [crowdsec]
    networks:
      dmzsec:
        ipv4_address: 172.31.90.12
    volumes:
      - /docker/crowdsec-spoa/crowdsec-spoa-bouncer.yaml:/etc/crowdsec/bouncers/crowdsec-spoa-bouncer.yaml:ro
```

### 4.2 HAProxy — `haproxy.cfg` (parties sécurité / supervision)

**Global**

```haproxy
global
  maxconn 2000
  hard-stop-after 25s
  tune.bufsize 65536            # requis par AppSec (trame SPOE ≤ 64 KB)
  log 172.31.90.10:514 local0 info
```

**Stats + métriques Prometheus**

```haproxy
listen stats
  bind :8404
  mode http
  stats enable
  stats uri /stats
  stats refresh 10s
  monitor-uri /healthz
  http-request use-service prometheus-exporter if { path /metrics }
```

**Frontend `FE_HTTPS_PUBLIC`** — l'ordre des `http-request` compte.

```haproxy
  bind :443 ssl alpn h2,http/1.1 strict-sni crt-list /usr/local/etc/haproxy/crt-list.txt

  # --- Hosts réservés au LAN / serveurs / WireGuard ---
  acl src_trusted src 192.168.0.0/24 172.16.70.0/24 172.16.111.0/24
  acl is_internal_only var(txn.txnhost) -m str -i -f /usr/local/etc/haproxy/hosts_internal.lst
  http-request deny deny_status 403 if is_internal_only !src_trusted

  # --- Vaultwarden : /admin réservé aux réseaux de confiance ---
  acl vw_admin_path path,url_dec,lower -m reg (^|/)admin(/|$)
  http-request deny deny_status 403 if acl_vw_host vw_admin_path !src_trusted

  # --- CrowdSec SPOA : décisions IP + WAF AppSec ---
  option http-buffer-request
  unique-id-format %[uuid()]
  filter spoe engine crowdsec config /usr/local/etc/haproxy/crowdsec.cfg

  acl body_within_limit req.body_size -m int le 51200
  http-request send-spoe-group crowdsec crowdsec-http-body    if body_within_limit || !{ req.body_size -m found }
  http-request send-spoe-group crowdsec crowdsec-http-no-body if !body_within_limit { req.body_size -m found }

  http-request deny deny_status 403 if { var(txn.crowdsec.remediation) -m str ban }
  http-request deny deny_status 403 if { var(txn.crowdsec.remediation) -m str captcha }
```

`hosts_internal.lst` : `monitoring`, `pdf`, `dns`, `firefox`, `qbt`, `convert`, `haproxy` (`.zonelibre.live`).

**Backend SPOA**

```haproxy
backend crowdsec-spoa
  mode tcp
  timeout connect 2s
  timeout server  60s
  server spoa 172.31.90.12:9000
```

### 4.3 HAProxy — `crowdsec.cfg` (agent SPOE)

```
[crowdsec]
spoe-agent crowdsec-agent
    messages    crowdsec-tcp
    groups      crowdsec-http-body crowdsec-http-no-body
    option      var-prefix      crowdsec
    option      set-on-error    error
    timeout     hello           200ms
    timeout     idle            55s
    timeout     processing      500ms
    use-backend crowdsec-spoa
    log         global

spoe-message crowdsec-tcp
    args id=unique-id src-ip=src src-port=src_port
    event on-client-session

spoe-message crowdsec-http-body
    args remediation=var(txn.crowdsec.remediation) id=unique-id method=method path=path query=query version=req.ver headers=req.hdrs body=req.body url=url ssl=ssl_fc src-ip=src src-port=src_port

spoe-message crowdsec-http-no-body
    args remediation=var(txn.crowdsec.remediation) id=unique-id method=method path=path query=query version=req.ver headers=req.hdrs url=url ssl=ssl_fc src-ip=src src-port=src_port

spoe-group crowdsec-http-body
    messages crowdsec-http-body

spoe-group crowdsec-http-no-body
    messages crowdsec-http-no-body
```

### 4.4 Bouncer SPOA — `crowdsec-spoa-bouncer.yaml`

```yaml
log_mode: stdout
log_level: info

update_frequency: 10s
api_url: http://crowdsec:8080/
api_key: <CLE_HAPROXY_SPOA>        # cscli bouncers add haproxy-spoa
retry_initial_connect: true

listen_tcp: 0.0.0.0:9000

appsec_url: http://crowdsec:7422
appsec_timeout: 200ms

hosts:
  - host: "*"
    appsec:
      always_send: false
```

> Sans captcha configuré, une décision `captcha` est traitée comme un `ban`. Le message `empty captcha provider` est **cosmétique**.

### 4.5 CrowdSec — `acquis.d/appsec.yaml`

```yaml
source: appsec
listen_addr: 0.0.0.0:7422
appsec_configs:
  - crowdsecurity/appsec-default
labels:
  type: appsec
```

`appsec-default` charge en **in-band** `base-config`, `vpatch-*`, `generic-*` (~207 règles), en out-of-band `experimental-*` et `appsec-generic-test`.

### 4.6 CrowdSec — `profiles.yaml`

> **Règle d'or** : les lignes d'une liste `filters` sont combinées en **OU**. Toujours **une seule ligne** par filtre, conditions reliées par `&&`.
> Chaque profil de ban **exclut explicitement les plages privées** : une IP interne ne peut jamais être bannie, même en cas d'erreur d'ordre des profils.

```yaml
name: internal_waf_notify
filters:
  - Alert.GetScope() == "Ip" && (IpInRange(Alert.GetValue(), "192.168.0.0/16") || IpInRange(Alert.GetValue(), "172.16.0.0/12") || IpInRange(Alert.GetValue(), "10.0.0.0/8"))
notifications:
  - email_default
  - http_loki
on_success: break
---
name: http_aggressive_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip" && Alert.GetScenario() contains "http-" && !IpInRange(Alert.GetValue(), "192.168.0.0/16") && !IpInRange(Alert.GetValue(), "172.16.0.0/12") && !IpInRange(Alert.GetValue(), "10.0.0.0/8")
decisions:
  - type: ban
    duration: 24h
duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 24)
notifications:
  - email_default
  - http_loki
on_success: break
---
name: default_ip_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip" && !IpInRange(Alert.GetValue(), "192.168.0.0/16") && !IpInRange(Alert.GetValue(), "172.16.0.0/12") && !IpInRange(Alert.GetValue(), "10.0.0.0/8")
decisions:
  - type: ban
    duration: 12h
duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 12)
notifications:
  - email_default
  - http_loki
on_success: break
---
name: default_range_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
  - type: ban
    duration: 24h
notifications:
  - email_default
  - http_loki
on_success: break
---
name: waf_log_only
filters:
  - Alert.Remediation == false && Alert.GetScope() == "Ip"
notifications:
  - http_loki
on_success: break
```

### 4.7 Notifications

- **`email_default`** (`notifications/email.yaml`) : relais SMTP Synology `172.16.70.3:25` sans authentification, `group_wait: 60s`.
- **`http_loki`** (`notifications/http_loki.yaml`) : push vers `http://172.16.70.12:3100/loki/api/v1/push`, flux `{job="crowdsec", host="dock00-sec"}`.

```yaml
type: http
name: http_loki
log_level: info
group_wait: 30s
max_retry: 3
timeout: 10s
url: http://172.16.70.12:3100/loki/api/v1/push
method: POST
headers:
  Content-Type: application/json
format: |
  {"streams":[{"stream":{"job":"crowdsec","host":"dock00-sec"},"values":[
  {{- range $i, $a := . -}}
  {{- if $i }},{{ end -}}
  {{- $meta := dict -}}
  {{- if $a.Events }}{{ range (index $a.Events 0).Meta }}{{ $_ := set $meta .Key .Value }}{{ end }}{{ end -}}
  ["{{ now | unixEpoch }}00000{{ printf "%04d" $i }}", {{ dict
      "ip" $a.Source.Value
      "country" $a.Source.Cn
      "as_name" $a.Source.AsName
      "as_number" $a.Source.AsNumber
      "scenario" $a.Scenario
      "remediation" $a.Remediation
      "start_at" $a.StartAt
      "events_count" (len $a.Events)
      "decisions" $a.Decisions
      "meta" $meta
      | toJson | toJson }}]
  {{- end -}}
  ]}]}
```

Champs `meta` observés pour une alerte WAF : `rule_name`, `message`, `target_fqdn`, `uri`, `matched_zones`, `data`.

### 4.8 Allowlist

**Aucune allowlist active.** Une IP en allowlist n'est **pas inspectée du tout** par le WAF. Usage ponctuel seulement (faux positif bloquant), avec expiration :

```bash
docker exec crowdsec cscli allowlists create internes -d "Exceptions WAF"
docker exec crowdsec cscli allowlists add internes 172.16.70.11 -e 1h
```

AppSec recharge les allowlists **une fois par minute**.

### 4.9 OPNsense — bouncer firewall

**Paquet** : `crowdsec-firewall-bouncer` (pkg FreeBSD, pas le plugin `os-crowdsec` → pas de menu dans l'interface). Service `crowdsec_firewall`, activé au démarrage (`sysrc crowdsec_firewall_enable="YES"`). Mises à jour avec le firmware OPNsense.

**Config** (`/usr/local/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`, extraits) :

```yaml
api_url: http://172.16.90.1:8888/
api_key: '<CLE_OPNSENSE>'
mode: pf
pf:
  anchor_name: ''
blacklists_ipv4: crowdsec_blacklists
blacklists_ipv6: crowdsec6_blacklists
retry_initial_connect: true
```

**Alias** (Pare-feu > Alias) : `crowdsec_blacklists` et `crowdsec6_blacklists`, type **Externe (avancé)** (contenu géré par le bouncer, jamais par OPNsense).

**Règles** (Pare-feu > Règles) :

| Champ | IPv4 | IPv6 |
|---|---|---|
| Séquence | 1 (règle "Plex exclude geoip" passée en 2) | 1 |
| Action / Rapide | Bloquer / ✅ | Bloquer / ✅ |
| Interfaces | WAN01_FC, WAN02_5G, WAN03_DSL | idem |
| Direction | in | in |
| Source | `crowdsec_blacklists` | `crowdsec6_blacklists` |
| Journaliser | ✅ (temporaire, pour validation) | — |

> **Leçon du setup de février** : le bouncer remplissait la table, mais **aucune règle ne l'utilisait** — rien n'était bloqué, et pf vidait la table non référencée à chaque rechargement. Une table pf ne bloque rien seule : il faut **toujours** une règle qui la référence. Le bon test est le **compteur de paquets de la règle**, pas le contenu de la table.

---

## 5. Exploitation courante

### HAProxy : valider puis recharger (sans couper les connexions)

```bash
docker exec haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg && docker kill -s USR2 haproxy
```

`haproxy -c` n'affiche rien si tout va bien : seul le **code retour** compte. Préférer le reload au `docker restart` (qui coupe les connexions au bout de `hard-stop-after`).

### Valider une nouvelle image à blanc

```bash
docker run --rm -v /docker/haproxy:/usr/local/etc/haproxy:ro haproxy:<TAG> \
  haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg; echo "code $?"

docker run --rm -v /docker/syslog/syslog-ng.conf:/etc/syslog-ng/syslog-ng.conf:ro \
  balabit/syslog-ng:<TAG> --syntax-only 2>&1 | grep -v '^[A-Z_]*=' ; echo "code ${PIPESTATUS[0]}"

docker exec crowdsec crowdsec -t      # config CrowdSec (profils, acquisitions, notifications)
```

### Santé CrowdSec / HAProxy

```bash
docker exec haproxy haproxy -v | head -1
docker inspect --format '{{.State.Health.Status}}' haproxy
docker exec crowdsec cscli bouncers list                # opnsense-fw@… et haproxy-spoa : "Last API pull" récent
docker exec crowdsec cscli metrics show acquisition
docker exec crowdsec cscli metrics show appsec
docker exec crowdsec cscli alerts list -l 20
docker exec crowdsec cscli decisions list --origin crowdsec     # bans locaux (CAPI = communauté)
docker exec crowdsec cscli notifications test http_loki
docker logs crowdsec-spoa --tail 20
```

### Santé OPNsense (shell : taper `sh` d'abord, le shell root est `csh`)

```sh
service crowdsec_firewall status
tail -n 20 /var/log/crowdsec/crowdsec-firewall-bouncer.log
pfctl -t crowdsec_blacklists -T show | wc -l                # ~15 500
pfctl -vvsr | grep -A1 crowdsec_blacklists | grep Packets    # doit augmenter avec le temps
```

### Analyser / débannir

```bash
docker exec crowdsec cscli alerts inspect <ID> -d
docker exec crowdsec cscli decisions list -i <IP>
docker exec crowdsec cscli decisions delete -i <IP>       # SPOA ~10 s, OPNsense ~10 s
docker exec -it crowdsec cscli bouncers prune --duration 720h   # interactif → -it
```

### Lire les timings HAProxy (`TR/Tw/Tc/Tr/Ta`)

| Champ | Signification | Si élevé |
|---|---|---|
| TR | Réception de la requête (body bufferisé compris) | Attente du body ou client lent |
| Tw | File d'attente | Saturation `maxconn` |
| Tc | Connexion au serveur | Backend lent à accepter |
| Tr | Réponse du serveur | Application lente |
| Ta | Total | — |

> Horodatages des logs en **UTC** (+1 h hiver, +2 h été).

---

## 6. Supervision

| Source | Collecte | Contenu |
|---|---|---|
| CrowdSec `172.16.90.1:6060` | Prometheus | `cs_active_decisions`, `cs_alerts`, `cs_appsec_reqs_total`, `cs_appsec_block_total`, `cs_appsec_rule_hits` |
| HAProxy `172.16.90.1:8404/metrics` | Prometheus (job `haproxy`) | Trafic, codes HTTP, temps de réponse par frontend/backend |
| Alertes CrowdSec | Loki (plugin `http_loki`) | Inventaire : IP, pays, AS, scénario/règle, décision, service et URI visés |

Requêtes utiles :

```promql
sum(rate(cs_appsec_reqs_total[5m]))
sum(rate(cs_appsec_block_total[5m]))
topk(10, sum by (rule_name) (increase(cs_appsec_rule_hits[24h])))
sum by (reason) (cs_active_decisions{origin="crowdsec"})
```

```logql
{job="crowdsec"} | json
{job="crowdsec"} | json | remediation="true"
topk(10, sum by (ip) (count_over_time({job="crowdsec"} | json [24h])))
sum by (meta_target_fqdn) (count_over_time({job="crowdsec"} | json [7d]))
```

---

## 7. Procédures de test

### Non-régression

- LAN : `curl.exe -sI https://qbt.zonelibre.live` → 200/302
- 4G/5G : `curl -sI --resolve qbt.zonelibre.live:443:<IP_PUBLIQUE> https://qbt.zonelibre.live` → **403**
- 4G/5G : `/admin` Vaultwarden → **403**
- WireGuard : service interne accessible
- Applications : Bitwarden, DAVx5, Synology Photos, Drive, FileStation

### WAF (depuis le LAN, sans risque de ban)

```
curl.exe -sI https://photos.zonelibre.live/.env      # 403
```

Puis : `cscli metrics show appsec` (Blocked +1), mail reçu, ligne dans Loki, **aucune décision** sur l'IP.

### Bouncer OPNsense

```bash
docker exec crowdsec cscli decisions add -i 203.0.113.50 -t ban -d 5m -r "test bouncer"
```
```sh
pfctl -t crowdsec_blacklists -T test 203.0.113.50      # 1/1 addresses match
```
```bash
docker exec crowdsec cscli decisions delete -i 203.0.113.50
```

Et surtout : vérifier que le compteur `Packets` de la règle augmente au fil du temps.

### Fail-open SPOA

```bash
docker stop crowdsec-spoa    # services accessibles (sans WAF ni bans côté HAProxy ; OPNsense continue de bloquer)
docker start crowdsec-spoa
```

---

## 8. Retour arrière

| Besoin | Action |
|---|---|
| Couper le WAF sans redéployer | Commenter `filter spoe …`, les deux `send-spoe-group` et les deux `deny … remediation` → valider + reload |
| Couper le WAF en urgence | `docker stop crowdsec-spoa` (fail-open) |
| Couper les bans OPNsense | Désactiver les deux règles "CrowdSec blocklist" |
| Revenir à HAProxy 3.0 | Tag `haproxy:3.0` → commit → redéploiement |
| Revenir à syslog-ng 4.7 | Tag `balabit/syslog-ng:4.7.1` + `@version: 4.7` → redéploiement |
| Annuler une modif de `profiles.yaml` | Restaurer, puis `docker exec crowdsec crowdsec -t && docker restart crowdsec` |
| Se débannir | `cscli decisions delete -i <IP>` |

Avant tout redéploiement : **watchdog HAProxy en pause**, pas de `docker image prune` avant validation.

---

## 9. Limites connues

- **Body > ~50 KB non inspecté** (limite du protocole SPOE, non contournable). Groupe `no-body` : URI, paramètres et en-têtes inspectés, pas le body. Contournement par remplissage → phase 2.
- **Fail-open** du SPOA (500 ms) : choix assumé.
- **Contenu des uploads** non analysé (aucun WAF ne le fait) : Antivirus Essential (Synology), Defender (postes et serveur de fichiers), snapshots/versioning/sauvegardes.
- **Vaultwarden** : coffre chiffré côté client, l'inspection du body n'apporte rien ; protection sur URI, en-têtes, authentification.
- **Services exposés en direct** (Plex, SFTP, Drive 6690, WireGuard) : pas de WAF, seulement bans OPNsense + géoblocage.
- **`RAF_WKS`** a accès à tous les réseaux internes : un poste compromis contournerait HAProxy et le WAF.
- **`be_libretime` DOWN** : hors production.

---

## 10. Feuille de route

### Phase 2 WAF (après 1 à 2 semaines d'observation)
1. CRS OWASP en **out-of-band** (détection seule), suivi via `cs_appsec_rule_hits` et Loki
2. Politique de taille de body par hôte : 413 au-delà de 50 KB sauf chemins d'upload
3. Exclusions ciblées (WebDAV `PROPFIND`/`REPORT`, vCards avec photo…)
4. Passage progressif du CRS en **in-band**

### Autres chantiers
- Dashboard Grafana complet (Prometheus CrowdSec/AppSec/HAProxy + inventaire Loki)
- Alertmanager : CrowdSec down, bouncer sans pull, pic d'alertes
- Désactiver la journalisation de la règle CrowdSec OPNsense une fois validée
- Filtrage inter-VLAN : réduire les accès de `RAF_WKS`, administration via WireGuard
- Revoir l'exposition directe de Synology Drive (6690) et SFTP
- Vaultwarden : `ADMIN_TOKEN` en hash Argon2 (ou désactivé hors intervention)
- Suricata (OPNsense) en IDS seul sur les interfaces internes
- Nettoyage de `/docker/haproxy/` (`.bak`, `.new`, `.test`)

---

## Annexe — Microsoft Defender sur le serveur de fichiers (Windows Server 2019)

- Fonctionnalité `Windows-Defender` installée, plateforme mise à jour via KB4052623 : **4.18.26090.9**
- Protection temps réel active, `AMRunningMode = Normal`, PUA activé
- À finaliser : GPO *Configuration ordinateur > Modèles d'administration > Composants Windows > Antivirus Microsoft Defender* (PUA = Bloquer, MAPS activé, échantillons = Ne jamais envoyer), liée à l'OU du serveur (et *Domain Controllers* si souhaité). Contrôle : `Get-MpPreference | Select PUAProtection, MAPSReporting, SubmitSamplesConsent` → `1 / 2 / 2`
- Clichés instantanés VSS sur les volumes partagés recommandés