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
CONFIG_URL="${RAW_BASE}/nut-config.sh"
VERSION_URL="${RAW_BASE}/VERSION"

PERSISTENT_INSTALLER="/root/setup-nut-powerwalker-proxmox.sh"
PERSISTENT_CONFIG="/root/nut-config.sh"
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
TMP_CONFIG="${TMP_DIR}/nut-config.sh"
TMP_VERSION="${TMP_DIR}/VERSION"

info "Źródło instalatora: ${SETUP_URL}"
info "Źródło konfiguratora: ${CONFIG_URL}"
info "Pobieram pliki Q-Tronic..."

for pair in "${SETUP_URL}|${TMP_SETUP}" "${CONFIG_URL}|${TMP_CONFIG}" "${VERSION_URL}|${TMP_VERSION}"; do
    url="${pair%%|*}"
    dst="${pair#*|}"

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
        "${url}" \
        -o "${dst}"

    [[ -s "${dst}" ]] || die "Pobrany plik jest pusty: ${url}"
done

# Proste sanity-checki chronią przed uruchomieniem strony błędu/HTML
# albo przypadkowo podmienionego pliku.
head -n1 "${TMP_SETUP}" | grep -Fq '#!/usr/bin/env bash' \
    || die "Pobrany plik nie wygląda jak oczekiwany skrypt Bash."

grep -Fq '# Autor: Q-Tronic' "${TMP_SETUP}" \
    || die "Pobrany skrypt nie zawiera oczekiwanego oznaczenia autora Q-Tronic."

grep -Fq 'managed-by: q-tronic-nut-powerwalker-installer' "${TMP_SETUP}" \
    || die "Pobrany skrypt nie zawiera oczekiwanego markera instalatora."

head -n1 "${TMP_CONFIG}" | grep -Fq '#!/usr/bin/env bash' \
    || die "nut-config.sh nie wygląda jak skrypt Bash."

grep -Fq '# Autor: Q-Tronic' "${TMP_CONFIG}" \
    || die "nut-config.sh nie zawiera oczekiwanego oznaczenia autora."

VERSION_VALUE="$(tr -d '\r\n' < "${TMP_VERSION}")"
[[ "${VERSION_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]] || die "Plik VERSION ma nieprawidłowy format."
grep -Fq "QTRONIC_VERSION=\"${VERSION_VALUE}\"" "${TMP_CONFIG}" \
    || die "VERSION (${VERSION_VALUE}) nie zgadza się z QTRONIC_VERSION w nut-config.sh."
info "Wersja projektu: ${VERSION_VALUE}"

info "Sprawdzam składnię Bash..."
bash -n "${TMP_SETUP}" || die "Główny instalator nie przeszedł bash -n."
bash -n "${TMP_CONFIG}" || die "nut-config.sh nie przeszedł bash -n."

# Zachowujemy dokładne pobrane wersje na serwerze.
install -o root -g root -m 0700 "${TMP_SETUP}" "${PERSISTENT_INSTALLER}"
install -o root -g root -m 0700 "${TMP_CONFIG}" "${PERSISTENT_CONFIG}"

ok "Instalator zapisany: ${PERSISTENT_INSTALLER}"
ok "Konfigurator zapisany: ${PERSISTENT_CONFIG}"

echo
echo "============================================================"
echo " Q-Tronic | uruchamiam główny instalator"
echo " Ref: ${REF}"
echo "============================================================"
echo

# Zmienne środowiskowe takie jak SHUTDOWN_DELAY, FORCE, UPS_DRIVER,
# UPS_VENDORID, UPS_PRODUCTID, MQTT_HOST itd. są dziedziczone przez
# główny instalator.
if bash "${PERSISTENT_INSTALLER}"; then
    RC=0
else
    RC=$?
fi

if [[ "${RC}" -ne 0 ]]; then
    echo
    warn "Główny instalator zakończył się kodem ${RC}."
    echo "Konfigurator nie będzie nakładany na niedokończoną instalację."
    echo "Uruchom, jeśli zostały utworzone:"
    echo "  nut-report"
    exit "${RC}"
fi

ok "Główny instalator zakończył pracę poprawnie."

echo
info "Instaluję/aktualizuję centralny konfigurator nut-config..."
if bash "${PERSISTENT_CONFIG}" --install; then
    CFG_RC=0
else
    CFG_RC=$?
fi

if [[ "${CFG_RC}" -ne 0 ]]; then
    warn "nut-config zakończył się kodem ${CFG_RC}."
    exit "${CFG_RC}"
fi

echo
ok "Instalacja Q-Tronic zakończona."
echo
echo "Konfiguracja także po instalacji:"
echo "  nut-config"
echo "  nut-config menu"
echo "  nut-delay 2m"
echo
echo "Diagnostyka:"
echo "  nut-status"
echo "  nut-capabilities"
echo "  nut-report"
echo "  nut-ha-info"
echo "  nut-mqtt-config"
echo "  nut-config version"
echo "  nut-config doctor"

exit 0
