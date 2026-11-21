#!/usr/bin/with-contenv bashio
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Watchdog Wi-Fi verso la stufa.
#
# Il Wi-Fi della stufa ogni tanto cade. Se il ricollegamento fallisce durante
# lo scambio chiavi, NetworkManager pensa che la password sia sbagliata e
# blocca l'autoconnessione ("no-secrets"), anche se la password salvata e'
# corretta. Qui controlliamo lo stato dell'interfaccia e, se resta
# "disconnected" per due controlli di fila, riattiviamo la connessione salvata.

# bashio attiva errexit/nounset/pipefail: qui un grep senza risultati e' normale
# e non deve terminare il watchdog.
set +o errexit +o nounset +o pipefail

IFACE="$(bashio::config 'wifi_interface')"
# with-contenv non eredita le variabili di run.sh: le rileggiamo qui
TOPIC_PREFIX="$(bashio::config 'topic_prefix')"
MQTT_ip="$(bashio::services mqtt 'host')"
MQTT_port="$(bashio::services mqtt 'port')"
MQTT_user="$(bashio::services mqtt 'username')"
MQTT_pass="$(bashio::services mqtt 'password')"
INTERVAL=60
NM="org.freedesktop.NetworkManager"
G=(gdbus call --system --dest="${NM}")

dev_path() {
    "${G[@]}" --object-path=/org/freedesktop/NetworkManager \
        --method="${NM}.GetDeviceByIpIface" "${IFACE}" 2>/dev/null \
        | grep -o "/org/[A-Za-z0-9/_]*"
}

dev_state() {
    # Risposta tipo "(<uint32 100>,)": 100 = activated, 30 = disconnected,
    # 20 = unavailable, 40-90 = in attivazione
    "${G[@]}" --object-path="$1" --method=org.freedesktop.DBus.Properties.Get \
        "${NM}.Device" State 2>/dev/null | grep -o "uint32 [0-9]\+" | grep -o "[0-9]\+$"
}

active_connection() {
    # Profilo salvato della connessione attualmente attiva sull'interfaccia
    local ac
    ac="$("${G[@]}" --object-path="$1" --method=org.freedesktop.DBus.Properties.Get \
        "${NM}.Device" ActiveConnection 2>/dev/null | grep -o "/org/[A-Za-z0-9/_]*")"
    [ -z "${ac}" ] || [ "${ac}" = "/" ] && return
    "${G[@]}" --object-path="${ac}" --method=org.freedesktop.DBus.Properties.Get \
        "${NM}.Connection.Active" Connection 2>/dev/null \
        | grep -o "/org/freedesktop/NetworkManager/Settings/[0-9]\+"
}

supervisor_connection() {
    # Ripiego: profilo "Supervisor <iface>" creato da Home Assistant (WPA)
    local c s
    for c in $("${G[@]}" --object-path="$1" --method=org.freedesktop.DBus.Properties.Get \
        "${NM}.Device" AvailableConnections 2>/dev/null \
        | grep -o "/org/freedesktop/NetworkManager/Settings/[0-9]\+"); do
        s="$("${G[@]}" --object-path="${c}" \
            --method="${NM}.Settings.Connection.GetSettings" 2>/dev/null)"
        if echo "${s}" | grep -q "'id': <'Supervisor ${IFACE}'>" \
           && echo "${s}" | grep -q "'key-mgmt': <'wpa-psk'>"; then
            echo "${c}"; return
        fi
    done
}

wifi_connection() {
    # Ultimo profilo visto funzionante, altrimenti quello creato da Home Assistant
    if [ -n "${LAST_GOOD}" ]; then echo "${LAST_GOOD}"; else supervisor_connection "$1"; fi
}

LAST_GOOD=""

bashio::log.info "Watchdog Wi-Fi attivo su ${IFACE} (controllo ogni ${INTERVAL}s)"
d0="$(dev_path)"
if [ -n "${d0}" ]; then
    [ "$(dev_state "${d0}")" = "100" ] && LAST_GOOD="$(active_connection "${d0}")"
    bashio::log.info "Watchdog: ${IFACE} stato NetworkManager = $(dev_state "${d0}") (100 = collegata), connessione salvata = $(wifi_connection "${d0}")"
else
    bashio::log.error "Watchdog: impossibile leggere NetworkManager via D-Bus"
fi
# ---- Monitoraggio canale/segnale della rete della stufa (lettura passiva, nessuna scansione)
prop() {  # prop <path> <interface> <nome>
    "${G[@]}" --object-path="$1" --method=org.freedesktop.DBus.Properties.Get "$2" "$3" 2>/dev/null
}
ap_freq()   { prop "$1" "${NM}.AccessPoint" Frequency | grep -o "uint32 [0-9]\+" | grep -o "[0-9]\+$"; }
ap_signal() { prop "$1" "${NM}.AccessPoint" Strength | grep -o "0x[0-9a-f]\+" | head -1; }
ap_bssid()  { prop "$1" "${NM}.AccessPoint" HwAddress | grep -o "[0-9A-Fa-f:]\{17\}"; }

