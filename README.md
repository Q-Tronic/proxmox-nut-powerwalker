# Proxmox NUT PowerWalker

Bezpieczna integracja UPS z **Proxmox VE** przy użyciu **Network UPS Tools (NUT)**, z opcjonalnym monitoringiem w **Home Assistant** i przez **MQTT**.

Projekt jest przygotowany przede wszystkim dla **PowerWalker VI 2200 STL FR**. Może działać także z innymi UPS-ami USB HID obsługiwanymi przez NUT, ale dostępne dane i komendy zależą od modelu, firmware, wersji NUT i sterownika.

Autor: **Q-Tronic**  
Wersja projektu: **1.0.0-rc2** (`VERSION` w repo) — release candidate do testów na fizycznym UPS

## Co ten projekt robi

Domyślna polityka jest prosta:

- Proxmox sam podejmuje decyzję o shutdownie — Home Assistant i MQTT nie są do tego potrzebne;
- po przejściu UPS na baterię (`OB`) uruchamiany jest timer, domyślnie **60 s**;
- jeśli zasilanie wróci przed końcem timera (`OL`), shutdown jest anulowany;
- stan krytyczny `OB+LB` / `LOWBATT` jest obsługiwany **natywnie przez `upsmon`** i może natychmiast rozpocząć FSD/shutdown; tej ochrony projekt nie pozwala wyłączyć;
- `nut-monitor` jest uzbrajany tylko po potwierdzeniu komunikacji z UPS i stabilnego `OL`;
- power-cycle UPS jest domyślnie **wyłączony** i ma osobną bramkę bezpieczeństwa;
- planowane fizyczne odłączenie UPS wykonuje się przez tryb **BYPASS**, a nie przez samo wyrwanie USB.

## Wymagania

- Proxmox VE / Debian z `systemd`;
- dostęp `root`;
- UPS podłączony do hosta przez USB;
- Internet podczas instalacji pakietów i pobrania skryptów.
- przy wielu UPS-ach USB instalator nie zgaduje; dwa identyczne urządzenia z tym samym VID/PID należy na czas pierwszej konfiguracji fizycznie rozdzielić/odłączyć pozostałe.

## Instalacja

Uruchom jako `root` na hoście Proxmox:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Instalator robi backup istniejącej konfiguracji, wykrywa UPS, instaluje NUT, sprawdza komunikację i dopiero po stabilnym `OL` może uruchomić `nut-monitor`. Backup instalatora dostaje unikalny katalog nawet przy dwóch uruchomieniach w tej samej sekundzie. Jeżeli wykryta konfiguracja jest już zarządzana przez Q-Tronic, reinstalacja/aktualizacja ma dodatkowy preflight: **zanim zmieni `/etc/nut`, aktualny UPS musi odpowiadać i raportować stabilne `OL` bez `OB`**.

Po instalacji zacznij od:

```bash
nut-status
nut-config doctor
nut-config show
nut-capabilities
nut-config powercycle probe
```

`powercycle probe` jest **tylko odczytem**. Nie odcina zasilania, nie wysyła `shutdown.return` i nie nadpisuje zapisanego capability/fingerprintu używanego do uzbrojenia power-cycle.

---

# Najważniejsze statusy UPS

Najczęściej zobaczysz:

| Status | Znaczenie | Co robić |
|---|---|---|
| `OL` | On Line — UPS pracuje z sieci | normalny, bezpieczny stan do konfiguracji |
| `OB` | On Battery — UPS pracuje z baterii | nie zmieniaj konfiguracji i nie odłączaj USB |
| `LB` / `LOWBATT` | niski poziom baterii | host może rozpocząć natychmiastowy FSD |
| brak odpowiedzi | utrata komunikacji z UPS | sprawdź USB/driver; nie zgaduj stanu urządzenia |

**Nie odłączaj przewodu USB, gdy ostatni znany stan to `OB`.** Jeśli chcesz świadomie wyjąć UPS z układu i zasilać serwer bezpośrednio z sieci, użyj procedury BYPASS opisanej niżej.

---

# Jak czytać opisy komend

W dokumentacji i menu przyjmujemy prostą zasadę:

- **ODCZYT** — niczego nie zmienia; bezpieczne do diagnostyki;
- **ZMIANA** — zapisuje konfigurację i może restartować usługi NUT;
- **OCHRONA** — wpływa na to, kiedy host ma się automatycznie wyłączyć;
- **PROCEDURA** — prowadzi przez wieloetapową operację, np. fizyczne wyjęcie UPS;
- **UZBROJENIE / ZAAWANSOWANE** — funkcje, które mogą wpłynąć na późniejszy fizyczny power-cycle.

Jeśli nie wiesz, co wybrać, zacznij od `nut-status`, `nut-config show` albo `nut-config menu`.

# Menu — najprostszy sposób konfiguracji

```bash
nut-config menu
```

Menu pokazuje na górze aktualny `ups.status`, stan `nut-monitor`, power-cycle, BYPASS, timer i LOWBATT. Opcje są pogrupowane na:

```text
1) Status i wszystkie ustawienia
2) Shutdown: timer / delay / wyjaśnienie LOWBATT
3) UPS / USB
4) LAN / Home Assistant
5) Monitor NUT
6) BYPASS — bezpieczne odłączenie/powrót UPS
7) Power-cycle UPS
8) Self-test baterii (warunkowy)
9) MQTT
10) Doctor / prowadzony test / logi / raporty
11) Backupy / rollback
12) Read-only health watchdog
13) Wersja / kanał / aktualizacja
14) Pomoc — dokładny opis wszystkich komend
0) Wyjście
```

Operacje zmniejszające ochronę, pokazujące hasło, zmieniające wykryty sprzęt albo uzbrajające power-cycle wymagają dodatkowego potwierdzenia konkretnym słowem, np. `WYLACZ`, `POKAZ`, `WYKRYJ`, `BYPASS`, `WLACZ` lub `PRZYWROC`. Ma to ograniczyć przypadkowe wybranie złej opcji.

