#!/usr/bin/python3
# coding: utf-8
# SPDX-License-Identifier: GPL-3.0-or-later
"""
Home Assistant MQTT discovery per maestrogateway.

Pubblica (retained) la configurazione delle entita' che leggono gli stati
pubblicati da maestro.py su <prefix>/<Nome> e inviano i comandi su
<prefix>/Command/<Nome>. Quando Home Assistant si riavvia (homeassistant/status
= online) ripubblica tutto e chiede a maestro.py un Refresh, cosi' tutti gli
stati vengono reinviati al giro successivo (entro ~15 s).
"""
import json
import os
import threading
import time

import paho.mqtt.client as mqtt

P = os.getenv("TOPIC_PREFIX", "Maestro")
NAME = os.getenv("DEVICE_NAME", "Stufa MCZ")
NODE = "mcz_maestro"
DISC = "homeassistant"

DEVICE = {
    "identifiers": [NODE],
    "name": NAME,
    "manufacturer": "MCZ",
    "model": "Maestro (locale)",
}

STATE = lambda n: f"{P}/{n}"
CMD = lambda n: f"{P}/Command/{n}"

STOVE_STATES = {
    0: "Spenta", 1: "Verifica caldo/freddo", 2: "Pulizia a freddo",
    3: "Carico pellet a freddo", 4: "Avvio 1 a freddo", 5: "Avvio 2 a freddo",
    6: "Pulizia a caldo", 7: "Carico pellet a caldo", 8: "Avvio 1 a caldo",
    9: "Avvio 2 a caldo", 10: "Stabilizzazione", 11: "Potenza 1",
    12: "Potenza 2", 13: "Potenza 3", 14: "Potenza 4", 15: "Potenza 5",
    30: "Diagnostica", 31: "Accesa", 40: "Spegnimento", 41: "Raffreddamento",
    42: "Pulizia bassa", 43: "Pulizia alta", 44: "Sblocco coclea",
    45: "Auto Eco", 46: "Standby", 48: "Diagnostica", 49: "Carico coclea",
    50: "Errore A01 - Accensione fallita", 51: "Errore A02 - Assenza fiamma",
    52: "Errore A03 - Surriscaldamento serbatoio",
    53: "Errore A04 - Temperatura fumi troppo alta",
    54: "Errore A05 - Ostruzione condotto / vento", 55: "Errore A06",
    56: "Errore A09 - Sonda fumi", 57: "Errore A11 - Motoriduttore",
    58: "Errore A13 - Temperatura scheda", 59: "Errore A14 - Active",
    60: "Errore A18 - Temperatura acqua", 61: "Errore A19 - Sonda acqua",
    62: "Errore A20 - Sonda ausiliaria", 63: "Errore A21 - Pressostato",
    64: "Errore A22 - Sonda ambiente", 65: "Errore A23 - Chiusura braciere",
    66: "Errore A12 - Controllo motoriduttore", 67: "Errore A17 - Coclea bloccata",
    69: "Attesa allarmi sicurezza",
}
STATE_MAP_JINJA = "{% set m = " + json.dumps({str(k): v for k, v in STOVE_STATES.items()}) + " %}"

MODES = {0: "Manuale", 1: "Dynamic", 2: "Overnight", 3: "Comfort", 4: "Power"}
SET_MODE = f"{P}/Set/Modalita"

FAN_OPTIONS = ["Spenta", "1", "2", "3", "4", "5", "Auto"]
FAN_STATE_TPL = "{% set v = value | int %}{{ 'Spenta' if v == 0 else ('Auto' if v == 6 else v | string) }}"
FAN_CMD_TPL = "{{ 0 if value == 'Spenta' else (6 if value == 'Auto' else value) }}"


