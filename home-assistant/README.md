# Home Assistant

Projekt współpracuje z Home Assistant na dwa sposoby:

1. przez oficjalną integrację **Network UPS Tools (NUT)** — wariant zalecany;
2. opcjonalnie przez MQTT i Home Assistant MQTT Discovery.

Shutdown hosta Proxmox jest wykonywany lokalnie przez NUT. Home Assistant nie jest wymagany do bezpiecznego zamknięcia serwera.

## Integracja NUT

Na Proxmoxie wyświetl aktualne dane połączenia:

```bash
nut-ha-info
```

W Home Assistant przejdź do:

**Ustawienia → Urządzenia i usługi → Dodaj integrację → Network UPS Tools (NUT)**

Wprowadź dokładnie host, port, użytkownika i hasło pokazane przez `nut-ha-info`.

Dla stabilnego połączenia warto używać stałego adresu IP Proxmoxa, rezerwacji DHCP albo stabilnej nazwy DNS.

Konto `homeassistant` utworzone przez projekt ma służyć do monitoringu. Nie otrzymuje `instcmds`, więc Home Assistant nie może przez to konto wykonywać poleceń UPS.

## MQTT

MQTT jest opcjonalną dodatkową warstwą telemetryczną.

Konfiguracja:

```bash
nut-config mqtt setup
```

Status:

```bash
nut-config mqtt status
```

Wyłączenie:

```bash
nut-config mqtt disable
```

Most publikuje stan UPS i konfigurację Home Assistant MQTT Discovery. Nie publikuje topiców sterujących UPS-em.

Jeżeli broker Mosquitto działa jako dodatek Home Assistant, z perspektywy Proxmoxa użyj adresu IP lub nazwy DNS hosta Home Assistant dostępnej w LAN.

## Automatyzacje

Przykłady znajdują się w:

```text
home-assistant/automations-example.yaml
```

Po dodaniu integracji sprawdź rzeczywiste `entity_id` w swojej instalacji i dopasuj przykłady przed użyciem.


## Przykładowe automatyzacje

- `automations-nut-example.yaml` — oficjalna integracja NUT;
- `automations-mqtt-example.yaml` — opcjonalne MQTT Discovery.

`automations-example.yaml` pozostaje zgodnościową kopią wariantu NUT. Zawsze sprawdź rzeczywiste `entity_id`.