Nagłówek menu stale pokazuje `ups.status`, stan `nut-monitor`, power-cycle, BYPASS, timer i LOWBATT. Przy `OB` albo braku komunikacji menu wyświetla wyraźne ostrzeżenie. Podczas aktywnego BYPASS większość zmian jest ukryta i zablokowana.

---

# BYPASS — gdy chcesz fizycznie odłączyć UPS

To jest właściwa procedura, jeśli UPS był używany przez tydzień/miesiąc, a później chcesz wyjąć go z toru zasilania i podłączyć serwer bezpośrednio do 230 V.

## Dlaczego nie wystarczy po prostu wyciągnąć USB?

Jeżeli UPS ma być **planowo** usunięty z układu, projekt nie traktuje zwykłego wyrwania USB jako poprawnej procedury. `nut-monitor` nadal zakłada wtedy, że zarządza UPS-em i zobaczy utratę komunikacji. Szczególnie niebezpieczne jest odłączenie komunikacji po stanie `OB` lub w trakcie zdarzenia zasilania.

BYPASS najpierw wyłącza elementy reagujące na UPS i usuwa runtime power-cycle, a dopiero potem daje wyraźne `Gotowy do odpięcia: TAK`. Dlatego do planowanego przepięcia serwera na zwykłe 230 V zawsze używaj BYPASS.

## Przed odłączeniem UPS

Najpierw sprawdź:

```bash
nut-status
```

UPS musi odpowiadać i być stabilnie `OL`. Następnie:

```bash
nut-config bypass enable
```

Komenda:

- zapisuje stan monitora, MQTT i power-cycle sprzed BYPASS;
- zapisuje fingerprint aktualnego UPS;
- zatrzymuje i wyłącza `nut-monitor`;
- zatrzymuje i wyłącza most MQTT;
- wyłącza power-cycle;
- usuwa jego wrapper, późny hook systemd i flagę FSD;
- oznacza BYPASS jako gotowy dopiero po zakończeniu całej procedury oraz potwierdzeniu, że `nut-monitor` i `nut-mqtt` są zatrzymane i wyłączone z autostartu.

Sprawdź:

```bash
nut-config bypass status
```

Dopiero gdy zobaczysz:

```text
BYPASS:              TAK
Gotowy do odpięcia:   TAK
```

możesz odłączyć USB UPS i przepiąć zasilanie serwera bezpośrednio do sieci.

Jeżeli widzisz `Gotowy do odpięcia: NIE`, **nie odłączaj UPS**. Użyj `nut-config resume`, żeby wrócić do normalnego trybu, albo sprawdź diagnostykę.

## Po ponownym podłączeniu UPS

Podłącz UPS do sieci, zasilanie serwera do UPS oraz USB do Proxmoxa, a następnie:

```bash
nut-config resume
```

`resume`:

- uruchamia ponownie driver i serwer NUT;
- wymaga komunikacji z UPS i stabilnego `OL`;
- przywraca stan `nut-monitor` sprzed BYPASS;
- przywraca MQTT, jeśli wcześniej działało;
- power-cycle przywraca automatycznie tylko wtedy, gdy podłączony jest ten sam fingerprint UPS i urządzenie ponownie przejdzie capability probe;
- jeśli UPS jest inny albo probe nie przejdzie, power-cycle pozostaje wyłączony, ale zwykła ochrona NUT może zostać przywrócona.

W czasie aktywnego BYPASS skrypt blokuje m.in. ponowne uzbrajanie monitora, power-cycle, konfigurację MQTT, zmiany USB/drivera, obrót haseł i rollback konfiguracji. Aktualizacja/reinstalacja głównego setupu też jest blokowana, dopóki BYPASS nie zostanie zakończony.

---

# Pierwszy test po instalacji

Najpierw **power-cycle ma być wyłączony**.

```bash
nut-config powercycle status
```

Uruchom podgląd:

```bash
nut-watch
```

W drugim terminalu:

```bash
nut-logs 100
```

Odłącz od ściany **wejście UPS**, nie kabel serwera z UPS. Oczekiwane:

```text
OL -> OB
```

Przy pierwszym teście podłącz sieć z powrotem **przed końcem timera shutdownu**. Oczekiwane:

```text
OB -> OL
```

i anulowanie timera.

Dopiero po poprawnym teście `OL -> OB -> OL` wykonuj osobno test pełnego shutdownu. Power-cycle testuj na samym końcu, po pozytywnym `probe`, z dostępem do serwera i świadomością, że firmware UPS może deklarować komendę, ale zachować się inaczej fizycznie.

---

# Pełny opis komend

Poniżej są polecenia instalowane przez projekt oraz wszystkie publiczne komendy `nut-config`.

## `nut-status`

```bash
nut-status
```

Najprostszy podgląd UPS. Pokazuje m.in. model, `ups.status`, baterię, runtime, obciążenie, moc, napięcia, stan BYPASS oraz stan `nut-monitor`, `nut-server` i MQTT.

Jeśli BYPASS jest aktywny i UPS został już fizycznie odłączony, brak komunikacji jest pokazany jako **oczekiwany stan BYPASS**, a nie jako zwykły alarm.

**Kiedy używać:** zawsze jako pierwsza komenda diagnostyczna.

**Ryzyko:** tylko odczyt.

## `nut-watch`

```bash
nut-watch
```

Uruchamia `nut-status` co sekundę przez `watch`. Przydatne podczas testu zaniku zasilania.

**Ryzyko:** tylko odczyt.

## `nut-capabilities`

```bash
nut-capabilities
```

Pokazuje pełne dane z `upsc`, listę komend `upscmd -l` oraz zmienne zapisywalne `upsrw`.

**Kiedy używać:** identyfikacja modelu, firmware, możliwości i diagnostyka.

