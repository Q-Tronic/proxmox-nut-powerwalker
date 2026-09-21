#!/usr/bin/env python3
from pathlib import Path
import ast
import re
import yaml

root = Path(__file__).resolve().parents[1]

version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-.+][0-9A-Za-z.-]+)?", version):
    raise SystemExit("invalid VERSION")

nut = (root / "nut-config.sh").read_text()
if f'QTRONIC_VERSION="{version}"' not in nut:
    raise SystemExit("VERSION != QTRONIC_VERSION")

# Bash files can embed Python helpers in quoted heredocs, including forms
# like <<'PY_LABEL' || die ... . Parse every such block, not only the simplest syntax.
def quoted_python_heredocs(text):
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.search(r"<<'(?P<label>PY(?:_[A-Z0-9]+)?)'", lines[i])
        if not m:
            i += 1
            continue
        label = m.group("label")
        start = i + 1
        i = start
        while i < len(lines) and lines[i].strip() != label:
            i += 1
        if i >= len(lines):
            raise SystemExit(f"unterminated embedded Python heredoc: {label}")
        yield "\n".join(lines[start:i]) + "\n"
        i += 1

for rel in ["nut-config.sh", "setup-nut-powerwalker-proxmox.sh", "install.sh"]:
    text = (root / rel).read_text()
    for idx, block in enumerate(quoted_python_heredocs(text), 1):
        try:
            ast.parse(block)
        except SyntaxError as exc:
            raise SystemExit(f"{rel}: embedded Python #{idx}: {exc}")

# YAML shipped by the project and workflow YAML must remain parseable.
yaml_paths = [
    root / "home-assistant" / "automations-example.yaml",
    root / "home-assistant" / "automations-nut-example.yaml",
    root / "home-assistant" / "automations-mqtt-example.yaml",
    root / ".github" / "workflows" / "ci.yml",
    root / ".github" / "workflows" / "release.yml",
]
for path in yaml_paths:
    if path.exists():
        yaml.safe_load(path.read_text())

readme = (root / "README.md").read_text()

help_match = re.search(
    r"help_text\(\)\s*\{\s*cat <<'EOF_HELP'\n(.*?)\nEOF_HELP\n\}",
    nut,
    flags=re.S,
)
if not help_match:
    raise SystemExit("cannot locate nut-config help_text")
help_text = help_match.group(1)

helpers = [
    "nut-status",
    "nut-watch",
    "nut-capabilities",
    "nut-phase2-check",
    "nut-logs",
    "nut-test-guide",
    "nut-restart",
    "nut-report",
    "nut-ha-info",
    "nut-mqtt-config",
    "nut-mqtt-disable",
    "nut-rollback",
    "nut-delay",
]
public_commands = [
    "nut-config show",
    "nut-config menu",
    "nut-config help",
    "nut-config apply",
    "nut-config version",
    "nut-config doctor",
    "nut-config test",
    "nut-config selftest probe",
    "nut-config selftest quick TESTUJ",
    "nut-config selftest cleanup",
    "nut-config watchdog",
    "nut-config update",
    "nut-config update --check",
    "nut-config update channel main",
    "nut-config update channel stable",
    "nut-config backup",
    "nut-config backup list",
    "nut-config backup restore",
    "nut-config backup prune",
    "nut-config rollback",
    "nut-config report",
    "nut-config report --public",
    "nut-config capabilities",
    "nut-config logs",
    "nut-config powercycle probe",
    "nut-config powercycle status",
    "nut-config powercycle delays",
    "nut-config powercycle enable",
    "nut-config powercycle disable",
    "nut-config bypass status",
    "nut-config bypass enable",
    "nut-config resume",
    "nut-config monitor status",
    "nut-config monitor enable",
    "nut-config monitor disable",
    "nut-config timed on",
    "nut-config timed off",
    "nut-config lowbatt status",
    "nut-config lowbatt on",
    "nut-config lowbatt off",
    "nut-config listen",
    "nut-config port",
    "nut-config ha show",
    "nut-config ha rotate",
    "nut-config ups show",
    "nut-config ups auto",
    "nut-config usb",
    "nut-config mqtt setup",
    "nut-config mqtt status",
    "nut-config mqtt show",
    "nut-config mqtt interval",
    "nut-config mqtt disable",
    "nut-config primary rotate",
    "nut-config get",
    "nut-config set",
]
for cmd in helpers + public_commands:
    if cmd not in readme:
        raise SystemExit(f"README missing: {cmd}")
    if cmd not in help_text:
        raise SystemExit(f"nut-config help missing: {cmd}")

