# GitHub z telefonu — Q-Tronic

## 1. Pobierz i rozpakuj paczkę

Pobierz `proxmox-nut-powerwalker-qtronic.zip` i rozpakuj ją w aplikacji Pliki / Files na telefonie.

W pełnej paczce repozytorium znajdują się m.in.:

```text
install.sh
setup-nut-powerwalker-proxmox.sh
README.md
LICENSE
.gitignore
home-assistant/
```

Jeżeli aktualizujesz istniejące repo paczką typu **delta**, wgrywasz wyłącznie pliki znajdujące się w tej paczce i zastępujesz ich starsze wersje. Nie trzeba ponownie wysyłać pozostałych plików.

## 2. Utwórz repozytorium

W przeglądarce telefonu wejdź na GitHub i utwórz nowe repozytorium, np.:

```text
proxmox-nut-powerwalker
```

Może być `Private` albo `Public`.

Repozytorium nie zawiera haseł generowanych przez instalator.

## 3. Wgraj pliki

Najwygodniej użyć GitHuba w przeglądarce.

W repozytorium:

```text
Add file -> Upload files
```

Przy pełnym pierwszym wgraniu główne pliki to:

```text
install.sh
setup-nut-powerwalker-proxmox.sh
README.md
LICENSE
.gitignore
GITHUB-MOBILE.md
```

Przy aktualizacji obecnego repo przez paczkę delta wybierz tylko pliki z paczki. GitHub zastąpi starsze `README.md` i `GITHUB-MOBILE.md`, a `install.sh` doda jako nowy plik.

Jeśli mobilny GitHub utrudnia wysłanie całego katalogu `home-assistant`, możesz:

1. przełączyć przeglądarkę w tryb „Wersja na komputer”;
2. ponownie użyć `Add file -> Upload files`;
3. albo utworzyć pliki ręcznie przez `Add file -> Create new file`, wpisując nazwę ze ścieżką:

```text
home-assistant/README.md
```

oraz:

```text
home-assistant/automations-example.yaml
```

Opis commita może być:

```text
Initial Q-Tronic NUT setup
```

## 4. Skopiuj adres repozytorium

Przykład:

```text
https://github.com/TWOJ_LOGIN/proxmox-nut-powerwalker.git
```

## 5. Instalacja na Proxmoxie

Dla repo Q-Tronic nie musisz już klonować całego projektu. Zaloguj się jako `root` przez SSH i uruchom:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Jeśli system zgłosi brak `curl`:

```bash
apt update && apt install -y curl ca-certificates
```

i ponów pierwszą komendę.

`install.sh` pobierze właściwy duży instalator, sprawdzi jego podstawowe markery i składnię Bash, zapisze go w `/root/setup-nut-powerwalker-proxmox.sh`, a następnie uruchomi.

## 6. Po instalacji

Najpierw:

```bash
nut-status
```

Następnie:

```bash
nut-capabilities
```

i:

```bash
nut-report
```

Wynik `nut-report` możesz wkleić do ChatGPT.

Dane dla Home Assistant:

```bash
nut-ha-info
```

MQTT:

```bash
nut-mqtt-config
```

Instrukcja bezpiecznego testu zaniku zasilania:

```bash
nut-test-guide
```

## 7. Aktualizacja z GitHuba

Ponownie uruchom tę samą prostą komendę:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Q-Tronic/proxmox-nut-powerwalker/main/install.sh)
```

Pobrana zostanie aktualna wersja głównego instalatora z brancha `main`. Przed zmianami główny instalator wykona kolejny backup `/etc/nut` i zachowa istniejące wygenerowane hasła.

## 8. Ważne

Nie dodawaj do repozytorium plików powstałych na serwerze:

```text
/root/nut-powerwalker/credentials.env
/etc/nut/nut-mqtt.json
```

Zawierają dane dostępowe.

Autor: **Q-Tronic**