**Ryzyko:** tylko odczyt. Samo wyświetlenie listy komend ich nie wykonuje.

## `nut-phase2-check`

```bash
nut-phase2-check
```

Starszy, prosty helper tylko do odczytu możliwości związanych z power-cycle. Szuka m.in. `shutdown.return`, `load.off.delay`, `load.on.delay`, `ups.delay.start` i `ups.delay.shutdown`.

**Ryzyko:** tylko odczyt.

**Zalecenie:** do właściwej decyzji o power-cycle używaj `nut-config powercycle probe`, bo ma dodatkowe zabezpieczenia i fingerprint.

## `nut-logs`

```bash
nut-logs 100
```

Pokazuje ostatnie wpisy z logu zdarzeń NUT, logu MQTT oraz journala usług NUT/MQTT. Maksymalnie 500 linii.

Przykład:

```bash
nut-logs 300
```

**Ryzyko:** tylko odczyt.

## `nut-test-guide`

```bash
nut-test-guide
```

Wyświetla krótką, bezpieczną instrukcję pierwszego testu `OL -> OB -> OL` i przypomina, których komend nie wykonywać ręcznie.

**Ryzyko:** tylko odczyt.

## `nut-restart`

```bash
nut-restart
```

Restartuje stos NUT, sprawdza `upsc` i `ups.status`. `nut-monitor` zostanie włączony tylko przy stabilnym `OL` bez `OB`.

Jeżeli BYPASS jest aktywny, komenda **odmawia uzbrojenia monitora** i kieruje do:

```bash
nut-config resume
```

**Kiedy używać:** po naprawieniu komunikacji USB poza trybem BYPASS.

## `nut-report`

```bash
nut-report
```

Tworzy pełny raport diagnostyczny w katalogu projektu i jednocześnie wyświetla go na ekranie. Zawiera informacje o Proxmoxie, systemie, sieci, USB, NUT, usługach, `upsc`, `upscmd`, `upsrw` i logach.

Hasło z wpisu `MONITOR` jest maskowane, ale raport nadal może zawierać:

- adresy IP;
- nazwę hosta i informacje systemowe;
- identyfikatory USB;
- model lub numer seryjny UPS.

**Przejrzyj raport przed publicznym udostępnieniem.**

## `nut-ha-info`

```bash
nut-ha-info
```

Pokazuje dane potrzebne do połączenia Home Assistant z NUT: host, port, użytkownika, hasło oraz nazwę UPS.

**UWAGA:** wynik zawiera hasło konta Home Assistant. Nie wrzucaj go publicznie bez zamazania hasła.

## `nut-mqtt-config`

```bash
nut-mqtt-config
```

Interaktywnie konfiguruje broker MQTT, zapisuje konfigurację, testuje połączenie i dopiero po udanym teście włącza `nut-mqtt.service`.

Podczas BYPASS komenda jest blokowana.

To samo można uruchomić przez:

```bash
nut-config mqtt setup
```

## `nut-mqtt-disable`

```bash
nut-mqtt-disable
```

Zatrzymuje i wyłącza `nut-mqtt.service`, ale zachowuje `/etc/nut/nut-mqtt.json`, więc konfiguracji nie trzeba wpisywać od nowa.

## `nut-rollback`

```bash
nut-rollback
```

Przywraca ostatni **snapshot konfiguracji** utworzony przez główny instalator. To nie jest to samo co `nut-config rollback`.

Snapshot zapisuje również stan `active/enabled` usług NUT, MQTT i health-watchdoga. Przy odtwarzaniu aktywnego `nut-monitor` skrypt ponownie wymaga komunikacji z UPS i stabilnego `OL`; nieudany start lub walidacja kończy rollback błędem zamiast udawać sukces. Jeżeli przed pierwszą instalacją nie istniał `/etc/nut`, rollback usuwa utworzoną konfigurację i pozostawia ochronę rozbrojoną.

**`nut-rollback` nie cofa wersji kodu, nie usuwa zainstalowanych pakietów i nie jest deinstalatorem.** Służy do odzyskania snapshotu konfiguracji po problemie z instalacją/aktualizacją.

Podczas BYPASS rollback snapshotu instalatora jest blokowany.

---

# `nut-config` — pełna dokumentacja

Bez argumentu:

```bash
nut-config
```

zachowuje się dokładnie jak:

```bash
nut-config show
```

## `nut-config show`

```bash
nut-config show
```

Pokazuje:

- konfigurację UPS/USB;
- politykę shutdownu;
- LAN/port NUT;
- parametry timingowe;
- logrotate;
- power-cycle;
- status BYPASS;
- stan usług;
- bieżący `ups.status`.

**Ryzyko:** tylko odczyt.

## `nut-config menu`

```bash
nut-config menu
```

Uruchamia prowadzone menu. To zalecana metoda dla użytkownika, który nie chce pamiętać składni. Ryzykowne zmiany mają dodatkowe potwierdzenia.

## `nut-config help`

```bash
nut-config help
```

Wyświetla rozbudowaną pomoc terminalową z opisem komend, zasadami bezpieczeństwa i przykładami.

Działają również:

```bash
nut-config -h
nut-config --help
```

## `nut-config apply`

```bash
nut-config apply
```

Ponownie renderuje i stosuje aktualnie zapisane ustawienia. Przed zmianą tworzy backup, restartuje stos NUT, wymaga stabilnego `OL` po zmianie i wykonuje rollback, jeśli walidacja się nie powiedzie.

Jeśli power-cycle jest aktywny, capability gate jest sprawdzany przed i po restarcie.

Komenda jest blokowana podczas BYPASS.

**Nie używaj podczas awarii zasilania.**

Od RC1 każda operacja, która renderuje konfigurację lub restartuje stos NUT, wymaga stabilnego `OL` **niezależnie od tego, czy `nut-monitor` jest aktualnie włączony**. Brak komunikacji nie jest traktowany jako bezpieczne okno do zmian.

