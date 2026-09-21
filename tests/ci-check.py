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

# Bash files can embed small Python helpers. Parse every quoted PY/PY_* heredoc.
for rel in ["nut-config.sh", "setup-nut-powerwalker-proxmox.sh", "install.sh"]:
    text = (root / rel).read_text()
    for idx, block in enumerate(
        re.findall(r"<<'PY(?:_[A-Z0-9]+)?'\n(.*?)\nPY(?:_[A-Z0-9]+)?\n", text, flags=re.S),
        1,
    ):
        try:
            ast.parse(block)
        except SyntaxError as exc:
            raise SystemExit(f"{rel}: embedded Python #{idx}: {exc}")

# YAML shipped by the project and workflow YAML must remain parseable.
yaml_paths = [
    root / "home-assistant" / "automations-example.yaml",
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

# Public repo cleanup invariant.
if (root / "GITHUB-MOBILE.md").exists():
    raise SystemExit("GITHUB-MOBILE.md must not exist")

print("ci-check: OK")