def entities():
    e = []

    def add(component, obj_id, cfg):
        cfg = dict(cfg)
        cfg.setdefault("unique_id", f"{NODE}_{obj_id}")
        cfg.setdefault("default_entity_id", f"{component}.stufa_{obj_id}")
        cfg["device"] = DEVICE
        e.append((f"{DISC}/{component}/{NODE}/{obj_id}/config", cfg))

    # Termostato: accensione/spegnimento + temperatura impostata
    add("climate", "termostato", {
        "name": None,
        "modes": ["off", "heat"],
        "mode_state_topic": STATE("Power"),
        "mode_state_template": "{{ 'heat' if value | int == 1 else 'off' }}",
        "mode_command_topic": CMD("Power"),
        "mode_command_template": "{{ 'ON' if value == 'heat' else 'OFF' }}",
        "current_temperature_topic": STATE("Ambient_Temperature"),
        "temperature_state_topic": STATE("Temperature_Setpoint"),
        "temperature_command_topic": CMD("Temperature_Setpoint"),
        "action_topic": STATE("Stove_State"),
        "action_template": (
            "{% set s = value | int %}"
            "{% if s in [0, 46] %}off"
            "{% elif (1 <= s <= 15) or s == 31 %}heating"
            "{% else %}idle{% endif %}"
        ),
        "min_temp": 5, "max_temp": 35, "temp_step": 0.5, "precision": 0.5,
        "temperature_unit": "C",
    })

    # Ventole (mappatura verificata sull'impianto:
    #   Fan_State  -> bocchetta cameretta
    #   DuctedFan1 -> bocchetta corridoio
    #   DuctedFan2 -> ventola frontale della stufa)
    for obj_id, name, topic, icon in [
        ("bocchetta_corridoio", "Bocchetta corridoio", "DuctedFan1", "mdi:air-duct"),
        ("bocchetta_cameretta", "Bocchetta cameretta", "Fan_State", "mdi:air-duct"),
        ("ventola_frontale", "Ventola frontale", "DuctedFan2", "mdi:fan"),
    ]:
        add("select", obj_id, {
            "name": name, "icon": icon, "options": FAN_OPTIONS,
            "state_topic": STATE(topic), "value_template": FAN_STATE_TPL,
            "command_topic": CMD(topic), "command_template": FAN_CMD_TPL,
        })

    # Modalita' di funzionamento (mappatura verificata con l'app MCZ Maestro:
    # Manuale = Profile 0 + Control_Mode 0, Overnight = 2/1, Comfort = 3/1)
    add("select", "modalita", {
        "name": "Modalita'", "icon": "mdi:thermostat-auto",
        "options": list(MODES.values()),
        "state_topic": STATE("Profile"),
        "value_template": "{% set m = " + json.dumps({str(k): v for k, v in MODES.items()})
                          + " %}{{ m.get((value | int % 10) | string, 'Manuale') }}",
        "command_topic": SET_MODE,
    })

    # Potenza 1-5 (la stufa la riporta come 11-15)
    add("number", "potenza", {
        "name": "Potenza", "icon": "mdi:fire", "min": 1, "max": 5, "step": 1,
        "mode": "slider",
        "state_topic": STATE("Power_Level"),
        "value_template": "{% set v = value | int %}{{ v - 10 if v > 10 else v }}",
        "command_topic": CMD("Power_Level"),
    })

    # Interruttori
    for obj_id, name, topic, icon in [
        ("eco", "Modalita' Eco", "Eco_Mode", "mdi:leaf"),
        ("silent", "Modalita' Silent", "Silent_Mode", "mdi:volume-off"),
        ("crono", "Cronotermostato", "Chronostat", "mdi:calendar-clock"),
    ]:
        add("switch", obj_id, {
            "name": name, "icon": icon,
            "state_topic": STATE(topic), "command_topic": CMD(topic),
            "payload_on": "ON", "payload_off": "OFF",
            "state_on": "1", "state_off": "0",
        })

    # Sensori
    add("sensor", "stato", {
        "name": "Stato", "icon": "mdi:fireplace",
        "state_topic": STATE("Stove_State"),
        "value_template": STATE_MAP_JINJA + "{{ m.get(value | int | string, 'Sconosciuto') }}",
        "device_class": "enum",
        "options": list(dict.fromkeys(list(STOVE_STATES.values()) + ["Sconosciuto"])),
    })
    add("sensor", "stato_codice", {
        "name": "Stato (codice)", "icon": "mdi:numeric",
        "state_topic": STATE("Stove_State"), "value_template": "{{ value | int }}",
        "entity_category": "diagnostic",
    })
    for obj_id, name, topic in [
        ("profilo_codice", "Profilo (codice)", "Profile"),
        ("modalita_controllo_codice", "Modalita' controllo (codice)", "Control_Mode"),
        ("active_codice", "Active (codice)", "Active_Mode"),
    ]:
        add("sensor", obj_id, {
            "name": name, "icon": "mdi:numeric", "state_topic": STATE(topic),
            "entity_category": "diagnostic",
        })
    for obj_id, name, topic in [
        ("temperatura_ambiente", "Temperatura ambiente", "Ambient_Temperature"),
        ("temperatura_fumi", "Temperatura fumi", "Fume_Temperature"),
        ("temperatura_scheda", "Temperatura scheda", "Temperature_Motherboard"),
    ]:
        add("sensor", obj_id, {
            "name": name, "state_topic": STATE(topic),
            "device_class": "temperature", "unit_of_measurement": "°C",
            "state_class": "measurement",
        })
    add("sensor", "giri_fumi", {
        "name": "Giri estrattore fumi", "icon": "mdi:fan-chevron-up",
        "state_topic": STATE("RPM_Fam_Fume"), "unit_of_measurement": "rpm",
        "state_class": "measurement", "entity_category": "diagnostic",
    })
    # La stufa riporta i secondi totali, maestro.py li pubblica come "ore:mm:ss"
    hours_tpl = ("{% set p = value.split(':') %}"
                 "{{ (p[0] | int + p[1] | int / 60 + p[2] | int / 3600) | round(1) }}")
    add("sensor", "ore_funzionamento", {
        "name": "Ore di funzionamento", "icon": "mdi:timer-outline",
        "state_topic": STATE("Total_Operating_Hours"), "value_template": hours_tpl,
        "device_class": "duration", "unit_of_measurement": "h",
        "state_class": "total_increasing", "suggested_display_precision": 0,
        "entity_category": "diagnostic",
    })
    for lvl in range(1, 6):
        add("sensor", f"ore_potenza_{lvl}", {
            "name": f"Ore a potenza {lvl}", "icon": "mdi:timer-outline",
            "state_topic": STATE(f"Hours_Of_Operation_In_Power{lvl}"),
            "value_template": hours_tpl,
            "device_class": "duration", "unit_of_measurement": "h",
            "state_class": "total_increasing", "suggested_display_precision": 0,
            "entity_category": "diagnostic", "enabled_by_default": False,
        })
    add("sensor", "ore_manutenzione", {
        "name": "Ore alla manutenzione", "icon": "mdi:wrench-clock",
        "state_topic": STATE("Hours_To_Service"), "unit_of_measurement": "h",
        "entity_category": "diagnostic",
    })
    add("sensor", "accensioni", {
        "name": "Numero accensioni", "icon": "mdi:counter",
        "state_topic": STATE("Number_Of_Ignitions"), "state_class": "total_increasing",
        "entity_category": "diagnostic",
    })
    # Pubblicati dal watchdog Wi-Fi
    add("sensor", "wifi_canale", {
        "name": "Canale Wi-Fi stufa", "icon": "mdi:wifi-cog",
        "state_topic": STATE("Wifi_Channel"), "state_class": "measurement",
        "entity_category": "diagnostic",
    })
    add("sensor", "wifi_segnale", {
        "name": "Segnale Wi-Fi stufa", "icon": "mdi:wifi-strength-2",
        "state_topic": STATE("Wifi_Signal"), "unit_of_measurement": "%",
        "state_class": "measurement", "entity_category": "diagnostic",
    })
    add("binary_sensor", "connessione", {
        "name": "Connessione stufa", "device_class": "connectivity",
        "state_topic": STATE("Status"),
        "payload_on": "connected", "payload_off": "disconnected",
        "entity_category": "diagnostic",
    })
    return e