# Home Assistant observer account must remain monitoring-only.
for rel in ["nut-config.sh", "setup-nut-powerwalker-proxmox.sh"]:
    text = (root / rel).read_text()
    for match in re.finditer(
        r"\[homeassistant\](.*?)(?=\n\[[^\n]+\]|EOF|$)", text, flags=re.S
    ):
        body = match.group(1).lower()
        if "instcmds" in body or "actions =" in body:
            raise SystemExit(f"{rel}: HA has command privileges")

# RC1 safety/correctness invariants.
setup = (root / "setup-nut-powerwalker-proxmox.sh").read_text()
install = (root / "install.sh").read_text()

for rel, text in [("nut-config.sh", nut), ("setup-nut-powerwalker-proxmox.sh", setup)]:
    if "EXECUTE emergency_shutdown" in text or "EMERGENCY: LOWBATT" in text:
        raise SystemExit(f"{rel}: redundant LOWBATT emergency FSD must not exist")
    if "CANCEL-TIMER shutdown_on_battery timer_cancel_failed" not in text:
        raise SystemExit(f"{rel}: missing CANCEL-TIMER fallback")

if 'lowbatt off jest celowo zablokowane' not in nut.lower():
    raise SystemExit("nut-config must reject lowbatt off")
if 'PENDING_NOT_ARMED' not in nut or 'powercycle_runtime_state' not in nut:
    raise SystemExit("power-cycle armed/pending state missing")
if nut.count('powercycle_probe 0 1') != 1 or 'local quiet="${1:-0}" commit="${2:-0}"' not in nut:
    raise SystemExit("powercycle capability commit must be explicit and limited to enable")
if 'Probe nie wysłał żadnej komendy UPS ani nie zmienił capability gate.' not in nut:
    raise SystemExit("read-only powercycle probe invariant missing")
if 'file-state.txt' not in nut or 'backup-format.txt' not in nut or 'format=2' not in nut:
    raise SystemExit("backup v2 manifest missing")
if 'nut-mqtt działa podczas BYPASS' not in nut:
    raise SystemExit("doctor must check MQTT during BYPASS")
if 'bypass_services_quiesced' not in nut or 'require_bypass_services_quiesced' not in nut:
    raise SystemExit("BYPASS must verify monitor and MQTT active/enabled state before ready")
if '[[ "${BYPASS_READY:-0}" == "1" ]] && bypass_services_quiesced' not in nut:
    raise SystemExit("BYPASS status/doctor must not trust a stale ready flag")
if '127.0.0.1:3493 nasłuchuje' not in nut:
    raise SystemExit("doctor localhost listener check missing")
if 'selftest cleanup' not in nut or 'remove_reserved_selftest_user' not in nut:
    raise SystemExit("self-test orphan cleanup missing")
if 'deadline timera liczonego od zdarzenia ONBATT' not in nut or 'CANCEL-FAILED:' not in nut:
    raise SystemExit("guided cancellation verification missing")
if 'power-cycle disabled, ale pozostał runtime/flag' not in nut:
    raise SystemExit("stale power-cycle runtime detection missing")
if 'fingerprint power-cycle nie pasuje do aktualnego UPS' not in nut:
    raise SystemExit("watchdog current UPS fingerprint check missing")
if 'Nie udało się odtworzyć stanu ${unit}' not in nut:
    raise SystemExit("restore service-state failure propagation missing")
if 'Backup v2 jest niekompletny (brak manifestu).' not in nut or 'Nieoczekiwana ścieżka w manifeście backupu' not in nut:
    raise SystemExit("backup v2 manifest validation missing")
if 'Wymagany plik backupu nie może być oznaczony jako absent:' not in nut:
    raise SystemExit("backup v2 must reject absent critical files")
if 'if ! validate_backup_v2 "${d}"; then' not in nut:
    raise SystemExit("new backup v2 must be validated before becoming LAST")
if 'Nieoczekiwana jednostka w manifeście backupu' not in nut or 'Manifest usług backupu v2 jest niekompletny lub zduplikowany.' not in nut:
    raise SystemExit("backup v2 service manifest validation missing")
if 'Backup ma power-cycle=ON, ale nie zawiera własnego capability fingerprintu.' not in nut:
    raise SystemExit("power-cycle restore must require capability fingerprint from selected backup")
