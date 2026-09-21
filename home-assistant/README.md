# Home Assistant

Autor: **Q-Tronic**

## Wariant zalecany: oficjalna integracja NUT

Po uruchomieniu instalatora na Proxmoxie wpisz:

```bash
nut-ha-info
```

Następnie w Home Assistant:

**Ustawienia → Urządzenia i usługi → Dodaj integrację → Network UPS Tools (NUT)**

Wprowadź dane pokazane przez `nut-ha-info`:

- host: IP Proxmoxa,
- port: `3493`,
- użytkownik: `homeassistant`,
- hasło: wygenerowane przez instalator.

To jest najważniejsza integracja. **Home Assistant nie steruje shutdownem serwera** — robi to lokalny NUT na Proxmoxie, więc awaria HA nie blokuje bezpiecznego zamknięcia hosta.

## MQTT

MQTT jest opcjonalną, dodatkową warstwą telemetryczną. Na Proxmoxie:

```bash
nut-mqtt-config
```

Konfigurator zapyta o:

- adres/IP brokera,
- port (zwykle `1883`),
- użytkownika,
- hasło.

Jeśli brokerem jest dodatek Mosquitto w Home Assistant, z punktu widzenia Proxmoxa użyj **adresu IP Home Assistanta**, nie nazwy `core-mosquitto`.

Po poprawnym teście połączenia zostanie uruchomiona usługa:

```bash
systemctl status nut-mqtt.service
```

Most publikuje:

```text
qtronic/proxmox/powerwalker/state
qtronic/proxmox/powerwalker/availability
```

oraz używa **Home Assistant MQTT Discovery**, więc encje powinny pojawić się automatycznie pod jednym urządzeniem „PowerWalker UPS”.

## Ważne

Możesz używać integracji NUT i MQTT równolegle, ale część danych będzie zdublowana. Najrozsądniej traktować:

- **NUT** jako podstawowy monitoring UPS,
- **MQTT** jako dodatkową telemetrię i źródło do własnych automatyzacji.

MQTT nie ma żadnego topicu sterującego UPS-em i nie może wyłączyć Proxmoxa.
