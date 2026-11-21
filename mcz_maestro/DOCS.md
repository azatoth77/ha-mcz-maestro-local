# MCZ Maestro (locale)

Controllo locale della stufa MCZ Maestro tramite la sua rete Wi-Fi, senza cloud.

## Prerequisiti

- Add-on **Mosquitto broker** installato e avviato: le credenziali MQTT vengono
  prese automaticamente, non serve configurarle.
- L'interfaccia Wi-Fi dell'host collegata alla rete della stufa (`MCZ-…`) con IP
  statico (es. `192.168.120.10/24`) e **senza gateway**. Vedi il README del repository.

## Opzioni

| Opzione | Default | Descrizione |
|---|---|---|
| `mcz_ip` | `192.168.120.1` | Indirizzo della stufa sulla sua rete Wi-Fi |
| `mcz_port` | `81` | Porta websocket della stufa |
| `device_name` | `Stufa MCZ` | Nome del dispositivo in Home Assistant |
| `topic_prefix` | `Maestro` | Prefisso dei topic MQTT (`Maestro/<valore>`, comandi su `Maestro/Command/<valore>`) |
| `wifi_watchdog` | `true` | Riattiva la connessione Wi-Fi verso la stufa se NetworkManager si blocca |
| `wifi_interface` | `wlan0` | Interfaccia Wi-Fi collegata alla stufa |

## Entità

| Entità | Parametro stufa | Note |
|---|---|---|
| `climate.stufa_termostato` | Power, Temperature_Setpoint, Ambient_Temperature, Stove_State | Modi `off` / `heat` |
| `select.stufa_modalita` | Profile (149) + Control_Mode (40) | Manuale = 0/0, Dynamic 1, Overnight 2, Comfort 3, Power 4 (Control_Mode 1) |
| `number.stufa_potenza` | Power_Level (36) | 1–5 (la stufa lo riporta come 11–15) |
| `select.stufa_bocchetta_corridoio` | DuctedFan1 (38) | Spenta / 1–5 / Auto |
| `select.stufa_bocchetta_cameretta` | Fan_State (37) | Spenta / 1–5 / Auto |
| `select.stufa_ventola_frontale` | DuctedFan2 (39) | Spenta / 1–5 / Auto |
| `switch.stufa_eco`, `_silent`, `_crono` | Eco_Mode, Silent_Mode, Chronostat | |
| `sensor.stufa_stato` | Stove_State | Enum con tutti gli stati ed errori |
| `sensor.stufa_*` | vari | Temperature, giri estrattore, ore, accensioni, codici grezzi |
| `sensor.stufa_wifi_canale`, `_segnale` | watchdog | Canale e segnale della rete della stufa |
| `binary_sensor.stufa_connessione` | Status | Connessione websocket alla stufa |

I nomi delle ventole riflettono l'impianto dell'autore: quale parametro alimenta quale
bocchetta dipende dall'installazione. Rinomina le entità in Home Assistant.

## Risoluzione problemi

- **La stufa risulta disconnessa**: controlla nel log dell'add-on le righe `Watchdog:`.
  Se la rete della stufa cambia canale, i client vengono disconnessi per alcuni minuti;
  il watchdog ricollega automaticamente. Se resta bloccata a lungo, a stufa **spenta e
  fredda** togli alimentazione per un minuto per riavviare il modulo Wi-Fi.
- **Profili Wi-Fi duplicati**: tentativi di connessione falliti possono lasciare più
  profili "Supervisor wlan0" (es. uno con password vuota) che NetworkManager può provare
  al posto di quello giusto. Tieni solo quello funzionante.
- Il gateway apre una sola connessione websocket: evita altri client sulla rete della stufa.
