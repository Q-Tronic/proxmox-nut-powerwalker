# Proxmox NUT PowerWalker

Autor: **Q-Tronic**

Bezpieczna konfiguracja UPS dla **Proxmox VE**, **Network UPS Tools (NUT)**, **Home Assistant** i opcjonalnego **MQTT**.

Projekt został przygotowany przede wszystkim pod **PowerWalker VI 2200 STL FR**, ale instalator nie zakłada na sztywno jednego identyfikatora USB. Próbuje wykryć urządzenie przez `nut-scanner`, obsługuje znany wariant HID `0764:0601`, a przy niejednoznacznym wykryciu zatrzymuje się zamiast zgadywać.

## Co robi instalator

- instaluje NUT i wymagane narzędzia,
- robi backup istniejącego `/etc/nut`,
- nie nadpisuje obcej konfiguracji bez `FORCE=1`,
- automatycznie wykrywa UPS USB,
- konfiguruje `usbhid-ups` lub sterownik wskazany przez `nut-scanner`,
- wystawia NUT dla Home Assistanta,
- generuje osobne losowe hasła,
- ustawia shutdown po **60 sekundach ciągłej pracy na baterii**,
- anuluje timer, jeśli sieć wróci,
- natychmiast rozpoczyna FSD przy `LOWBATT`,
- uzbraja `nut-monitor` **dopiero po poprawnym odczycie `ups.status`**,
- tworzy komendy diagnostyczne,
- prowadzi niewielkie, rotowane logi zdarzeń,
- może publikować telemetrię do MQTT przez Home Assistant MQTT Discovery.

## Czego instalator celowo nie robi

Nie wykonuje i nie konfiguruje automatycznie:

```text
shutdown.return
shutdown.stayoff
load.off
load.off.delay
POWERDOWNFLAG
```

To są funkcje mogące fizycznie odciąć wyjście UPS. Zostaną dopiero osobno zweryfikowane na konkretnej sztuce UPS.

## Instalacja na Proxmoxie

Najprościej: zaloguj się jako `root` przez SSH i uruchom jedną komendę:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

`install.sh` jest małym bootstrapem: pobiera właściwy `setup-nut-powerwalker-proxmox.sh`, sprawdza czy plik wygląda jak skrypt Q-Tronic, wykonuje `bash -n`, zapisuje kopię jako `/root/setup-nut-powerwalker-proxmox.sh` i dopiero wtedy uruchamia główny instalator.

Jeśli na Proxmoxie nie ma `curl`, najpierw:

```bash
apt update && apt install -y curl ca-certificates
```

Jeśli chcesz np. 120 sekund zamiast domyślnych 60:

```bash
SHUTDOWN_DELAY=120 bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Możesz także przypiąć instalację do konkretnego tagu, brancha albo commita:

```bash
QTRONIC_REF=v1.0.0 bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

### Alternatywnie: instalacja przez `git clone`

```bash
apt update
apt install -y git
cd /root
git clone https://github.com/Q-Tronic/proxmox-nut-powerwalker.git
cd proxmox-nut-powerwalker
bash ./setup-nut-powerwalker-proxmox.sh
```

## Najważniejsze komendy po instalacji

```bash
nut-status
```

Czytelny status UPS i usług.

```bash
nut-watch
```

Status odświeżany na żywo.

```bash
nut-capabilities
```

Pełne `upsc`, `upscmd -l` i `upsrw`.

```bash
nut-phase2-check
```

Sprawdza bez wykonywania komend, czy UPS raportuje m.in. `shutdown.return`, `load.on.delay`, `ups.delay.start`.

```bash
nut-logs 100
```

Ostatnie logi NUT/MQTT. Maksymalnie można poprosić o 500 linii.

```bash
nut-report
```

Najważniejsza komenda diagnostyczna. Generuje raport, ukrywa hasło NUT i wyświetla dane, które można wkleić do ChatGPT.

```bash
nut-ha-info
```

Wyświetla dane potrzebne do konfiguracji Home Assistanta.