---

# Shutdown

## `nut-delay`

Odczyt:

```bash
nut-delay
```

Zmiana:

```bash
nut-delay 90
nut-delay 2m
nut-delay 1h
```

Alias do ustawienia `SHUTDOWN_DELAY`. Przyjmuje sekundy albo suffix `s`, `m`, `h`. Zakres po przeliczeniu: **15-86400 s**.

## `nut-config delay`

```bash
nut-config delay
```

Pokazuje aktualny delay.

```bash
nut-config delay 120
```

Ustawia delay tak samo jak `nut-delay 120`.

## `nut-config timed on`

```bash
nut-config timed on
```

Włącza timer shutdownu po zdarzeniu `ONBATT`.

## `nut-config timed off`

```bash
nut-config timed off
```

Wyłącza timer shutdownu po czasie. Reakcja `LOWBATT` jest niezależna i może nadal być aktywna.

**Wyłączenie timera zmniejsza ochronę przy długim zaniku zasilania.**

## `nut-config lowbatt status` / `nut-config lowbatt on`

```bash
nut-config lowbatt status
```

Od `1.0.0-rc1` projekt **nie implementuje własnego przełącznika LOWBATT**. NUT `upsmon` traktuje stan `OB+LB` jako krytyczny i sam rozpoczyna FSD zgodnie ze swoim mechanizmem ochrony. Komenda `status` pokazuje tę zasadę, a zgodnościowe `on` jest bezpiecznym no-op.

Próba:

```bash
nut-config lowbatt off
```

jest celowo **odrzucana**. Nie oferujemy opcji wyłączenia natywnej ochrony `OB+LB`.

---

# BYPASS

## `nut-config bypass status`

```bash
nut-config bypass status
```

Pokazuje, czy BYPASS jest aktywny, czy procedura jest gotowa do fizycznego odłączenia UPS i jaki był stan usług przed wejściem w BYPASS.

## `nut-config bypass enable`

```bash
nut-config bypass enable
```

Bezpiecznie przygotowuje host do fizycznego wyjęcia UPS. Wymaga komunikacji i stabilnego `OL`.

Akceptowane są również aliasy:

```bash
nut-config bypass enter
nut-config bypass on
```

To są dokładnie te same operacje co `bypass enable`; nie tworzą osobnego trybu.

**Nie odłączaj UPS, dopóki komenda nie zakończy się `[OK]` i `nut-config bypass status` nie pokaże `Gotowy do odpięcia: TAK`.**

## `nut-config resume`

```bash
nut-config resume
```

Kończy BYPASS po ponownym podłączeniu UPS. Wymaga stabilnego `OL`, przywraca wcześniejsze usługi i ostrożnie obsługuje power-cycle.

To samo:

```bash
nut-config bypass disable
nut-config bypass resume
nut-config bypass off
```

Wszystkie te aliasy kończą BYPASS przez tę samą procedurę walidującą stabilne `OL`.

---

# Monitor NUT

## `nut-config monitor status`

```bash
nut-config monitor status
```

Pokazuje pełny status `nut-monitor.service`.

## `nut-config monitor enable`

```bash
nut-config monitor enable
```

Włącza automatyczną ochronę hosta. Wymaga stabilnego `OL` i jest blokowane podczas BYPASS.

Alias:

```bash
nut-config monitor on
```

`enable` i `on` robią to samo.

## `nut-config monitor disable`

```bash
nut-config monitor disable
```

Zatrzymuje i wyłącza `nut-monitor`. Host przestaje automatycznie reagować na zdarzenia UPS.

Alias:

```bash
nut-config monitor off
```

`disable` i `off` robią to samo.

Do planowanego wyjęcia UPS lepiej użyj **BYPASS**, bo pamięta poprzedni stan i dodatkowo obsługuje MQTT/power-cycle.

---

# Power-cycle

## `nut-config powercycle probe`

```bash
nut-config powercycle probe
```

Read-only capability gate. Wymaga stabilnego `OL` i sprawdza m.in.:

- fingerprint urządzenia;
- driver;
- VID/PID, jeśli są raportowane;
- `shutdown.return`;
- `ups.delay.start` i `ups.delay.shutdown`;
- `load.off.delay` / `load.on.delay`;
- dostępność `upsdrvctl`.

**Nie wysyła `shutdown.return`, nie odcina zasilania i nie zmienia zapisanego capability gate.** Fingerprint zostaje utrwalony dopiero podczas świadomego `nut-config powercycle enable`. Dzięki temu samo `probe`/`status` po podmianie UPS-a nie może przepiąć autoryzacji power-cycle na nowe urządzenie.

## `nut-config powercycle status`

```bash
nut-config powercycle status
```

Pokazuje stan funkcji, opóźnienia, capability file, flagę FSD, wrapper i late hook, a następnie wykonuje read-only probe.

## `nut-config powercycle delays`

```bash
nut-config powercycle delays 60 300
```

Ustawia:

- OFF delay: **60-3600 s**;
- ON delay: **120-86400 s**;
- ON delay musi być większy od OFF delay.

Jeżeli power-cycle jest wyłączony, wartości są tylko zapisane. Jeżeli jest aktywny, urządzenie musi ponownie przejść capability gate.

## `nut-config powercycle enable`

```bash
nut-config powercycle enable
```

Uzbraja mechanizm power-cycle na przyszły prawdziwy FSD. Komenda:

- wymaga bezpiecznego stanu i stabilnego `OL`;
- robi capability probe;
- wiąże konfigurację z VID/PID, jeśli urządzenie je raportuje;
- tworzy zabezpieczony wrapper/hook;
- stosuje konfigurację;
- ponawia probe po restarcie;
- robi rollback przy błędzie.

**Samo `enable` nie wykonuje testowego `shutdown.return` i nie odcina wyjścia UPS.**

