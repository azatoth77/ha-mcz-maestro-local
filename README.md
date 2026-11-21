# MCZ Maestro (local) — Home Assistant add-on

Local, cloud-free control of **MCZ pellet stoves with Maestro technology** from
Home Assistant, including the **ducted (canalized) fans**.

The add-on talks directly to the stove's own Wi-Fi access point (websocket on
`192.168.120.1:81`) using [maestrogateway](https://github.com/Chibald/maestrogateway)
by Chibald, and exposes everything to Home Assistant through **MQTT discovery**.
The MCZ cloud and the official app keep working in parallel, but are not needed.

> 🇮🇹 Controllo locale delle stufe a pellet MCZ Maestro da Home Assistant, senza cloud,
> comprese le ventole canalizzate. Le entità sono in italiano.

## Features

- **Thermostat** (`climate`): on/off, target temperature, room temperature, heating action
- **Operating mode** (`select`): Manuale, Dynamic, Overnight, Comfort, Power
- **Power level** 1–5 (`number`)
- **Fans** (`select`: Spenta / 1–5 / Auto): front fan and the two ducted fans
- **Switches**: Eco, Silent, Chronothermostat
- **Sensors**: state (enum with all states and error codes A01–A23), room / flue gas /
  board temperature, flue fan RPM, operating hours (total and per power level),
  hours to service, number of ignitions, connection
- **Wi-Fi manager / watchdog**: the stove's access point drops clients often (it changes
  channel and sometimes disappears for minutes). The add-on manages the Wi-Fi profile
  itself (optional `wifi_ssid` / `wifi_password`): power saving off, infinite retries,
  forced rescan and reconnect every 20 s, duplicate profiles removed. It publishes the
  stove's Wi-Fi **channel** and **signal** as sensors for troubleshooting.

## Requirements

- Home Assistant **OS** (the add-on uses Supervisor services and host D-Bus)
- The **Mosquitto broker** add-on and the MQTT integration
- An MCZ stove with **Maestro** electronics that exposes its **own Wi-Fi network**
  (SSID `MCZ-xxxxxxxx`). Newer *Maestro+* stoves that only offer cloud/Bluetooth are
  not supported.
- A Home Assistant host with **two network interfaces**: typically Ethernet to your LAN
  and the built-in Wi-Fi joined to the stove's network (e.g. Raspberry Pi 4).

## Installation

1. **Add this repository** in Home Assistant: *Settings → Add-ons → Add-on store →
   ⋮ → Repositories*, paste `https://github.com/azatoth77/ha-mcz-maestro-local`.
2. Install **MCZ Maestro (locale)**.
3. In the add-on **Configuration** tab set `wifi_ssid` (the stove's `MCZ-…` network) and
   `wifi_password` (printed on the stove label / QR code). The add-on joins the host's
   Wi-Fi interface to the stove with a static IP and **no gateway**, so internet keeps
   going through Ethernet.
4. Start the add-on and check the log. The device **Stufa MCZ** appears under the MQTT
   integration.

<details><summary>Alternative: join the stove's Wi-Fi manually</summary>

From the *Terminal & SSH* add-on (zsh), then leave `wifi_ssid` / `wifi_password` empty:

```sh
read -rs "P?Stove Wi-Fi password: "; echo; ha network update wlan0   --ipv4-method static --ipv4-address 192.168.120.10/24 --ipv6-method disabled   --wifi-mode infrastructure --wifi-ssid "MCZ-XXXXXXXXXXXX" --wifi-auth wpa-psk   --wifi-psk "$P"; unset P
```
</details>

See [the add-on documentation](mcz_maestro/DOCS.md) for options, entity details and
troubleshooting.

## Notes

- **Fan names depend on the installation.** The stove exposes three fan parameters
  (`Fan_State`, `DuctedFan1`, `DuctedFan2`); which one feeds which outlet depends on how
  the stove was installed. The default names reflect the author's setup — rename the
  entities in Home Assistant to match yours.
- Mode codes were verified against the official app (Manuale = 0, Overnight = 2,
  Comfort = 3; Dynamic = 1 and Power = 4 follow the same order).

## Credits and license

- Stove protocol and gateway: [Chibald/maestrogateway](https://github.com/Chibald/maestrogateway)
  (GPL-3.0), included **unmodified** in [`mcz_maestro/app`](mcz_maestro/app)
  from commit `4c4e551907790bfcc80b6f8d78aea858090e8087`.
  See [`mcz_maestro/app/UPSTREAM.md`](mcz_maestro/app/UPSTREAM.md).
- Home Assistant add-on packaging, MQTT discovery, mode handling and Wi-Fi watchdog:
  this repository.

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

**Disclaimer.** This is an unofficial, community project, not affiliated with or endorsed
by MCZ Group S.p.A. "MCZ" and "Maestro" are trademarks of their respective owners.
You are controlling a combustion appliance: use at your own risk, keep the stove's own
safety features and controls in place, and never rely on this software for safety.
