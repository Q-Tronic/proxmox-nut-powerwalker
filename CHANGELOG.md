# Changelog

## 1.0.0-rc1 — 2026-09-21

Finalny kandydat przed testami na fizycznym PowerWalkerze.

### Safety / correctness

- LOWBATT/`OB+LB` pozostawiono natywnemu mechanizmowi `upsmon`; usunięto redundantny własny `emergency_shutdown` i możliwość sugerowania, że tę ochronę można wyłączyć.
- `CANCEL-TIMER shutdown_on_battery` dostał fallback `timer_cancel_failed`; prowadzony test `OL -> OB -> OL` sprawdza logi i, gdy dostępne, `upssched -l`.
- Operacje renderujące/restartujące konfigurację wymagają stabilnego `OL` niezależnie od stanu `nut-monitor`.
- Backup v2 zapisuje obecność/brak plików i osobne stany `active/enabled` monitora, MQTT i health-watchdoga.
- Udane zmiany konfiguracji i rotacja haseł zachowują dokładnie oba stany `active/enabled` `nut-monitor` (np. ręcznie uruchomiony, ale disabled, nie staje się przypadkiem enabled).
- Restore fail-closed: błąd restartu/walidacji lub odtworzenia stanu usług propaguje się, monitor wraca tylko po potwierdzonym `OL`, a nieudany restore próbuje wrócić do backupu bezpieczeństwa.
- Restore v2 waliduje whitelistę ścieżek/jednostek i kompletność manifestów; wymagany plik nie może być oznaczony jako nieobecny, a power-cycle z backupu wymaga capability fingerprintu zapisnego w tym samym backupie i zgodnego z aktualnym UPS.
- Power-cycle rozróżnia stan skonfigurowany od faktycznie uzbrojonego runtime (`DISABLED` / `ARMED` / `PENDING_NOT_ARMED`). Aktualizacja bez możliwości świeżej walidacji utrwala `POWERCYCLE_ENABLED=0`.
- `powercycle probe/status` nie nadpisuje już zapisanego capability fingerprintu; nowy fingerprint może zostać utrwalony wyłącznie podczas świadomego `powercycle enable`, więc samo sprawdzenie po podmianie UPS-a nie przepina autoryzacji.
- Dodatkowa walidacja `UPS_NAME`, `UPS_PORT`, `UPS_SUBDRIVER`, opisu i `UPSMON_ROLE`.
- `doctor` i watchdog sprawdzają lokalny nasłuch 127.0.0.1:3493, MQTT w BYPASS, zgodność `SHUTDOWNCMD` z power-cycle, bieżący fingerprint UPS, stale runtime i osierocone konto self-test.
- Dodano `nut-config selftest cleanup`; instalacja/aktualizacja usuwa zarezerwowane osierocone konto self-test.
- `install.sh` poprawnie przechwytuje kody błędów setupu i konfiguratora mimo `set -e`.

### Home Assistant

- Rozdzielono przykłady na `automations-nut-example.yaml` (oficjalna integracja NUT) i `automations-mqtt-example.yaml` (MQTT Discovery).
- Tag z sufiksem pre-release (np. `v1.0.0-rc1`) jest automatycznie publikowany jako GitHub **pre-release**, dzięki czemu nie zasila kanału `stable`.
- `automations-example.yaml` pozostaje kopią zgodnościową przykładu oficjalnej integracji NUT.

### CI / docs

- Rozszerzono `tests/ci-check.py` o inwarianty LOWBATT, CANCEL-TIMER, backup v2, safe-change, power-cycle runtime, cleanup self-test i rozdzielenie przykładów HA.
- README i `nut-config help` opisują zachowanie RC1 i nowe zabezpieczenia.

## 1.0.0 — pre-release baseline

Pierwszy zestaw funkcji Quality & Safety przygotowany przed audytem RC1: BYPASS, guarded power-cycle, doctor, guided test, backupy, public report, watchdog, self-test framework, wersjonowanie, kanały aktualizacji, GitHub CI i Release workflow.