stove_ap() {
    # AP attivo se collegati, altrimenti l'ultimo AP della stufa visto in cache
    local ap
    ap="$(prop "$1" "${NM}.Device.Wireless" ActiveAccessPoint | grep -o "/org/[A-Za-z0-9/_]*")"
    if [ -n "${ap}" ] && [ "${ap}" != "/" ]; then echo "${ap}"; return; fi
    for ap in $(prop "$1" "${NM}.Device.Wireless" AccessPoints | grep -o "/org/freedesktop/NetworkManager/AccessPoint/[0-9]\+"); do
        if [ -n "${LAST_BSSID}" ]; then
            [ "$(ap_bssid "${ap}")" = "${LAST_BSSID}" ] && { echo "${ap}"; return; }
        else
            # Ripiego: rete il cui nome inizia con "MCZ-"
            prop "${ap}" "${NM}.AccessPoint" Ssid | grep -q "0x4d, 0x43, 0x5a, 0x2d" \
                && { echo "${ap}"; return; }
        fi
    done
}

channel_of() {  # MHz -> canale 2.4/5 GHz
    local f="$1"
    if [ "${f}" -eq 2484 ]; then echo 14
    elif [ "${f}" -lt 3000 ]; then echo $(( (f - 2407) / 5 ))
    else echo $(( (f - 5000) / 5 )); fi
}

mqtt_pub() {  # mqtt_pub <topic> <valore>  (retained)
    local err
    err="$(mosquitto_pub -h "${MQTT_ip}" -p "${MQTT_port}" -u "${MQTT_user}" -P "${MQTT_pass}" \
        -i "MCZ_Watchdog" -r -q 1 -t "${TOPIC_PREFIX}/$1" -m "$2" 2>&1)" \
        || bashio::log.warning "Watchdog: invio MQTT ${TOPIC_PREFIX}/$1 fallito (host=${MQTT_ip:-vuoto}): ${err}"
}

LAST_BSSID=""; LAST_CH=""; LAST_STATE=""; DOWN_SINCE=""
monitor() {  # monitor <device> <stato>
    local dev="$1" state="$2" ap f ch sig now
    now="$(date +%s)"
    ap="$(stove_ap "${dev}")"
    if [ -n "${ap}" ]; then
        f="$(ap_freq "${ap}")"
        [ "${state}" = "100" ] && LAST_BSSID="$(ap_bssid "${ap}")"
        if [ -n "${f}" ]; then
            ch="$(channel_of "${f}")"
            if [ -n "${LAST_CH}" ] && [ "${ch}" != "${LAST_CH}" ]; then
                bashio::log.warning "Watchdog: la rete della stufa ha cambiato canale ${LAST_CH} -> ${ch} (${f} MHz)"
            fi
            [ "${ch}" != "${LAST_CH}" ] && mqtt_pub "Wifi_Channel" "${ch}"
            LAST_CH="${ch}"
        fi
        sig="$(ap_signal "${ap}")"
        [ -n "${sig}" ] && [ "${state}" = "100" ] && mqtt_pub "Wifi_Signal" "$((sig))"
    fi
    if [ "${state}" = "100" ] && [ -n "${LAST_STATE}" ] && [ "${LAST_STATE}" != "100" ]; then
        bashio::log.info "Watchdog: Wi-Fi stufa ricollegato (canale ${LAST_CH:-?}) dopo $(( (now - ${DOWN_SINCE:-now}) / 60 )) min"
        DOWN_SINCE=""
    elif [ "${state}" != "100" ] && { [ -z "${LAST_STATE}" ] || [ "${LAST_STATE}" = "100" ]; }; then
        bashio::log.warning "Watchdog: Wi-Fi stufa scollegato (stato ${state}, ultimo canale ${LAST_CH:-?})"
        DOWN_SINCE="${now}"
    fi
    [ "${state}" != "100" ] && mqtt_pub "Wifi_Signal" "0"
    LAST_STATE="${state}"
}

strikes=0
while true; do
    dev="$(dev_path)"
    [ -z "${dev}" ] && { bashio::log.warning "Watchdog: interfaccia ${IFACE} non trovata"; sleep "${INTERVAL}"; continue; }
    state="$(dev_state "${dev}")"
    monitor "${dev}" "${state}"
    sleep "${INTERVAL}"
    state="$(dev_state "${dev}")"
    if [ "${state}" = "100" ]; then
        good="$(active_connection "${dev}")"
        [ -n "${good}" ] && LAST_GOOD="${good}"
    fi
    if [ "${state}" = "30" ]; then
        strikes=$((strikes + 1))
    else
        strikes=0
    fi
    if [ "${strikes}" -ge 2 ]; then
        conn="$(wifi_connection "${dev}")"
        if [ -n "${conn}" ]; then
            bashio::log.warning "Watchdog: ${IFACE} scollegata, riattivo la connessione salvata"
            "${G[@]}" --object-path=/org/freedesktop/NetworkManager \
                --method="${NM}.ActivateConnection" "${conn}" "${dev}" "/" >/dev/null 2>&1 \
                || bashio::log.warning "Watchdog: riattivazione non riuscita, riprovo"
        else
            bashio::log.warning "Watchdog: nessuna connessione salvata disponibile (rete della stufa non visibile?)"
        fi
        strikes=0
    fi
done
