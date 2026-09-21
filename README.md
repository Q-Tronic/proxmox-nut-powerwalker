# Proxmox NUT PowerWalker

Bezpieczna integracja UPS z **Proxmox VE** przy użyciu **Network UPS Tools (NUT)**, z opcjonalnym monitoringiem w **Home Assistant** i przez **MQTT**.

Projekt jest przygotowany przede wszystkim dla **PowerWalker VI 2200 STL FR**. Może działać także z innymi UPS-ami USB HID obsługiwanymi przez NUT, ale możliwości zależą od konkretnego modelu, firmware i sterownika.

Autor: **Q-Tronic**

## Najważniejsze założenia

- decyzję o shutdownie podejmuje lokalnie NUT na hoście Proxmox;
- Home Assistant i MQTT nie są wymagane do bezpiecznego wyłączenia serwera;
- domyślnie shutdown następuje po **60 sekundach ciągłej pracy na baterii**;
- jeśli zasilanie wróci przed upływem timera, shutdown jest anulowany;
- `LOWBATT` może rozpocząć natychmiastowy FSD;
- `nut-monitor` jest aktywowany dopiero po potwierdzeniu komunikacji z UPS-em i stabilnego statusu `OL`;
- fizyczny power-cycle UPS-a jest domyślnie **wyłączony**;
- konfiguracja power-cycle jest odblokowywana dopiero po sprawdzeniu możliwości aktualnie podłączonego UPS-a.

## Wymagania

- Proxmox VE / Debian z `systemd`;
- dostęp `root`;
- UPS podłączony do hosta przez USB;
- dostęp do Internetu podczas instalacji pakietów i pobrania skryptów.

Skrypt instaluje wymagane pakiety NUT i narzędzia pomocnicze.

## Instalacja

Uruchom jako `root` na hoście Proxmox:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Instalator:

1. wykonuje backup istniejącej konfiguracji NUT;
2. nie nadpisuje obcej konfiguracji bez jawnego `FORCE=1`;
3. próbuje wykryć UPS przez `nut-scanner`;
4. konfiguruje NUT;
5. sprawdza komunikację przez `upsc`;
6. aktywuje `nut-monitor` tylko wtedy, gdy UPS odpowiada i raportuje stabilne `OL`;
7. instaluje `nut-config`, który służy do późniejszej konfiguracji.

Po zakończeniu sprawdź:

```bash
nut-status
```

## Konfiguracja po instalacji

Aktualne ustawienia:

```bash
nut-config show
```

Menu interaktywne:

```bash
nut-config menu
```

Pełna lista dostępnych poleceń:

```bash
nut-config help
```

### Czas do shutdownu

Przykłady:

```bash
nut-delay 90
nut-delay 2m
nut-delay 1h
```

Aktualna wartość:

```bash
nut-delay
```

### Polityka shutdownu

Timer po przejściu na baterię:

```bash
nut-config timed on
nut-config timed off
```

Reakcja na `LOWBATT`:

```bash
nut-config lowbatt on
nut-config lowbatt off
```

Wyłączenie reakcji na `LOWBATT` zmniejsza poziom ochrony hosta i powinno być wykonywane świadomie.

### Dostęp NUT z sieci LAN

Automatycznie użyj adresu LAN hosta:

```bash
nut-config listen auto
```

Wyłącz dostęp NUT z LAN:

```bash
nut-config listen off
```

Ustaw konkretny adres:

```bash
nut-config listen 192.168.1.10
```

Port dla klientów LAN / Home Assistant:

```bash
nut-config port 3493
```

Lokalna komunikacja NUT na hoście pozostaje na `127.0.0.1:3493`.

## Home Assistant

Najprostszy wariant to oficjalna integracja **Network UPS Tools (NUT)**.

Wyświetl dane połączenia:

```bash
nut-ha-info
```

Następnie w Home Assistant:

**Ustawienia → Urządzenia i usługi → Dodaj integrację → Network UPS Tools (NUT)**

Użyj hosta, portu, użytkownika i hasła pokazanych przez `nut-ha-info`. Dla Home Assistanta warto używać stałego adresu IP, rezerwacji DHCP albo stabilnej nazwy DNS.

Konto `homeassistant` jest przeznaczone do monitoringu. Projekt nie przyznaje mu uprawnień do wykonywania poleceń UPS, dzięki czemu Home Assistant nie steruje procedurą shutdownu hosta.

Dodatkowe przykłady znajdują się w katalogu:

```text
home-assistant/
```

## MQTT

MQTT jest opcjonalny. Nie jest używany do podejmowania decyzji o shutdownie.

Konfiguracja:

```bash
nut-config mqtt setup
```

Status:

```bash
nut-config mqtt status
```

Podgląd konfiguracji bez hasła:

```bash
nut-config mqtt show
```

Zmiana interwału publikacji:

```bash
nut-config mqtt interval 15
```

