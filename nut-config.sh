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
    upsc "$(local_target)" 2>/dev/null | sed -n 's/^ups.status: //p' | head -n1
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
    local d="${CFG_BACKUPS}/config-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${d}"
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
        /etc/nut/nut-mqtt.json; do
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
SHUTDOWNCMD "$(command -v shutdown) -h now"
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
    load_settings
    load_creds
    validate_settings
    require_safe_change_window

    local previous_monitor backup tmp result status
    previous_monitor="$(systemctl is-active nut-monitor.service 2>/dev/null || true)"
    backup="$(backup_now)"
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
    echo "BŁĄD: brak komunikacji z ${UPS_NAME}@localhost"
    echo "${RAW}"
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
    local resolved status
    resolved="$(resolve_listen_ip)"
    status="$(status_now || true)"

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

mqtt_cmd() {
    local sub="${1:-status}"
    case "${sub}" in
        setup|config)
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
            systemctl restart nut-mqtt.service
            ok "MQTT interval=${sec}s"
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

help_text() {
    cat <<'EOF_HELP'
Q-Tronic nut-config

Podstawowe:
  nut-config show
  nut-config menu
  nut-config apply
  nut-config help

Shutdown:
  nut-delay
  nut-delay 90
  nut-delay 2m
  nut-delay 1h
  nut-config timed on|off
  nut-config lowbatt on|off

Home Assistant / NUT LAN:
  nut-config listen auto
  nut-config listen off
  nut-config listen 192.168.1.10
  nut-config port 3493
  nut-config ha show
  nut-config ha rotate

Parametry NUT:
  nut-config set POLLFREQ 5
  nut-config set POLLFREQALERT 5
  nut-config set HOSTSYNC 15
  nut-config set DEADTIME 15
  nut-config set FINALDELAY 5
  nut-config set RBWARNTIME 43200
  nut-config set NOCOMMWARNTIME 300

UPS / USB:
  nut-config ups show
  nut-config ups auto
  nut-config usb 0764 0601
  nut-config usb auto auto
  nut-config set UPS_DESC "PowerWalker VI 2200 STL FR"
  nut-config set UPS_DRIVER usbhid-ups
  nut-config set UPS_PORT auto
  nut-config set UPS_SUBDRIVER "CyberPower HID"

Logi:
  nut-config set LOG_ROTATE_SIZE 512k
  nut-config set LOG_ROTATE_COUNT 6
  nut-config logs 100

MQTT:
  nut-config mqtt setup
  nut-config mqtt status
  nut-config mqtt show
  nut-config mqtt interval 15
  nut-config mqtt disable

Hasła:
  nut-config ha rotate
  nut-config primary rotate

Monitor:
  nut-config monitor status
  nut-config monitor enable
  nut-config monitor disable

Backup/diagnostyka:
  nut-config backup
  nut-config rollback
  nut-config report
  nut-config capabilities
  nut-config powercycle status

Zasady bezpieczeństwa:
- localhost:3493 pozostaje stałym wewnętrznym control-plane NUT.
- Zmienny port dotyczy tylko dostępu LAN/Home Assistant.
- Każda zmiana konfiguracji tworzy backup.
- Gdy aktywny monitor widzi OB/brak odpowiedzi, zmiana jest blokowana.
- Po zmianie wymagane jest stabilne OL; inaczej następuje rollback.
- UPS_NAME jest celowo stałym identyfikatorem logicznym.
- Fizyczne odcinanie 230 V nie jest włączane automatycznie.
EOF_HELP
}

menu() {
    while true; do
        echo
        echo "Q-Tronic NUT - konfiguracja"
        echo "1) Pokaż ustawienia"
        echo "2) Shutdown delay"
        echo "3) Timed shutdown ON/OFF"
        echo "4) LOWBATT shutdown ON/OFF"
        echo "5) NUT LAN IP"
        echo "6) NUT LAN port"
        echo "7) Auto-detect UPS USB"
        echo "8) Home Assistant"
        echo "9) MQTT"
        echo "10) Monitor NUT"
        echo "11) Raport"
        echo "0) Wyjście"
        read -r -p "Wybór: " choice

        case "${choice}" in
            1) show ;;
            2) read -r -p "Czas (90 / 2m / 1h): " v; set_key SHUTDOWN_DELAY "${v}" ;;
            3) read -r -p "on/off: " v; set_key TIMED_SHUTDOWN "${v}" ;;
            4) read -r -p "on/off: " v; set_key LOWBATT_SHUTDOWN "${v}" ;;
            5) read -r -p "auto / off / IP: " v; set_key NUT_LISTEN_IP "${v}" ;;
            6) read -r -p "Port: " v; set_key NUT_PORT "${v}" ;;
            7) detect_ups ;;
            8) /usr/local/sbin/nut-ha-info ;;
            9) /usr/local/sbin/nut-mqtt-config ;;
            10) read -r -p "status/enable/disable: " v; monitor_cmd "${v}" ;;
            11) /usr/local/sbin/nut-report ;;
            0) exit 0 ;;
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
            UPS_NAME|UPS_DESC|UPS_DRIVER|UPS_PORT|UPS_VENDORID|UPS_PRODUCTID|UPS_SUBDRIVER|NUT_LISTEN_IP|NUT_PORT|SHUTDOWN_DELAY|TIMED_SHUTDOWN|LOWBATT_SHUTDOWN|POLLFREQ|POLLFREQALERT|HOSTSYNC|DEADTIME|FINALDELAY|RBWARNTIME|NOCOMMWARNTIME|LOG_ROTATE_SIZE|LOG_ROTATE_COUNT|UPSMON_ROLE)
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
    monitor)
        monitor_cmd "${1:-status}"
        ;;
    backup)
        echo "$(backup_now)"
        ;;
    rollback)
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
        case "${sub}" in
            status)
                /usr/local/sbin/nut-phase2-check
                echo
                echo "Automatyczne włączanie power-cycle pozostaje zablokowane."
                echo "Najpierw potwierdzamy możliwości konkretnej sztuki UPS."
                ;;
            *)
                die "Obecnie dostępne: nut-config powercycle status"
                ;;
        esac
        ;;
    *)
        help_text
        exit 2
        ;;
esac