# Entita' della prima versione da rimuovere da Home Assistant
REMOVED = [("select", "canalizzata_1"), ("select", "canalizzata_2")]


def publish_all(client):
    for component, obj_id in REMOVED:
        client.publish(f"{DISC}/{component}/{NODE}/{obj_id}/config", "", qos=1, retain=True)
    for topic, cfg in entities():
        client.publish(topic, json.dumps(cfg), qos=1, retain=True)
    print(f"Discovery: pubblicate {len(entities())} entita'", flush=True)
    # Dopo che Home Assistant ha registrato le entita', chiede a maestro.py di
    # ripubblicare tutti gli stati (al giro successivo, entro ~15 s)
    for delay in (10, 40):
        threading.Timer(delay, lambda: client.publish(CMD("Refresh"), "1", qos=1)).start()


def on_connect(client, userdata, flags, rc):
    print(f"Discovery: connesso a MQTT (rc={rc})", flush=True)
    client.subscribe(f"{DISC}/status", qos=1)
    client.subscribe(SET_MODE, qos=1)
    publish_all(client)


def set_mode(client, name):
    """Come l'app: Manuale -> Profile 0 + Control_Mode 0; altrimenti Control_Mode 1 + Profile N."""
    code = next((k for k, v in MODES.items() if v == name), None)
    if code is None:
        print(f"Discovery: modalita' sconosciuta '{name}'", flush=True)
        return
    print(f"Discovery: imposto modalita' {name} (Profile={code})", flush=True)
    if code == 0:
        client.publish(CMD("Profile"), "0", qos=1)
        client.publish(CMD("Control_Mode"), "0", qos=1)
    else:
        client.publish(CMD("Control_Mode"), "1", qos=1)
        client.publish(CMD("Profile"), str(code), qos=1)


def on_message(client, userdata, msg):
    payload = msg.payload.decode()
    if msg.topic == f"{DISC}/status" and payload == "online":
        time.sleep(5)
        publish_all(client)
    elif msg.topic == SET_MODE:
        set_mode(client, payload)


def main():
    client = mqtt.Client(client_id="MCZ_Discovery")
    if os.getenv("MQTT_user"):
        client.username_pw_set(os.getenv("MQTT_user"), os.getenv("MQTT_pass"))
    client.on_connect = on_connect
    client.on_message = on_message
    while True:
        try:
            client.connect(os.getenv("MQTT_ip", "core-mosquitto"), int(os.getenv("MQTT_port", "1883")))
            break
        except Exception as ex:  # broker non ancora pronto
            print(f"Discovery: MQTT non raggiungibile ({ex}), riprovo tra 10 s", flush=True)
            time.sleep(10)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()