`nut-config show` i `nut-config powercycle status` rozróżniają teraz **configured** od **runtime state** (`DISABLED`, `ARMED`, `PENDING_NOT_ARMED`). Po aktualizacji zapisane `ON` nie może pozostać myląco uzbrojone bez świeżej walidacji: jeśli urządzenia/statusu nie da się potwierdzić, aktualizacja fail-closed zapisuje power-cycle jako `OFF`.

Komenda jest blokowana podczas BYPASS.

## `nut-config powercycle disable`

```bash
nut-config powercycle disable
```

Wyłącza power-cycle, przywraca zwykły shutdown hosta i usuwa runtime wrapper/hook/flagę.

Komenda jest blokowana podczas BYPASS — w tym trybie mechanizm jest już bezpiecznie wyłączony, a powrót wykonuje `nut-config resume`.

---

# NUT w LAN / Home Assistant

## `nut-config listen`

```bash
nut-config listen
```

Pokazuje bieżące ustawienie interfejsu/adresu LAN NUT.

## `nut-config listen auto`

```bash
nut-config listen auto
```

Automatycznie wybiera adres IP hosta dla klientów LAN.

## `nut-config listen off`

```bash
nut-config listen off
```

Wyłącza wystawienie NUT do LAN. Lokalny control-plane nadal pozostaje na:

```text
127.0.0.1:3493
```

## `nut-config listen ADRES_IP`

```bash
nut-config listen 192.168.1.10
```

Ustawia konkretny IPv4/IPv6 hosta do nasłuchiwania dla klientów LAN.

## `nut-config port`

```bash
nut-config port
```

Pokazuje port NUT dla LAN/Home Assistant.

## `nut-config port PORT`

```bash
nut-config port 3493
```

Ustawia port LAN/HA w zakresie **1-65535**. Wewnętrzny localhost pozostaje na `3493`.

## `nut-config ha show`

```bash
nut-config ha show
```

Pokazuje dane logowania dla Home Assistant.

**Wynik zawiera hasło.**

## `nut-config ha rotate`

```bash
nut-config ha rotate
```

Generuje nowe losowe hasło HA, stosuje konfigurację z backupem i walidacją, a następnie pokazuje nowe dane logowania. Stare hasło przestaje działać.

---

# UPS / USB

## `nut-config ups show`

```bash
nut-config ups show
```

Pokazuje aktualny `UPS_NAME`, opis, driver, port urządzenia, VID, PID i subdriver.

`UPS_NAME` jest celowo stabilnym logicznym identyfikatorem i nie jest zmieniany przez auto-detect.

## `nut-config ups auto`

```bash
nut-config ups auto
```

Uruchamia `nut-scanner -U`, ocenia znalezione urządzenia i stosuje najbardziej prawdopodobny wynik. Przy kilku równie prawdopodobnych UPS-ach przerywa zamiast zgadywać.

Blokowane podczas BYPASS.

## `nut-config usb VID PID`

```bash
nut-config usb 0764 0601
```

Ręcznie ustawia 4-znakowe VID/PID hex.

Opcjonalnie można podać subdriver:

```bash
nut-config usb 0764 0601 "CyberPower HID"
```

## `nut-config usb auto auto`

```bash
nut-config usb auto auto
```

Usuwa ręczne ograniczenie VID/PID. Używaj tylko wtedy, gdy wiesz, że automatyczny wybór jest właściwy.

---

# MQTT

MQTT jest tylko telemetrią. Nie jest źródłem decyzji o shutdownie i nie publikuje topiców sterujących UPS.

## `nut-config mqtt setup`

```bash
nut-config mqtt setup
```

Uruchamia konfigurator MQTT, zapisuje ustawienia, wykonuje test i dopiero po sukcesie uruchamia usługę.

Alias:

```bash
nut-config mqtt config
```

`setup` i `config` robią to samo. Blokowane podczas BYPASS.

## `nut-config mqtt status`

```bash
nut-config mqtt status
```

Pokazuje pełny status systemd mostu MQTT.

## `nut-config mqtt show`

```bash
nut-config mqtt show
```

Pokazuje konfigurację MQTT po usunięciu pola hasła z wyświetlanego JSON.

## `nut-config mqtt interval SEKUNDY`

```bash
nut-config mqtt interval 15
```

Ustawia interwał publikacji w zakresie **5-3600 s**. Jeśli usługa już działa, jest restartowana. Jeśli była wyłączona, sama zmiana interwału jej nie uruchomi.

Blokowane podczas BYPASS.

## `nut-config mqtt disable`

```bash
nut-config mqtt disable
```

Wyłącza usługę, ale pozostawia konfigurację na dysku.

Alias:

```bash
nut-config mqtt off
```

`disable` i `off` robią to samo.

---

# Hasła

## `nut-config primary rotate`

```bash
nut-config primary rotate
```

Zmienia hasło lokalnego konta `proxmoxmon`, używanego przez `upsmon`. Robi backup, restart, kontrolę `OL` i rollback przy niepowodzeniu.

Blokowane podczas BYPASS.

---

# Zaawansowane ustawienia `get` / `set`

Jeżeli nie wiesz dokładnie, co robi dany parametr, użyj `nut-config menu` zamiast `set`. `get` jest odczytem; `set` jest zmianą konfiguracji i może restartować stos NUT.


## `nut-config get KLUCZ`

Przykład:

```bash
nut-config get DEADTIME
```

Odczytuje pojedynczą wartość.

Obsługiwane klucze odczytu:

```text
UPS_NAME
UPS_DESC
UPS_DRIVER
UPS_PORT
UPS_VENDORID
UPS_PRODUCTID
UPS_SUBDRIVER
NUT_LISTEN_IP
NUT_PORT
SHUTDOWN_DELAY
TIMED_SHUTDOWN
POLLFREQ
POLLFREQALERT
HOSTSYNC
DEADTIME
FINALDELAY
RBWARNTIME
NOCOMMWARNTIME
LOG_ROTATE_SIZE
LOG_ROTATE_COUNT
UPSMON_ROLE
POWERCYCLE_ENABLED
POWERCYCLE_OFFDELAY
POWERCYCLE_ONDELAY
```

