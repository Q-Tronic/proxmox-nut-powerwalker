# Changelog

## 1.0.0 - 2026-09-21

Pierwsze wersjonowane wydanie publiczne.

### Safety
- `nut-config doctor` z wynikami `PASS / WARN / FAIL`;
- prowadzony, ograniczony czasowo test `OL -> OB -> OL`;
- tryb BYPASS i bezpieczny `resume` pozostają integralną częścią ochrony;
- dodatkowe zabezpieczenie restore backupu z aktywnym power-cycle: fail-closed runtime przed restore, świeży capability probe po restarcie i rollback bezpieczeństwa przy błędzie;
- warunkowy quick self-test baterii z minimalnym tymczasowym kontem NUT;
- opcjonalny read-only health watchdog; domyślnie wyłączony;
- ostrzeżenie o wielowęzłowym klastrze Proxmox w `doctor`;
- `nut-report --public` z best-effort redakcją danych identyfikujących.

### Operations
- `VERSION` i `nut-config version`;
- kanały aktualizacji `main` / `stable`;
- `nut-config update --check` i `--force`;
- historia backupów: create/list/restore/prune oraz konfigurowalna retencja;
- rozszerzone menu i `nut-config help`.

### Repository quality
- GitHub Actions CI;
- sprawdzanie Bash, ShellCheck, osadzonego Pythona i YAML;
- kontrola zgodności `VERSION` z kodem;
- kontrola dokumentacji publicznych komend;
- tag-driven GitHub Releases dla tagów `vX.Y.Z`;
- rozbudowana dokumentacja README.
