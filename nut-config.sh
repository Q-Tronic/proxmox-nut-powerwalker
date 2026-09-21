#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ==============================================================================
# Q-Tronic - konfigurator NUT / PowerWalker dla Proxmox
# Autor: Q-Tronic
#
# Ten skrypt jest instalowany jako:
#   /usr/local/sbin/nut-config
#   /usr/local/sbin/nut-delay
#
# Cel:
# - konfiguracja także PO instalacji,
# - backup przed każdą zmianą,
# - blokada zmian w krytycznym momencie pracy na baterii,
# - walidacja OL po zmianie,
# - automatyczny rollback po nieudanej zmianie.
#
# Nie aktywuje automatycznie POWERDOWNFLAG / shutdown.return / load.off.
# ==============================================================================

SELF="${BASH_SOURCE[0]}"
INSTALL_DIR="/usr/local/lib/nut-powerwalker"
INSTALL_PATH="${INSTALL_DIR}/nut-config.sh"
SETTINGS="/etc/nut/qtronic-settings.env"
CREDS="/root/nut-powerwalker/credentials.env"
BASE="/root/nut-powerwalker"
CFG_BACKUPS="${BASE}/config-backups"
REPORT_DIR="${BASE}/reports"
LOG_DIR="/var/log/nut-powerwalker"
LOGROTATE="/etc/logrotate.d/nut-powerwalker"
LOCK="/run/lock/qtronic-nut-config.lock"
BYPASS_STATE="/etc/nut/qtronic-bypass-state.env"
MARKER="# managed-by: q-tronic-nut-powerwalker-installer"

die()  { echo "[BŁĄD] $*" >&2; exit 1; }
warn() { echo "[UWAGA] $*" >&2; }
info() { echo "[INFO] $*"; }
ok()   { echo "[OK] $*"; }

[[ "${EUID}" -eq 0 ]] || die "Uruchom jako root."

mkdir -p "${BASE}" "${CFG_BACKUPS}" "${REPORT_DIR}" "${INSTALL_DIR}"
chmod 0700 "${BASE}" "${CFG_BACKUPS}" "${REPORT_DIR}"
chmod 0755 "${INSTALL_DIR}"

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_bool() { [[ "$1" == "0" || "$1" == "1" ]]; }
is_hex4_or_empty() { [[ -z "$1" || "$1" =~ ^[0-9A-Fa-f]{4}$ ]]; }
is_log_size() { [[ "$1" =~ ^[1-9][0-9]*[kKmMgG]?$ ]]; }

parse_duration() {
    local raw="${1,,}" n
    if [[ "${raw}" =~ ^([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${raw}" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${raw}" =~ ^([0-9]+)m$ ]]; then
        n="${BASH_REMATCH[1]}"
        echo $(( n * 60 ))
    elif [[ "${raw}" =~ ^([0-9]+)h$ ]]; then
        n="${BASH_REMATCH[1]}"
        echo $(( n * 3600 ))
    else
        return 1
    fi
}

get_conf_value() {
    local file="$1" key="$2" def="$3" value
    value="$(awk -v k="${key}" '
        $1 == k {
            $1=""; sub(/^[[:space:]]+/, "");
            gsub(/^"|"$/, "");
            print; exit
        }' "${file}" 2>/dev/null || true)"
    echo "${value:-${def}}"
}

get_ups_name() {
    awk '
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            gsub(/^[[:space:]]*\[/,"");
            gsub(/\][[:space:]]*$/,"");
            print; exit
        }' /etc/nut/ups.conf 2>/dev/null || true
}

get_ups_option() {
    local key="$1" def="$2" value
    value="$(awk -F= -v k="${key}" '
        BEGIN { found=0 }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ { found=1; next }
        found && $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
            v=$2
            sub(/^[[:space:]]+/,"",v)
            sub(/[[:space:]]+$/,"",v)
            gsub(/^"|"$/,"",v)
            print v
            exit
        }' /etc/nut/ups.conf 2>/dev/null || true)"
    echo "${value:-${def}}"
}

derive_settings_from_current() {
    UPS_NAME="$(get_ups_name)"
    UPS_NAME="${UPS_NAME:-powerwalker}"

    UPS_DESC="$(get_ups_option desc "PowerWalker VI 2200 STL FR")"
    UPS_DRIVER="$(get_ups_option driver usbhid-ups)"
    UPS_PORT="$(get_ups_option port auto)"
    UPS_VENDORID="$(get_ups_option vendorid "")"
    UPS_PRODUCTID="$(get_ups_option productid "")"
    UPS_SUBDRIVER="$(get_ups_option subdriver "")"

    local ext_line
    ext_line="$(awk '$1=="LISTEN" && $2!="127.0.0.1" {print $2 " " $3; exit}' /etc/nut/upsd.conf 2>/dev/null || true)"
    if [[ -n "${ext_line}" ]]; then
        NUT_LISTEN_IP="${ext_line%% *}"
        NUT_PORT="${ext_line##* }"
    else
        NUT_LISTEN_IP="auto"
        NUT_PORT="3493"
    fi

    SHUTDOWN_DELAY="$(awk '
        $1=="AT" && $2=="ONBATT" && $4=="START-TIMER" && $5=="shutdown_on_battery" {
            print $6; exit
        }' /etc/nut/upssched.conf 2>/dev/null || true)"
    SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-60}"

    if grep -Eq '^[[:space:]]*AT[[:space:]]+ONBATT[[:space:]]+\*[[:space:]]+START-TIMER[[:space:]]+shutdown_on_battery' /etc/nut/upssched.conf 2>/dev/null; then
        TIMED_SHUTDOWN=1
    else
        TIMED_SHUTDOWN=0
    fi

    if grep -Eq '^[[:space:]]*AT[[:space:]]+LOWBATT[[:space:]]+\*[[:space:]]+EXECUTE[[:space:]]+emergency_shutdown' /etc/nut/upssched.conf 2>/dev/null; then
        LOWBATT_SHUTDOWN=1
    else
        LOWBATT_SHUTDOWN=0
    fi

    POLLFREQ="$(get_conf_value /etc/nut/upsmon.conf POLLFREQ 5)"
    POLLFREQALERT="$(get_conf_value /etc/nut/upsmon.conf POLLFREQALERT 5)"
    HOSTSYNC="$(get_conf_value /etc/nut/upsmon.conf HOSTSYNC 15)"
    DEADTIME="$(get_conf_value /etc/nut/upsmon.conf DEADTIME 15)"
    FINALDELAY="$(get_conf_value /etc/nut/upsmon.conf FINALDELAY 5)"
    RBWARNTIME="$(get_conf_value /etc/nut/upsmon.conf RBWARNTIME 43200)"
    NOCOMMWARNTIME="$(get_conf_value /etc/nut/upsmon.conf NOCOMMWARNTIME 300)"

    UPSMON_ROLE="$(awk '$1=="MONITOR" {print $NF; exit}' /etc/nut/upsmon.conf 2>/dev/null || true)"
    UPSMON_ROLE="${UPSMON_ROLE:-primary}"

    LOG_ROTATE_SIZE="$(awk '$1=="size" {print $2; exit}' "${LOGROTATE}" 2>/dev/null || true)"
    LOG_ROTATE_SIZE="${LOG_ROTATE_SIZE:-512k}"

    LOG_ROTATE_COUNT="$(awk '$1=="rotate" {print $2; exit}' "${LOGROTATE}" 2>/dev/null || true)"
    LOG_ROTATE_COUNT="${LOG_ROTATE_COUNT:-6}"

    # Nigdy nie aktywujemy power-cycle tylko dlatego, że coś podobnego
    # znajdowało się wcześniej w konfiguracji. Wymagany jest capability probe.
    POWERCYCLE_ENABLED=0
    POWERCYCLE_OFFDELAY=60
    POWERCYCLE_ONDELAY=300
}

load_settings() {
    [[ -r "${SETTINGS}" ]] || die "Brak ${SETTINGS}. Uruchom: bash ${SELF} --install"
    # shellcheck disable=SC1090
    source "${SETTINGS}"

    UPS_NAME="${UPS_NAME:-powerwalker}"
    UPS_DESC="${UPS_DESC:-PowerWalker VI 2200 STL FR}"
    UPS_DRIVER="${UPS_DRIVER:-usbhid-ups}"
    UPS_PORT="${UPS_PORT:-auto}"
    UPS_VENDORID="${UPS_VENDORID:-}"
    UPS_PRODUCTID="${UPS_PRODUCTID:-}"
    UPS_SUBDRIVER="${UPS_SUBDRIVER:-}"

    NUT_LISTEN_IP="${NUT_LISTEN_IP:-auto}"
    NUT_PORT="${NUT_PORT:-3493}"

    SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-60}"
    TIMED_SHUTDOWN="${TIMED_SHUTDOWN:-1}"
    LOWBATT_SHUTDOWN="${LOWBATT_SHUTDOWN:-1}"

    POLLFREQ="${POLLFREQ:-5}"
    POLLFREQALERT="${POLLFREQALERT:-5}"
    HOSTSYNC="${HOSTSYNC:-15}"
    DEADTIME="${DEADTIME:-15}"
    FINALDELAY="${FINALDELAY:-5}"
    RBWARNTIME="${RBWARNTIME:-43200}"
    NOCOMMWARNTIME="${NOCOMMWARNTIME:-300}"

    LOG_ROTATE_SIZE="${LOG_ROTATE_SIZE:-512k}"
    LOG_ROTATE_COUNT="${LOG_ROTATE_COUNT:-6}"
    UPSMON_ROLE="${UPSMON_ROLE:-primary}"

    POWERCYCLE_ENABLED="${POWERCYCLE_ENABLED:-0}"
    POWERCYCLE_OFFDELAY="${POWERCYCLE_OFFDELAY:-60}"
    POWERCYCLE_ONDELAY="${POWERCYCLE_ONDELAY:-300}"
}

load_creds() {
    [[ -r "${CREDS}" ]] || die "Brak ${CREDS}. Najpierw uruchom główny instalator."
    # shellcheck disable=SC1090
    source "${CREDS}"
    [[ -n "${PRIMARY_PASS:-}" ]] || die "Brak PRIMARY_PASS."
    [[ -n "${HA_PASS:-}" ]] || die "Brak HA_PASS."
}

validate_settings() {
    is_uint "${SHUTDOWN_DELAY}" || die "SHUTDOWN_DELAY nie jest liczbą."
    (( SHUTDOWN_DELAY >= 15 && SHUTDOWN_DELAY <= 86400 )) || die "SHUTDOWN_DELAY: 15-86400 s."

    is_bool "${TIMED_SHUTDOWN}" || die "TIMED_SHUTDOWN: 0/1."
    is_bool "${LOWBATT_SHUTDOWN}" || die "LOWBATT_SHUTDOWN: 0/1."

    is_uint "${NUT_PORT}" || die "NUT_PORT nie jest liczbą."
    (( NUT_PORT >= 1 && NUT_PORT <= 65535 )) || die "NUT_PORT: 1-65535."

    for pair in \
        "POLLFREQ:${POLLFREQ}:1:300" \
        "POLLFREQALERT:${POLLFREQALERT}:1:300" \
        "HOSTSYNC:${HOSTSYNC}:5:600" \
        "DEADTIME:${DEADTIME}:5:600" \
        "FINALDELAY:${FINALDELAY}:0:300" \
        "RBWARNTIME:${RBWARNTIME}:0:604800" \
        "NOCOMMWARNTIME:${NOCOMMWARNTIME}:0:86400"; do
        IFS=: read -r key val min max <<<"${pair}"
        is_uint "${val}" || die "${key} nie jest liczbą."
        (( val >= min && val <= max )) || die "${key}: ${min}-${max}."
    done

    is_hex4_or_empty "${UPS_VENDORID}" || die "UPS_VENDORID: 4 znaki hex albo puste."
    is_hex4_or_empty "${UPS_PRODUCTID}" || die "UPS_PRODUCTID: 4 znaki hex albo puste."

    [[ "${UPS_DRIVER}" =~ ^[A-Za-z0-9_.+-]+$ ]] || die "Nieprawidłowy UPS_DRIVER."
    [[ "${UPS_PORT}" != *$'\n'* ]] || die "Nieprawidłowy UPS_PORT."
    [[ "${UPS_DESC}" != *$'\n'* ]] || die "UPS_DESC nie może zawierać nowej linii."

    is_log_size "${LOG_ROTATE_SIZE}" || die "LOG_ROTATE_SIZE np. 512k, 2M."
    is_uint "${LOG_ROTATE_COUNT}" || die "LOG_ROTATE_COUNT nie jest liczbą."
    (( LOG_ROTATE_COUNT >= 1 && LOG_ROTATE_COUNT <= 50 )) || die "LOG_ROTATE_COUNT: 1-50."

    is_bool "${POWERCYCLE_ENABLED}" || die "POWERCYCLE_ENABLED: 0/1."
    is_uint "${POWERCYCLE_OFFDELAY}" || die "POWERCYCLE_OFFDELAY nie jest liczbą."
    is_uint "${POWERCYCLE_ONDELAY}" || die "POWERCYCLE_ONDELAY nie jest liczbą."
    (( POWERCYCLE_OFFDELAY >= 60 && POWERCYCLE_OFFDELAY <= 3600 ))         || die "POWERCYCLE_OFFDELAY: 60-3600 s."
    (( POWERCYCLE_ONDELAY >= 120 && POWERCYCLE_ONDELAY <= 86400 ))         || die "POWERCYCLE_ONDELAY: 120-86400 s."
    (( POWERCYCLE_ONDELAY > POWERCYCLE_OFFDELAY ))         || die "POWERCYCLE_ONDELAY musi być większy od POWERCYCLE_OFFDELAY."

    if [[ "${NUT_LISTEN_IP}" != "auto" && "${NUT_LISTEN_IP}" != "off" ]]; then
        python3 - "${NUT_LISTEN_IP}" <<'PY'
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
    fi
}

resolve_listen_ip() {
    if [[ "${NUT_LISTEN_IP}" == "off" ]]; then
        echo ""
        return
    fi

    if [[ "${NUT_LISTEN_IP}" != "auto" ]]; then
        echo "${NUT_LISTEN_IP}"
        return
    fi

    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -z "${ip}" ]]; then
        ip="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
    fi
    echo "${ip}"
}

# Wewnętrzny control-plane NUT pozostaje na localhost:3493.
# Zmieniany NUT_PORT dotyczy dostępu z LAN/HA. Dzięki temu upsmon, MQTT
# i narzędzia lokalne nie przestają działać po zmianie portu zewnętrznego.
local_target() {
    echo "${UPS_NAME}@localhost"
}

status_now() {
    timeout 5s upsc "$(local_target)" 2>/dev/null | sed -n 's/^ups.status: //p' | head -n1
}

