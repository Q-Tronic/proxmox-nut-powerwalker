# GitHub z telefonu — Q-Tronic

## 1. Pobierz i rozpakuj paczkę

Pobierz `proxmox-nut-powerwalker-qtronic.zip` i rozpakuj ją w aplikacji Pliki / Files na telefonie.

W środku powinny być:

```text
setup-nut-powerwalker-proxmox.sh
README.md
LICENSE
.gitignore
home-assistant/
```

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

Wgraj główne pliki:

```text
setup-nut-powerwalker-proxmox.sh
README.md
LICENSE
.gitignore
GITHUB-MOBILE.md
```

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

Zaloguj się jako `root` przez SSH:

```bash
apt update
apt install -y git
cd /root
git clone https://github.com/TWOJ_LOGIN/proxmox-nut-powerwalker.git
cd proxmox-nut-powerwalker
chmod +x setup-nut-powerwalker-proxmox.sh
bash ./setup-nut-powerwalker-proxmox.sh
```

Jeśli repo jest prywatne, GitHub będzie wymagał uwierzytelnienia. Najwygodniej później skonfigurować klucz SSH GitHuba.

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

```bash
cd /root/proxmox-nut-powerwalker
git pull
bash ./setup-nut-powerwalker-proxmox.sh
```

Przed zmianami instalator wykona kolejny backup `/etc/nut`.

## 8. Ważne

Nie dodawaj do repozytorium plików powstałych na serwerze:

```text
/root/nut-powerwalker/credentials.env
/etc/nut/nut-mqtt.json
```

Zawierają dane dostępowe.

Autor: **Q-Tronic**
