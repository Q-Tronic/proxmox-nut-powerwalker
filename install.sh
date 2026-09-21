#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ==============================================================================
# Q-Tronic - prosty instalator startowy
# Repo: https://github.com/Q-Tronic/proxmox-nut-powerwalker
#
# Ten plik NIE zawiera konfiguracji NUT.
# Pobiera właściwy instalator setup-nut-powerwalker-proxmox.sh,
# sprawdza jego podstawową integralność/składnię i dopiero wtedy go uruchamia.
#
# Użycie:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
#
# Przykład z innym czasem shutdownu:
#   SHUTDOWN_DELAY=120 bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
#
# Opcjonalnie można wskazać konkretny tag/branch/commit:
#   QTRONIC_REF=v1.0.0 bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
#
# Autor: Q-Tronic
# ==============================================================================

REPO_OWNER="Q-Tronic"
REPO_NAME="proxmox-nut-powerwalker"
REF="${QTRONIC_REF:-main}"

RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REF}"
SETUP_URL="${RAW_BASE}/setup-nut-powerwalker-proxmox.sh"

PERSISTENT_INSTALLER="/root/setup-nut-powerwalker-proxmox.sh"
TMP_DIR=""

C_GREEN='\033[1;32m'
C_BLUE='\033[1;34m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_RESET='\033[0m'

ok()   { printf "\n${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
info() { printf "\n${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; }
warn() { printf "\n${C_YELLOW}[UWAGA]${C_RESET} %s\n" "$*" >&2; }
die()  { printf "\n${C_RED}[BŁĄD]${C_RESET} %s\n" "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}
trap cleanup EXIT
trap 'die "Instalator startowy przerwał pracę w linii ${LINENO}."' ERR

[[ "${EUID}" -eq 0 ]] || die "Uruchom jako root na hoście Proxmox."

if command -v pveversion >/dev/null 2>&1; then
    ok "Wykryto Proxmox VE: $(pveversion 2>/dev/null | head -n1 || true)"
else
    warn "Nie wykryto pveversion. Główny instalator jest przygotowany dla Proxmox VE/Debian."
fi

# curl jest potrzebny tylko do pobrania właściwego instalatora.
if ! command -v curl >/dev/null 2>&1; then
    info "Brak curl - instaluję curl i ca-certificates..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates
fi

command -v curl >/dev/null 2>&1 || die "Nie udało się zainstalować curl."
command -v mktemp >/dev/null 2>&1 || die "Brak mktemp."
command -v bash >/dev/null 2>&1 || die "Brak bash."

TMP_DIR="$(mktemp -d /tmp/qtronic-nut-installer.XXXXXX)"
TMP_SETUP="${TMP_DIR}/setup-nut-powerwalker-proxmox.sh"

info "Źródło: ${SETUP_URL}"
info "Pobieram właściwy instalator..."

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 10 \
    --max-time 120 \
    --proto '=https' \
    --tlsv1.2 \
    "${SETUP_URL}" \
    -o "${TMP_SETUP}"

[[ -s "${TMP_SETUP}" ]] || die "Pobrany instalator jest pusty."

# Proste sanity-checki chronią przed uruchomieniem strony błędu/HTML
# albo przypadkowo podmienionego pliku.
head -n1 "${TMP_SETUP}" | grep -Fq '#!/usr/bin/env bash' \
    || die "Pobrany plik nie wygląda jak oczekiwany skrypt Bash."

grep -Fq '# Autor: Q-Tronic' "${TMP_SETUP}" \
    || die "Pobrany skrypt nie zawiera oczekiwanego oznaczenia autora Q-Tronic."

grep -Fq 'managed-by: q-tronic-nut-powerwalker-installer' "${TMP_SETUP}" \
    || die "Pobrany skrypt nie zawiera oczekiwanego markera instalatora."

info "Sprawdzam składnię Bash..."
bash -n "${TMP_SETUP}" || die "Główny instalator nie przeszedł bash -n."

# Zachowujemy dokładną pobraną wersję na serwerze.
install -o root -g root -m 0700 "${TMP_SETUP}" "${PERSISTENT_INSTALLER}"

ok "Instalator zapisany: ${PERSISTENT_INSTALLER}"

echo
echo "============================================================"
echo " Q-Tronic | uruchamiam główny instalator"
echo " Ref: ${REF}"
echo "============================================================"
echo

# Zmienne środowiskowe takie jak SHUTDOWN_DELAY, FORCE, UPS_DRIVER,
# UPS_VENDORID, UPS_PRODUCTID, MQTT_HOST itd. są dziedziczone przez
# główny instalator.
bash "${PERSISTENT_INSTALLER}"
RC=$?

echo
if [[ "${RC}" -eq 0 ]]; then
    ok "Główny instalator zakończył pracę poprawnie."
    echo
    echo "Przydatne komendy:"
    echo "  nut-status"
    echo "  nut-capabilities"
    echo "  nut-report"
    echo "  nut-ha-info"
    echo "  nut-mqtt-config"
else
    warn "Główny instalator zakończył się kodem ${RC}."
    echo "Uruchom, jeśli zostały utworzone:"
    echo "  nut-report"
fi

exit "${RC}"