save_settings_to() {
    local dst="$1"
    {
        printf 'UPS_NAME=%q\n' "${UPS_NAME}"
        printf 'UPS_DESC=%q\n' "${UPS_DESC}"
        printf 'UPS_DRIVER=%q\n' "${UPS_DRIVER}"
        printf 'UPS_PORT=%q\n' "${UPS_PORT}"
        printf 'UPS_VENDORID=%q\n' "${UPS_VENDORID}"
        printf 'UPS_PRODUCTID=%q\n' "${UPS_PRODUCTID}"
        printf 'UPS_SUBDRIVER=%q\n' "${UPS_SUBDRIVER}"
        printf 'NUT_LISTEN_IP=%q\n' "${NUT_LISTEN_IP}"
        printf 'NUT_PORT=%q\n' "${NUT_PORT}"
        printf 'SHUTDOWN_DELAY=%q\n' "${SHUTDOWN_DELAY}"
        printf 'TIMED_SHUTDOWN=%q\n' "${TIMED_SHUTDOWN}"
        printf 'LOWBATT_SHUTDOWN=%q\n' "${LOWBATT_SHUTDOWN}"
        printf 'POLLFREQ=%q\n' "${POLLFREQ}"
        printf 'POLLFREQALERT=%q\n' "${POLLFREQALERT}"
        printf 'HOSTSYNC=%q\n' "${HOSTSYNC}"
        printf 'DEADTIME=%q\n' "${DEADTIME}"
        printf 'FINALDELAY=%q\n' "${FINALDELAY}"
        printf 'RBWARNTIME=%q\n' "${RBWARNTIME}"
        printf 'NOCOMMWARNTIME=%q\n' "${NOCOMMWARNTIME}"
        printf 'LOG_ROTATE_SIZE=%q\n' "${LOG_ROTATE_SIZE}"
        printf 'LOG_ROTATE_COUNT=%q\n' "${LOG_ROTATE_COUNT}"
        printf 'UPSMON_ROLE=%q\n' "${UPSMON_ROLE}"
        printf 'POWERCYCLE_ENABLED=%q\n' "${POWERCYCLE_ENABLED}"
        printf 'POWERCYCLE_OFFDELAY=%q\n' "${POWERCYCLE_OFFDELAY}"
        printf 'POWERCYCLE_ONDELAY=%q\n' "${POWERCYCLE_ONDELAY}"
    } > "${dst}"
}

save_settings() {
    local tmp
    tmp="$(mktemp "${SETTINGS}.tmp.XXXXXX")"
    save_settings_to "${tmp}"
    chown root:nut "${tmp}"
    chmod 0640 "${tmp}"
    mv -f "${tmp}" "${SETTINGS}"
}

require_safe_change_window() {
    local active status
    active="$(systemctl is-active nut-monitor.service 2>/dev/null || true)"
    status="$(status_now || true)"

    if [[ "${active}" == "active" ]]; then
        [[ -n "${status}" ]] || die "nut-monitor jest aktywny, ale UPS nie odpowiada. Najpierw: nut-report"
        printf '%s\n' "${status}" | grep -qw OL || die "UPS nie jest OL (${status}). Nie zmieniam konfiguracji podczas awarii."
        ! printf '%s\n' "${status}" | grep -qw OB || die "UPS raportuje OB. Nie zmieniam konfiguracji podczas pracy z baterii."
    fi
}

backup_now() {
    local d
    d="$(mktemp -d "${CFG_BACKUPS}/config-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
    chmod 0700 "${d}"

    for f in \
        "${SETTINGS}" \
        /etc/nut/ups.conf \
        /etc/nut/upsd.conf \
        /etc/nut/upsd.users \
        /etc/nut/upsmon.conf \
        /etc/nut/upssched.conf \
        "${LOGROTATE}" \
        "${CREDS}" \
        /etc/nut/nut-mqtt.json \
        /etc/nut/qtronic-powercycle-capability.json; do
        if [[ -e "${f}" ]]; then
            cp -a "${f}" "${d}/$(echo "${f}" | sed 's#^/##; s#/#__#g')"
        fi
    done

    {
        echo "nut-monitor=$(systemctl is-active nut-monitor.service 2>/dev/null || true)"
        echo "nut-mqtt=$(systemctl is-active nut-mqtt.service 2>/dev/null || true)"
    } > "${d}/service-state.txt"

    printf '%s\n' "${d}" > "${BASE}/LAST_CONFIG_BACKUP"
    chmod 0600 "${BASE}/LAST_CONFIG_BACKUP"
    echo "${d}"
}

restart_stack() {
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
            upsdrvctl start >/dev/null 2>&1 || true
        fi
    fi

    sleep 2
    systemctl restart nut-server.service
    sleep 2
}

restore_backup_dir() {
    local d="$1" encoded target
    [[ -d "${d}" ]] || die "Brak backupu ${d}"

    systemctl stop nut-monitor.service 2>/dev/null || true
    systemctl stop nut-mqtt.service 2>/dev/null || true

    for encoded in \
        "${d}"/etc__nut__* \
        "${d}"/etc__logrotate.d__nut-powerwalker \
        "${d}"/root__nut-powerwalker__credentials.env; do
        [[ -e "${encoded}" ]] || continue
        target="/${encoded##*/}"
        target="${target//__/\/}"
        mkdir -p "$(dirname "${target}")"
        cp -a "${encoded}" "${target}"
    done

    restart_stack || true

    if grep -q '^nut-monitor=active$' "${d}/service-state.txt" 2>/dev/null; then
        systemctl enable --now nut-monitor.service 2>/dev/null || true
    else
        systemctl disable --now nut-monitor.service 2>/dev/null || true
    fi

    if grep -q '^nut-mqtt=active$' "${d}/service-state.txt" 2>/dev/null; then
        systemctl enable --now nut-mqtt.service 2>/dev/null || true
    fi

    ok "Przywrócono backup: ${d}"
}