`get` nie zmienia konfiguracji.

## `nut-config set KLUCZ WARTOŚĆ`

Przykłady:

```bash
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
```

Zakresy timingów:

| Klucz | Zakres |
|---|---:|
| `POLLFREQ` | 1-300 s |
| `POLLFREQALERT` | 1-300 s |
| `HOSTSYNC` | 5-600 s |
| `DEADTIME` | 5-600 s |
| `FINALDELAY` | 0-300 s |
| `RBWARNTIME` | 0-604800 s |
| `NOCOMMWARNTIME` | 0-86400 s |
| `LOG_ROTATE_COUNT` | 1-50 |

Nie zmieniaj `POWERCYCLE_*` przez `set`; skrypt celowo odrzuca taką próbę. Do power-cycle służą dedykowane komendy z capability gate.

Zmiany przez `set` są blokowane podczas BYPASS.

---

# Backup / rollback / diagnostyka przez `nut-config`

Backupy `nut-config` są przechowywane w:

```text
/root/nut-powerwalker/config-backups/
```

Każdy backup ma unikalną nazwę. Domyślnie projekt zachowuje maksymalnie **30** najnowszych backupów; dopuszczalny limit to 5-200. Backup wskazywany przez `LAST_CONFIG_BACKUP` jest dodatkowo chroniony przed przypadkowym usunięciem.

## `nut-config backup` / `nut-config backup create`

```bash
nut-config backup
nut-config backup create
```

Obie formy tworzą natychmiastowy backup bieżącej konfiguracji i stanu usług. Komenda wypisuje utworzony katalog.

## `nut-config backup list`

```bash
nut-config backup list
```

Pokazuje backupy od najnowszego do najstarszego. Aktualny backup `LAST` jest oznaczony.

**Ryzyko:** tylko odczyt.

## `nut-config backup restore`

Najprościej przywrócić ostatni backup:

```bash
nut-config backup restore LAST
```

Można też wskazać konkretną nazwę z `backup list`:

```bash
nut-config backup restore config-YYYYmmdd-HHMMSS-XXXXXX
```

Przed przywróceniem zawsze powstaje **dodatkowy backup bezpieczeństwa**. Restore jest blokowany podczas BYPASS i przechodzi przez kontrolę bezpiecznego stanu UPS.

Jeżeli wybrany backup miał aktywny power-cycle, skrypt przygotowuje fail-closed runtime przed przywróceniem, a po restarcie **ponownie** sprawdza capabilities i świeży fingerprint UPS. Jeśli walidacja po restore nie przejdzie, skrypt próbuje wrócić do backupu bezpieczeństwa zamiast pozostawiać niezweryfikowany power-cycle.

Backup formatu RC1 zapisuje też, czy opcjonalne pliki istniały oraz osobno stan `active/enabled` dla `nut-monitor`, MQTT i health-watchdoga. Restore usuwa opcjonalny plik, który w danym backupie był nieobecny, zamiast przypadkiem zostawić nowszą konfigurację. Wymagany plik oznaczony jako brakujący powoduje odmowę restore; manifest v2 akceptuje wyłącznie znane ścieżki i jednostki systemd. `nut-monitor` jest przywracany dopiero po ponownym potwierdzeniu stabilnego `OL`; błąd restartu, walidacji **lub odtworzenia stanu usług** nie kończy się fałszywym `[OK]`. Backup z power-cycle=ON musi posiadać własny capability fingerprint zgodny z aktualnym UPS. Starsze backupy bez manifestu pozostają obsługiwane w ograniczonym trybie zgodnościowym.

Także zwykłe udane zmiany konfiguracji i rotacja haseł zachowują dokładny stan `active/enabled` `nut-monitor`, zamiast niejawnie zmieniać politykę startu usługi.

## `nut-config backup prune`

```bash
nut-config backup prune 30
```

Usuwa starsze backupy ponad podany limit. Zakres: **5-200**.

Zmiana domyślnego limitu:

```bash
nut-config set CONFIG_BACKUP_KEEP 40
```

Ta zmiana nie restartuje NUT.

## `nut-config rollback`

```bash
nut-config rollback
```

Skrót przywracający `LAST_CONFIG_BACKUP`. To **nie jest** to samo co:

```bash
nut-rollback
```

`nut-rollback` przywraca backup głównego instalatora, natomiast `nut-config rollback` pracuje na historii konfiguratora.

## `nut-config report`

Raport prywatny:

```bash
nut-config report
nut-report
```

Raport publiczny z dodatkową redakcją:

```bash
nut-config report --public
nut-report --public
```

Tryb `--public` best-effort maskuje m.in. hostname, adresy IP, MAC, hasła, Machine/Boot ID oraz numer seryjny UPS. Model i VID/PID pozostają, ponieważ są przydatne diagnostycznie.

**WAŻNE:** automatyczna redakcja nie jest gwarancją pełnej anonimizacji. Zawsze przejrzyj plik przed wrzuceniem go publicznie.

## `nut-config capabilities`

```bash
nut-config capabilities
```

Uruchamia ten sam helper co:

```bash
nut-capabilities
```

## `nut-config logs`

```bash
nut-config logs 100
```

Uruchamia `nut-logs` z podaną liczbą linii.

---

# Home Assistant

Wyświetl dane:

```bash
nut-ha-info
```

W Home Assistant:

**Ustawienia → Urządzenia i usługi → Dodaj integrację → Network UPS Tools (NUT)**

Wpisz dokładnie host, port, użytkownika i hasło pokazane przez `nut-ha-info`. Zalecany jest stały adres IP, rezerwacja DHCP albo stabilna nazwa DNS Proxmoxa.

