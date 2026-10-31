#!/usr/bin/env python3
"""
Collecte l'état du contrôleur MegaRAID (storcli2 sur ESXi) via une clé SSH
en commande forcée, et l'écrit au format Prometheus pour le textfile collector
de node_exporter.

  megaraid.prom            -> métriques du contrôleur (écrit seulement si la collecte réussit)
  megaraid_collector.prom  -> état de la dernière tentative (écrit à chaque passage)
"""
import json, os, re, subprocess, sys, tempfile, time
import xml.etree.ElementTree as ET

ESXI = "root@172.16.70.8"
SSH_KEY = "/root/.ssh/esxi_raidstatus_rsa"
OUT_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/node_exporter/textfile")
CTRL = "c0"

# ---------------------------------------------------------------------------
def write_atomic(name, text):
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=f".{name}.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(OUT_DIR, name))

def esc(v):
    return str(v).strip().replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")

class Metrics:
    def __init__(self):
        self.series = {}          # name -> (help, type, [lines])
    def add(self, name, value, help_, labels=None, type_="gauge"):
        lab = ",".join(f'{k}="{esc(v)}"' for k, v in (labels or {}).items())
        line = f"{name}{{{lab}}} {value}" if lab else f"{name} {value}"
        self.series.setdefault(name, (help_, type_, []))[2].append(line)
    def render(self):
        out = []
        for name, (h, t, lines) in self.series.items():
            out += [f"# HELP {name} {h}", f"# TYPE {name} {t}", *lines]
        return "\n".join(out) + "\n"

def parse_block(text):
    """storcli2 sur ESXi emballe parfois son JSON dans du XML esxcli (&quot;...)."""
    text = text.strip()
    if text.startswith("<"):
        text = ET.fromstring(text).find(".//string").text
    data = json.loads(text)
    ctrl = data["Controllers"][0]
    status = ctrl["Command Status"]["Status"]
    if status != "Success":
        raise RuntimeError(f"storcli2 status={status}: {ctrl['Command Status'].get('Description')}")
    return ctrl["Response Data"], ctrl["Command Status"]

def sectors_to_bytes(size_str, sector_size_str):
    """'7.276 TiB [0x3a3710000 Sectors]' + '512B' -> octets exacts"""
    m = re.search(r"\[0x([0-9a-fA-F]+) Sectors\]", size_str or "")
    if not m:
        return None
    s = (sector_size_str or "512B").replace(" ", "")
    unit = 4096 if s.upper().startswith("4K") else int(re.sub(r"\D", "", s) or 512)
    return int(m.group(1), 16) * unit