render_temp() {
    local dir="$1" listen safe_desc
    listen="$(resolve_listen_ip)"
    safe_desc="${UPS_DESC//\"/}"

    mkdir -p "${dir}"

    {
        echo "${MARKER}"
        echo "[${UPS_NAME}]"
        echo "    driver = ${UPS_DRIVER}"
        echo "    port = ${UPS_PORT}"
        echo "    desc = \"${safe_desc}\""
        [[ -n "${UPS_VENDORID}" ]] && echo "    vendorid = ${UPS_VENDORID}"
        [[ -n "${UPS_PRODUCTID}" ]] && echo "    productid = ${UPS_PRODUCTID}"
        [[ -n "${UPS_SUBDRIVER}" ]] && echo "    subdriver = \"${UPS_SUBDRIVER//\"/}\""

        # offdelay/ondelay są parametrami usbhid-ups. Nigdy nie dodajemy
        # ich przed pozytywnym capability probe konkretnego UPS-a.
        if [[ "${POWERCYCLE_ENABLED}" == "1" && "${UPS_DRIVER}" == "usbhid-ups" ]]; then
            echo "    offdelay = ${POWERCYCLE_OFFDELAY}"
            echo "    ondelay = ${POWERCYCLE_ONDELAY}"
        fi
    } > "${dir}/ups.conf"

    {
        echo "${MARKER}"
        echo "# Lokalny control-plane NUT - nie zmieniamy go:"
        echo "LISTEN 127.0.0.1 3493"
        if [[ -n "${listen}" ]]; then
            if [[ "${listen}" != "127.0.0.1" || "${NUT_PORT}" != "3493" ]]; then
                echo "# Dostęp LAN / Home Assistant:"
                echo "LISTEN ${listen} ${NUT_PORT}"
            fi
        fi
    } > "${dir}/upsd.conf"

    cat > "${dir}/upsd.users" <<EOF_USERS
${MARKER}

[proxmoxmon]
    password = ${PRIMARY_PASS}
    upsmon ${UPSMON_ROLE}

[homeassistant]
    password = ${HA_PASS}
EOF_USERS

    cat > "${dir}/upsmon.conf" <<EOF_MON
${MARKER}

RUN_AS_USER nut
MONITOR ${UPS_NAME}@localhost 1 proxmoxmon ${PRIMARY_PASS} ${UPSMON_ROLE}

MINSUPPLIES 1
SHUTDOWNCMD "$([[ "${POWERCYCLE_ENABLED}" == "1" ]] && echo "${INSTALL_DIR}/qtronic-shutdown-wrapper.sh" || echo "$(command -v shutdown) -h now")"
NOTIFYCMD $(command -v upssched)

POLLFREQ ${POLLFREQ}
POLLFREQALERT ${POLLFREQALERT}
HOSTSYNC ${HOSTSYNC}
DEADTIME ${DEADTIME}
RBWARNTIME ${RBWARNTIME}
NOCOMMWARNTIME ${NOCOMMWARNTIME}
FINALDELAY ${FINALDELAY}

NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
EOF_MON

    {
        echo "${MARKER}"
        echo
        echo "CMDSCRIPT ${INSTALL_DIR}/event-handler.sh"
        echo
        echo "PIPEFN /var/lib/nut/upssched/upssched.pipe"
        echo "LOCKFN /var/lib/nut/upssched/upssched.lock"
        echo
        echo "AT ONBATT * EXECUTE power_lost"

        if [[ "${TIMED_SHUTDOWN}" == "1" ]]; then
            echo "AT ONBATT * START-TIMER shutdown_on_battery ${SHUTDOWN_DELAY}"
            echo "AT ONLINE * CANCEL-TIMER shutdown_on_battery"
        fi

        echo "AT ONLINE * EXECUTE power_restored"
        echo

        if [[ "${LOWBATT_SHUTDOWN}" == "1" ]]; then
            [[ "${TIMED_SHUTDOWN}" == "1" ]] && echo "AT LOWBATT * CANCEL-TIMER shutdown_on_battery"
            echo "AT LOWBATT * EXECUTE low_battery"
            echo "AT LOWBATT * EXECUTE emergency_shutdown"
        else
            echo "AT LOWBATT * EXECUTE low_battery"
        fi

        echo
        echo "AT FSD * EXECUTE fsd_started"
        echo "AT COMMBAD * EXECUTE communication_lost"
        echo "AT COMMOK * EXECUTE communication_restored"
    } > "${dir}/upssched.conf"

    save_settings_to "${dir}/qtronic-settings.env"

    cat > "${dir}/logrotate" <<EOF_LOG
/var/log/nut-powerwalker/*.log {
    size ${LOG_ROTATE_SIZE}
    rotate ${LOG_ROTATE_COUNT}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF_LOG
}

install_rendered() {
    local dir="$1"
    install -o root -g nut -m 0640 "${dir}/ups.conf" /etc/nut/ups.conf
    install -o root -g nut -m 0640 "${dir}/upsd.conf" /etc/nut/upsd.conf
    install -o root -g nut -m 0640 "${dir}/upsd.users" /etc/nut/upsd.users
    install -o root -g nut -m 0640 "${dir}/upsmon.conf" /etc/nut/upsmon.conf
    install -o root -g nut -m 0640 "${dir}/upssched.conf" /etc/nut/upssched.conf
    install -o root -g nut -m 0640 "${dir}/qtronic-settings.env" "${SETTINGS}"
    install -o root -g root -m 0644 "${dir}/logrotate" "${LOGROTATE}"
}

apply_current() {
    # UWAGA: nie wywołuj tutaj load_settings.
    # Wywołujący ma już w pamięci aktualne wartości (również świeżo zmienione).
    # Ponowne load_settings w tym miejscu kasowałoby zmianę przed zapisem.
    load_creds
    validate_settings
    require_safe_change_window

    local previous_monitor backup tmp result status
    previous_monitor="$(systemctl is-active nut-monitor.service 2>/dev/null || true)"

    if [[ "${POWERCYCLE_ENABLED}" == "1" ]]; then
        powercycle_probe 1 || die "Aktywny power-cycle nie przechodzi capability gate. Nie zmieniam konfiguracji."
    fi

    backup="$(backup_now)"

    if [[ "${POWERCYCLE_ENABLED}" == "1" ]]; then
        install_powercycle_runtime
    fi

    tmp="$(mktemp -d /tmp/qtronic-nut-config.XXXXXX)"

    render_temp "${tmp}"

    systemctl stop nut-monitor.service 2>/dev/null || true
    install_rendered "${tmp}"
    rm -rf "${tmp}"

    if ! restart_stack; then
        warn "Restart NUT nie powiódł się. Przywracam backup."
        restore_backup_dir "${backup}"
        return 10
    fi

    result="$(upsc "$(local_target)" 2>&1 || true)"
    status="$(printf '%s\n' "${result}" | sed -n 's/^ups.status: //p' | head -n1)"

    if [[ -z "${status}" ]] || ! printf '%s\n' "${status}" | grep -qw OL || printf '%s\n' "${status}" | grep -qw OB; then
        warn "Nowa konfiguracja nie przeszła walidacji OL."
        echo "${result}" >&2
        warn "Przywracam backup: ${backup}"
        restore_backup_dir "${backup}"
        return 11
    fi

    # Gdy power-cycle jest aktywny, sprawdzamy capabilities jeszcze raz
    # po restarcie sterownika. Zmiana drivera/USB nie może pozostawić
    # aktywnego power-cycle dla niezweryfikowanego urządzenia.
    if [[ "${POWERCYCLE_ENABLED}" == "1" ]]; then
        if ! powercycle_probe 1; then
            warn "Po restarcie aktualny UPS nie przechodzi capability gate."
            warn "Przywracam backup: ${backup}"
            restore_backup_dir "${backup}"
            return 12
        fi
    fi

    if [[ "${previous_monitor}" == "active" ]]; then
        systemctl enable --now nut-monitor.service
    else
        systemctl disable --now nut-monitor.service 2>/dev/null || true
    fi

    ok "Konfiguracja zastosowana. Backup: ${backup}"
}

install_event_handler() {
    cat > "${INSTALL_DIR}/event-handler.sh" <<'EOF_HANDLER'
#!/usr/bin/env bash
set -u

SETTINGS="/etc/nut/qtronic-settings.env"
EVENT_LOG="/var/log/nut-powerwalker/events.log"
LOCK_FILE="/var/lib/nut/upssched/event-handler.lock"

[[ -r "${SETTINGS}" ]] && source "${SETTINGS}"

UPS_NAME="${UPS_NAME:-powerwalker}"
SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-60}"
UPSC="$(command -v upsc)"
UPSMON="$(command -v upsmon)"
LOGGER="$(command -v logger)"

timestamp() { date -Is; }

snapshot() {
    "${UPSC}" "${UPS_NAME}@localhost" 2>/dev/null |
        grep -E '^(ups.status|ups.load|ups.realpower|ups.realpower.nominal|battery.charge|battery.runtime|battery.voltage|input.voltage|output.voltage):' |
        tr '\n' ' ' |
        sed 's/[[:space:]]*$//'
}

event_log() {
    local message="$1" snap
    snap="$(snapshot || true)"
    if [[ -n "${snap}" ]]; then
        printf '%s | %s | %s\n' "$(timestamp)" "${message}" "${snap}" >> "${EVENT_LOG}"
    else
        printf '%s | %s\n' "$(timestamp)" "${message}" >> "${EVENT_LOG}"
    fi
    "${LOGGER}" -t NUT-PowerWalker "${message}"
}

exec 9>"${LOCK_FILE}"
flock -w 10 9 || exit 0

case "${1:-}" in
    power_lost)
        event_log "ONBATT: UPS przeszedł na baterię; skonfigurowany timer ${SHUTDOWN_DELAY}s."
        ;;
    power_restored)
        event_log "ONLINE: zasilanie sieciowe wróciło; timer anulowany."
        ;;
    low_battery)
        event_log "LOWBATT: UPS zgłosił niski poziom baterii."
        ;;
    shutdown_on_battery)
        event_log "TIMER: ${SHUTDOWN_DELAY}s ciągłej pracy na baterii; rozpoczynam FSD."
        "${UPSMON}" -c fsd
        ;;
    emergency_shutdown)
        event_log "EMERGENCY: LOWBATT; rozpoczynam natychmiastowy FSD."
        "${UPSMON}" -c fsd
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
        event_log "UNKNOWN: nieznane zdarzenie: ${1:-BRAK}"
        ;;
esac
EOF_HANDLER
    chown root:nut "${INSTALL_DIR}/event-handler.sh"
    chmod 0750 "${INSTALL_DIR}/event-handler.sh"
}

install_status_helper() {
    cat > "${INSTALL_DIR}/nut-status.sh" <<'EOF_STATUS'
#!/usr/bin/env bash
set -u
source /etc/nut/qtronic-settings.env 2>/dev/null || true

UPS_NAME="${UPS_NAME:-powerwalker}"
SHUTDOWN_DELAY="${SHUTDOWN_DELAY:-60}"
TIMED_SHUTDOWN="${TIMED_SHUTDOWN:-1}"
LOWBATT_SHUTDOWN="${LOWBATT_SHUTDOWN:-1}"

if ! RAW="$(upsc "${UPS_NAME}@localhost" 2>&1)"; then
    if [[ -f /etc/nut/qtronic-bypass-state.env ]]; then
        echo "============================================================"
        echo " Q-Tronic | NUT / PowerWalker"
        echo "============================================================"
        echo "BYPASS:          AKTYWNY"
        echo "UPS:             celowo może być fizycznie odłączony"
        echo "Komunikacja:     brak (oczekiwane w BYPASS po odpięciu UPS)"
        echo "nut-monitor:     $(systemctl is-active nut-monitor.service 2>/dev/null || true)"
        echo "nut-server:      $(systemctl is-active nut-server.service 2>/dev/null || true)"
        echo "nut-mqtt:        $(systemctl is-active nut-mqtt.service 2>/dev/null || true)"
        echo "------------------------------------------------------------"
        echo "Po ponownym podłączeniu UPS uruchom: nut-config resume"
        echo "============================================================"
        exit 0
    fi
    echo "BŁĄD: brak komunikacji z ${UPS_NAME}@localhost"
    echo "${RAW}"
    echo "Jeśli UPS został odłączony celowo, użyj wcześniej: nut-config bypass enable"
    exit 1
fi

getv() {
    printf '%s\n' "${RAW}" | sed -n "s/^$1: //p" | head -n1
}

echo "============================================================"
echo " Q-Tronic | NUT / PowerWalker"
echo "============================================================"
echo "UPS:             ${UPS_NAME}"
echo "Model:           $(getv ups.model)"
echo "Status:          $(getv ups.status)"
echo "Bateria:         $(getv battery.charge) %"
echo "Runtime:         $(getv battery.runtime) s"
echo "Obciążenie:      $(getv ups.load) %"
echo "Moc:             $(getv ups.realpower) W"
echo "Moc znamionowa:  $(getv ups.realpower.nominal) W"
echo "Napięcie wej.:   $(getv input.voltage) V"
echo "Napięcie wyj.:   $(getv output.voltage) V"
echo "------------------------------------------------------------"
echo "Timed shutdown:  $([[ "${TIMED_SHUTDOWN}" == "1" ]] && echo ON || echo OFF)"
echo "Shutdown delay:  ${SHUTDOWN_DELAY} s"
echo "LOWBATT action:  $([[ "${LOWBATT_SHUTDOWN}" == "1" ]] && echo shutdown || echo log-only)"
echo "BYPASS:          $([[ -f /etc/nut/qtronic-bypass-state.env ]] && echo AKTYWNY || echo nie)"
echo "------------------------------------------------------------"
echo "nut-monitor:     $(systemctl is-active nut-monitor.service 2>/dev/null || true)"
echo "nut-server:      $(systemctl is-active nut-server.service 2>/dev/null || true)"
echo "nut-mqtt:        $(systemctl is-active nut-mqtt.service 2>/dev/null || true)"
echo "============================================================"
EOF_STATUS
    chmod 0755 "${INSTALL_DIR}/nut-status.sh"
    ln -sf "${INSTALL_DIR}/nut-status.sh" /usr/local/sbin/nut-status
}

install_ha_helper() {
    cat > "${INSTALL_DIR}/nut-ha-info.sh" <<'EOF_HA'
#!/usr/bin/env bash
set -u
source /root/nut-powerwalker/credentials.env
source /etc/nut/qtronic-settings.env 2>/dev/null || true

NUT_LISTEN_IP="${NUT_LISTEN_IP:-auto}"
NUT_PORT="${NUT_PORT:-3493}"

if [[ "${NUT_LISTEN_IP}" == "auto" ]]; then
    HOST="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    [[ -n "${HOST}" ]] || HOST="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
elif [[ "${NUT_LISTEN_IP}" == "off" ]]; then
    HOST="LAN WYŁĄCZONY"
else
    HOST="${NUT_LISTEN_IP}"
fi

echo "============================================================"
echo " Home Assistant / NUT"
echo " Autor: Q-Tronic"
echo "============================================================"
echo "Host:      ${HOST:-brak}"
echo "Port:      ${NUT_PORT}"
echo "User:      homeassistant"
echo "Password:  ${HA_PASS}"
echo "UPS name:  ${UPS_NAME:-powerwalker}"
echo "------------------------------------------------------------"
if [[ "${HOST}" == "LAN WYŁĄCZONY" ]]; then
    echo "Dostęp NUT z LAN jest wyłączony."
    echo "Włącz: nut-config listen auto"
fi
echo "============================================================"
EOF_HA
    chmod 0755 "${INSTALL_DIR}/nut-ha-info.sh"
    ln -sf "${INSTALL_DIR}/nut-ha-info.sh" /usr/local/sbin/nut-ha-info
}

install_self() {
    [[ ! -f "${BYPASS_STATE}" ]] || die "Tryb BYPASS jest aktywny. Zakończ go przez: nut-config resume — dopiero potem aktualizuj nut-config."
    command -v upsc >/dev/null 2>&1 || die "NUT nie jest jeszcze zainstalowany."
    [[ -f /etc/nut/ups.conf ]] || die "Brak /etc/nut/ups.conf."
    [[ -f /etc/nut/upsmon.conf ]] || die "Brak /etc/nut/upsmon.conf."

    local had_settings=0 current_status
    [[ -f "${SETTINGS}" ]] && had_settings=1

    install -o root -g root -m 0755 "${SELF}" "${INSTALL_PATH}"
    ln -sf "${INSTALL_PATH}" /usr/local/sbin/nut-config
    ln -sf "${INSTALL_PATH}" /usr/local/sbin/nut-delay

    if (( had_settings == 0 )); then
        derive_settings_from_current
        validate_settings
        save_settings
        ok "Utworzono centralny plik ustawień ${SETTINGS}"
    else
        load_settings
        validate_settings
        ok "Zachowano istniejące ustawienia ${SETTINGS}"
    fi

    install_event_handler
    install_status_helper
    install_ha_helper

    # Zachowana funkcja power-cycle nie jest ślepo odtwarzana.
    # Najpierw aktualny sprzęt musi ponownie przejść probe.
    if [[ "${POWERCYCLE_ENABLED:-0}" == "1" ]]; then
        current_status="$(status_now || true)"

        if printf '%s
' "${current_status}" | grep -qw OL            && ! printf '%s
' "${current_status}" | grep -qw OB; then
            if powercycle_probe 1; then
                install_powercycle_runtime
            else
                warn "Zapisany power-cycle nie przechodzi capability gate na aktualnym sprzęcie."
                warn "Pozostawiam ustawienie zapisane, ale nie uzbrajam runtime."
                warn "Sprawdź: nut-config powercycle probe"
                remove_powercycle_runtime
            fi
        else
            warn "Nie weryfikuję power-cycle podczas statusu ${current_status:-brak}."
            warn "Ustawienie pozostaje zapisane, ale runtime nie jest teraz uzbrajany."
            warn "Po stabilnym OL uruchom: nut-config apply"
            remove_powercycle_runtime
        fi
    else
        remove_powercycle_runtime
    fi

    # Przy aktualizacji główny setup mógł na chwilę przywrócić wartości domyślne.
    # Jeśli UPS jest stabilnie OL, nakładamy zachowane ustawienia.
    if (( had_settings == 1 )); then
        current_status="$(status_now || true)"
        if printf '%s\n' "${current_status}" | grep -qw OL && ! printf '%s\n' "${current_status}" | grep -qw OB; then
            info "Nakładam zachowane ustawienia po aktualizacji..."
            if ! apply_current; then
                warn "Nie udało się ponownie nałożyć ustawień. Uruchom: nut-report"
            fi
        else
            warn "UPS nie jest teraz stabilnie OL (${current_status:-brak})."
            warn "Ustawienia są zachowane, ale ich ponowne zastosowanie odłożono."
            warn "Po powrocie OL uruchom: nut-config apply"
        fi
    fi

    echo
    ok "Zainstalowano nut-config i nut-delay."
    echo "  nut-config show"
    echo "  nut-config menu"
    echo "  nut-delay 2m"
}

show() {
    load_settings
    local resolved status bypass
    resolved="$(resolve_listen_ip)"
    status="$(status_now || true)"
    bypass="$([[ -f "${BYPASS_STATE}" ]] && echo TAK || echo NIE)"

    cat <<EOF_SHOW
============================================================
 Q-Tronic | nut-config
============================================================
UPS:
  nazwa wewnętrzna:    ${UPS_NAME}
  opis:                ${UPS_DESC}
  driver:              ${UPS_DRIVER}
  port urządzenia:     ${UPS_PORT}
  vendorid:            ${UPS_VENDORID:-auto/brak}
  productid:           ${UPS_PRODUCTID:-auto/brak}
  subdriver:           ${UPS_SUBDRIVER:-auto/brak}

Shutdown:
  czasowy:             $([[ "${TIMED_SHUTDOWN}" == "1" ]] && echo ON || echo OFF)
  delay:               ${SHUTDOWN_DELAY} s
  LOWBATT shutdown:    $([[ "${LOWBATT_SHUTDOWN}" == "1" ]] && echo ON || echo OFF)

NUT:
  localhost:           127.0.0.1:3493 (stały control-plane)
  LAN setting:         ${NUT_LISTEN_IP}
  LAN resolved:        ${resolved:-OFF}
  LAN/HA port:         ${NUT_PORT}
  POLLFREQ:            ${POLLFREQ}
  POLLFREQALERT:       ${POLLFREQALERT}
  HOSTSYNC:            ${HOSTSYNC}
  DEADTIME:            ${DEADTIME}
  FINALDELAY:          ${FINALDELAY}
  RBWARNTIME:          ${RBWARNTIME}
  NOCOMMWARNTIME:      ${NOCOMMWARNTIME}

Logi:
  rotate size:         ${LOG_ROTATE_SIZE}
  rotate count:        ${LOG_ROTATE_COUNT}

Power-cycle:
  enabled:             $([[ "${POWERCYCLE_ENABLED}" == "1" ]] && echo TAK || echo NIE)
  offdelay:            ${POWERCYCLE_OFFDELAY} s
  ondelay:             ${POWERCYCLE_ONDELAY} s

Tryb BYPASS (UPS fizycznie poza układem):
  aktywny:             ${bypass}
  stan:                $([[ "${bypass}" == "TAK" ]] && echo "ochrona UPS celowo wstrzymana" || echo "normalna ochrona NUT")

Usługi:
  nut-server:          $(systemctl is-active nut-server.service 2>/dev/null || true)
  nut-monitor:         $(systemctl is-active nut-monitor.service 2>/dev/null || true)
  nut-mqtt:            $(systemctl is-active nut-mqtt.service 2>/dev/null || true)

ups.status:            ${status:-brak danych}
============================================================
EOF_SHOW
}

set_key() {
    local key="$1" value="$2"
    require_normal_mode
    load_settings
    load_creds

    case "${key}" in
        SHUTDOWN_DELAY)
            value="$(parse_duration "${value}")" || die "Użyj np. 90, 90s, 2m, 1h."
            SHUTDOWN_DELAY="${value}"
            ;;
        TIMED_SHUTDOWN)
            case "${value,,}" in on|1|yes|true) TIMED_SHUTDOWN=1 ;; off|0|no|false) TIMED_SHUTDOWN=0 ;; *) die "on/off" ;; esac
            ;;
        LOWBATT_SHUTDOWN)
            case "${value,,}" in on|1|yes|true) LOWBATT_SHUTDOWN=1 ;; off|0|no|false) LOWBATT_SHUTDOWN=0 ;; *) die "on/off" ;; esac
            ;;
        NUT_LISTEN_IP)
            case "${value,,}" in
                auto) NUT_LISTEN_IP="auto" ;;
                off|none|disable) NUT_LISTEN_IP="off" ;;
                *) NUT_LISTEN_IP="${value}" ;;
            esac
            ;;
        NUT_PORT)
            NUT_PORT="${value}"
            ;;
        POLLFREQ|POLLFREQALERT|HOSTSYNC|DEADTIME|FINALDELAY|RBWARNTIME|NOCOMMWARNTIME|LOG_ROTATE_COUNT)
            printf -v "${key}" '%s' "${value}"
            ;;
        POWERCYCLE_ENABLED|POWERCYCLE_OFFDELAY|POWERCYCLE_ONDELAY)
            die "Użyj dedykowanej bramki: nut-config powercycle ..."
            ;;
        LOG_ROTATE_SIZE)
            LOG_ROTATE_SIZE="${value}"
            ;;
        UPS_DESC)
            UPS_DESC="${value}"
            ;;
        UPS_DRIVER)
            UPS_DRIVER="${value}"
            ;;
        UPS_PORT)
            UPS_PORT="${value}"
            ;;
        UPS_VENDORID)
            [[ "${value,,}" == "auto" || "${value}" == "-" ]] && value=""
            UPS_VENDORID="${value,,}"
            ;;
        UPS_PRODUCTID)
            [[ "${value,,}" == "auto" || "${value}" == "-" ]] && value=""
            UPS_PRODUCTID="${value,,}"
            ;;
        UPS_SUBDRIVER)
            [[ "${value,,}" == "auto" || "${value}" == "-" ]] && value=""
            UPS_SUBDRIVER="${value}"
            ;;
        *)
            die "Klucz nie jest konfigurowalny: ${key}"
            ;;
    esac

    validate_settings
    apply_current
}

set_usb_pair() {
    [[ $# -ge 2 ]] || die "nut-config usb VID PID [SUBDRIVER]"
    require_normal_mode
    load_settings
    load_creds

    local vid="$1" pid="$2" sub="${3:-${UPS_SUBDRIVER}}"
    [[ "${vid,,}" == "auto" || "${vid}" == "-" ]] && vid=""
    [[ "${pid,,}" == "auto" || "${pid}" == "-" ]] && pid=""
    [[ "${sub,,}" == "auto" || "${sub}" == "-" ]] && sub=""

    UPS_VENDORID="${vid,,}"
    UPS_PRODUCTID="${pid,,}"
    UPS_SUBDRIVER="${sub}"

    validate_settings
    apply_current
}

detect_ups() {
    require_normal_mode
    load_settings
    load_creds
    require_safe_change_window

    local scan json
    scan="$(mktemp /tmp/qtronic-nut-scan.XXXXXX)"
    json="${scan}.json"
    trap 'rm -f "${scan}" "${json}"' RETURN

    timeout 30s nut-scanner -U > "${scan}" 2>/dev/null || true

    python3 - "${scan}" "${json}" <<'PY'
import configparser, json, pathlib, re, sys

text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
idx = text.find("[")
ini = text[idx:] if idx >= 0 else ""
items = []

if ini:
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str.lower
    try:
        cp.read_string(ini)
        for sec in cp.sections():
            d = {k.lower(): v.strip().strip('"').strip("'") for k, v in cp.items(sec)}
            if d.get("driver"):
                items.append(d)
    except Exception:
        pass

def hx(v):
    x = re.sub(r"[^0-9a-fA-F]", "", v or "").lower()
    return x.zfill(4)[-4:] if x else ""

def score(c):
    s = 0
    if hx(c.get("vendorid")) == "0764" and hx(c.get("productid")) == "0601":
        s += 1000
    if (c.get("driver") or "").lower() == "usbhid-ups":
        s += 100
    h = " ".join(c.values()).lower()
    if "powerwalker" in h:
        s += 50
    if "2200" in h:
        s += 25
    return s

if not items:
    raise SystemExit("Nie wykryto UPS przez nut-scanner.")

items = sorted(items, key=score, reverse=True)

if len(items) > 1 and score(items[0]) == score(items[1]):
    raise SystemExit("Wiele równie prawdopodobnych UPS-ów. Ustaw VID/PID ręcznie.")

c = items[0]
result = {
    "driver": c.get("driver") or "usbhid-ups",
    "port": "auto" if (c.get("driver") or "") == "usbhid-ups" else (c.get("port") or "auto"),
    "vendorid": hx(c.get("vendorid")),
    "productid": hx(c.get("productid")),
    "subdriver": c.get("subdriver") or "",
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(result), encoding="utf-8")
PY

    UPS_DRIVER="$(jq -r '.driver' "${json}")"
    UPS_PORT="$(jq -r '.port' "${json}")"
    UPS_VENDORID="$(jq -r '.vendorid' "${json}")"
    UPS_PRODUCTID="$(jq -r '.productid' "${json}")"
    UPS_SUBDRIVER="$(jq -r '.subdriver' "${json}")"

    echo "Wykryto:"
    echo "  driver=${UPS_DRIVER}"
    echo "  port=${UPS_PORT}"
    echo "  vendorid=${UPS_VENDORID:-brak}"
    echo "  productid=${UPS_PRODUCTID:-brak}"
    echo "  subdriver=${UPS_SUBDRIVER:-brak}"

    validate_settings
    apply_current
}

rotate_credential() {
    local which="$1"
    require_normal_mode
    load_settings
    load_creds
    require_safe_change_window

    local previous_monitor backup new tmpdir result status
    previous_monitor="$(systemctl is-active nut-monitor.service 2>/dev/null || true)"
    backup="$(backup_now)"
    new="$(openssl rand -hex 24)"
    tmpdir="$(mktemp -d /tmp/qtronic-nut-cred.XXXXXX)"

    if [[ "${which}" == "ha" ]]; then
        HA_PASS="${new}"
    elif [[ "${which}" == "primary" ]]; then
        PRIMARY_PASS="${new}"
    else
        die "Nieznany typ credential."
    fi

    {
        printf 'PRIMARY_PASS=%q\n' "${PRIMARY_PASS}"
        printf 'HA_PASS=%q\n' "${HA_PASS}"
    } > "${tmpdir}/credentials.env"

    render_temp "${tmpdir}/rendered"

    systemctl stop nut-monitor.service 2>/dev/null || true
    install -o root -g root -m 0600 "${tmpdir}/credentials.env" "${CREDS}"
    install_rendered "${tmpdir}/rendered"
    rm -rf "${tmpdir}"

    if ! restart_stack; then
        warn "Restart nieudany. Rollback."
        restore_backup_dir "${backup}"
        return 20
    fi

    result="$(upsc "$(local_target)" 2>&1 || true)"
    status="$(printf '%s\n' "${result}" | sed -n 's/^ups.status: //p' | head -n1)"

    if [[ -z "${status}" ]] || ! printf '%s\n' "${status}" | grep -qw OL || printf '%s\n' "${status}" | grep -qw OB; then
        warn "Walidacja po zmianie hasła nieudana. Rollback."
        restore_backup_dir "${backup}"
        return 21
    fi

    if [[ "${previous_monitor}" == "active" ]]; then
        systemctl enable --now nut-monitor.service
    fi

    ok "Hasło ${which} zmienione. Backup: ${backup}"
}


# ------------------------------------------------------------------------------
# Guarded power-cycle UPS
# ------------------------------------------------------------------------------

CAPABILITY_FILE="/etc/nut/qtronic-powercycle-capability.json"
POWERCYCLE_FLAG="/run/qtronic-nut-powercycle-fsd-ok"
CUSTOM_HOOK_NAME="qtronic-nut-powercycle"

powercycle_fingerprint() {
    local raw="$1"
    printf '%s\n' "${raw}" |
        grep -E '^(device\.mfr|device\.model|device\.serial|ups\.mfr|ups\.model|ups\.serial|ups\.vendorid|ups\.productid|driver\.parameter\.vendorid|driver\.parameter\.productid|driver\.name|driver\.version\.data):' |
        sort |
        sha256sum |
        awk '{print $1}'
}

powercycle_probe() {
    local quiet="${1:-0}"

    # Nie przeładowujemy tutaj settings. Probe ma sprawdzać sprzęt dla
    # aktualnej transakcji konfiguracyjnej, bez kasowania zmian w pamięci.
    local raw cmds rw status fp driver_name vendorid productid
    local has_return=0 has_start=0 has_shutdown=0 has_off_delay=0 has_on_delay=0
    local supported=0

    raw="$(upsc "$(local_target)" 2>&1 || true)"
    status="$(printf '%s\n' "${raw}" | sed -n 's/^ups.status: //p' | head -n1)"

    if [[ -z "${status}" ]]; then
        [[ "${quiet}" == "1" ]] || echo "[NIE] Brak odpowiedzi upsc."
        return 1
    fi

    if ! printf '%s\n' "${status}" | grep -qw OL || printf '%s\n' "${status}" | grep -qw OB; then
        [[ "${quiet}" == "1" ]] || echo "[NIE] Probe wymaga stabilnego OL. Aktualnie: ${status}"
        return 1
    fi

    cmds="$(upscmd -l "$(local_target)" 2>&1 || true)"
    rw="$(upsrw "$(local_target)" 2>&1 || true)"

    printf '%s\n' "${cmds}" | grep -Eq '^shutdown\.return([[:space:]]|$)' && has_return=1
    printf '%s\n' "${rw}" | grep -Eq '^\[ups\.delay\.start\]' && has_start=1
    printf '%s\n' "${rw}" | grep -Eq '^\[ups\.delay\.shutdown\]' && has_shutdown=1
    printf '%s\n' "${cmds}" | grep -Eq '^load\.off\.delay([[:space:]]|$)' && has_off_delay=1
    printf '%s\n' "${cmds}" | grep -Eq '^load\.on\.delay([[:space:]]|$)' && has_on_delay=1

    driver_name="$(printf '%s\n' "${raw}" | sed -n 's/^driver.name: //p' | head -n1)"
    vendorid="$(printf '%s\n' "${raw}" | sed -n 's/^ups.vendorid: //p' | head -n1)"
    productid="$(printf '%s\n' "${raw}" | sed -n 's/^ups.productid: //p' | head -n1)"

    [[ -n "${vendorid}" ]] || vendorid="$(printf '%s\n' "${raw}" | sed -n 's/^driver.parameter.vendorid: //p' | head -n1)"
    [[ -n "${productid}" ]] || productid="$(printf '%s\n' "${raw}" | sed -n 's/^driver.parameter.productid: //p' | head -n1)"

    fp="$(powercycle_fingerprint "${raw}")"

    if [[ "${has_return}" == "1" ]] \
       && [[ -n "${driver_name}" ]] \
       && command -v upsdrvctl >/dev/null 2>&1 \
       && command -v systemctl >/dev/null 2>&1; then
        supported=1
    fi

    python3 - "${CAPABILITY_FILE}" \
        "${fp}" "${status}" "${driver_name}" "${vendorid}" "${productid}" \
        "${has_return}" "${has_start}" "${has_shutdown}" \
        "${has_off_delay}" "${has_on_delay}" "${supported}" <<'PY'
import json, os, sys
(
    path, fp, status, driver_name, vendorid, productid,
    shutdown_return, delay_start, delay_shutdown,
    load_off_delay, load_on_delay, supported
) = sys.argv[1:]

data = {
    "fingerprint": fp,
    "status": status,
    "driver_name": driver_name,
    "vendorid": vendorid,
    "productid": productid,
    "shutdown_return": shutdown_return == "1",
    "ups_delay_start_rw": delay_start == "1",
    "ups_delay_shutdown_rw": delay_shutdown == "1",
    "load_off_delay": load_off_delay == "1",
    "load_on_delay": load_on_delay == "1",
    "supported": supported == "1",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
os.chmod(tmp, 0o640)
os.replace(tmp, path)
PY
    chown root:nut "${CAPABILITY_FILE}" 2>/dev/null || true

    if [[ "${quiet}" != "1" ]]; then
        echo "============================================================"
        echo " Q-Tronic | power-cycle probe"
        echo "============================================================"
        echo "ups.status:              ${status}"
        echo "driver.name:             ${driver_name:-brak}"
        echo "USB VID:                 ${vendorid:-brak}"
        echo "USB PID:                 ${productid:-brak}"
        echo "fingerprint:             ${fp}"
        echo "shutdown.return:         $([[ "${has_return}" == "1" ]] && echo TAK || echo NIE)"
        echo "ups.delay.start R/W:     $([[ "${has_start}" == "1" ]] && echo TAK || echo NIE)"
        echo "ups.delay.shutdown R/W:  $([[ "${has_shutdown}" == "1" ]] && echo TAK || echo NIE)"
        echo "load.off.delay:          $([[ "${has_off_delay}" == "1" ]] && echo TAK || echo NIE)"
        echo "load.on.delay:           $([[ "${has_on_delay}" == "1" ]] && echo TAK || echo NIE)"
        echo "upsdrvctl:               $(command -v upsdrvctl || echo BRAK)"
        echo "------------------------------------------------------------"
        if [[ "${supported}" == "1" ]]; then
            echo "WYNIK: POWER-CYCLE MOŻE ZOSTAĆ ODBLOKOWANY."
            echo "Następny krok: nut-config powercycle enable"
        else
            echo "WYNIK: POWER-CYCLE POZOSTAJE ZABLOKOWANY."
        fi
        echo "============================================================"
    fi

    [[ "${supported}" == "1" ]]
}

install_powercycle_runtime() {
    local hookdir hook upsdrvctl_bin logger_bin

    # Wrapper wywoływany przez upsmon w momencie prawdziwego FSD.
    # Jeszcze raz sprawdza fingerprint i shutdown.return. Dopiero wtedy
    # tworzy prywatny Q-Tronic flag dla bardzo późnego hooka systemd.
    cat > "${INSTALL_DIR}/qtronic-shutdown-wrapper.sh" <<'EOF_WRAP'
#!/usr/bin/env bash
set -u

SETTINGS="/etc/nut/qtronic-settings.env"
CAP="/etc/nut/qtronic-powercycle-capability.json"
FLAG="/run/qtronic-nut-powercycle-fsd-ok"

[[ -r "${SETTINGS}" ]] && source "${SETTINGS}"

rm -f "${FLAG}" 2>/dev/null || true

if [[ "${POWERCYCLE_ENABLED:-0}" == "1" && -r "${CAP}" ]]; then
    RAW="$(upsc "${UPS_NAME:-powerwalker}@localhost" 2>/dev/null || true)"
    CMDS="$(upscmd -l "${UPS_NAME:-powerwalker}@localhost" 2>/dev/null || true)"

    CURRENT_FP="$(
        printf '%s\n' "${RAW}" |
            grep -E '^(device\.mfr|device\.model|device\.serial|ups\.mfr|ups\.model|ups\.serial|ups\.vendorid|ups\.productid|driver\.parameter\.vendorid|driver\.parameter\.productid|driver\.name|driver\.version\.data):' |
            sort |
            sha256sum |
            awk '{print $1}'
    )"

    EXPECTED_FP="$(jq -r '.fingerprint // empty' "${CAP}" 2>/dev/null || true)"
    SUPPORTED="$(jq -r '.supported // false' "${CAP}" 2>/dev/null || true)"

    if [[ "${SUPPORTED}" == "true" \
       && -n "${EXPECTED_FP}" \
       && "${CURRENT_FP}" == "${EXPECTED_FP}" ]] \
       && printf '%s\n' "${CMDS}" | grep -Eq '^shutdown\.return([[:space:]]|$)'; then
        {
            echo "fingerprint=${CURRENT_FP}"
            echo "created_epoch=$(date +%s)"
        } > "${FLAG}.tmp"
        chown root:root "${FLAG}.tmp"
        chmod 0600 "${FLAG}.tmp"
        mv -f "${FLAG}.tmp" "${FLAG}"
        logger -t Q-Tronic-NUT "FSD: capability gate OK; późny power-cycle uzbrojony." || true
    else
        logger -t Q-Tronic-NUT "FSD: capability gate NIE przeszedł; shutdown bez power-cycle." || true
    fi
fi

exec "$(command -v shutdown)" -h now
EOF_WRAP
    chown root:root "${INSTALL_DIR}/qtronic-shutdown-wrapper.sh"
    chmod 0755 "${INSTALL_DIR}/qtronic-shutdown-wrapper.sh"

    if [[ -d /usr/lib/systemd/system-shutdown ]]; then
        hookdir="/usr/lib/systemd/system-shutdown"
    elif [[ -d /lib/systemd/system-shutdown ]]; then
        hookdir="/lib/systemd/system-shutdown"
    else
        hookdir="/usr/lib/systemd/system-shutdown"
        mkdir -p "${hookdir}"
    fi

    hook="${hookdir}/${CUSTOM_HOOK_NAME}"
    upsdrvctl_bin="$(command -v upsdrvctl)"
    logger_bin="$(command -v logger || true)"

    cat > "${hook}" <<EOF_HOOK
#!/bin/sh
# Q-Tronic: uruchamiane bardzo późno przez systemd-shutdown.
# Bez prywatnego flagu stworzonego podczas prawdziwego FSD nic nie robi.

SETTINGS="/etc/nut/qtronic-settings.env"
FLAG="/run/qtronic-nut-powercycle-fsd-ok"

[ -r "\${SETTINGS}" ] || exit 0
. "\${SETTINGS}"

# Hooki systemd-shutdown dostają: poweroff/halt/reboot/kexec.
# Power-cycle UPS wolno wykonać wyłącznie po naszym FSD i przy poweroff.
[ "\${1:-}" = "poweroff" ] || exit 0
[ "\${POWERCYCLE_ENABLED:-0}" = "1" ] || exit 0
[ -s "\${FLAG}" ] || exit 0

created_epoch=""
fingerprint=""
. "\${FLAG}" 2>/dev/null || exit 0

case "\${created_epoch}" in
    ''|*[!0-9]*) exit 0 ;;
esac

now_epoch="$(date +%s 2>/dev/null || echo 0)"
case "\${now_epoch}" in
    ''|*[!0-9]*) exit 0 ;;
esac

age=$((now_epoch - created_epoch))
[ "\${age}" -ge 0 ] 2>/dev/null || exit 0
[ "\${age}" -le 900 ] 2>/dev/null || exit 0

# Zużywamy flagę przed komendą, aby nie mogła zostać użyta drugi raz.
rm -f "\${FLAG}" 2>/dev/null || true

${logger_bin:-/usr/bin/logger} -t Q-Tronic-NUT \
    "Late shutdown: upsdrvctl shutdown \${UPS_NAME:-powerwalker}" 2>/dev/null || true

export NUT_QUIET_INIT_NDE_WARNING=1
${upsdrvctl_bin} shutdown "\${UPS_NAME:-powerwalker}" >/dev/null 2>&1 || true

exit 0
EOF_HOOK

    chown root:root "${hook}"
    chmod 0755 "${hook}"

    # Migracja ze starszej wersji, która używała trwałej flagi w /etc.
    systemctl disable qtronic-nut-powercycle-clear.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/qtronic-nut-powercycle-clear.service
    rm -f /etc/nut/qtronic-powercycle-fsd-ok "${POWERCYCLE_FLAG}" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_powercycle_runtime() {
    rm -f \
        "${INSTALL_DIR}/qtronic-shutdown-wrapper.sh" \
        /usr/lib/systemd/system-shutdown/${CUSTOM_HOOK_NAME} \
        /lib/systemd/system-shutdown/${CUSTOM_HOOK_NAME} \
        "${POWERCYCLE_FLAG}" \
        /etc/nut/qtronic-powercycle-fsd-ok \
        2>/dev/null || true

    systemctl disable qtronic-nut-powercycle-clear.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/qtronic-nut-powercycle-clear.service
    systemctl daemon-reload >/dev/null 2>&1 || true
}

powercycle_status() {
    load_settings

    echo "============================================================"
    echo " Q-Tronic | power-cycle status"
    echo "============================================================"
    echo "Enabled:           $([[ "${POWERCYCLE_ENABLED}" == "1" ]] && echo TAK || echo NIE)"
    echo "OFF delay:         ${POWERCYCLE_OFFDELAY}s"
    echo "ON delay:          ${POWERCYCLE_ONDELAY}s"
    echo "Capability file:   $([[ -f "${CAPABILITY_FILE}" ]] && echo TAK || echo NIE)"
    echo "FSD flag:          $([[ -f "${POWERCYCLE_FLAG}" ]] && echo UZBROJONY || echo nie)"
    echo "Wrapper:           $([[ -x "${INSTALL_DIR}/qtronic-shutdown-wrapper.sh" ]] && echo TAK || echo NIE)"
    echo "Late hook:         $([[ -x /usr/lib/systemd/system-shutdown/${CUSTOM_HOOK_NAME} || -x /lib/systemd/system-shutdown/${CUSTOM_HOOK_NAME} ]] && echo TAK || echo NIE)"
    echo "------------------------------------------------------------"
    powercycle_probe 0 || true
}

powercycle_enable() {
    [[ ! -f "${BYPASS_STATE}" ]] || die "Tryb BYPASS jest aktywny. Najpierw podłącz UPS i uruchom: nut-config resume"
    load_settings
    load_creds
    require_safe_change_window

    echo "Sprawdzam konkretny aktualnie podłączony UPS..."
    powercycle_probe 0 || die "Capability gate nie został spełniony."

    local outer_backup detected_vid detected_pid
    outer_backup="$(backup_now)"

    # Jeżeli UPS raportuje VID/PID, wiążemy aktywną konfigurację właśnie z nimi.
    detected_vid="$(jq -r '.vendorid // empty' "${CAPABILITY_FILE}")"
    detected_pid="$(jq -r '.productid // empty' "${CAPABILITY_FILE}")"

    if [[ "${detected_vid}" =~ ^[0-9A-Fa-f]{4}$ ]]; then
        UPS_VENDORID="${detected_vid,,}"
    fi
    if [[ "${detected_pid}" =~ ^[0-9A-Fa-f]{4}$ ]]; then
        UPS_PRODUCTID="${detected_pid,,}"
    fi

    POWERCYCLE_ENABLED=1
    validate_settings
    install_powercycle_runtime

    if ! apply_current; then
        warn "Nie udało się zastosować konfiguracji power-cycle."
        restore_backup_dir "${outer_backup}"
        remove_powercycle_runtime
        return 1
    fi

    # Po restarcie sterownika jeszcze raz tylko odczytujemy capabilities.
    if ! powercycle_probe 1; then
        warn "Po przeładowaniu UPS nie przechodzi już capability gate."
        restore_backup_dir "${outer_backup}"
        remove_powercycle_runtime
        return 2
    fi

    ok "Power-cycle WŁĄCZONY."
    echo "OFF delay: ${POWERCYCLE_OFFDELAY}s"
    echo "ON delay:  ${POWERCYCLE_ONDELAY}s"
    echo
    echo "Podczas konfiguracji NIE wykonano shutdown.return."
    echo "Przed prawdziwym FSD wrapper ponownie sprawdzi fingerprint i shutdown.return."
}

powercycle_disable() {
    require_normal_mode
    load_settings
    load_creds
    require_safe_change_window

    POWERCYCLE_ENABLED=0
    apply_current
    remove_powercycle_runtime

    ok "Power-cycle WYŁĄCZONY."
}

powercycle_delays() {
    [[ $# -eq 2 ]] || die "nut-config powercycle delays OFF_SECONDS ON_SECONDS"

    require_normal_mode
    load_settings
    load_creds

    POWERCYCLE_OFFDELAY="$1"
    POWERCYCLE_ONDELAY="$2"
    validate_settings

    if [[ "${POWERCYCLE_ENABLED}" == "1" ]]; then
        powercycle_probe 1 || die "Aktualny UPS nie przechodzi capability gate."
        apply_current
        powercycle_probe 1 || die "Po zmianie delay UPS nie przechodzi ponownego probe."
    else
        local backup
        backup="$(backup_now)"
        save_settings
        ok "Delay zapisane. Zostaną użyte dopiero po bezpiecznym powercycle enable."
        echo "Backup: ${backup}"
    fi
}

mqtt_cmd() {
    local sub="${1:-status}"
    case "${sub}" in
        setup|config)
            [[ ! -f "${BYPASS_STATE}" ]] || die "Tryb BYPASS jest aktywny. Najpierw podłącz UPS i uruchom: nut-config resume"
            /usr/local/sbin/nut-mqtt-config
            ;;
        status)
            systemctl --no-pager --full status nut-mqtt.service || true
            ;;
        disable|off)
            /usr/local/sbin/nut-mqtt-disable
            ;;
        show)
            if [[ -f /etc/nut/nut-mqtt.json ]]; then
                jq 'del(.password)' /etc/nut/nut-mqtt.json
            else
                echo "MQTT nie jest skonfigurowane."
            fi
            ;;
        interval)
            require_normal_mode
            [[ $# -eq 2 ]] || die "nut-config mqtt interval SEKUNDY"
            local sec="$2" tmp
            is_uint "${sec}" || die "Interwał musi być liczbą."
            (( sec >= 5 && sec <= 3600 )) || die "Interwał: 5-3600 s."
            [[ -f /etc/nut/nut-mqtt.json ]] || die "Najpierw: nut-config mqtt setup"
            tmp="$(mktemp /etc/nut/nut-mqtt.json.tmp.XXXXXX)"
            jq --argjson n "${sec}" '.interval=$n' /etc/nut/nut-mqtt.json > "${tmp}"
            chown root:nut "${tmp}"
            chmod 0640 "${tmp}"
            mv -f "${tmp}" /etc/nut/nut-mqtt.json
            if systemctl is-active --quiet nut-mqtt.service 2>/dev/null; then
                systemctl restart nut-mqtt.service
                ok "MQTT interval=${sec}s; usługa zrestartowana."
            else
                ok "MQTT interval=${sec}s; usługa pozostaje wyłączona."
            fi
            ;;
        *)
            die "nut-config mqtt setup|status|show|disable|interval N"
            ;;
    esac
}

monitor_cmd() {
    local action="${1:-status}" status
    case "${action}" in
        status)
            systemctl --no-pager --full status nut-monitor.service || true
            ;;
        disable|off)
            systemctl disable --now nut-monitor.service
            ok "nut-monitor wyłączony."
            ;;
        enable|on)
            [[ ! -f "${BYPASS_STATE}" ]] || die "Tryb BYPASS jest aktywny. Najpierw podłącz UPS i uruchom: nut-config resume"
            load_settings
            status="$(status_now || true)"
            printf '%s\n' "${status}" | grep -qw OL || die "Nie włączam monitora bez OL. Status: ${status:-brak}"
            ! printf '%s\n' "${status}" | grep -qw OB || die "UPS raportuje OB."
            systemctl enable --now nut-monitor.service
            ok "nut-monitor włączony."
            ;;
        *)
            die "nut-config monitor status|enable|disable"
            ;;
    esac
}


bypass_active() {
    [[ -f "${BYPASS_STATE}" ]]
}

require_normal_mode() {
    if bypass_active; then
        die "Tryb BYPASS jest aktywny. Ta zmiana jest zablokowana. Podłącz UPS i uruchom: nut-config resume"
    fi
    return 0
}

service_active_bit() {
    systemctl is-active --quiet "$1" 2>/dev/null && echo 1 || echo 0
}

service_enabled_bit() {
    systemctl is-enabled --quiet "$1" 2>/dev/null && echo 1 || echo 0
}

restore_service_state() {
    local unit="$1" was_active="$2" was_enabled="$3"

    if [[ "${was_enabled}" == "1" ]]; then
        systemctl enable "${unit}" >/dev/null 2>&1 || true
    else
        systemctl disable "${unit}" >/dev/null 2>&1 || true
    fi

    if [[ "${was_active}" == "1" ]]; then
        systemctl start "${unit}" >/dev/null 2>&1 || true
    else
        systemctl stop "${unit}" >/dev/null 2>&1 || true
    fi
}

bypass_mark_ready() {
    local value="$1" tmp
    is_bool "${value}" || die "Nieprawidłowy stan BYPASS_READY."
    [[ -f "${BYPASS_STATE}" ]] || die "Brak ${BYPASS_STATE}."

    tmp="$(mktemp "${BYPASS_STATE}.tmp.XXXXXX")"
    awk '!/^BYPASS_READY=/' "${BYPASS_STATE}" > "${tmp}"
    printf 'BYPASS_READY=%q\n' "${value}" >> "${tmp}"
    chown root:nut "${tmp}"
    chmod 0640 "${tmp}"
    mv -f "${tmp}" "${BYPASS_STATE}"
}

bypass_status() {
    local status
    status="$(status_now || true)"

    echo "============================================================"
    echo " Q-Tronic | BYPASS / praca bez UPS"
    echo "============================================================"

    if ! bypass_active; then
        echo "BYPASS:              NIE"
        echo "Ochrona NUT:          tryb normalny"
        echo "ups.status:           ${status:-brak komunikacji}"
        echo
        echo "Jeśli chcesz fizycznie wyjąć UPS z układu:"
        echo "  1) upewnij się, że UPS jest OL"
        echo "  2) uruchom: nut-config bypass enable"
        echo "  3) dopiero potem odłącz USB i przepnij zasilanie serwera"
        echo "============================================================"
        return 0
    fi

    # shellcheck disable=SC1090
    source "${BYPASS_STATE}"
    echo "BYPASS:              TAK"
    echo "Gotowy do odpięcia:   $([[ "${BYPASS_READY:-0}" == "1" ]] && echo TAK || echo NIE)"
    echo "Ochrona UPS:          celowo wstrzymana"
    echo "Włączono epoch:       ${BYPASS_ENTERED_EPOCH:-brak}"
    echo "Poprzedni monitor:    $([[ "${PREV_MONITOR_ACTIVE:-0}" == "1" ]] && echo aktywny || echo nieaktywny)"
    echo "Poprzedni MQTT:       $([[ "${PREV_MQTT_ACTIVE:-0}" == "1" ]] && echo aktywny || echo nieaktywny)"
    echo "Poprzedni powercycle: $([[ "${PREV_POWERCYCLE:-0}" == "1" ]] && echo aktywny || echo nieaktywny)"
    echo "ups.status teraz:     ${status:-brak komunikacji (normalne po odłączeniu UPS)}"
    if [[ "${BYPASS_READY:-0}" != "1" ]]; then
        echo
        echo "UWAGA: BYPASS NIE zakończył przygotowania. NIE ODŁĄCZAJ UPS."
        echo "Aby wrócić do normalnego trybu: nut-config resume"
    fi
    echo
    echo "Po ponownym podłączeniu UPS uruchom:"
    echo "  nut-config resume"
    echo "============================================================"
}

bypass_enable() {
    load_settings
    load_creds

    if bypass_active; then
        warn "Tryb BYPASS jest już aktywny."
        bypass_status
        return 0
    fi

    local raw status fp tmp
    local mon_active mon_enabled mqtt_active mqtt_enabled

    raw="$(upsc "$(local_target)" 2>&1 || true)"
    status="$(printf '%s\n' "${raw}" | sed -n 's/^ups.status: //p' | head -n1)"

    [[ -n "${status}" ]] || die "Nie włączam BYPASS bez komunikacji z UPS. Najpierw przywróć połączenie i stabilne OL."
    printf '%s\n' "${status}" | grep -qw OL || die "BYPASS można włączyć tylko przy stabilnym OL. Status: ${status}"
    ! printf '%s\n' "${status}" | grep -qw OB || die "UPS raportuje OB. Nie odłączaj go teraz."

    fp="$(powercycle_fingerprint "${raw}")"
    mon_active="$(service_active_bit nut-monitor.service)"
    mon_enabled="$(service_enabled_bit nut-monitor.service)"
    mqtt_active="$(service_active_bit nut-mqtt.service)"
    mqtt_enabled="$(service_enabled_bit nut-mqtt.service)"

    tmp="$(mktemp "${BYPASS_STATE}.tmp.XXXXXX")"
    {
        printf 'BYPASS_ENTERED_EPOCH=%q\n' "$(date +%s)"
        printf 'BYPASS_READY=%q\n' "0"
        printf 'BYPASS_UPS_FP=%q\n' "${fp}"
        printf 'PREV_MONITOR_ACTIVE=%q\n' "${mon_active}"
        printf 'PREV_MONITOR_ENABLED=%q\n' "${mon_enabled}"
        printf 'PREV_MQTT_ACTIVE=%q\n' "${mqtt_active}"
        printf 'PREV_MQTT_ENABLED=%q\n' "${mqtt_enabled}"
        printf 'PREV_POWERCYCLE=%q\n' "${POWERCYCLE_ENABLED}"
    } > "${tmp}"
    chown root:nut "${tmp}"
    chmod 0640 "${tmp}"
    mv -f "${tmp}" "${BYPASS_STATE}"

    # Najpierw wyłączamy procesy, które reagują na utratę komunikacji.
    systemctl disable --now nut-monitor.service >/dev/null 2>&1 || true
    systemctl disable --now nut-mqtt.service >/dev/null 2>&1 || true

    if systemctl is-active --quiet nut-monitor.service 2>/dev/null; then
        die "Nie udało się zatrzymać nut-monitor. NIE odłączaj UPS."
    fi

    # Usuwamy późny hook/flagę zanim cokolwiek fizycznie odłączysz.
    remove_powercycle_runtime

    if [[ "${POWERCYCLE_ENABLED}" == "1" ]]; then
        POWERCYCLE_ENABLED=0
        if ! apply_current; then
            warn "Nie udało się przepisać konfiguracji z wyłączonym power-cycle."
            warn "Monitor i runtime power-cycle pozostają zatrzymane. NIE odłączaj UPS bez sprawdzenia: nut-config bypass status"
            return 1
        fi
        remove_powercycle_runtime
    fi

    bypass_mark_ready 1

    ok "Tryb BYPASS WŁĄCZONY I GOTOWY DO FIZYCZNEGO ODŁĄCZENIA UPS."
    echo "nut-monitor: zatrzymany"
    echo "nut-mqtt:    zatrzymany"
    echo "power-cycle: wyłączony, runtime usunięty"
    echo
    echo "TERAZ możesz odłączyć USB UPS i przepiąć serwer bezpośrednio do sieci."
    echo "Po ponownym podłączeniu UPS uruchom: nut-config resume"
}

bypass_resume() {
    bypass_active || die "Tryb BYPASS nie jest aktywny. Nic nie trzeba przywracać."

    load_settings
    load_creds

    # shellcheck disable=SC1090
    source "${BYPASS_STATE}"

    for v in BYPASS_READY PREV_MONITOR_ACTIVE PREV_MONITOR_ENABLED PREV_MQTT_ACTIVE PREV_MQTT_ENABLED PREV_POWERCYCLE; do
        is_bool "${!v:-}" || die "Uszkodzony ${BYPASS_STATE}: ${v}. Nie przywracam automatycznie usług."
    done

    info "Ponownie uruchamiam stos NUT i sprawdzam podłączony UPS..."
    systemctl stop nut-monitor.service 2>/dev/null || true
    systemctl stop nut-mqtt.service 2>/dev/null || true

    restart_stack || die "Nie udało się uruchomić sterownika/serwera NUT. BYPASS pozostaje aktywny."

    local raw status current_fp powercycle_restored=1
    raw="$(upsc "$(local_target)" 2>&1 || true)"
    status="$(printf '%s\n' "${raw}" | sed -n 's/^ups.status: //p' | head -n1)"

    [[ -n "${status}" ]] || die "UPS nadal nie odpowiada. BYPASS pozostaje aktywny."
    printf '%s\n' "${status}" | grep -qw OL || die "Nie kończę BYPASS bez stabilnego OL. Status: ${status}"
    ! printf '%s\n' "${status}" | grep -qw OB || die "UPS raportuje OB. BYPASS pozostaje aktywny."

    current_fp="$(powercycle_fingerprint "${raw}")"

    # Power-cycle przywracamy tylko dla tego samego UPS i tylko po nowym probe.
    if [[ "${PREV_POWERCYCLE}" == "1" ]]; then
        if [[ -n "${BYPASS_UPS_FP:-}" && "${current_fp}" == "${BYPASS_UPS_FP}" ]]; then
            if powercycle_probe 0; then
                POWERCYCLE_ENABLED=1
                if ! apply_current; then
                    warn "Nie udało się ponownie aktywować power-cycle. Pozostaje WYŁĄCZONY."
                    load_settings
                    POWERCYCLE_ENABLED=0
                    remove_powercycle_runtime
                    apply_current || die "Nie udało się bezpiecznie utrwalić power-cycle=OFF. BYPASS pozostaje aktywny."
                    powercycle_restored=0
                fi
            else
                warn "UPS nie przeszedł ponownego capability probe. Power-cycle pozostaje WYŁĄCZONY."
                POWERCYCLE_ENABLED=0
                remove_powercycle_runtime
                apply_current || die "Nie udało się bezpiecznie utrwalić power-cycle=OFF. BYPASS pozostaje aktywny."
                powercycle_restored=0
            fi
        else
            warn "Fingerprint UPS różni się od urządzenia sprzed BYPASS."
            warn "Nie przywracam power-cycle automatycznie dla innego sprzętu."
            POWERCYCLE_ENABLED=0
            remove_powercycle_runtime
            apply_current || die "Nie udało się bezpiecznie utrwalić power-cycle=OFF. BYPASS pozostaje aktywny."
            powercycle_restored=0
        fi
    else
        POWERCYCLE_ENABLED=0
        remove_powercycle_runtime
        apply_current || die "Nie udało się bezpiecznie utrwalić konfiguracji po BYPASS. BYPASS pozostaje aktywny."
    fi

    # Przywracamy stan usług sprzed BYPASS dopiero po stabilnym OL.
    restore_service_state nut-monitor.service "${PREV_MONITOR_ACTIVE}" "${PREV_MONITOR_ENABLED}"

    if [[ -f /etc/nut/nut-mqtt.json ]]; then
        restore_service_state nut-mqtt.service "${PREV_MQTT_ACTIVE}" "${PREV_MQTT_ENABLED}"
    else
        systemctl disable --now nut-mqtt.service >/dev/null 2>&1 || true
        [[ "${PREV_MQTT_ACTIVE}" == "0" ]] || warn "MQTT było wcześniej aktywne, ale brakuje /etc/nut/nut-mqtt.json."
    fi

    rm -f "${BYPASS_STATE}"

    ok "Tryb BYPASS zakończony. UPS jest stabilnie OL."
    echo "nut-monitor: $(systemctl is-active nut-monitor.service 2>/dev/null || true)"
    echo "nut-mqtt:    $(systemctl is-active nut-mqtt.service 2>/dev/null || true)"
    if [[ "${PREV_POWERCYCLE}" == "1" && "${powercycle_restored}" != "1" ]]; then
        warn "Power-cycle NIE został automatycznie przywrócony. To celowe zabezpieczenie."
        echo "Sprawdź ręcznie: nut-config powercycle probe"
        echo "A potem ewentualnie: nut-config powercycle enable"
    fi
}


update_project() {
    require_normal_mode
    load_settings
    load_creds

    command -v curl >/dev/null 2>&1 || die "Brak curl. Zainstaluj pakiet curl i spróbuj ponownie."

    local status backup tmp url rc
    status="$(status_now || true)"
    [[ -n "${status}" ]] || die "Nie aktualizuję bez komunikacji z UPS. Najpierw przywróć UPS i sprawdź: nut-status"
    printf '%s\n' "${status}" | grep -qw OL || die "Aktualizacja wymaga stabilnego OL. Aktualny status: ${status}"
    ! printf '%s\n' "${status}" | grep -qw OB || die "UPS raportuje OB. Nie aktualizuję podczas pracy na baterii."

    backup="$(backup_now)"
    tmp="$(mktemp /tmp/qtronic-update-install.XXXXXX.sh)"
    chmod 0700 "${tmp}"
    url="https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh"

    info "Backup przed aktualizacją: ${backup}"
    info "Pobieram aktualny bootstrap z oficjalnego repo Q-Tronic..."
    if ! curl \
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
        "${url}" -o "${tmp}"; then
        rm -f "${tmp}"
        die "Nie udało się pobrać instalatora aktualizacji. Obecna instalacja nie została przez ten krok zmieniona."
    fi

    [[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "Pobrany install.sh jest pusty."; }
    head -n1 "${tmp}" | grep -Fq '#!/usr/bin/env bash' \
        || { rm -f "${tmp}"; die "Pobrany plik nie wygląda jak skrypt Bash."; }
    grep -Fq 'REPO_OWNER="Q-Tronic"' "${tmp}" \
        || { rm -f "${tmp}"; die "Pobrany install.sh nie zawiera oczekiwanego repozytorium Q-Tronic."; }
    grep -Fq 'REPO_NAME="proxmox-nut-powerwalker"' "${tmp}" \
        || { rm -f "${tmp}"; die "Pobrany install.sh nie zawiera oczekiwanej nazwy projektu."; }
    bash -n "${tmp}" \
        || { rm -f "${tmp}"; die "Pobrany install.sh nie przeszedł bash -n."; }

    echo
    echo "Aktualizacja uruchomi oficjalny install.sh z gałęzi main."
    echo "Istniejące dane dostępowe i ustawienia Q-Tronic mają zostać zachowane,"
    echo "a konfiguracja po aktualizacji zostanie ponownie zweryfikowana przez instalator."
    echo

    set +e
    bash "${tmp}"
    rc=$?
    set -e
    rm -f "${tmp}"

    if (( rc != 0 )); then
        warn "Aktualizacja zakończyła się kodem ${rc}."
        echo "Backup sprzed aktualizacji nut-config: ${backup}"
        echo "Diagnostyka: nut-report"
        echo "Pełny rollback instalatora (jeśli potrzebny): nut-rollback"
        return "${rc}"
    fi

    ok "Aktualizacja zakończona."
    echo "Po wyjściu z bieżącego polecenia sprawdź:"
    echo "  nut-status"
    echo "  nut-config show"
    echo "  nut-config powercycle status"
}

help_text() {
    cat <<'EOF_HELP'
Q-Tronic nut-config — pomoc

NAJWAŻNIEJSZE ZASADY
  - Normalny stan zasilania UPS: OL (On Line).
  - OB oznacza pracę na baterii. Wtedy nie zmieniaj konfiguracji ani nie odłączaj USB.
  - Jeśli chcesz fizycznie wyjąć UPS z układu, użyj BYPASS. Nie wyłączaj samego kabla USB "na żywo".
  - Power-cycle jest domyślnie wyłączony i wymaga pozytywnego capability probe.
  - Probe i powercycle enable NIE wysyłają testowego shutdown.return.

SZYBKI START
  nut-config
  nut-config show
      Bez argumentu działa tak samo jak "nut-config show". Pokazuje całą bieżącą
      konfigurację, stan usług, ups.status i stan BYPASS.

  nut-config menu
      Otwiera prowadzone menu z opisami i potwierdzeniami przy ryzykownych operacjach.

  nut-config help
      Wyświetla tę pomoc.

  nut-config apply
      Ponownie renderuje i stosuje zapisane ustawienia. Tworzy backup, wymaga bezpiecznego
      stanu i po zmianie sprawdza stabilne OL. Przy błędzie wykonuje rollback.
      Blokowane w BYPASS, bo planowo odłączony UPS nie powinien być restartowany/sondowany.

AKTUALIZACJA
  nut-config update
      Zalecany sposób aktualizacji projektu z gałęzi main. Komenda:
      - odmawia pracy podczas BYPASS;
      - wymaga komunikacji z UPS i stabilnego OL;
      - tworzy dodatkowy backup konfiguracji przed aktualizacją;
      - pobiera oficjalny install.sh tylko przez HTTPS;
      - sprawdza podstawowe markery projektu oraz bash -n;
      - uruchamia ten sam bezpieczny bootstrap co pierwsza instalacja;
      - zachowuje istniejące dane dostępowe i ustawienia Q-Tronic;
      - po aktualizacji główny instalator ponownie waliduje UPS i stos NUT.
      Jeśli aktualizacja zwróci błąd, nie ignoruj go: uruchom nut-report i sprawdź backup.

      Alternatywa ręczna (robi to samo z publicznego main):
        bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)

SHUTDOWN
  nut-delay
  nut-config delay
      Pokazuje aktualny czas ciągłej pracy na baterii przed FSD/shutdownem.

  nut-delay 90
  nut-delay 2m
  nut-delay 1h
  nut-config delay 90
      Ustawia opóźnienie shutdownu. Zakres: 15-86400 s. Zasilanie powracające przed
      końcem timera anuluje shutdown.

  nut-config timed on
      Włącza shutdown po upływie skonfigurowanego czasu ONBATT.

  nut-config timed off
      Wyłącza shutdown czasowy. LOWBATT może nadal wywołać natychmiastowy FSD.

  nut-config lowbatt on
      Włącza natychmiastowy FSD po zdarzeniu LOWBATT. Zalecane ustawienie.

  nut-config lowbatt off
      Wyłącza reakcję shutdown na LOWBATT i pozostawia tylko logowanie. Używaj świadomie.

BYPASS — BEZPIECZNE FIZYCZNE ODŁĄCZENIE UPS
  nut-config bypass status
      Pokazuje, czy tryb BYPASS jest aktywny i jaki był stan usług przed jego włączeniem.

  nut-config bypass enable
  nut-config bypass enter
  nut-config bypass on
      Użyj PRZED odłączeniem UPS. Wymaga działającego UPS w stabilnym OL. Zapamiętuje
      stan usług, zatrzymuje nut-monitor i MQTT, wyłącza power-cycle oraz usuwa jego
      późny hook/flagę. Dopiero po komunikacie [OK] i statusie "Gotowy do odpięcia: TAK"
      wolno odłączyć USB i przepiąć serwer.

  nut-config resume
  nut-config bypass disable
  nut-config bypass resume
  nut-config bypass off
      Użyj PO ponownym podłączeniu UPS. Restartuje stos NUT, wymaga stabilnego OL i
      przywraca wcześniejszy stan monitora/MQTT. Power-cycle wraca automatycznie tylko
      dla tego samego fingerprintu UPS i po świeżym pozytywnym probe. W przeciwnym
      razie pozostaje bezpiecznie wyłączony.

SZYBKA PROCEDURA: CHCĘ ODPIĄĆ UPS I ZASILAĆ SERWER Z GNIAZDKA
  1) nut-status            -> upewnij się, że widzisz OL
  2) nut-config bypass enable
  3) nut-config bypass status -> musi być "Gotowy do odpięcia: TAK"
  4) dopiero wtedy odłącz USB i przepnij zasilanie serwera

  Gdy UPS wróci: podłącz zasilanie + USB, potem uruchom nut-config resume.

MONITOR NUT
  nut-config monitor status
      Pokazuje pełny status systemd nut-monitor.service.

  nut-config monitor enable
  nut-config monitor on
      Włącza ochronę hosta przez NUT. Komenda jest blokowana bez stabilnego OL oraz
      podczas aktywnego BYPASS.

  nut-config monitor disable
  nut-config monitor off
      Wyłącza automatyczne reagowanie NUT na ONBATT/LOWBATT. Serwer przestaje być
      automatycznie chroniony przed zanikiem zasilania.

POWER-CYCLE UPS
  nut-config powercycle probe
      Tylko odczyt. Sprawdza bieżący UPS, status OL, fingerprint, listę komend i m.in.
      shutdown.return. Niczego nie odcina i nie wysyła shutdown.return.

  nut-config powercycle status
      Pokazuje konfigurację power-cycle, obecność capability file, flagi FSD i hooka,
      a następnie wykonuje bieżący read-only probe.

  nut-config powercycle delays 60 300
      Ustawia OFF delay i ON delay w sekundach. OFF: 60-3600, ON: 120-86400, ON musi
      być większe od OFF. Przy wyłączonym power-cycle tylko zapisuje wartości.

  nut-config powercycle enable
      Włącza zabezpieczony mechanizm power-cycle. Wymaga stabilnego OL i jawnego
      shutdown.return. Robi probe przed i po przeładowaniu konfiguracji. Nie wykonuje
      fizycznego odcięcia podczas samego enable. Blokowane w BYPASS.

  nut-config powercycle disable
      Wyłącza power-cycle, przywraca zwykły SHUTDOWNCMD i usuwa wrapper/hook/flagę.
      Blokowane w BYPASS; do powrotu z BYPASS służy wyłącznie nut-config resume.

HOME ASSISTANT / NUT LAN
  nut-config listen
      Pokazuje bieżące ustawienie adresu LAN NUT.

  nut-config listen auto
      Automatycznie wybiera adres IPv4 hosta dla klientów LAN/Home Assistant.

  nut-config listen off
      Wyłącza dostęp NUT z LAN. Lokalny control-plane 127.0.0.1:3493 pozostaje aktywny.

  nut-config listen 192.168.1.10
      Ustawia konkretny lokalny adres IP, na którym NUT ma słuchać dla klientów LAN.

  nut-config port
      Pokazuje port LAN/Home Assistant.

  nut-config port 3493
      Ustawia port LAN/HA. Wewnętrzny localhost pozostaje zawsze na 3493.

  nut-config ha show
      Pokazuje host, port, użytkownika i HASŁO konta Home Assistant. Nie publikuj wyniku.

  nut-config ha rotate
      Generuje nowe losowe hasło dla Home Assistant, stosuje konfigurację i pokazuje
      nowe dane logowania. Stare hasło przestaje działać.

UPS / USB
  nut-config ups show
      Pokazuje logiczną nazwę UPS i aktualne ustawienia driver/port/VID/PID/subdriver.

  nut-config ups auto
      Skanuje USB przez nut-scanner i próbuje bezpiecznie dobrać parametry urządzenia.
      Przy niejednoznacznym wyniku zatrzymuje się zamiast zgadywać.

  nut-config usb 0764 0601
      Ręcznie wiąże konfigurację z VID/PID. Używaj po sprawdzeniu lsusb/nut-scanner.

  nut-config usb 0764 0601 "CyberPower HID"
      Jak wyżej, ale dodatkowo ustawia subdriver.

  nut-config usb auto auto
      Usuwa ręczne ograniczenie VID/PID i wraca do automatycznego wyboru.

MQTT
  nut-config mqtt setup
  nut-config mqtt config
      Uruchamia konfigurator brokera, testuje połączenie i dopiero po udanym teście
      włącza nut-mqtt.service. Blokowane podczas BYPASS.

  nut-config mqtt status
      Pokazuje pełny status usługi mostu MQTT.

  nut-config mqtt show
      Pokazuje zapisane ustawienia MQTT bez hasła.

  nut-config mqtt interval 15
      Ustawia interwał publikacji 5-3600 s. Restartuje usługę tylko wtedy, gdy już działa.

  nut-config mqtt disable
  nut-config mqtt off
      Zatrzymuje i wyłącza usługę MQTT, ale zachowuje konfigurację do późniejszego użycia.

HASŁA
  nut-config primary rotate
      Zmienia hasło lokalnego konta upsmon/proxmoxmon. Operacja robi backup, restart,
      walidację OL i rollback przy błędzie.

PARAMETRY ZAAWANSOWANE
  nut-config get KLUCZ
      Odczytuje pojedynczą dozwoloną wartość, np. nut-config get DEADTIME.

  nut-config set KLUCZ WARTOŚĆ
      Zmienia dozwolony parametr i stosuje konfigurację z backupem/walidacją.

  Dozwolone przykłady:
      nut-config set POLLFREQ 5
      nut-config set POLLFREQALERT 5
      nut-config set HOSTSYNC 15
      nut-config set DEADTIME 15
      nut-config set FINALDELAY 5
      nut-config set RBWARNTIME 43200
      nut-config set NOCOMMWARNTIME 300
      nut-config set LOG_ROTATE_SIZE 512k
      nut-config set LOG_ROTATE_COUNT 6
      nut-config set UPS_DESC "PowerWalker VI 2200 STL FR"
      nut-config set UPS_DRIVER usbhid-ups
      nut-config set UPS_PORT auto
      nut-config set UPS_SUBDRIVER "CyberPower HID"

  Parametrów POWERCYCLE_* nie zmieniaj przez set — mają osobną bramkę bezpieczeństwa.

BACKUP / ROLLBACK / DIAGNOSTYKA
  nut-config backup
      Tworzy natychmiastowy backup bieżącej konfiguracji i wypisuje jego katalog.

  nut-config rollback
      Przywraca ostatni backup utworzony przez nut-config i stan usług zapisany w backupie.

  nut-config report
      Pokazuje ustawienia Q-Tronic i uruchamia pełny nut-report. Raport może zawierać
      IP, identyfikatory USB i numer seryjny UPS — przejrzyj przed publikacją.

  nut-config capabilities
      Uruchamia helper nut-capabilities i pokazuje dane/komendy/RW udostępniane przez UPS.

  nut-config logs 100
      Pokazuje ostatnie wpisy logów; liczba określa żądaną liczbę linii.

ZASADY BEZPIECZEŃSTWA
  - Nie odłączaj USB, gdy ups.status zawiera OB.
  - Przed fizycznym usunięciem UPS użyj: nut-config bypass enable
  - Po ponownym podłączeniu użyj: nut-config resume
  - Nie uruchamiaj ręcznie shutdown.return, shutdown.stayoff ani load.off na działającym serwerze.
  - localhost:3493 jest stałym wewnętrznym control-plane; zmienny port dotyczy LAN/HA.
  - Zmiany konfiguracji są blokowane w niebezpiecznym stanie i walidowane po restarcie.
EOF_HELP
}

menu_pause() {
    echo
    read -r -p "Naciśnij ENTER, aby wrócić do menu..." _ || true
}

menu_confirm_word() {
    local word="$1" prompt="$2" answer
    echo
    echo "UWAGA: ${prompt}"
    read -r -p "Aby potwierdzić wpisz dokładnie ${word}: " answer
    [[ "${answer}" == "${word}" ]]
}

menu_header() {
    load_settings
    local status bypass
    status="$(status_now || true)"
    bypass="$([[ -f "${BYPASS_STATE}" ]] && echo TAK || echo NIE)"

    clear 2>/dev/null || true
    echo "============================================================"
    echo " Q-Tronic NUT — bezpieczna konfiguracja"
    echo "============================================================"
    echo "UPS status:      ${status:-brak komunikacji}"
    echo "nut-monitor:     $(systemctl is-active nut-monitor.service 2>/dev/null || true)"
    echo "Power-cycle:     $([[ "${POWERCYCLE_ENABLED}" == "1" ]] && echo WŁĄCZONY || echo wyłączony)"
    echo "BYPASS:          ${bypass}"
    echo "Shutdown timer:  $([[ "${TIMED_SHUTDOWN}" == "1" ]] && echo "ON (${SHUTDOWN_DELAY}s)" || echo OFF)"
    echo "LOWBATT:         $([[ "${LOWBATT_SHUTDOWN}" == "1" ]] && echo shutdown || echo tylko-log)"
    echo "============================================================"
    if [[ -z "${status}" ]]; then
        echo "!!! BRAK KOMUNIKACJI Z UPS — nie zmieniaj konfiguracji ani okablowania w ciemno."
    elif printf '%s\n' "${status}" | grep -qw OB; then
        echo "!!! UPS PRACUJE Z BATERII (OB) — nie odłączaj USB i nie zmieniaj konfiguracji."
    elif printf '%s\n' "${status}" | grep -qw OL; then
        echo "Stan UPS: OL — normalne zasilanie sieciowe."
    else
        echo "UWAGA: nietypowy status UPS: ${status}. Przed zmianami sprawdź nut-status."
    fi
    echo "============================================================"
}

menu_shutdown() {
    while true; do
        load_settings
        echo
        echo "--- Shutdown ---"
        echo "Aktualnie: timer=$([[ "${TIMED_SHUTDOWN}" == "1" ]] && echo ON || echo OFF), delay=${SHUTDOWN_DELAY}s, LOWBATT=$([[ "${LOWBATT_SHUTDOWN}" == "1" ]] && echo ON || echo OFF)"
        echo "1) Zmień czas do shutdownu"
        echo "2) Włącz shutdown czasowy"
        echo "3) Wyłącz shutdown czasowy"
        echo "4) Włącz natychmiastowy shutdown LOWBATT (zalecane)"
        echo "5) Wyłącz shutdown LOWBATT (zmniejsza ochronę)"
        echo "0) Wróć"
        read -r -p "Wybór: " v
        case "${v}" in
            1) read -r -p "Nowy czas, np. 90 / 2m / 1h: " d; set_key SHUTDOWN_DELAY "${d}"; menu_pause ;;
            2) set_key TIMED_SHUTDOWN on; menu_pause ;;
            3) if menu_confirm_word WYLACZ "Serwer NIE wyłączy się po samym upływie czasu ONBATT."; then set_key TIMED_SHUTDOWN off; else echo "Anulowano."; fi; menu_pause ;;
            4) set_key LOWBATT_SHUTDOWN on; menu_pause ;;
            5) if menu_confirm_word WYLACZ "LOWBATT przestanie wymuszać awaryjny shutdown."; then set_key LOWBATT_SHUTDOWN off; else echo "Anulowano."; fi; menu_pause ;;
            0) return ;;
            *) echo "Nieprawidłowy wybór."; menu_pause ;;
        esac
    done
}

menu_bypass() {
    while true; do
        echo
        echo "--- BYPASS / praca bez UPS ---"
        echo "1) Pokaż status BYPASS"
        echo "2) Włącz BYPASS przed fizycznym odłączeniem UPS"
        echo "3) Zakończ BYPASS po ponownym podłączeniu UPS"
        echo "0) Wróć"
        read -r -p "Wybór: " v
        case "${v}" in
            1) bypass_status; menu_pause ;;
            2)
                echo "BYPASS zatrzyma nut-monitor i MQTT oraz wyłączy power-cycle."
                echo "UPS MUSI być teraz podłączony i raportować stabilne OL."
                if menu_confirm_word BYPASS "Po komunikacie [OK] możesz fizycznie usunąć UPS z toru zasilania."; then bypass_enable; else echo "Anulowano."; fi
                menu_pause
                ;;
            3)
                echo "Najpierw podłącz UPS do sieci, podłącz USB i upewnij się, że urządzenie jest gotowe."
                if menu_confirm_word PRZYWROC "Resume uruchomi ponownie stos NUT i może przywrócić monitor/MQTT oraz zweryfikowany power-cycle."; then bypass_resume; else echo "Anulowano."; fi
                menu_pause
                ;;
            0) return ;;
            *) echo "Nieprawidłowy wybór."; menu_pause ;;
        esac
    done
}

menu_powercycle() {
    while true; do
        load_settings
        echo
        echo "--- Power-cycle UPS ---"
        echo "Aktualnie: $([[ "${POWERCYCLE_ENABLED}" == "1" ]] && echo WŁĄCZONY || echo wyłączony), OFF=${POWERCYCLE_OFFDELAY}s, ON=${POWERCYCLE_ONDELAY}s"
        echo "1) [ODCZYT] Probe możliwości UPS — niczego nie wyłącza"
        echo "2) [ODCZYT] Pełny status power-cycle"
        echo "3) [ZMIANA] Zmień OFF/ON delay"
        echo "4) [UZBROJENIE] Włącz power-cycle — bez fizycznego testu w tej chwili"
        echo "5) [ZMIANA] Wyłącz power-cycle"
        echo "0) Wróć"
        read -r -p "Wybór: " v
        case "${v}" in
            1) powercycle_probe 0 || true; menu_pause ;;
            2) powercycle_status; menu_pause ;;
            3) read -r -p "OFF delay [60-3600 s]: " d1; read -r -p "ON delay [120-86400 s, > OFF]: " d2; powercycle_delays "${d1}" "${d2}"; menu_pause ;;
            4)
                echo "Enable sam NIE wyśle shutdown.return, ale uzbroi mechanizm na przyszły prawdziwy FSD."
                if menu_confirm_word WLACZ "Włączaj dopiero po pozytywnym probe i kontrolowanym planie testu."; then powercycle_enable; else echo "Anulowano."; fi
                menu_pause
                ;;
            5) powercycle_disable; menu_pause ;;
            0) return ;;
            *) echo "Nieprawidłowy wybór."; menu_pause ;;
        esac
    done
}

menu() {
    while true; do
        menu_header

        if bypass_active; then
            echo "BYPASS jest aktywny — menu ogranicza zmiany do bezpiecznych operacji."
            echo "1) Pokaż status BYPASS"
            echo "2) Zakończ BYPASS po ponownym podłączeniu UPS"
            echo "3) Pokaż ogólny status/ustawienia"
            echo "4) Pokaż ostatnie 100 linii logów"
            echo "0) Wyjście"
            read -r -p "Wybór: " choice
            case "${choice}" in
                1) bypass_status; menu_pause ;;
                2)
                    if menu_confirm_word PRZYWROC "UPS musi być ponownie podłączony; resume wymaga stabilnego OL i przywraca zapamiętane usługi."; then bypass_resume; else echo "Anulowano."; fi
                    menu_pause
                    ;;
                3) show; menu_pause ;;
                4) /usr/local/sbin/nut-logs 100; menu_pause ;;
                0) exit 0 ;;
                *) echo "Nieprawidłowy wybór."; menu_pause ;;
            esac
            continue
        fi

        echo "1)  [ODCZYT] Status i wszystkie ustawienia"
        echo "2)  [OCHRONA] Shutdown: timer / delay / LOWBATT"
        echo "3)  [SPRZĘT] UPS / USB: podgląd lub auto-detect"
        echo "4)  [SIEĆ] LAN / Home Assistant"
        echo "5)  [OCHRONA] Monitor NUT"
        echo "6)  [PROCEDURA] BYPASS — bezpieczne odłączenie/powrót UPS"
        echo "7)  [ZAAWANSOWANE] Power-cycle UPS"
        echo "8)  [OPCJONALNE] MQTT"
        echo "9)  [ODCZYT] Diagnostyka / logi / test guide"
        echo "10) [ODZYSKIWANIE] Backup / rollback"
        echo "11) [AKTUALIZACJA] Pobierz i zainstaluj najnowszą wersję"
        echo "12) [POMOC] Opis wszystkich komend"
        echo "0)  Wyjście"
        read -r -p "Wybór: " choice

        case "${choice}" in
            1) show; menu_pause ;;
            2) menu_shutdown ;;
            3)
                echo
                echo "1) Pokaż ustawienia UPS/USB"
                echo "2) Auto-detect przez nut-scanner"
                echo "0) Anuluj"
                read -r -p "Wybór: " v
                case "${v}" in
                    1) echo "UPS_NAME=${UPS_NAME}"; echo "UPS_DRIVER=${UPS_DRIVER}"; echo "UPS_PORT=${UPS_PORT}"; echo "UPS_VENDORID=${UPS_VENDORID}"; echo "UPS_PRODUCTID=${UPS_PRODUCTID}"; echo "UPS_SUBDRIVER=${UPS_SUBDRIVER}" ;;
                    2)
                        echo "Auto-detect może zmienić driver/VID/PID/subdriver i zrestartować NUT."
                        if menu_confirm_word WYKRYJ "Uruchom auto-detect tylko przy stabilnym OL i podłączonym właściwym UPS."; then detect_ups; else echo "Anulowano."; fi
                        ;;
                    0) : ;;
                    *) echo "Nieprawidłowy wybór." ;;
                esac
                menu_pause
                ;;
            4)
                echo
                echo "1) Pokaż dane Home Assistant (UWAGA: pokazuje hasło)"
                echo "2) LAN auto"
                echo "3) Wyłącz LAN"
                echo "4) Ustaw konkretny IP LAN"
                echo "5) Ustaw port LAN/HA"
                echo "0) Anuluj"
                read -r -p "Wybór: " v
                case "${v}" in
                    1)
                        if menu_confirm_word POKAZ "Na ekranie zostanie wyświetlone HASŁO konta Home Assistant."; then /usr/local/sbin/nut-ha-info; else echo "Anulowano."; fi
                        ;;
                    2) set_key NUT_LISTEN_IP auto ;;
                    3) set_key NUT_LISTEN_IP off ;;
                    4) read -r -p "Adres IPv4/IPv6 hosta: " ip; set_key NUT_LISTEN_IP "${ip}" ;;
                    5) read -r -p "Port [1-65535]: " port; set_key NUT_PORT "${port}" ;;
                    0) : ;;
                    *) echo "Nieprawidłowy wybór." ;;
                esac
                menu_pause
                ;;
            5)
                echo
                echo "1) Status monitora"
                echo "2) Włącz monitor (wymaga OL)"
                echo "3) Wyłącz monitor (wyłącza automatyczną ochronę)"
                echo "0) Anuluj"
                read -r -p "Wybór: " v
                case "${v}" in
                    1) monitor_cmd status ;;
                    2) monitor_cmd enable ;;
                    3) if menu_confirm_word WYLACZ "Po wyłączeniu nut-monitor host nie reaguje automatycznie na awarię zasilania."; then monitor_cmd disable; else echo "Anulowano."; fi ;;
                    0) : ;;
                    *) echo "Nieprawidłowy wybór." ;;
                esac
                menu_pause
                ;;
            6) menu_bypass ;;
            7) menu_powercycle ;;
            8)
                echo
                echo "1) Status MQTT"
                echo "2) Konfiguruj/testuj MQTT"
                echo "3) Pokaż konfigurację bez hasła"
                echo "4) Zmień interwał publikacji"
                echo "5) Wyłącz MQTT"
                echo "0) Anuluj"
                read -r -p "Wybór: " v
                case "${v}" in
                    1) mqtt_cmd status ;;
                    2) mqtt_cmd setup ;;
                    3) mqtt_cmd show ;;
                    4) read -r -p "Interwał [5-3600 s]: " sec; mqtt_cmd interval "${sec}" ;;
                    5) mqtt_cmd disable ;;
                    0) : ;;
                    *) echo "Nieprawidłowy wybór." ;;
                esac
                menu_pause
                ;;
            9)
                echo
                echo "1) nut-status — szybki stan UPS"
                echo "2) capabilities — dane/komendy/RW urządzenia"
                echo "3) ostatnie 100 linii logów"
                echo "4) pełny raport diagnostyczny"
                echo "5) bezpieczna instrukcja pierwszego testu"
                echo "0) Anuluj"
                read -r -p "Wybór: " v
                case "${v}" in
                    1) /usr/local/sbin/nut-status ;;
                    2) /usr/local/sbin/nut-capabilities ;;
                    3) /usr/local/sbin/nut-logs 100 ;;
                    4) /usr/local/sbin/nut-report ;;
                    5) /usr/local/sbin/nut-test-guide ;;
                    0) : ;;
                    *) echo "Nieprawidłowy wybór." ;;
                esac
                menu_pause
                ;;
            10)
                echo
                echo "1) Utwórz backup teraz"
                echo "2) Rollback ostatniej zmiany nut-config"
                echo "0) Anuluj"
                read -r -p "Wybór: " v
                case "${v}" in
                    1) backup_now ;;
                    2) if menu_confirm_word PRZYWROC "Rollback zastąpi bieżące pliki NUT ostatnim backupem."; then require_normal_mode; [[ -f "${BASE}/LAST_CONFIG_BACKUP" ]] || die "Brak LAST_CONFIG_BACKUP."; restore_backup_dir "$(cat "${BASE}/LAST_CONFIG_BACKUP")"; else echo "Anulowano."; fi ;;
                    0) : ;;
                    *) echo "Nieprawidłowy wybór." ;;
                esac
                menu_pause
                ;;
            11)
                echo
                echo "Aktualizacja wymaga podłączonego UPS w stabilnym OL."
                echo "Nie działa w BYPASS. Przed pobraniem zostanie utworzony backup."
                echo "Źródło: oficjalna gałąź main repo Q-Tronic/proxmox-nut-powerwalker."
                if menu_confirm_word AKTUALIZUJ "Skrypt pobierze i uruchomi kod instalatora jako root."; then
                    if update_project; then
                        echo
                        echo "Aktualizacja zakończona. Zamykam stare menu."
                        echo "Uruchom ponownie: nut-config menu"
                        exit 0
                    else
                        warn "Aktualizacja nie została zakończona poprawnie. Sprawdź komunikaty powyżej."
                    fi
                else
                    echo "Anulowano."
                fi
                menu_pause
                ;;
            12) help_text; menu_pause ;;
            0) exit 0 ;;
            *) echo "Nieprawidłowy wybór."; menu_pause ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Tryb instalacyjny
# ------------------------------------------------------------------------------

if [[ "${1:-}" == "--install" ]]; then
    install_self
    exit 0
fi

# Dalsze operacje muszą być serializowane.
exec 9>"${LOCK}"
flock -w 30 9 || die "Inny proces nut-config jest już uruchomiony."

load_settings

PROG="$(basename "$0")"

if [[ "${PROG}" == "nut-delay" ]]; then
    if [[ $# -eq 0 ]]; then
        echo "${SHUTDOWN_DELAY}"
        exit 0
    fi

    set_key SHUTDOWN_DELAY "$1"
    load_settings
    echo "Shutdown delay: ${SHUTDOWN_DELAY}s"
    exit 0
fi

cmd="${1:-show}"
shift || true

case "${cmd}" in
    show)
        show
        ;;
    menu)
        menu
        ;;
    help|-h|--help)
        help_text
        ;;
    apply)
        require_normal_mode
        load_creds
        apply_current
        ;;
    delay)
        if [[ $# -eq 0 ]]; then
            echo "${SHUTDOWN_DELAY}"
        else
            set_key SHUTDOWN_DELAY "$1"
        fi
        ;;
    timed)
        [[ $# -eq 1 ]] || die "nut-config timed on|off"
        set_key TIMED_SHUTDOWN "$1"
        ;;
    lowbatt)
        [[ $# -eq 1 ]] || die "nut-config lowbatt on|off"
        set_key LOWBATT_SHUTDOWN "$1"
        ;;
    listen)
        if [[ $# -eq 0 ]]; then
            echo "${NUT_LISTEN_IP}"
        else
            set_key NUT_LISTEN_IP "$1"
        fi
        ;;
    port)
        if [[ $# -eq 0 ]]; then
            echo "${NUT_PORT}"
        else
            set_key NUT_PORT "$1"
        fi
        ;;
    set)
        [[ $# -ge 2 ]] || die "nut-config set KLUCZ WARTOŚĆ"
        key="$1"
        shift
        set_key "${key}" "$*"
        ;;
    get)
        [[ $# -eq 1 ]] || die "nut-config get KLUCZ"
        key="$1"
        case "${key}" in
            UPS_NAME|UPS_DESC|UPS_DRIVER|UPS_PORT|UPS_VENDORID|UPS_PRODUCTID|UPS_SUBDRIVER|NUT_LISTEN_IP|NUT_PORT|SHUTDOWN_DELAY|TIMED_SHUTDOWN|LOWBATT_SHUTDOWN|POLLFREQ|POLLFREQALERT|HOSTSYNC|DEADTIME|FINALDELAY|RBWARNTIME|NOCOMMWARNTIME|LOG_ROTATE_SIZE|LOG_ROTATE_COUNT|UPSMON_ROLE|POWERCYCLE_ENABLED|POWERCYCLE_OFFDELAY|POWERCYCLE_ONDELAY)
                printf '%s\n' "${!key}"
                ;;
            *)
                die "Nieznany klucz."
                ;;
        esac
        ;;
    ups)
        sub="${1:-show}"
        case "${sub}" in
            show)
                echo "UPS_NAME=${UPS_NAME} (stałe)"
                echo "UPS_DESC=${UPS_DESC}"
                echo "UPS_DRIVER=${UPS_DRIVER}"
                echo "UPS_PORT=${UPS_PORT}"
                echo "UPS_VENDORID=${UPS_VENDORID}"
                echo "UPS_PRODUCTID=${UPS_PRODUCTID}"
                echo "UPS_SUBDRIVER=${UPS_SUBDRIVER}"
                ;;
            auto)
                detect_ups
                ;;
            *)
                die "nut-config ups show|auto"
                ;;
        esac
        ;;
    usb)
        set_usb_pair "$@"
        ;;
    ha)
        sub="${1:-show}"
        case "${sub}" in
            show)
                /usr/local/sbin/nut-ha-info
                ;;
            rotate)
                rotate_credential ha
                /usr/local/sbin/nut-ha-info
                ;;
            *)
                die "nut-config ha show|rotate"
                ;;
        esac
        ;;
    primary)
        sub="${1:-}"
        case "${sub}" in
            rotate)
                rotate_credential primary
                ;;
            *)
                die "nut-config primary rotate"
                ;;
        esac
        ;;
    mqtt)
        mqtt_cmd "$@"
        ;;
    bypass)
        sub="${1:-status}"
        case "${sub}" in
            status)
                bypass_status
                ;;
            enable|enter|on)
                bypass_enable
                ;;
            disable|resume|off)
                bypass_resume
                ;;
            *)
                die "nut-config bypass status|enable|disable"
                ;;
        esac
        ;;
    resume)
        bypass_resume
        ;;
    monitor)
        monitor_cmd "${1:-status}"
        ;;
    update)
        [[ $# -eq 0 ]] || die "Użycie: nut-config update"
        update_project
        ;;
    backup)
        echo "$(backup_now)"
        ;;
    rollback)
        require_normal_mode
        [[ -f "${BASE}/LAST_CONFIG_BACKUP" ]] || die "Brak LAST_CONFIG_BACKUP."
        restore_backup_dir "$(cat "${BASE}/LAST_CONFIG_BACKUP")"
        ;;
    report)
        echo "=== Q-Tronic settings ==="
        cat "${SETTINGS}"
        echo
        /usr/local/sbin/nut-report
        ;;
    capabilities)
        /usr/local/sbin/nut-capabilities
        ;;
    logs)
        /usr/local/sbin/nut-logs "${1:-100}"
        ;;
    powercycle)
        sub="${1:-status}"
        shift || true
        case "${sub}" in
            probe)
                powercycle_probe 0
                ;;
            status)
                powercycle_status
                ;;
            delays)
                powercycle_delays "$@"
                ;;
            enable)
                powercycle_enable
                ;;
            disable)
                powercycle_disable
                ;;
            *)
                die "nut-config powercycle probe|status|delays OFF ON|enable|disable"
                ;;
        esac
        ;;
    *)
        help_text
        exit 2
        ;;
esac