```bash
nut-mqtt-config
```

Konfiguruje opcjonalny most NUT → MQTT.

```bash
nut-test-guide
```

Wyświetla bezpieczną procedurę pierwszego testu zaniku zasilania.

```bash
nut-rollback
```

Przywraca backup `/etc/nut` wykonany przed ostatnim uruchomieniem instalatora.

## Home Assistant

Szczegóły są w:

```text
home-assistant/README.md
```

Podstawowa integracja:

**Ustawienia → Urządzenia i usługi → Dodaj integrację → Network UPS Tools (NUT)**

Dane pokaże:

```bash
nut-ha-info
```

Port NUT `3493/TCP` powinien być dostępny tylko w zaufanej sieci LAN/VLAN. **Nie wystawiaj go do Internetu.**

## MQTT

MQTT jest opcjonalne. NUT działa bez niego.

Konfiguracja:

```bash
nut-mqtt-config
```

Po poprawnym teście połączenia instalator uruchomi:

```bash
systemctl status nut-mqtt.service
```

Most publikuje jeden JSON stanu co kilkanaście sekund oraz konfigurację Home Assistant MQTT Discovery. Nie publikuje komend sterujących UPS-em.

## Logi

Własne logi:

```text
/var/log/nut-powerwalker/events.log
/var/log/nut-powerwalker/mqtt.log
```

Logi są obracane przez `logrotate` po osiągnięciu około `512 kB`; przechowywanych jest 6 rotacji z kompresją.

## Pliki na serwerze

Po instalacji:

```text
/root/nut-powerwalker/
```

Znajdziesz tam m.in.:

```text
credentials.env
HA-SETUP.txt
COMMANDS.txt
README-SERVER.txt
backups/
reports/
```

Hasła mają prawa `600` i nie są częścią repozytorium GitHub.

## Pierwszy test

Najpierw:

```bash
nut-test-guide
```

Przy pierwszym teście **nie czekaj pełnych 60 sekund**. Odłącz od sieci 230 V tylko wejście UPS-a i przywróć zasilanie wcześniej. Sprawdź przejście `OL → OB → OL`.

Nie uruchamiaj ręcznie:

```bash
upsmon -c fsd
```

ani poleceń `shutdown.return`/`load.off` bez osobnej weryfikacji.

---

# Jak wrzucić repozytorium na GitHuba z telefonu

Najprościej zrobić to w przeglądarce telefonu na `github.com`.

1. Zaloguj się do GitHuba.
2. Utwórz nowe repozytorium, np.:
   `proxmox-nut-powerwalker`
3. Możesz ustawić je jako **Private** albo **Public**. Repo nie zawiera żadnych wygenerowanych haseł.
4. Wejdź do pustego repozytorium.
5. Wybierz **Add file → Upload files**.
6. Wgraj:
   - `install.sh`
   - `setup-nut-powerwalker-proxmox.sh`
   - `README.md`
   - `.gitignore`
   - `LICENSE`
   - folder `home-assistant` wraz z plikami.
7. W polu opisu commita wpisz np.:
   `Initial Q-Tronic NUT setup`
8. Zatwierdź **Commit changes**.

Jeśli mobilny interfejs GitHuba nie pokazuje wygodnie `Upload files`, włącz w przeglądarce **wersję strony na komputer**. Do samego wgrywania plików przeglądarka jest zwykle wygodniejsza niż aplikacja GitHub.

## Użycie repo na Proxmoxie

Dla tego publicznego repo najprościej:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Nie trzeba robić `git clone`, `cd` ani `chmod`.

## Aktualizacja później

Aby pobrać aktualną wersję instalatora z brancha `main`, po prostu uruchom tę samą komendę ponownie:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Główny instalator zachowa istniejące wygenerowane hasła i przed zmianami wykona kolejny backup konfiguracji NUT.


## GitHub z telefonu

Szczegółowa instrukcja znajduje się w `GITHUB-MOBILE.md`.