# ---------------------------------------------------------------------------
def collect(raw):
    # marqueurs "### C0/VD/PD" posés par raidctl.sh (pas forcément en début de ligne :
    # storcli2 ne termine pas toujours sa sortie par un retour à la ligne)
    parts = re.split(r"### (C0|VD|PD)[ \t]*\r?\n", raw)
    blocks = dict(zip(parts[1::2], parts[2::2]))
    c0, cmd = parse_block(blocks["C0"])
    vd, _ = parse_block(blocks["VD"])
    pd, _ = parse_block(blocks["PD"])
    m = Metrics()
    base = {"controller": CTRL}

    # --- contrôleur
    m.add("megaraid_controller_info", 1, "Informations contrôleur (valeur toujours 1)",
          {**base, "model": c0.get("Product Name", ""), "firmware": c0.get("Firmware Version", ""),
           "driver": f'{c0.get("Driver Name","")} {c0.get("Driver Version","")}',
           "cli_version": cmd.get("CLI Version", "")})

    # --- energy pack (supercap / CacheVault)
    for ep in c0.get("Energy Pack Info", []):
        lab = {**base, "type": ep.get("Type", ""), "subtype": ep.get("SubType", "")}
        m.add("megaraid_energy_pack_ok", int(ep.get("Status") == "Optimal"),
              "1 si l'energy pack (supercap) est Optimal", {**lab, "status": ep.get("Status", "")})
        if isinstance(ep.get("Temperature(C)"), (int, float)):
            m.add("megaraid_energy_pack_temperature_celsius", ep["Temperature(C)"], "Température de l'energy pack", lab)
        if isinstance(ep.get("Voltage(mV)"), (int, float)):
            m.add("megaraid_energy_pack_voltage_volts", ep["Voltage(mV)"] / 1000, "Tension de l'energy pack", lab)

    # --- enclosures
    for enc in c0.get("Enclosure List", []):
        m.add("megaraid_enclosure_ok", int(enc.get("State") == "OK"), "1 si l'enclosure est OK",
              {**base, "eid": enc.get("EID"), "state": enc.get("State", "")})

    # --- tâches de fond par disque (colonne BT de la topologie)
    bt = {r["EID:Slot"]: int(r.get("BT") == "Y") for r in c0.get("TOPOLOGY", []) if r.get("Type") == "DRIVE"}

    # --- volumes RAID
    for v in vd.get("Virtual Drives", []):
        info, props = v.get("VD Info", {}), v.get("VD Properties", {})
        lab = {**base, "dg_vd": info.get("DG/VD"), "name": info.get("Name", ""), "raid_type": info.get("TYPE", "")}
        m.add("megaraid_vd_info", 1, "Volume RAID ; le label state porte l'état (Optl, Pdgd, Dgrd, OfLn, Rec...)",
              {**lab, "state": info.get("State", ""), "cache": info.get("CurrentCache", ""),
               "default_cache": info.get("DefaultCache", "")})
        m.add("megaraid_vd_optimal", int(info.get("State") == "Optl"), "1 si le volume est Optimal", lab)
        m.add("megaraid_vd_consistent", int(props.get("Consistent") == "Yes"), "1 si le volume est cohérent", lab)
        m.add("megaraid_vd_bad_blocks", int(props.get("Bad Block Exists") == "Yes"), "1 si des blocs défectueux existent", lab)
        m.add("megaraid_vd_drives", props.get("Number of Drives", 0), "Nombre de disques du volume", lab)
        if props.get("Number of Blocks") and props.get("Block Size"):
            m.add("megaraid_vd_size_bytes", props["Number of Blocks"] * props["Block Size"], "Taille du volume", lab)
        # le cache courant diffère du cache par défaut (ex. WB -> WT si l'energy pack lâche)
        cur_wb = "WB" in info.get("CurrentCache", "").split(",")
        def_wb = "WB" in info.get("DefaultCache", "").split(",")
        m.add("megaraid_vd_writeback_degraded", int(def_wb and not cur_wb),
              "1 si le volume devrait être en write-back mais est repassé en write-through", lab)

    # --- disques physiques
    for d in pd.get("Drives List", []):
        di = d.get("Drive Information", {})
        dd = d.get("Drive Detailed Information", {})
        slot = di.get("EID:Slt", "")
        dg = di.get("DG", "-")
        lab = {**base, "eid_slot": slot, "dg": dg, "model": di.get("Model", "").strip(), "media": di.get("Med", "")}
        m.add("megaraid_pd_info", 1, "Disque physique ; labels status/state = état",
              {**lab, "interface": di.get("Intf", ""), "status": di.get("Status", ""), "state": di.get("State", ""),
               "serial": dd.get("Serial Number", "").strip(), "firmware": dd.get("Firmware Revision Level", "").strip()})
        m.add("megaraid_pd_online", int(di.get("Status") == "Online"), "1 si le disque est Online", lab)
        if isinstance(dd.get("Temperature(C)"), (int, float)):
            m.add("megaraid_pd_temperature_celsius", dd["Temperature(C)"], "Température du disque", lab)
        if isinstance(dd.get("Shield Counter"), int):
            m.add("megaraid_pd_shield_counter", dd["Shield Counter"], "Compteur Shield (diagnostics après erreurs)", lab)
        if slot in bt:
            m.add("megaraid_pd_background_task", bt[slot], "1 si une tâche de fond tourne sur le disque (patrol read, rebuild, CC...)", lab)
        lu = next((v for k, v in dd.items() if k.startswith("LU/NS") and k.endswith("Properties")), {})
        for key, metric, h in (("Media Error Count", "megaraid_pd_media_errors", "Erreurs média (compteur contrôleur)"),
                               ("Other Error Count", "megaraid_pd_other_errors", "Autres erreurs (compteur contrôleur)"),
                               ("Predictive Failure Count", "megaraid_pd_predictive_failures", "Défaillances prédites (SMART)")):
            if isinstance(lu.get(key), int):
                m.add(metric, lu[key], h, lab)
        size = sectors_to_bytes(lu.get("Coerced size") or dd.get("Coerced size"),
                                lu.get("Logical Sector Size") or dd.get("Logical Sector Size"))
        if size:
            m.add("megaraid_pd_size_bytes", size, "Taille utile du disque", lab)

    m.add("megaraid_collector_last_success_timestamp_seconds", int(time.time()),
          "Horodatage de la dernière collecte réussie")
    return m.render()

def fetch():
    return subprocess.run(
        ["ssh", "-i", SSH_KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=10", ESXI, "status"],
        capture_output=True, text=True, timeout=60, check=True).stdout

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    t0 = time.time()
    try:
        raw = open(sys.argv[1]).read() if len(sys.argv) > 1 else fetch()   # argument = fichier de test
        write_atomic("megaraid.prom", collect(raw))
        ok, err = 1, ""
    except Exception as e:
        ok, err = 0, f"{type(e).__name__}: {e}"
        print(err, file=sys.stderr)
    c = Metrics()
    c.add("megaraid_collector_success", ok, "1 si la dernière collecte MegaRAID a réussi")
    c.add("megaraid_collector_duration_seconds", round(time.time() - t0, 3), "Durée de la dernière collecte")
    write_atomic("megaraid_collector.prom", c.render())
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
