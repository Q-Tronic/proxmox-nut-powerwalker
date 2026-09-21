#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ==============================================================================
# Proxmox + NUT + PowerWalker + Home Assistant + MQTT
# Autor: Q-Tronic
# ==============================================================================
#
# Bezpieczny instalator dla hosta Proxmox uruchamiany jako root.
#
# ZASADY:
# - NUT na Proxmoxie jest jedyną warstwą decydującą o shutdownie hosta.
# - Home Assistant i MQTT służą do monitoringu/automatyzacji.
# - nut-monitor zostaje uzbrojony WYŁĄCZNIE po poprawnym odczycie "ups.status".
# - Przy niejednoznacznym wykryciu UPS skrypt kończy pracę bez uzbrajania shutdownu.
# - Skrypt NIE uruchamia POWERDOWNFLAG, shutdown.return, shutdown.stayoff,
#   load.off ani innych poleceń odcinających 230 V.
# - Fizyczny power-cycle UPS jest osobnym etapem po sprawdzeniu możliwości
#   konkretnej sztuki: nut-capabilities oraz nut-phase2-check.
# - Przed zmianą /etc/nut tworzony jest backup.
# - Istniejąca obca konfiguracja NUT nie jest nadpisywana bez FORCE=1.
# - Logi własne są rotowane i ograniczone rozmiarem.
#
# Domyślne:
#   UPS_NAME=powerwalker
#   UPS_DESC="PowerWalker VI 2200 STL FR"
#   SHUTDOWN_DELAY=60
#   NUT_PORT=3493
#
# Przykłady:
#   bash ./setup-nut-powerwalker-proxmox.sh
#   SHUTDOWN_DELAY=120 bash ./setup-nut-powerwalker-proxmox.sh
#
# Jeśli istnieje ręczna konfiguracja NUT i świadomie chcesz ją zastąpić:
#   FORCE=1 bash ./setup-nut-powerwalker-proxmox.sh
#
# Jeśli masz wiele UPS-ów USB, możesz wymusić parametry:
#   UPS_DRIVER=usbhid-ups \
#   UPS_VENDORID=0764 \
#   UPS_PRODUCTID=0601 \
#   bash ./setup-nut-powerwalker-proxmox.sh
#
# MQTT konfigurujesz po instalacji:
#   nut-mqtt-config
#
# ==============================================================================

UPS_NAME="${UPS_NAME:-powerwalker}"
UPS_DESC="${UPS_DESC:-PowerWalker VI 2200 STL FR}"
SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-60}"
NUT_PORT="${NUT_PORT:-3493}"
FORCE="${FORCE:-0}"

UPS_DRIVER="${UPS_DRIVER:-}"
UPS_PORT="${UPS_PORT:-}"
UPS_VENDORID="${UPS_VENDORID:-}"
UPS_PRODUCTID="${UPS_PRODUCTID:-}"
UPS_SUBDRIVER="${UPS_SUBDRIVER:-}"
NUT_LISTEN_IP="${NUT_LISTEN_IP:-}"

BASE_DIR="/root/nut-powerwalker"
BACKUP_ROOT="${BASE_DIR}/backups"
REPORT_DIR="${BASE_DIR}/reports"
LOG_DIR="/var/log/nut-powerwalker"
LIB_DIR="/usr/local/lib/nut-powerwalker"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/nut-${TS}"
MARKER="# managed-by: q-tronic-nut-powerwalker-installer"