Wyłączenie mostu:

```bash
nut-config mqtt disable
```

Most publikuje telemetrię UPS i korzysta z Home Assistant MQTT Discovery. Nie publikuje topiców sterujących UPS-em.

## Power-cycle UPS

Power-cycle jest funkcją opcjonalną i domyślnie pozostaje wyłączony.

Jego zadaniem jest umożliwienie pełnego odcięcia wyjścia UPS po bezpiecznym shutdownie hosta, a następnie ponownego zasilenia po powrocie sieci. Automatyczny start serwera po powrocie AC wymaga odpowiedniego ustawienia BIOS/UEFI, np. **Restore on AC Power Loss / Power On**.

### 1. Sprawdzenie możliwości

```bash
nut-config powercycle probe
```

`probe` jest operacją odczytową. Nie wysyła `shutdown.return` i nie odcina zasilania.

Power-cycle może zostać odblokowany tylko wtedy, gdy aktualny UPS raportuje wymaganą możliwość, w szczególności `shutdown.return`.

> Sam fakt raportowania komendy przez firmware nie gwarantuje jej poprawnego fizycznego działania. Pierwszy rzeczywisty test należy wykonać pod nadzorem.

### 2. Opóźnienia

Przykład:

```bash
nut-config powercycle delays 60 300
```

Dla `usbhid-ups` odpowiada to odpowiednio `offdelay` i `ondelay`.

### 3. Aktywacja

```bash
nut-config powercycle enable
```

Przy aktywacji oraz przed końcowym power-cycle skrypt ponownie sprawdza bieżący sprzęt i jego możliwości. Jeśli walidacja nie przejdzie, host może się bezpiecznie wyłączyć bez odcinania wyjścia UPS.

Status:

```bash
nut-config powercycle status
```

Wyłączenie:

```bash
nut-config powercycle disable
```

## Pierwszy test zaniku zasilania

Wyświetl przygotowaną procedurę:

```bash
nut-test-guide
```

Do podglądu statusu:

```bash
nut-watch
```

Podczas pierwszego testu odłącz **zasilanie wejściowe UPS-a od sieci**, a nie przewód serwera od UPS-a.

Sprawdź przejście:

```text
OL -> OB -> OL
```

i przywróć zasilanie przed upływem skonfigurowanego timera shutdownu.

Nie wykonuj ręcznie `upsmon -c fsd`, `shutdown.return` ani `load.off` jako zwykłego testu działającego serwera.

## Diagnostyka

Status:

```bash
nut-status
```

Pełne dane i możliwości UPS:

```bash
nut-capabilities
```

Logi:

```bash
nut-logs 100
```

Raport diagnostyczny:

```bash
nut-report
```

Raport ukrywa hasło z wpisu `MONITOR`, ale może zawierać adresy IP, dane systemu, identyfikatory USB lub numer seryjny UPS-a. Przejrzyj go przed opublikowaniem.

## Aktualizacja

Aby pobrać aktualną wersję projektu, uruchom ponownie:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Instalator zachowuje wygenerowane dane dostępowe i tworzy backup przed zmianą konfiguracji.

Aktualizację najlepiej wykonywać przy stabilnym zasilaniu i statusie UPS `OL`.

## Backup i rollback

Backup instalatora znajduje się w:

```text
/root/nut-powerwalker/backups/
```

Backup zmian wykonywanych przez `nut-config`:

```text
/root/nut-powerwalker/config-backups/
```

Przywrócenie ostatniej konfiguracji utworzonej przez instalator:

```bash
nut-rollback
```

Rollback przywraca konfigurację NUT; nie jest pełnym deinstalatorem pakietów i wszystkich plików pomocniczych.

## Bezpieczeństwo

- nie wystawiaj portu NUT do Internetu;
- ogranicz dostęp do zaufanego LAN/VLAN i odpowiednich reguł firewalla;
- nie publikuj `/root/nut-powerwalker/credentials.env`;
- nie publikuj `/etc/nut/nut-mqtt.json`;
- przed udostępnieniem `nut-report` przejrzyj zawartość raportu;
- nie aktywuj power-cycle bez pozytywnego `probe` i kontrolowanego testu konkretnego UPS-a.

## Zgodność

Głównym urządzeniem docelowym jest **PowerWalker VI 2200 STL FR**.

Instalator próbuje automatycznie wykryć urządzenie USB i zawiera obsługę znanego wariantu `0764:0601`. Inne urządzenia zgodne z NUT mogą działać, ale projekt nie zakłada pełnej kompatybilności ze wszystkimi UPS-ami.

Obsługa telemetrii, komend i power-cycle zależy od:

- modelu i firmware UPS-a;
- wersji NUT;
- użytego sterownika / subdrivera;
- możliwości raportowanych przez urządzenie.

## Licencja

MIT — szczegóły w pliku `LICENSE`.