Konto `homeassistant` nie dostaje `instcmds`, więc nie służy do sterowania UPS ani shutdownem hosta.

Przykłady są rozdzielone, żeby nie mieszać encji oficjalnej integracji z MQTT:

```text
home-assistant/automations-nut-example.yaml
home-assistant/automations-mqtt-example.yaml
```

`automations-example.yaml` pozostaje kopią zgodnościową przykładu dla oficjalnej integracji NUT. Po dodaniu integracji zawsze sprawdź rzeczywiste `entity_id` i stany encji przed użyciem przykładów.

---

# Czego NIE uruchamiać „dla testu”

Na działającym serwerze nie wykonuj ręcznie bez świadomego planu testu:

```text
upsmon -c fsd
shutdown.return
shutdown.stayoff
load.off
load.off.delay
```

Te polecenia mogą zatrzymać host lub fizycznie odciąć wyjście UPS.

Do sprawdzania możliwości używaj:

```bash
nut-config powercycle probe
nut-capabilities
nut-phase2-check
```

---

# Bezpieczeństwo

- nie wystawiaj portu NUT do Internetu;
- ogranicz go do zaufanego LAN/VLAN/firewalla;
- nie publikuj `/root/nut-powerwalker/credentials.env`;
- nie publikuj `/etc/nut/nut-mqtt.json`;
- `nut-ha-info` pokazuje hasło HA;
- przed publikacją `nut-report` przejrzyj IP, dane systemowe, USB i numer seryjny UPS;
- nie traktuj pojedynczego podejrzanego pola HID jako prawdy absolutnej — niektóre urządzenia potrafią raportować nietypowe wartości telemetryczne;
- nie aktywuj power-cycle bez pozytywnego `probe` i kontrolowanego testu konkretnej sztuki UPS;
- przed planowanym fizycznym usunięciem UPS zawsze użyj BYPASS.

---

# Wersja i aktualizacja

Projekt ma własny plik `VERSION`. Aktualna wersja kodu jest również pokazywana przez:

```bash
nut-config version
```

Przykładowy wynik:

```text
Q-Tronic Proxmox NUT PowerWalker
Wersja lokalna: 1.0.0-rc2
Kanał update:   main
Repo:           Q-Tronic/proxmox-nut-powerwalker
```

## Sprawdzenie aktualizacji bez instalowania

```bash
nut-config update --check
```

Ta komenda tylko sprawdza wybrany kanał aktualizacji. Nie restartuje NUT i nie instaluje kodu.

## Kanały aktualizacji

Kanał bieżącego `main`:

```bash
nut-config update channel main
```

Kanał wydań oznaczonych GitHub Release:

```bash
nut-config update channel stable
```

`main` śledzi aktualny kod gałęzi głównej. `stable` pobiera najnowszy opublikowany GitHub Release i używa jego taga jako ref. Jeśli repo nie ma jeszcze żadnego Release, kanał `stable` **odmówi aktualizacji**, zamiast zgadywać wersję.

Zmiana kanału zapisuje ustawienie, ale nie restartuje NUT.

## Zalecana aktualizacja

Przy podłączonym UPS i stabilnym `OL`:

```bash
nut-config update
```

Komenda:

1. odmawia pracy podczas BYPASS;
2. wymaga komunikacji z UPS i stabilnego `OL`;
3. tworzy backup konfiguracji;
4. ustala ref zgodnie z kanałem `main` / `stable`;
5. pobiera oficjalny `install.sh` przez HTTPS;
6. sprawdza markery projektu i `bash -n`;
7. uruchamia bootstrap z wybranym `QTRONIC_REF`;
8. zachowuje dane dostępowe i ustawienia Q-Tronic;
9. po instalacji ponownie waliduje UPS i stos NUT.

Jeżeli kanał `stable` wskazuje tę samą wersję, zwykłe `update` niczego nie reinstaluje. Świadomy reinstall:

```bash
nut-config update --force
```

Po aktualizacji:

```bash
nut-config version
nut-config doctor
nut-status
```

Jeżeli aktualizacja zgłosi błąd:

```bash
nut-config doctor
nut-report --public
nut-config backup list
```

Nie wykonuj kolejnych ryzykownych zmian, dopóki nie wyjaśnisz przyczyny.

### Aktualizacja z menu

```bash
nut-config menu
```

Wybierz kategorię:

```text
13) Wersja / kanał / aktualizacja
```

Menu potrafi sprawdzić wersję, zmienić kanał, uruchomić aktualizację i wymusić reinstall. Operacja instalująca kod wymaga dodatkowego potwierdzenia `AKTUALIZUJ`.

### Metoda ręczna dla `main`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Ręczny bootstrap również jest blokowany podczas aktywnego BYPASS przez główny setup.

**Nie aktualizuj podczas `OB`, zaniku zasilania ani celowo odłączonego UPS.**

---

# Status wydania RC2

`1.0.0-rc2` jest kandydatem do pierwszego stabilnego wydania z finalnym hotfixem BYPASS i restore. Statyczne CI może sprawdzić składnię, ShellCheck, YAML i inwarianty projektu, ale **nie zastępuje testu konkretnego firmware UPS**. Taga `v1.0.0` nie twórz przed przejściem testów sprzętowych `OL -> OB -> OL`, pełnego shutdownu i — jeżeli zostanie użyty — kontrolowanego power-cycle.

Jeżeli utworzysz techniczny tag `v1.0.0-rc2`, workflow GitHub oznaczy go automatycznie jako **pre-release**. Kanał `stable` korzysta z `/releases/latest`, więc RC nie stanie się przypadkiem wydaniem stabilnym.


# Zgodność

Głównym urządzeniem docelowym jest **PowerWalker VI 2200 STL FR**. Projekt zna wariant USB `0764:0601`, ale nie zakłada, że każdy egzemplarz lub firmware będzie raportował identyczne możliwości.