C_GREEN='\033[1;32m'
C_BLUE='\033[1;34m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_RESET='\033[0m'

ok()   { printf "\n${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
info() { printf "\n${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; }
warn() { printf "\n${C_YELLOW}[UWAGA]${C_RESET} %s\n" "$*" >&2; }
die()  { printf "\n${C_RED}[BŁĄD]${C_RESET} %s\n" "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Uruchom skrypt jako root."

if [[ -f /etc/nut/qtronic-bypass-state.env ]]; then
    die "Tryb BYPASS jest aktywny. Nie aktualizuję/reinstaluję NUT podczas celowo odłączonego UPS. Najpierw podłącz UPS i uruchom: nut-config resume"
fi

case "${SHUTDOWN_DELAY}" in
  ''|*[!0-9]*) die "SHUTDOWN_DELAY musi być liczbą całkowitą sekund." ;;
esac
(( SHUTDOWN_DELAY >= 15 )) || die "SHUTDOWN_DELAY poniżej 15 s jest zbyt ryzykowne."

case "${NUT_PORT}" in
  ''|*[!0-9]*) die "NUT_PORT musi być liczbą." ;;
esac
(( NUT_PORT >= 1 && NUT_PORT <= 65535 )) || die "NUT_PORT poza zakresem 1-65535."

mkdir -p "${BASE_DIR}" "${BACKUP_ROOT}" "${REPORT_DIR}" "${LIB_DIR}"
chmod 0700 "${BASE_DIR}" "${BACKUP_ROOT}" "${REPORT_DIR}"
chmod 0755 "${LIB_DIR}"

atomic_install() {
    local dst="$1" owner="$2" group="$3" mode="$4" tmp
    mkdir -p "$(dirname "${dst}")"
    tmp="$(mktemp "${dst}.tmp.XXXXXX")"
    cat > "${tmp}"
    chown "${owner}:${group}" "${tmp}"
    chmod "${mode}" "${tmp}"
    mv -f "${tmp}" "${dst}"
}

service_state() {
    local unit="$1"
    printf '%s enabled=%s active=%s\n' \
        "${unit}" \
        "$(systemctl is-enabled "${unit}" 2>/dev/null || true)" \
        "$(systemctl is-active "${unit}" 2>/dev/null || true)"
}

# ------------------------------------------------------------------------------
# Backup i ochrona istniejącej konfiguracji
# ------------------------------------------------------------------------------

info "Tworzę backup bieżącej konfiguracji NUT..."
mkdir -p "${BACKUP_DIR}"

if [[ -d /etc/nut ]]; then
    cp -a /etc/nut "${BACKUP_DIR}/nut"
else
    touch "${BACKUP_DIR}/NO_ETC_NUT_BEFORE_INSTALL"
fi

{
    service_state nut-server.service
    service_state nut-monitor.service
    service_state nut-driver-enumerator.service
    service_state nut-driver-enumerator.path
} > "${BACKUP_DIR}/service-state.txt"

printf '%s\n' "${BACKUP_DIR}" > "${BASE_DIR}/LAST_BACKUP"
chmod 0600 "${BASE_DIR}/LAST_BACKUP"
ok "Backup: ${BACKUP_DIR}"

if [[ -f /etc/nut/ups.conf ]] \
   && grep -Eq '^[[:space:]]*\[[^]]+\][[:space:]]*$' /etc/nut/ups.conf \
   && ! grep -Fq "${MARKER}" /etc/nut/ups.conf 2>/dev/null \
   && [[ "${FORCE}" != "1" ]]; then
    die "Wykryłem istniejącą konfigurację /etc/nut/ups.conf, której ten instalator nie utworzył.
Nie nadpisuję jej automatycznie.

Backup: ${BACKUP_DIR}

Jeśli świadomie chcesz zastąpić obecną konfigurację:
FORCE=1 bash $0"
fi

# ------------------------------------------------------------------------------
# Pakiety
# ------------------------------------------------------------------------------

info "Instaluję wymagane pakiety..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    nut nut-client nut-server \
    usbutils openssl iproute2 procps \
    python3 python3-paho-mqtt \
    jq logrotate util-linux

for cmd in upsc upscmd upsrw upsmon upssched python3 jq lsusb flock; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Brakuje wymaganego polecenia: ${cmd}"
done

UPSC_BIN="$(command -v upsc)"
UPSCMD_BIN="$(command -v upscmd)"
UPSRW_BIN="$(command -v upsrw)"
UPSMON_BIN="$(command -v upsmon)"
UPSSCHED_BIN="$(command -v upssched)"
NUT_SCANNER_BIN="$(command -v nut-scanner || true)"
UPSDRVCTL_BIN="$(command -v upsdrvctl || true)"
UPSDRVSVCCTL_BIN="$(command -v upsdrvsvcctl || true)"
SHUTDOWN_BIN="$(command -v shutdown)"
LOGGER_BIN="$(command -v logger)"
PYTHON_BIN="$(command -v python3)"
JQ_BIN="$(command -v jq)"

NUT_VERSION="$("${UPSMON_BIN}" -V 2>&1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
[[ -n "${NUT_VERSION}" ]] || NUT_VERSION="unknown"

if [[ "${NUT_VERSION}" != "unknown" ]] && dpkg --compare-versions "${NUT_VERSION}" ge "2.8.0"; then
    UPSMON_ROLE="primary"
else
    UPSMON_ROLE="master"
fi

ok "NUT ${NUT_VERSION}; rola upsmon: ${UPSMON_ROLE}"

if command -v pveversion >/dev/null 2>&1; then
    pveversion -v > "${BASE_DIR}/pveversion-${TS}.txt" 2>&1 || true
    ok "Wykryto Proxmox VE."
else
    warn "Nie wykryto pveversion. Skrypt jest przygotowany pod Proxmox VE/Debian."
fi

if [[ -f "$0" ]]; then
    cp -f "$0" "${BASE_DIR}/installer.sh"
    chmod 0700 "${BASE_DIR}/installer.sh"
fi

# ------------------------------------------------------------------------------
# Logi i rotacja
# ------------------------------------------------------------------------------

install -d -o nut -g nut -m 0750 "${LOG_DIR}"
touch "${LOG_DIR}/events.log" "${LOG_DIR}/mqtt.log"
chown nut:nut "${LOG_DIR}/events.log" "${LOG_DIR}/mqtt.log"
chmod 0640 "${LOG_DIR}/events.log" "${LOG_DIR}/mqtt.log"

cat > /etc/logrotate.d/nut-powerwalker <<'EOF'
/var/log/nut-powerwalker/*.log {
    size 512k
    rotate 6
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
chmod 0644 /etc/logrotate.d/nut-powerwalker

# ------------------------------------------------------------------------------
# Wykrycie UPS
# ------------------------------------------------------------------------------

info "Skanuję USB i dostępne urządzenia NUT..."

LSUSB_FILE="${BASE_DIR}/lsusb-${TS}.txt"
SCANNER_FILE="${BASE_DIR}/nut-scanner-${TS}.txt"
SCANNER_ERR="${BASE_DIR}/nut-scanner-${TS}.err"
DETECTION_JSON="${BASE_DIR}/detection-${TS}.json"

lsusb > "${LSUSB_FILE}" 2>&1 || true

if [[ -n "${NUT_SCANNER_BIN}" ]]; then
    timeout 30s "${NUT_SCANNER_BIN}" -U > "${SCANNER_FILE}" 2> "${SCANNER_ERR}" || true
else
    : > "${SCANNER_FILE}"
    echo "nut-scanner niedostępny" > "${SCANNER_ERR}"
fi

"${PYTHON_BIN}" - "${SCANNER_FILE}" "${LSUSB_FILE}" "${DETECTION_JSON}" <<'PY'
import configparser
import json
import pathlib
import re
import sys

scanner = pathlib.Path(sys.argv[1])
lsusb = pathlib.Path(sys.argv[2])
out = pathlib.Path(sys.argv[3])

result = {
    "ambiguous": False,
    "driver": None,
    "port": None,
    "vendorid": None,
    "productid": None,
    "subdriver": None,
    "reason": None,
    "candidate_count": 0,
}

text = scanner.read_text(errors="replace") if scanner.exists() else ""
usbtext = lsusb.read_text(errors="replace") if lsusb.exists() else ""
idx = text.find("[")
ini_text = text[idx:] if idx >= 0 else ""
candidates = []

if ini_text:
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str.lower
    try:
        cp.read_string(ini_text)
        for section in cp.sections():
            d = {k.lower(): v.strip().strip('"').strip("'") for k, v in cp.items(section)}
            if d.get("driver"):
                d["_section"] = section
                candidates.append(d)
    except Exception:
        pass

result["candidate_count"] = len(candidates)

def normhex(value):
    if not value:
        return ""
    chars = re.sub(r"[^0-9a-fA-F]", "", str(value)).lower()
    return chars.zfill(4)[-4:] if chars else ""

def score(c):
    s = 0
    vid = normhex(c.get("vendorid"))
    pid = normhex(c.get("productid"))
    driver = (c.get("driver") or "").lower()
    hay = " ".join(str(v) for v in c.values()).lower()

    # Znany raport VI 2200 STL:
    if vid == "0764" and pid == "0601":
        s += 1000
    if driver == "usbhid-ups":
        s += 100
    if "powerwalker" in hay:
        s += 50
    if "cyber" in hay:
        s += 25
    if "2200" in hay:
        s += 25
    return s

selected = None
reason = None

exact = [
    c for c in candidates
    if normhex(c.get("vendorid")) == "0764"
    and normhex(c.get("productid")) == "0601"
]

if exact:
    exact.sort(key=score, reverse=True)
    selected = exact[0]
    reason = "nut-scanner: dokładny USB ID 0764:0601"
elif len(candidates) == 1:
    selected = candidates[0]
    reason = "nut-scanner: dokładnie jeden kandydat UPS"
elif len(candidates) > 1:
    ranked = sorted(candidates, key=score, reverse=True)
    if score(ranked[0]) > score(ranked[1]):
        selected = ranked[0]
        reason = "nut-scanner: jednoznacznie najwyżej oceniony kandydat"
    else:
        result["ambiguous"] = True
        result["reason"] = "wiele równie prawdopodobnych urządzeń UPS"
else:
    if re.search(r"\b0764:0601\b", usbtext, re.I):
        selected = {
            "driver": "usbhid-ups",
            "port": "auto",
            "vendorid": "0764",
            "productid": "0601",
        }
        reason = "lsusb: znany USB ID 0764:0601"
    else:
        selected = {
            "driver": "usbhid-ups",
            "port": "auto",
        }
        reason = "bezpieczny fallback usbhid-ups/auto; wymagane potwierdzenie upsc"

if selected is not None:
    result["driver"] = selected.get("driver") or "usbhid-ups"
    result["port"] = selected.get("port") or "auto"
    result["vendorid"] = normhex(selected.get("vendorid")) or None
    result["productid"] = normhex(selected.get("productid")) or None
    result["subdriver"] = selected.get("subdriver") or None
    result["reason"] = reason

out.write_text(json.dumps(result, indent=2), encoding="utf-8")
PY

DETECTION_AMBIGUOUS="$("${JQ_BIN}" -r '.ambiguous // false' "${DETECTION_JSON}")"
AUTO_DRIVER="$("${JQ_BIN}" -r '.driver // "usbhid-ups"' "${DETECTION_JSON}")"
AUTO_PORT="$("${JQ_BIN}" -r '.port // "auto"' "${DETECTION_JSON}")"
AUTO_VENDORID="$("${JQ_BIN}" -r '.vendorid // empty' "${DETECTION_JSON}")"
AUTO_PRODUCTID="$("${JQ_BIN}" -r '.productid // empty' "${DETECTION_JSON}")"
AUTO_SUBDRIVER="$("${JQ_BIN}" -r '.subdriver // empty' "${DETECTION_JSON}")"
DETECTION_REASON="$("${JQ_BIN}" -r '.reason // "nieznany"' "${DETECTION_JSON}")"

if [[ "${DETECTION_AMBIGUOUS}" == "true" ]] \
   && [[ -z "${UPS_DRIVER}${UPS_VENDORID}${UPS_PRODUCTID}" ]]; then
    warn "Wykryto wiele równie prawdopodobnych UPS-ów USB."
    warn "Nie będę zgadywał, który ma sterować shutdownem."
    warn "Zapisano: ${SCANNER_FILE}"
    warn "Uruchom później np.:"
    warn "UPS_DRIVER=usbhid-ups UPS_VENDORID=0764 UPS_PRODUCTID=0601 bash $0"
    exit 20
fi

DRIVER="${UPS_DRIVER:-${AUTO_DRIVER}}"
PORT="${UPS_PORT:-${AUTO_PORT}}"
VENDORID="${UPS_VENDORID:-${AUTO_VENDORID}}"
PRODUCTID="${UPS_PRODUCTID:-${AUTO_PRODUCTID}}"
SUBDRIVER="${UPS_SUBDRIVER:-${AUTO_SUBDRIVER}}"

[[ -n "${DRIVER}" ]] || DRIVER="usbhid-ups"
[[ -n "${PORT}" ]] || PORT="auto"
[[ "${DRIVER}" == "usbhid-ups" ]] && PORT="auto"

ok "Sterownik: ${DRIVER}; port: ${PORT}"
info "Detekcja: ${DETECTION_REASON}"
[[ -n "${VENDORID}" ]] && ok "USB VID: ${VENDORID}"
[[ -n "${PRODUCTID}" ]] && ok "USB PID: ${PRODUCTID}"

# ------------------------------------------------------------------------------
# IP hosta
# ------------------------------------------------------------------------------

case "${NUT_LISTEN_IP,,}" in
    off|none|disable)
        PVE_IP=""
        info "Dostęp NUT z LAN został jawnie wyłączony (NUT_LISTEN_IP=${NUT_LISTEN_IP})."
        ;;
    ""|auto)
        PVE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
        if [[ -z "${PVE_IP}" ]]; then
            PVE_IP="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
        fi
        ;;
    *)
        PVE_IP="${NUT_LISTEN_IP}"
        python3 - "${PVE_IP}" <<'PY_IP'
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY_IP
        ;;
esac

if [[ -n "${PVE_IP}" ]]; then
    ok "Adres LAN Proxmoxa dla NUT: ${PVE_IP}"
else
    warn "NUT nie będzie wystawiony do LAN; lokalny control-plane pozostaje na 127.0.0.1:3493."
fi

# ------------------------------------------------------------------------------
# Hasła
# ------------------------------------------------------------------------------

if [[ -f "${BASE_DIR}/credentials.env" ]]; then
    # shellcheck disable=SC1090
    source "${BASE_DIR}/credentials.env"
fi

PRIMARY_PASS="${PRIMARY_PASS:-$(openssl rand -hex 24)}"
HA_PASS="${HA_PASS:-$(openssl rand -hex 24)}"

cat > "${BASE_DIR}/credentials.env" <<EOF
PRIMARY_PASS='${PRIMARY_PASS}'
HA_PASS='${HA_PASS}'
EOF
chmod 0600 "${BASE_DIR}/credentials.env"

# ------------------------------------------------------------------------------
# NUT config
# ------------------------------------------------------------------------------

info "Zapisuję konfigurację NUT..."

atomic_install /etc/nut/nut.conf root nut 0640 <<EOF
${MARKER}
MODE=netserver
EOF

{
    echo "${MARKER}"
    echo "[${UPS_NAME}]"
    echo "    driver = ${DRIVER}"
    echo "    port = ${PORT}"
    echo "    desc = \"${UPS_DESC}\""
    [[ -n "${VENDORID}" ]] && echo "    vendorid = ${VENDORID}"
    [[ -n "${PRODUCTID}" ]] && echo "    productid = ${PRODUCTID}"
    [[ -n "${SUBDRIVER}" ]] && echo "    subdriver = ${SUBDRIVER}"
} | atomic_install /etc/nut/ups.conf root nut 0640

if [[ -n "${PVE_IP}" && "${PVE_IP}" != "127.0.0.1" ]]; then
    atomic_install /etc/nut/upsd.conf root nut 0640 <<EOF
${MARKER}
# Stały lokalny control-plane NUT dla upsmon/narzędzi na hoście:
LISTEN 127.0.0.1 3493
# Port konfigurowalny dotyczy klientów LAN / Home Assistant:
LISTEN ${PVE_IP} ${NUT_PORT}
EOF
else
    atomic_install /etc/nut/upsd.conf root nut 0640 <<EOF
${MARKER}
# Stały lokalny control-plane NUT:
LISTEN 127.0.0.1 3493
EOF
fi

atomic_install /etc/nut/upsd.users root nut 0640 <<EOF
${MARKER}

[proxmoxmon]
    password = ${PRIMARY_PASS}
    upsmon ${UPSMON_ROLE}

[homeassistant]
    password = ${HA_PASS}
EOF

# Celowo bez POWERDOWNFLAG.
atomic_install /etc/nut/upsmon.conf root nut 0640 <<EOF
${MARKER}

RUN_AS_USER nut
MONITOR ${UPS_NAME}@localhost 1 proxmoxmon ${PRIMARY_PASS} ${UPSMON_ROLE}

MINSUPPLIES 1
SHUTDOWNCMD "${SHUTDOWN_BIN} -h now"
NOTIFYCMD ${UPSSCHED_BIN}

POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5

NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
EOF

install -d -o nut -g nut -m 0750 /var/lib/nut/upssched

atomic_install /etc/nut/upssched.conf root nut 0640 <<EOF
${MARKER}

CMDSCRIPT ${LIB_DIR}/event-handler.sh

PIPEFN /var/lib/nut/upssched/upssched.pipe
LOCKFN /var/lib/nut/upssched/upssched.lock

AT ONBATT * EXECUTE power_lost
AT ONBATT * START-TIMER shutdown_on_battery ${SHUTDOWN_DELAY}

AT ONLINE * CANCEL-TIMER shutdown_on_battery
AT ONLINE * EXECUTE power_restored

AT LOWBATT * CANCEL-TIMER shutdown_on_battery
AT LOWBATT * EXECUTE low_battery
AT LOWBATT * EXECUTE emergency_shutdown

AT FSD * EXECUTE fsd_started
AT COMMBAD * EXECUTE communication_lost
AT COMMOK * EXECUTE communication_restored
EOF

# ------------------------------------------------------------------------------
# Event handler
# ------------------------------------------------------------------------------

atomic_install "${LIB_DIR}/event-handler.sh" root nut 0750 <<EOF
#!/usr/bin/env bash
set -u

UPS_NAME="${UPS_NAME}"
UPSC="${UPSC_BIN}"
UPSMON="${UPSMON_BIN}"
LOGGER="${LOGGER_BIN}"
EVENT_LOG="${LOG_DIR}/events.log"
LOCK_FILE="/var/lib/nut/upssched/event-handler.lock"

timestamp() { date -Is; }

snapshot() {
    "\${UPSC}" "\${UPS_NAME}@localhost" 2>/dev/null |
        grep -E '^(ups.status|ups.load|ups.realpower|ups.realpower.nominal|battery.charge|battery.runtime|battery.voltage|input.voltage|output.voltage):' |
        tr '\\n' ' ' |
        sed 's/[[:space:]]*$//'
}

event_log() {
    local message="\$1" snap
    snap="\$(snapshot || true)"

    if [[ -n "\${snap}" ]]; then
        printf '%s | %s | %s\\n' "\$(timestamp)" "\${message}" "\${snap}" >> "\${EVENT_LOG}"
    else
        printf '%s | %s\\n' "\$(timestamp)" "\${message}" >> "\${EVENT_LOG}"
    fi

    "\${LOGGER}" -t NUT-PowerWalker "\${message}"
}

exec 9>"\${LOCK_FILE}"
flock -w 10 9 || exit 0

case "\${1:-}" in
    power_lost)
        event_log "ONBATT: UPS przeszedł na baterię; start timera ${SHUTDOWN_DELAY}s."
        ;;
    power_restored)
        event_log "ONLINE: zasilanie sieciowe wróciło; timer shutdownu anulowany."
        ;;
    low_battery)
        event_log "LOWBATT: UPS zgłosił niski poziom baterii."
        ;;
    shutdown_on_battery)
        event_log "TIMER: ${SHUTDOWN_DELAY}s ciągłej pracy na baterii; rozpoczynam FSD."
        "\${UPSMON}" -c fsd
        ;;
    emergency_shutdown)
        event_log "EMERGENCY: LOWBATT; rozpoczynam natychmiastowy FSD."
        "\${UPSMON}" -c fsd
        ;;
    fsd_started)
        event_log "FSD: rozpoczęto bezpieczne zamykanie hosta."
        ;;
    communication_lost)
        event_log "COMMBAD: utracono komunikację NUT/UPS."
        ;;
    communication_restored)
        event_log "COMMOK: komunikacja NUT/UPS została przywrócona."
        ;;
    *)
        event_log "UNKNOWN: nieznane zdarzenie: \${1:-BRAK}"
        ;;
esac

exit 0
EOF

# ------------------------------------------------------------------------------
# Restart stosu NUT
# ------------------------------------------------------------------------------

atomic_install "${LIB_DIR}/restart-stack.sh" root root 0750 <<'EOF'
#!/usr/bin/env bash
set -u

systemctl stop nut-monitor.service 2>/dev/null || true

if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nut-driver-enumerator\.path'; then
    systemctl enable --now nut-driver-enumerator.path >/dev/null 2>&1 || true
    systemctl restart nut-driver-enumerator.service >/dev/null 2>&1 || true
    if command -v upsdrvsvcctl >/dev/null 2>&1; then
        upsdrvsvcctl resync >/dev/null 2>&1 || true
    fi
else
    if command -v upsdrvctl >/dev/null 2>&1; then
        upsdrvctl stop >/dev/null 2>&1 || true
        sleep 1
        upsdrvctl start
    fi
fi

sleep 2
systemctl restart nut-server.service
sleep 2
EOF

# ------------------------------------------------------------------------------
# MQTT bridge
# ------------------------------------------------------------------------------

atomic_install "${LIB_DIR}/mqtt_bridge.py" root nut 0750 <<'PY'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

try:
    import paho.mqtt.client as mqtt
except Exception as exc:
    print(f"Brak paho-mqtt: {exc}", file=sys.stderr)
    raise SystemExit(2)

DEFAULT_CONFIG = "/etc/nut/nut-mqtt.json"
RUNTIME_FILE = pathlib.Path("/var/lib/nut/nut-mqtt-runtime.json")
LOG_FILE = pathlib.Path("/var/log/nut-powerwalker/mqtt.log")

connected = threading.Event()
need_discovery = threading.Event()

def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")

def load_config(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def load_runtime():
    try:
        return json.loads(RUNTIME_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}

def save_runtime(data):
    try:
        tmp = RUNTIME_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        os.chmod(tmp, 0o640)
        os.replace(tmp, RUNTIME_FILE)
    except Exception:
        pass

def log_event(message, force=False):
    rt = load_runtime()
    key = hashlib.sha256(message.encode("utf-8", errors="replace")).hexdigest()
    now = time.time()

    if not force and rt.get("last_log_key") == key and now - float(rt.get("last_log_ts", 0)) < 900:
        return

    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"{now_iso()} | {message}\n")

    rt["last_log_key"] = key
    rt["last_log_ts"] = now
    save_runtime(rt)

def read_upsc(ups_name):
    cp = subprocess.run(
        ["upsc", f"{ups_name}@localhost"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or cp.stdout.strip() or "upsc failed")

    raw = {}
    for line in cp.stdout.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            raw[k.strip()] = v.strip()
    return raw

def num(raw, key):
    v = raw.get(key)
    if v is None or v == "":
        return None
    try:
        f = float(v)
        return int(f) if f.is_integer() else f
    except Exception:
        return None

def normalize(raw):
    s = {
        "timestamp": now_iso(),
        "ups_status": raw.get("ups.status"),
        "ups_model": raw.get("ups.model") or raw.get("device.model"),
        "ups_manufacturer": raw.get("ups.mfr") or raw.get("device.mfr"),
        "battery_charge": num(raw, "battery.charge"),
        "battery_runtime": num(raw, "battery.runtime"),
        "battery_voltage": num(raw, "battery.voltage"),
        "ups_load": num(raw, "ups.load"),
        "ups_realpower": num(raw, "ups.realpower"),
        "ups_realpower_nominal": num(raw, "ups.realpower.nominal"),
        "input_voltage": num(raw, "input.voltage"),
        "input_frequency": num(raw, "input.frequency"),
        "output_voltage": num(raw, "output.voltage"),
        "output_voltage_nominal": num(raw, "output.voltage.nominal"),
        "output_frequency": num(raw, "output.frequency"),
        "battery_charge_low": num(raw, "battery.charge.low"),
        "battery_runtime_low": num(raw, "battery.runtime.low"),
        "ups_delay_start": num(raw, "ups.delay.start"),
        "ups_delay_shutdown": num(raw, "ups.delay.shutdown"),
    }

    tokens = set((s.get("ups_status") or "").split())
    s["on_battery"] = "OB" in tokens
    s["low_battery"] = "LB" in tokens
    s["online"] = "OL" in tokens

    # Znany przypadek raportowania absurdalnej wartości output.voltage
    # przez część urządzeń 0764:0601. Nie udajemy, że 2.6 V jest poprawne.
    ov = s.get("output_voltage")
    ovn = s.get("output_voltage_nominal")
    if ov is not None and ovn is not None and ovn >= 100 and ov < 50:
        s["output_voltage_suspicious"] = ov
        s["output_voltage"] = None

    if s["ups_realpower"] is None and s["ups_load"] is not None and s["ups_realpower_nominal"] is not None:
        s["estimated_power_w"] = round(s["ups_load"] * s["ups_realpower_nominal"] / 100.0, 1)
    else:
        s["estimated_power_w"] = None

    return s

def clean(d):
    if isinstance(d, dict):
        return {k: clean(v) for k, v in d.items() if v is not None}
    if isinstance(d, list):
        return [clean(v) for v in d]
    return d

def make_client(cfg):
    cid = cfg.get("client_id") or "qtronic-nut-powerwalker"

    try:
        client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=cid,
            protocol=mqtt.MQTTv311,
        )
    except Exception:
        client = mqtt.Client(client_id=cid, protocol=mqtt.MQTTv311)

    if cfg.get("username"):
        client.username_pw_set(cfg["username"], cfg.get("password", ""))

    if cfg.get("tls"):
        client.tls_set()

    availability_topic = f"{cfg['topic_prefix']}/availability"
    client.will_set(availability_topic, payload="offline", qos=1, retain=True)

    def on_connect(client, userdata, flags, rc, *args):
        try:
            good = int(rc) == 0
        except Exception:
            good = str(rc).lower() in ("0", "success")
        if good:
            connected.set()
            need_discovery.set()
        else:
            connected.clear()

    def on_disconnect(client, userdata, *args):
        connected.clear()

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    return client

def publish(client, topic, payload, qos=0, retain=False):
    info = client.publish(topic, payload=payload, qos=qos, retain=retain)
    try:
        info.wait_for_publish(timeout=5)
    except TypeError:
        info.wait_for_publish()
    if getattr(info, "rc", mqtt.MQTT_ERR_SUCCESS) != mqtt.MQTT_ERR_SUCCESS:
        raise RuntimeError(f"MQTT publish rc={info.rc}, topic={topic}")

def device(cfg, state):
    return clean({
        "identifiers": [cfg["device_id"]],
        "name": cfg.get("device_name", "PowerWalker UPS"),
        "manufacturer": state.get("ups_manufacturer") or "PowerWalker",
        "model": state.get("ups_model") or "UPS NUT",
    })

def publish_discovery(client, cfg, state):
    dp = cfg.get("discovery_prefix", "homeassistant")
    st = f"{cfg['topic_prefix']}/state"
    av = f"{cfg['topic_prefix']}/availability"
    dev = device(cfg, state)
    expire = max(int(cfg.get("interval", 15)) * 4, 60)

    defs = [
        ("battery_charge", "Bateria", "%", "battery", "measurement", None),
        ("battery_runtime", "Pozostały czas baterii", "s", "duration", "measurement", None),
        ("battery_voltage", "Napięcie baterii", "V", "voltage", "measurement", "diagnostic"),
        ("ups_load", "Obciążenie UPS", "%", None, "measurement", None),
        ("ups_realpower", "Moc rzeczywista UPS", "W", "power", "measurement", None),
        ("estimated_power_w", "Szacowana moc obciążenia", "W", "power", "measurement", "diagnostic"),
        ("ups_realpower_nominal", "Moc znamionowa UPS", "W", "power", "measurement", "diagnostic"),
        ("input_voltage", "Napięcie wejściowe", "V", "voltage", "measurement", None),
        ("input_frequency", "Częstotliwość wejściowa", "Hz", "frequency", "measurement", "diagnostic"),
        ("output_voltage", "Napięcie wyjściowe", "V", "voltage", "measurement", None),
        ("output_frequency", "Częstotliwość wyjściowa", "Hz", "frequency", "measurement", "diagnostic"),
        ("battery_charge_low", "Próg niskiej baterii", "%", "battery", "measurement", "diagnostic"),
        ("battery_runtime_low", "Próg niskiego czasu baterii", "s", "duration", "measurement", "diagnostic"),
        ("ups_delay_start", "Opóźnienie startu UPS", "s", "duration", "measurement", "diagnostic"),
        ("ups_delay_shutdown", "Opóźnienie wyłączenia UPS", "s", "duration", "measurement", "diagnostic"),
    ]

    if state.get("ups_status") is not None:
        payload = clean({
            "name": "Status",
            "unique_id": f"{cfg['device_id']}_status",
            "state_topic": st,
            "value_template": "{{ value_json.ups_status }}",
            "availability_topic": av,
            "payload_available": "online",
            "payload_not_available": "offline",
            "expire_after": expire,
            "entity_category": "diagnostic",
            "device": dev,
        })
        publish(client, f"{dp}/sensor/{cfg['device_id']}_status/config",
                json.dumps(payload, separators=(",", ":")), qos=1, retain=True)

    for key, name, unit, dc, sc, category in defs:
        if state.get(key) is None:
            continue
        payload = clean({
            "name": name,
            "unique_id": f"{cfg['device_id']}_{key}",
            "state_topic": st,
            "value_template": "{{ value_json." + key + " }}",
            "unit_of_measurement": unit,
            "device_class": dc,
            "state_class": sc,
            "entity_category": category,
            "availability_topic": av,
            "payload_available": "online",
            "payload_not_available": "offline",
            "expire_after": expire,
            "device": dev,
        })
        publish(client, f"{dp}/sensor/{cfg['device_id']}_{key}/config",
                json.dumps(payload, separators=(",", ":")), qos=1, retain=True)

    binaries = [
        ("on_battery", "Praca na baterii", "{{ 'ON' if value_json.on_battery else 'OFF' }}", None, None),
        ("low_battery", "Niski poziom baterii", "{{ 'ON' if value_json.low_battery else 'OFF' }}", "problem", "diagnostic"),
        ("online", "Zasilanie sieciowe", "{{ 'ON' if value_json.online else 'OFF' }}", "power", None),
    ]

    for key, name, template, dc, category in binaries:
        payload = clean({
            "name": name,
            "unique_id": f"{cfg['device_id']}_{key}",
            "state_topic": st,
            "value_template": template,
            "payload_on": "ON",
            "payload_off": "OFF",
            "availability_topic": av,
            "payload_available": "online",
            "payload_not_available": "offline",
            "expire_after": expire,
            "device_class": dc,
            "entity_category": category,
            "device": dev,
        })
        publish(client, f"{dp}/binary_sensor/{cfg['device_id']}_{key}/config",
                json.dumps(payload, separators=(",", ":")), qos=1, retain=True)

def test(cfg):
    client = make_client(cfg)
    try:
        client.connect(cfg["host"], int(cfg.get("port", 1883)), 20)
        client.loop_start()
        if not connected.wait(10):
            raise RuntimeError("broker nie potwierdził połączenia w 10 s")
        publish(client, f"{cfg['topic_prefix']}/test",
                json.dumps({"ok": True, "timestamp": now_iso()}), qos=1, retain=False)
        print("MQTT TEST OK")
        return 0
    except Exception as exc:
        print(f"MQTT TEST FAILED: {exc}", file=sys.stderr)
        return 1
    finally:
        try:
            client.disconnect()
            client.loop_stop()
        except Exception:
            pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--test", action="store_true")
    args = ap.parse_args()

    cfg = load_config(args.config)
    for key in ("host", "port", "ups_name", "topic_prefix", "device_id"):
        if key not in cfg:
            print(f"Brak pola {key} w konfiguracji MQTT.", file=sys.stderr)
            return 2

    if args.test:
        return test(cfg)

    client = make_client(cfg)
    client.connect_async(cfg["host"], int(cfg.get("port", 1883)), 30)
    client.loop_start()

    interval = max(int(cfg.get("interval", 15)), 5)
    last_status = object()
    last_upsc_ok = None
    last_keys = None

    while True:
        try:
            raw = read_upsc(cfg["ups_name"])
            state = normalize(raw)
            upsc_ok = True
        except Exception as exc:
            state = None
            upsc_ok = False
            if last_upsc_ok is not False:
                log_event(f"NUT read failed: {exc}", force=True)

        if connected.is_set():
            try:
                if not upsc_ok:
                    publish(client, f"{cfg['topic_prefix']}/availability",
                            "offline", qos=1, retain=True)
                else:
                    keys = tuple(sorted(k for k, v in state.items() if v is not None))
                    if need_discovery.is_set() or keys != last_keys:
                        publish_discovery(client, cfg, state)
                        need_discovery.clear()
                        last_keys = keys

                    publish(client, f"{cfg['topic_prefix']}/availability",
                            "online", qos=1, retain=True)
                    publish(client, f"{cfg['topic_prefix']}/state",
                            json.dumps(state, separators=(",", ":")),
                            qos=0, retain=False)

                    status = state.get("ups_status")
                    if status != last_status:
                        log_event(f"UPS status: {last_status!r} -> {status!r}", force=True)
                        last_status = status

                    if state.get("output_voltage_suspicious") is not None:
                        log_event(
                            "Pominięto podejrzane output.voltage="
                            f"{state['output_voltage_suspicious']} V."
                        )
            except Exception as exc:
                log_event(f"MQTT publish error: {exc}")

        if upsc_ok and last_upsc_ok is False:
            log_event("Odczyt NUT został przywrócony.", force=True)

        last_upsc_ok = upsc_ok
        time.sleep(interval)

if __name__ == "__main__":
    raise SystemExit(main())
PY

# ------------------------------------------------------------------------------
# MQTT systemd service
# ------------------------------------------------------------------------------

cat > /etc/systemd/system/nut-mqtt.service <<EOF
[Unit]
Description=Q-Tronic NUT to MQTT bridge
After=network-online.target nut-server.service
Wants=network-online.target
Requires=nut-server.service

[Service]
Type=simple
User=nut
Group=nut
ExecStart=${PYTHON_BIN} ${LIB_DIR}/mqtt_bridge.py --config /etc/nut/nut-mqtt.json
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/nut ${LOG_DIR}
ReadOnlyPaths=/etc/nut/nut-mqtt.json

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 /etc/systemd/system/nut-mqtt.service
systemctl daemon-reload

# ------------------------------------------------------------------------------
# Narzędzia administracyjne
# ------------------------------------------------------------------------------

atomic_install "${LIB_DIR}/nut-status.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set -u

UPS="${UPS_NAME}@localhost"

if ! RAW="\$(${UPSC_BIN} "\${UPS}" 2>&1)"; then
    if [[ -f /etc/nut/qtronic-bypass-state.env ]]; then
        echo "============================================================"
        echo " Q-Tronic | NUT / PowerWalker"
        echo "============================================================"
        echo "BYPASS:          AKTYWNY"
        echo "UPS:             celowo może być fizycznie odłączony"
        echo "Komunikacja:     brak (oczekiwane w BYPASS po odpięciu UPS)"
        echo "nut-monitor:     \$(systemctl is-active nut-monitor.service 2>/dev/null || true)"
        echo "nut-server:      \$(systemctl is-active nut-server.service 2>/dev/null || true)"
        echo "nut-mqtt:        \$(systemctl is-active nut-mqtt.service 2>/dev/null || true)"
        echo "------------------------------------------------------------"
        echo "Po ponownym podłączeniu UPS uruchom: nut-config resume"
        echo "============================================================"
        exit 0
    fi
    echo "BŁĄD: brak komunikacji z \${UPS}"
    echo "\${RAW}"
    echo "Jeśli UPS został odłączony celowo, użyj wcześniej: nut-config bypass enable"
    exit 1
fi

getv() {
    printf '%s\n' "\${RAW}" | sed -n "s/^\$1: //p" | head -n1
}

STATUS="\$(getv ups.status)"
CHARGE="\$(getv battery.charge)"
RUNTIME="\$(getv battery.runtime)"
LOAD="\$(getv ups.load)"
REALPOWER="\$(getv ups.realpower)"
NOMINAL="\$(getv ups.realpower.nominal)"
INPUT="\$(getv input.voltage)"
OUTPUT="\$(getv output.voltage)"
MODEL="\$(getv ups.model)"

echo "============================================================"
echo " Q-Tronic | NUT / PowerWalker"
echo "============================================================"
echo "UPS:             ${UPS_NAME}"
echo "Model:           \${MODEL:-brak danych}"
echo "Status:          \${STATUS:-brak danych}"
echo "Bateria:         \${CHARGE:-?} %"
echo "Runtime:         \${RUNTIME:-?} s"
echo "Obciążenie:      \${LOAD:-?} %"
echo "Moc:             \${REALPOWER:-brak} W"
echo "Moc znamionowa:  \${NOMINAL:-brak} W"
echo "Napięcie wej.:   \${INPUT:-brak} V"
echo "Napięcie wyj.:   \${OUTPUT:-brak} V"
echo "BYPASS:          \$([[ -f /etc/nut/qtronic-bypass-state.env ]] && echo AKTYWNY || echo nie)"
echo "------------------------------------------------------------"
echo "nut-monitor:     \$(systemctl is-active nut-monitor.service 2>/dev/null || true)"
echo "nut-server:      \$(systemctl is-active nut-server.service 2>/dev/null || true)"
echo "nut-mqtt:        \$(systemctl is-active nut-mqtt.service 2>/dev/null || true)"
echo "============================================================"
EOF

atomic_install "${LIB_DIR}/nut-watch.sh" root root 0755 <<EOF
#!/usr/bin/env bash
exec watch -n 1 '${LIB_DIR}/nut-status.sh'
EOF

atomic_install "${LIB_DIR}/nut-capabilities.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set +e
echo "=== UPSC ==="
${UPSC_BIN} ${UPS_NAME}@localhost
echo
echo "=== UPSCMD -L ==="
${UPSCMD_BIN} -l ${UPS_NAME}@localhost
echo
echo "=== UPSRW ==="
${UPSRW_BIN} ${UPS_NAME}@localhost
EOF

atomic_install "${LIB_DIR}/nut-phase2-check.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set +e
CMDS="\$(${UPSCMD_BIN} -l ${UPS_NAME}@localhost 2>&1)"
RW="\$(${UPSRW_BIN} ${UPS_NAME}@localhost 2>&1)"

echo "=== Możliwości odcinania / restartu UPS ==="
echo "\${CMDS}"
echo
echo "=== Zmienne zapisywalne ==="
echo "\${RW}"
echo

if printf '%s\n' "\${CMDS}" | grep -qx 'shutdown.return'; then
    echo "[OK] UPS raportuje shutdown.return."
else
    echo "[INFO] shutdown.return NIE został znaleziony."
fi

if printf '%s\n' "\${CMDS}" | grep -qx 'load.off.delay'; then
    echo "[OK] UPS raportuje load.off.delay."
fi

if printf '%s\n' "\${CMDS}" | grep -qx 'load.on.delay'; then
    echo "[OK] UPS raportuje load.on.delay."
fi

if printf '%s\n' "\${RW}" | grep -q 'ups.delay.start'; then
    echo "[OK] UPS raportuje ups.delay.start."
fi

if printf '%s\n' "\${RW}" | grep -q 'ups.delay.shutdown'; then
    echo "[OK] UPS raportuje ups.delay.shutdown."
fi

echo
echo "UWAGA: to polecenie NICZEGO nie przełącza. Tylko odczytuje możliwości."
EOF

atomic_install "${LIB_DIR}/nut-logs.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set +e

LINES="\${1:-100}"
case "\${LINES}" in
  ''|*[!0-9]*) LINES=100 ;;
esac
(( LINES > 500 )) && LINES=500

echo "=== events.log ==="
tail -n "\${LINES}" ${LOG_DIR}/events.log 2>/dev/null || true
echo
echo "=== mqtt.log ==="
tail -n "\${LINES}" ${LOG_DIR}/mqtt.log 2>/dev/null || true
echo
echo "=== journal NUT ==="
journalctl --no-pager -n "\${LINES}" \
  -u nut-server.service \
  -u nut-monitor.service \
  -u nut-mqtt.service 2>/dev/null || true
EOF

atomic_install "${LIB_DIR}/nut-test-guide.sh" root root 0755 <<EOF
#!/usr/bin/env bash
cat <<'TXT'
============================================================
 BEZPIECZNY PIERWSZY TEST
 Autor konfiguracji: Q-Tronic
============================================================

0. Sprawdź, że power-cycle jest WYŁĄCZONY:
   nut-config powercycle status

1. W pierwszym SSH:
   nut-watch

2. W drugim SSH:
   nut-logs 100

   albo podgląd na żywo:
   journalctl -f -u nut-monitor.service -u nut-server.service

3. Wyciągnij ZE ŚCIANY przewód zasilający UPS-a.
   NIE wyciągaj przewodu serwera z UPS-a.

4. Oczekiwany status:
   OL  -> normalna sieć
   OB  -> praca na baterii

5. Przy pierwszym teście przywróć zasilanie PRZED upływem
   skonfigurowanego czasu shutdownu.

6. Sprawdź, czy wrócił OL i czy timer został anulowany.

NIE URUCHAMIAJ "dla testu":
   upsmon -c fsd

NIE URUCHAMIAJ bez osobnej weryfikacji:
   shutdown.return
   shutdown.stayoff
   load.off
   load.off.delay

Te komendy mogą naprawdę zatrzymać host lub odciąć wyjście UPS.

Jeśli chcesz celowo wyjąć UPS z układu i zasilać serwer bezpośrednio
z sieci, NIE odłączaj po prostu USB. Użyj:
   nut-config bypass enable
A po ponownym podłączeniu:
   nut-config resume
============================================================
TXT
EOF

atomic_install "${LIB_DIR}/nut-restart.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/nut/qtronic-bypass-state.env ]]; then
    echo "BYPASS jest aktywny. Nie uzbrajam monitora przez nut-restart." >&2
    echo "Po ponownym podłączeniu UPS użyj: nut-config resume" >&2
    exit 20
fi

${LIB_DIR}/restart-stack.sh

if ! ${UPSC_BIN} ${UPS_NAME}@localhost >/tmp/nut-restart-upsc.\$\$ 2>&1; then
    echo "Sterownik/server uruchomiony, ale UPS nie odpowiada:"
    cat /tmp/nut-restart-upsc.\$\$
    rm -f /tmp/nut-restart-upsc.\$\$
    systemctl disable --now nut-monitor.service 2>/dev/null || true
    exit 1
fi

if ! grep -q '^ups.status:' /tmp/nut-restart-upsc.\$\$; then
    echo "UPS odpowiada, ale brak ups.status. Monitor pozostaje wyłączony."
    rm -f /tmp/nut-restart-upsc.\$\$
    systemctl disable --now nut-monitor.service 2>/dev/null || true
    exit 2
fi

STATUS="\$(sed -n 's/^ups.status: //p' /tmp/nut-restart-upsc.\$\$ | head -n1)"

if ! printf '%s\n' "\${STATUS}" | grep -qw 'OL'; then
    echo "UPS odpowiada, ale nie raportuje aktualnie OL (On Line)."
    echo "Aktualny status: \${STATUS:-BRAK}"
    echo "Dla bezpieczeństwa nut-monitor pozostaje WYŁĄCZONY."
    echo "Gdy zasilanie sieciowe będzie stabilne, uruchom ponownie: nut-restart"
    rm -f /tmp/nut-restart-upsc.\$\$
    systemctl disable --now nut-monitor.service 2>/dev/null || true
    exit 3
fi

if printf '%s\n' "\${STATUS}" | grep -qw 'OB'; then
    echo "UPS jednocześnie raportuje OB. Nie uzbrajam monitora."
    rm -f /tmp/nut-restart-upsc.\$\$
    systemctl disable --now nut-monitor.service 2>/dev/null || true
    exit 4
fi

rm -f /tmp/nut-restart-upsc.\$\$
systemctl enable --now nut-monitor.service
${LIB_DIR}/nut-status.sh
EOF

atomic_install "${LIB_DIR}/nut-report.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set +e

OUT="${REPORT_DIR}/nut-report-\$(date +%Y%m%d-%H%M%S).txt"

section() {
    echo
    echo "============================================================"
    echo "### \$1"
    echo "============================================================"
}

{
    echo "Q-Tronic NUT / Proxmox diagnostic report"
    echo "Generated: \$(date -Is)"

    section "PROXMOX"
    pveversion -v 2>&1 || true

    section "SYSTEM"
    uname -a
    cat /etc/os-release

    section "NUT VERSION"
    upsmon -V 2>&1 || true

    section "NETWORK"
    ip -brief -4 addr
    ip -4 route
    ss -lntp | grep -E ':${NUT_PORT}\\b' || true

    section "USB"
    lsusb

    section "NUT-SCANNER USB"
    timeout 30s nut-scanner -U 2>&1 || true

    section "/etc/nut/ups.conf"
    cat /etc/nut/ups.conf 2>&1 || true

    section "/etc/nut/upsd.conf"
    cat /etc/nut/upsd.conf 2>&1 || true

    section "/etc/nut/upsmon.conf - HASŁO UKRYTE"
    sed -E 's#^(MONITOR[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+)[[:space:]]+[^[:space:]]+([[:space:]]+(primary|master).*)#\\1 ***REDACTED***\\2#' /etc/nut/upsmon.conf 2>&1 || true

    section "/etc/nut/upssched.conf"
    cat /etc/nut/upssched.conf 2>&1 || true

    section "SYSTEMD"
    systemctl --no-pager --type=service --all | grep -Ei 'nut|mqtt' || true

    section "NUT SERVER"
    systemctl --no-pager --full status nut-server.service 2>&1 || true

    section "NUT MONITOR"
    systemctl --no-pager --full status nut-monitor.service 2>&1 || true

    section "NUT MQTT"
    systemctl --no-pager --full status nut-mqtt.service 2>&1 || true

    section "UPSC"
    upsc ${UPS_NAME}@localhost 2>&1 || true

    section "UPSCMD -L"
    upscmd -l ${UPS_NAME}@localhost 2>&1 || true

    section "UPSRW"
    upsrw ${UPS_NAME}@localhost 2>&1 || true

    section "EVENT LOG - LAST 100"
    tail -n 100 ${LOG_DIR}/events.log 2>&1 || true

    section "MQTT LOG - LAST 100"
    tail -n 100 ${LOG_DIR}/mqtt.log 2>&1 || true

    section "JOURNAL - LAST 150"
    journalctl --no-pager -n 150 \
      -u nut-server.service \
      -u nut-monitor.service \
      -u nut-mqtt.service 2>&1 || true

} > "\${OUT}"

chmod 0600 "\${OUT}"
echo "Raport zapisany: \${OUT}"
echo
cat "\${OUT}"
EOF

atomic_install "${LIB_DIR}/nut-ha-info.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set -u
source ${BASE_DIR}/credentials.env

echo "============================================================"
echo " Home Assistant / NUT"
echo " Autor: Q-Tronic"
echo "============================================================"
echo "Host:      ${PVE_IP:-127.0.0.1}"
echo "Port:      ${NUT_PORT}"
echo "User:      homeassistant"
echo "Password:  \${HA_PASS}"
echo "UPS name:  ${UPS_NAME}"
echo "------------------------------------------------------------"
echo "HA:"
echo "Ustawienia -> Urządzenia i usługi -> Dodaj integrację"
echo "-> Network UPS Tools (NUT)"
echo
if [[ -f /etc/nut/nut-mqtt.json ]]; then
    echo "MQTT: skonfigurowane"
    jq 'del(.password)' /etc/nut/nut-mqtt.json 2>/dev/null || true
else
    echo "MQTT: nieskonfigurowane"
    echo "Uruchom: nut-mqtt-config"
fi
echo "============================================================"
EOF

# MQTT konfigurator
atomic_install "${LIB_DIR}/nut-mqtt-config.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ -f /etc/nut/qtronic-bypass-state.env ]]; then
    echo "BYPASS jest aktywny. Nie włączam MQTT bez aktywnego UPS." >&2
    echo "Po ponownym podłączeniu UPS użyj: nut-config resume" >&2
    exit 20
fi

CFG="/etc/nut/nut-mqtt.json"
HOSTNAME_ID="\$(hostname -s | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')"
DEVICE_ID="qtronic_\${HOSTNAME_ID}_${UPS_NAME}"
TOPIC_DEFAULT="qtronic/proxmox/${UPS_NAME}"

MQTT_HOST="\${MQTT_HOST:-}"
MQTT_PORT="\${MQTT_PORT:-1883}"
MQTT_USER="\${MQTT_USER:-}"
MQTT_PASS="\${MQTT_PASS:-}"
MQTT_TLS="\${MQTT_TLS:-0}"
MQTT_TOPIC="\${MQTT_TOPIC:-\${TOPIC_DEFAULT}}"
MQTT_INTERVAL="\${MQTT_INTERVAL:-15}"

if [[ -z "\${MQTT_HOST}" ]]; then
    read -r -p "Adres/IP brokera MQTT: " MQTT_HOST
fi

[[ -n "\${MQTT_HOST}" ]] || { echo "Brak hosta MQTT."; exit 1; }

if [[ -z "\${MQTT_PORT}" ]]; then
    read -r -p "Port MQTT [1883]: " MQTT_PORT
    MQTT_PORT="\${MQTT_PORT:-1883}"
fi

if [[ -z "\${MQTT_USER}" ]]; then
    read -r -p "Użytkownik MQTT [puste = bez uwierzytelnienia]: " MQTT_USER
fi

if [[ -n "\${MQTT_USER}" && -z "\${MQTT_PASS}" ]]; then
    read -r -s -p "Hasło MQTT: " MQTT_PASS
    echo
fi

case "\${MQTT_TLS}" in
    1|true|TRUE|yes|YES) TLS_JSON=true ;;
    *) TLS_JSON=false ;;
esac

python3 - "\${CFG}" "\${MQTT_HOST}" "\${MQTT_PORT}" "\${MQTT_USER}" "\${MQTT_PASS}" "\${MQTT_TOPIC}" "\${DEVICE_ID}" "\${MQTT_INTERVAL}" "\${TLS_JSON}" <<'PY'
import json
import os
import sys

path, host, port, user, password, topic, device_id, interval, tls = sys.argv[1:]
cfg = {
    "host": host,
    "port": int(port),
    "username": user,
    "password": password,
    "tls": tls.lower() == "true",
    "ups_name": "${UPS_NAME}",
    "topic_prefix": topic.rstrip("/"),
    "discovery_prefix": "homeassistant",
    "device_id": device_id,
    "device_name": "PowerWalker UPS",
    "client_id": device_id,
    "interval": max(int(interval), 5),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
os.chmod(tmp, 0o640)
os.replace(tmp, path)
PY

chown root:nut "\${CFG}"
chmod 0640 "\${CFG}"

echo "Testuję połączenie MQTT..."
if ! ${PYTHON_BIN} ${LIB_DIR}/mqtt_bridge.py --config "\${CFG}" --test; then
    echo
    echo "Test MQTT NIE powiódł się."
    echo "Usługa nut-mqtt pozostaje wyłączona."
    systemctl disable --now nut-mqtt.service >/dev/null 2>&1 || true
    exit 2
fi

systemctl daemon-reload
systemctl enable --now nut-mqtt.service
sleep 2

echo
echo "MQTT skonfigurowane."
echo "Status: systemctl --no-pager --full status nut-mqtt.service"
echo "Logi:   nut-logs 100"
echo "Dane:   cat \${CFG} | jq 'del(.password)'"
EOF

atomic_install "${LIB_DIR}/nut-mqtt-disable.sh" root root 0755 <<'EOF'
#!/usr/bin/env bash
set -e
systemctl disable --now nut-mqtt.service 2>/dev/null || true
echo "Most NUT -> MQTT wyłączony. Konfiguracja /etc/nut/nut-mqtt.json została zachowana."
EOF

# Rollback
atomic_install "${LIB_DIR}/rollback-last-backup.sh" root root 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/nut/qtronic-bypass-state.env ]]; then
    echo "BYPASS jest aktywny. Nie wykonuję pełnego rollbacku instalatora w tym trybie." >&2
    echo "Najpierw podłącz UPS i uruchom: nut-config resume" >&2
    exit 20
fi

BASE="${BASE_DIR}"
BACKUP="\$(cat "\${BASE}/LAST_BACKUP")"

[[ -d "\${BACKUP}" ]] || { echo "Brak backupu: \${BACKUP}"; exit 1; }

systemctl disable --now nut-mqtt.service 2>/dev/null || true
systemctl stop nut-monitor.service 2>/dev/null || true
systemctl stop nut-server.service 2>/dev/null || true

if [[ -d "\${BACKUP}/nut" ]]; then
    rm -rf /etc/nut
    cp -a "\${BACKUP}/nut" /etc/nut
else
    echo "Przed instalacją nie było /etc/nut."
fi

systemctl daemon-reload

if grep -q 'nut-server.service.*active=active' "\${BACKUP}/service-state.txt" 2>/dev/null; then
    systemctl restart nut-server.service 2>/dev/null || true
fi

if grep -q 'nut-monitor.service.*active=active' "\${BACKUP}/service-state.txt" 2>/dev/null; then
    systemctl restart nut-monitor.service 2>/dev/null || true
fi

echo "Przywrócono backup: \${BACKUP}"
EOF

# Symlinki komend
ln -sf "${LIB_DIR}/nut-status.sh" /usr/local/sbin/nut-status
ln -sf "${LIB_DIR}/nut-watch.sh" /usr/local/sbin/nut-watch
ln -sf "${LIB_DIR}/nut-capabilities.sh" /usr/local/sbin/nut-capabilities
ln -sf "${LIB_DIR}/nut-phase2-check.sh" /usr/local/sbin/nut-phase2-check
ln -sf "${LIB_DIR}/nut-logs.sh" /usr/local/sbin/nut-logs
ln -sf "${LIB_DIR}/nut-test-guide.sh" /usr/local/sbin/nut-test-guide
ln -sf "${LIB_DIR}/nut-restart.sh" /usr/local/sbin/nut-restart
ln -sf "${LIB_DIR}/nut-report.sh" /usr/local/sbin/nut-report
ln -sf "${LIB_DIR}/nut-ha-info.sh" /usr/local/sbin/nut-ha-info
ln -sf "${LIB_DIR}/nut-mqtt-config.sh" /usr/local/sbin/nut-mqtt-config
ln -sf "${LIB_DIR}/nut-mqtt-disable.sh" /usr/local/sbin/nut-mqtt-disable
ln -sf "${LIB_DIR}/rollback-last-backup.sh" /usr/local/sbin/nut-rollback

# ------------------------------------------------------------------------------
# Start driver + upsd. Monitor dopiero po walidacji UPS.
# ------------------------------------------------------------------------------

info "Uruchamiam sterownik i serwer NUT..."
systemctl daemon-reload
systemctl disable --now nut-monitor.service >/dev/null 2>&1 || true

if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^nut-driver-enumerator\.path'; then
    systemctl enable --now nut-driver-enumerator.path >/dev/null 2>&1 || true
    systemctl restart nut-driver-enumerator.service >/dev/null 2>&1 || true
    if [[ -n "${UPSDRVSVCCTL_BIN}" ]]; then
        "${UPSDRVSVCCTL_BIN}" resync >/dev/null 2>&1 || true
    fi
else
    if [[ -n "${UPSDRVCTL_BIN}" ]]; then
        "${UPSDRVCTL_BIN}" stop >/dev/null 2>&1 || true
        sleep 1
        "${UPSDRVCTL_BIN}" start || true
    fi
fi

sleep 3
systemctl enable nut-server.service >/dev/null 2>&1 || true

if ! systemctl restart nut-server.service; then
    warn "nut-server nie uruchomił się. Nie uzbrajam monitora."
    warn "Użyj: nut-report"
    exit 30
fi

sleep 3

VALIDATION="${BASE_DIR}/validation-${TS}.txt"
UPS_OK=0

if timeout 15s "${UPSC_BIN}" "${UPS_NAME}@localhost" > "${VALIDATION}" 2>&1 \
   && grep -q '^ups.status:' "${VALIDATION}"; then
    CURRENT_STATUS="$(sed -n 's/^ups.status: //p' "${VALIDATION}" | head -n1)"
    if printf '%s\n' "${CURRENT_STATUS}" | grep -qw 'OL' \
       && ! printf '%s\n' "${CURRENT_STATUS}" | grep -qw 'OB'; then
        UPS_OK=1
    else
        warn "UPS odpowiada, ale aktualny status to: ${CURRENT_STATUS:-BRAK}"
        warn "Pierwsze uzbrojenie monitora wymaga stabilnego OL (On Line)."
        warn "Gdy sieć będzie stabilna, uruchom: nut-restart"
    fi
fi

if (( UPS_OK == 1 )); then
    ok "UPS odpowiada, raportuje ups.status i jest stabilnie OL."
    systemctl enable --now nut-monitor.service
    sleep 2

    if ! systemctl is-active --quiet nut-monitor.service; then
        warn "nut-monitor nie jest aktywny mimo poprawnego odczytu UPS."
        warn "Monitor został wyłączony. Uruchom: nut-report"
        systemctl disable --now nut-monitor.service 2>/dev/null || true
        UPS_OK=0
    fi
else
    warn "Nie udało się potwierdzić poprawnej komunikacji przez upsc."
    warn "AUTOMATYCZNY SHUTDOWN POZOSTAJE WYŁĄCZONY."
    warn "To jest celowe zabezpieczenie."
    warn "Po podłączeniu/poprawieniu UPS uruchom: nut-restart"
fi

# ------------------------------------------------------------------------------
# Pliki informacyjne
# ------------------------------------------------------------------------------

cat > "${BASE_DIR}/HA-SETUP.txt" <<EOF
Q-Tronic - Home Assistant / NUT

Oficjalna integracja NUT:
Ustawienia -> Urządzenia i usługi -> Dodaj integrację
-> Network UPS Tools (NUT)

Host:
${PVE_IP:-BRAK_WYKRYTEGO_IP}

Port:
${NUT_PORT}

Username:
homeassistant

Password:
${HA_PASS}

Nazwa UPS:
${UPS_NAME}

WAŻNE:
- Home Assistant nie podejmuje decyzji o wyłączeniu Proxmoxa.
- Shutdown działa lokalnie na hoście przez NUT.
- Jeśli HA nie łączy się z NUT, sprawdź firewall LAN/Proxmox na TCP ${NUT_PORT}.
- MQTT jest opcjonalny i konfiguruje się poleceniem: nut-mqtt-config
EOF
chmod 0600 "${BASE_DIR}/HA-SETUP.txt"

cat > "${BASE_DIR}/COMMANDS.txt" <<EOF
Q-Tronic - najważniejsze komendy

Status:
  nut-status

Podgląd na żywo:
  nut-watch

Pełne dane i możliwości UPS:
  nut-capabilities

Sprawdzenie funkcji przyszłego power-cycle (tylko odczyt):
  nut-phase2-check

Logi:
  nut-logs 100

Bezpieczna instrukcja testu:
  nut-test-guide

Restart/ponowna walidacja NUT po podłączeniu UPS:
  nut-restart

Planowane fizyczne odłączenie UPS:
  nut-config bypass enable
  nut-config bypass status

Powrót po ponownym podłączeniu UPS:
  nut-config resume

Pełny raport diagnostyczny:
  nut-report

Dane do Home Assistant:
  nut-ha-info

Konfiguracja MQTT:
  nut-mqtt-config

Wyłączenie mostu MQTT:
  nut-mqtt-disable

Rollback ostatniej instalacji:
  nut-rollback

Surowe komendy:
  upsc ${UPS_NAME}@localhost
  upscmd -l ${UPS_NAME}@localhost
  upsrw ${UPS_NAME}@localhost

NIE URUCHAMIAJ BEZ WERYFIKACJI:
  upsmon -c fsd
  shutdown.return
  shutdown.stayoff
  load.off
  load.off.delay
EOF
chmod 0600 "${BASE_DIR}/COMMANDS.txt"

cat > "${BASE_DIR}/README-SERVER.txt" <<EOF
Q-Tronic - NUT / PowerWalker / Proxmox

UPS name:            ${UPS_NAME}
Opis:                ${UPS_DESC}
Driver:              ${DRIVER}
Port:                ${PORT}
VendorID:            ${VENDORID:-niewykryty}
ProductID:           ${PRODUCTID:-niewykryty}
NUT version:         ${NUT_VERSION}
upsmon role:         ${UPSMON_ROLE}
Shutdown delay:      ${SHUTDOWN_DELAY} s
Proxmox/NUT IP:      ${PVE_IP:-tylko localhost}
NUT port:            ${NUT_PORT}
Automatyczny monitor: $([[ "${UPS_OK}" == "1" ]] && echo WŁĄCZONY || echo WYŁĄCZONY)

Fizyczny power-cycle UPS:
WYŁĄCZONY - wymaga osobnej weryfikacji.

Katalog:
${BASE_DIR}

Backup:
${BACKUP_DIR}
EOF
chmod 0600 "${BASE_DIR}/README-SERVER.txt"

# ------------------------------------------------------------------------------
# Opcjonalna konfiguracja MQTT przez zmienne środowiskowe
# ------------------------------------------------------------------------------

if [[ -n "${MQTT_HOST:-}" ]]; then
    info "MQTT_HOST podano w środowisku - uruchamiam konfigurator MQTT."
    MQTT_HOST="${MQTT_HOST}" \
    MQTT_PORT="${MQTT_PORT:-1883}" \
    MQTT_USER="${MQTT_USER:-}" \
    MQTT_PASS="${MQTT_PASS:-}" \
    MQTT_TLS="${MQTT_TLS:-0}" \
    "${LIB_DIR}/nut-mqtt-config.sh" || warn "MQTT nie zostało aktywowane; NUT działa niezależnie."
fi

# ------------------------------------------------------------------------------
# Wynik
# ------------------------------------------------------------------------------

echo
echo "============================================================"
echo " Q-Tronic | INSTALACJA ZAKOŃCZONA"
echo "============================================================"
echo
echo "Katalog administracyjny:"
echo "  ${BASE_DIR}"
echo
echo "Najważniejsze komendy:"
echo "  nut-status"
echo "  nut-watch"
echo "  nut-capabilities"
echo "  nut-phase2-check"
echo "  nut-logs 100"
echo "  nut-test-guide"
echo "  nut-report"
echo "  nut-ha-info"
echo "  nut-mqtt-config"
echo
echo "Raport diagnostyczny:"
echo "  nut-report"
echo
echo "Dane HA:"
echo "  nut-ha-info"
echo
echo "Backup:"
echo "  ${BACKUP_DIR}"
echo
echo "Fizyczne odcinanie wyjścia UPS: NIEAKTYWNE."
echo

if (( UPS_OK == 1 )); then
    echo "STATUS: UPS zweryfikowany; automatyczny shutdown jest aktywny."
    echo
    "${LIB_DIR}/nut-status.sh" || true
else
    echo "STATUS: automatyczny shutdown NIE jest aktywny."
    echo "Po upewnieniu się, że UPS jest podłączony przez USB:"
    echo "  nut-restart"
    echo "  nut-report"
fi
echo