if 'previous_monitor="$(systemctl is-active nut-monitor.service' in nut:
    raise SystemExit("config changes must preserve monitor active/enabled separately")
if nut.count('restore_service_state nut-monitor.service "${previous_monitor_active}" "${previous_monitor_enabled}"') < 2:
    raise SystemExit("apply/credential rotation must restore exact monitor active/enabled state")
if 'if bash "${PERSISTENT_INSTALLER}"; then' not in install:
    raise SystemExit("install.sh does not safely capture setup rc under set -e")
if 'if bash "${PERSISTENT_CONFIG}" --install; then' not in install:
    raise SystemExit("install.sh does not safely capture config rc under set -e")
if 'len(exact) > 1' not in setup or 'known_usb_count > 1' not in setup or 'Sam VID/PID nie rozróżni bezpiecznie egzemplarzy' not in setup:
    raise SystemExit("setup must reject ambiguous identical UPS detection")

# Final five-point installer/rollback hotfix invariants.
if 'BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/nut-${TS}-XXXXXX")"' not in setup:
    raise SystemExit("installer backup directory must be collision-safe")
if 'Preflight aktualizacji/reinstalacji:' not in setup or 'Nie aktualizuję/reinstaluję podczas pracy z baterii.' not in setup:
    raise SystemExit("managed reinstall must require stable OL before changes")
if setup.index('Preflight aktualizacji/reinstalacji:') > setup.index('info "Tworzę backup bieżącej konfiguracji NUT..."'):
    raise SystemExit("managed reinstall preflight must run before installer snapshot/change phase")
for line in ['service_state nut-mqtt.service', 'service_state qtronic-nut-health.timer']:
    if line not in setup:
        raise SystemExit(f"installer snapshot missing optional service state: {line}")
rollback_match = re.search(
    r'atomic_install "\$\{LIB_DIR\}/rollback-last-backup\.sh" root root 0755 <<\'EOF_ROLLBACK\'\n(.*?)\nEOF_ROLLBACK',
    setup,
    flags=re.S,
)
if not rollback_match:
    raise SystemExit("cannot locate strict installer snapshot rollback helper")
rollback = rollback_match.group(1)
if 'require_restored_ol' not in rollback or 'Monitor pozostaje rozbrojony' not in rollback:
    raise SystemExit("installer rollback must validate OL before restoring active monitor")
if 'restore_unit_state qtronic-nut-health.timer' not in rollback or 'restore_enable_state nut-mqtt.service' not in rollback:
    raise SystemExit("installer rollback must restore optional service state")
if 'NO_ETC_NUT_BEFORE_INSTALL' not in rollback or 'rm -rf /etc/nut' not in rollback:
    raise SystemExit("installer rollback must restore absence of /etc/nut")
if 'nut-rollback NIE cofa wersji kodu i NIE odinstalowuje pakietów.' not in rollback:
    raise SystemExit("installer rollback scope must be explicit")
if re.search(r'systemctl (?:start|restart) nut-monitor\.service[^\n]*\|\| true', rollback):
    raise SystemExit("installer rollback must not swallow monitor start failures")

release_workflow = (root / ".github" / "workflows" / "release.yml").read_text()
if '--prerelease' not in release_workflow or '== *-*' not in release_workflow:
    raise SystemExit("RC tags must be published as GitHub prereleases")

nut_ha = (root / "home-assistant" / "automations-nut-example.yaml").read_text()
mqtt_ha = (root / "home-assistant" / "automations-mqtt-example.yaml").read_text()
if "sensor.ups_status" not in nut_ha or "sensor.ups_battery_charge" not in nut_ha:
    raise SystemExit("official NUT HA examples missing expected sensors")
if "binary_sensor.powerwalker" in nut_ha:
    raise SystemExit("official NUT HA example contains MQTT entities")
if "binary_sensor.powerwalker" not in mqtt_ha:
    raise SystemExit("MQTT HA example does not contain MQTT-discovered entities")
if (root / "home-assistant" / "automations-example.yaml").read_text() != nut_ha:
    raise SystemExit("automations-example.yaml must be exact compatibility copy of NUT example")

# Public repo cleanup invariant.
if (root / "GITHUB-MOBILE.md").exists():
    raise SystemExit("GITHUB-MOBILE.md must not exist")

print("ci-check: OK")