Fizyczny power-cycle zależy od tego, co faktycznie udostępnia konkretny UPS. Samo pojawienie się `shutdown.return` w liście możliwości nie jest dowodem, że firmware zachowa się prawidłowo fizycznie — dlatego pierwszy rzeczywisty test należy wykonać pod nadzorem.

Fingerprint jest tak unikalny, jak dane udostępniane przez UPS/NUT. Jeżeli dwa identyczne egzemplarze nie raportują numeru seryjnego ani innego unikalnego pola, sam fingerprint nie potrafi kryptograficznie odróżnić tych dwóch sztuk; dlatego przy zamianie identycznego UPS-a power-cycle należy świadomie wyłączyć, wykonać probe i ponownie włączyć dopiero po kontroli sprzętu.


---

# Quality & Safety — dodatkowe zabezpieczenia

## `nut-config doctor`

```bash
nut-config doctor
```

Zalecana komenda po instalacji, aktualizacji, ponownym podłączeniu UPS i po nietypowej sytuacji. Jest **read-only**: nie restartuje usług, nie zmienia konfiguracji i nie wysyła komend do UPS. Pokazuje `PASS / WARN / FAIL` dla narzędzi, plików, praw dostępu, usług, komunikacji, `OL/OB`, BYPASS, power-cycle, MQTT, backupów, watchdog i klastra Proxmox.

## Prowadzony test `OL -> OB -> OL`

```bash
nut-config test
```

Kreator nie steruje zasilaniem UPS. Wymaga wyłączonego power-cycle, aktywnego `nut-monitor`, włączonego timera, komunikacji i stabilnego `OL`. Jeżeli poziom baterii jest raportowany, wymaga co najmniej 30%. Wymaga co najmniej 45 s konfiguracji timera i prowadzi użytkownika przez ręczne odłączenie wejścia UPS oraz szybki powrót do `OL`.

Po powrocie zasilania test **nie kończy się już tylko na zobaczeniu `OL`**. Sprawdza świeże logi `ONBATT`/`ONLINE`, odrzuca test przy `CANCEL-FAILED`, `TIMER` lub `FSD`, a gdy wersja NUT obsługuje `upssched -l`, dodatkowo potwierdza, że `shutdown_on_battery` zniknął z kolejki timerów. Dla starszych NUT używany jest mechanizm `CANCEL-TIMER ... timer_cancel_failed`, więc nieudane/anachroniczne anulowanie zostawia jawny ślad.

## Self-test baterii

Najpierw tylko odczyt możliwości:

```bash
nut-config selftest probe
```

Quick test, ale wyłącznie po świadomym potwierdzeniu:

```bash
nut-config selftest quick TESTUJ
```

Quick self-test jest dostępny tylko, gdy UPS jawnie raportuje odpowiednią komendę, pracuje stabilnie `OL`, nie ma `LOWBATT`, power-cycle jest wyłączony i bateria ma co najmniej 50% — jeśli poziom jest raportowany. Skrypt tworzy na czas pojedynczej operacji losowe konto NUT ograniczone do wymaganej komendy, a po zakończeniu przywraca oryginalny `upsd.users`.

To nadal jest funkcja zależna od konkretnego firmware. Pierwszy test wykonuj pod nadzorem.

Jeżeli proces został brutalnie przerwany (`SIGKILL`, twardy reset) i `doctor` wykryje osierocone konto `qtronic-selftest`, użyj przy stabilnym `OL`:

```bash
nut-config selftest cleanup
```

Cleanup robi backup, usuwa wyłącznie zarezerwowaną sekcję self-test i restartuje `nut-server`. Aktualizacja/instalacja również usuwa taki osierocony wpis automatycznie.

## Read-only health watchdog

```bash
nut-config watchdog status
nut-config watchdog run
nut-config watchdog enable
nut-config watchdog disable
```

Timer jest instalowany, ale **domyślnie wyłączony**. Po włączeniu uruchamia kontrolę mniej więcej co 5 minut. Sprawdza spójność usług, lokalny nasłuch `127.0.0.1:3493`, komunikację, BYPASS, MQTT, osierocone konto self-test, zgodność `SHUTDOWNCMD` z power-cycle i runtime power-cycle oraz zapisuje problemy do journala.

Watchdog **niczego automatycznie nie naprawia, nie restartuje i nie wysyła komend do UPS**.

## Klaster Proxmox

`nut-config doctor` próbuje odczytać `pvecm status`. Przy aktywnym klastrze wielowęzłowym pokazuje ostrzeżenie, że projekt chroni lokalny host. Nie próbuje sam zarządzać migracjami, Proxmox HA ani quorum.

## GitHub CI i Releases

Repo zawiera:

```text
.github/workflows/ci.yml
.github/workflows/release.yml
tests/ci-check.py
VERSION
CHANGELOG.md
```

CI przy push/PR sprawdza składnię Bash, ShellCheck na poziomie błędów, osadzone bloki Python, YAML Home Assistant, zgodność `VERSION` z kodem, obecność dokumentacji kluczowych komend oraz brak uprawnień sterujących dla konta `homeassistant`.

Workflow Release uruchamia się dla tagów `vX.Y.Z`, wymaga zgodności taga z `VERSION` i tworzy GitHub Release. Dzięki temu kanał `stable` może instalować konkretny opublikowany tag zamiast bieżącego `main`.

---

# Zalecana sekwencja po instalacji / aktualizacji

```bash
nut-config version
nut-config doctor
nut-status
nut-config powercycle probe
```

Na nowym UPS najpierw wykonaj prowadzony:

```bash
nut-config test
```

Self-test baterii oraz pierwszy prawdziwy power-cycle wykonuj osobno i pod nadzorem. Przy `FAIL` z `doctor` najpierw zbierz diagnostykę:

```bash
nut-report --public
```

i usuń przyczynę przed ryzykownymi zmianami.

## Licencja

MIT — szczegóły w pliku `LICENSE`.
