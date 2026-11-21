#!/usr/bin/with-contenv bashio
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
#
# Watchdog Wi-Fi verso la stufa (usa nmcli sul NetworkManager dell'host via D-Bus).
#
# - Gestisce il profilo Wi-Fi della stufa: risparmio energetico disattivato,
#   tentativi di autoconnessione infiniti, nessun gateway. Se nelle opzioni ci
#   sono SSID e password, crea il profilo se manca e reimposta la password.
# - Elimina profili duplicati per la stessa rete (es. tentativi falliti).
# - Se il Wi-Fi resta scollegato, forza una scansione e riattiva il profilo
#   appena la rete della stufa e' visibile.
# - Pubblica canale e segnale della rete della stufa su MQTT.

# bashio attiva errexit/nounset/pipefail: qui un comando senza risultati e'
# normale e non deve terminare il watchdog.
set +o errexit +o nounset +o pipefail

opt() { local v; v="$(bashio::config "$1")"; [ "${v}" = "null" ] && v=""; echo "${v}"; }

IFACE="$(opt wifi_interface)"; IFACE="${IFACE:-wlan0}"
SSID="$(opt wifi_ssid)"
PSK="$(opt wifi_password)"
WIFI_IP="$(opt wifi_ip)"; WIFI_IP="${WIFI_IP:-192.168.120.10/24}"
INTERVAL="$(opt wifi_check_interval)"; INTERVAL="${INTERVAL:-20}"

# with-contenv non eredita le variabili di run.sh: le rileggiamo qui
TOPIC_PREFIX="$(opt topic_prefix)"
MQTT_ip="$(bashio::services mqtt 'host')"
MQTT_port="$(bashio::services mqtt 'port')"
MQTT_user="$(bashio::services mqtt 'username')"
MQTT_pass="$(bashio::services mqtt 'password')"

export NO_COLOR=1
nm() {  # nmcli senza l'avviso di versione client/server; restituisce l'esito di nmcli
    local out rc
    out="$(nmcli "$@" 2>&1)"; rc=$?
    out="$(printf '%s\n' "${out}" | grep -v "versions don't match")"
    [ -n "${out}" ] && printf '%s\n' "${out}"
    return "${rc}"
}

mqtt_pub() {  # mqtt_pub <topic> <valore>  (retained)
    local err
    err="$(mosquitto_pub -h "${MQTT_ip}" -p "${MQTT_port}" -u "${MQTT_user}" -P "${MQTT_pass}" \
        -i "MCZ_Watchdog" -r -q 1 -t "${TOPIC_PREFIX}/$1" -m "$2" 2>&1)" \
        || bashio::log.warning "Watchdog: invio MQTT ${TOPIC_PREFIX}/$1 fallito: ${err}"
}

# ------------------------------------------------------------------ profilo
wifi_profiles() {  # UUID dei profili Wi-Fi legati all'interfaccia (o senza interfaccia)
    local uuid type ifn
    nm -t -f UUID,TYPE con show | while IFS=: read -r uuid type; do
        [ "${type}" = "802-11-wireless" ] || continue
        ifn="$(nm -g connection.interface-name con show "${uuid}")"
        { [ -z "${ifn}" ] || [ "${ifn}" = "${IFACE}" ]; } && echo "${uuid}"
    done
}
profile_ssid()  { nm -g 802-11-wireless.ssid con show "$1"; }
profile_stamp() { nm -g connection.timestamp con show "$1"; }

pick_profile() {
    # Il profilo per SSID (se configurato) usato piu' di recente; senza SSID,
    # quello attivo o il piu' recente sull'interfaccia.
    local best="" best_ts=-1 u s ts
    for u in $(wifi_profiles); do
        s="$(profile_ssid "${u}")"
        if [ -n "${SSID}" ]; then
            [ "${s}" = "${SSID}" ] || continue
        else
            case "${s}" in MCZ-*) ;; *) continue ;; esac
        fi
        ts="$(profile_stamp "${u}")"; ts="${ts:-0}"
        [ "${ts}" -gt "${best_ts}" ] && { best="${u}"; best_ts="${ts}"; }
    done
    echo "${best}"
}

PROFILE=""
ensure_profile() {
    local u s out args
    PROFILE="$(pick_profile)"
    if [ -z "${PROFILE}" ]; then
        if [ -n "${SSID}" ] && [ -n "${PSK}" ]; then
            out="$(nm con add type wifi ifname "${IFACE}" con-name "MCZ stufa" ssid "${SSID}" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${PSK}" \
                ipv4.method manual ipv4.addresses "${WIFI_IP}" ipv4.never-default yes \
                ipv6.method disabled 802-11-wireless.powersave 2 \
                connection.autoconnect yes connection.autoconnect-retries 0)"
            PROFILE="$(pick_profile)"
            bashio::log.info "Watchdog: creato profilo Wi-Fi per ${SSID} (${PROFILE:-errore: ${out}})"
        else
            bashio::log.warning "Watchdog: nessun profilo Wi-Fi della stufa trovato. Collega ${IFACE} alla rete della stufa oppure imposta wifi_ssid e wifi_password."
            return 1
        fi
    fi
    SSID_ACTIVE="$(profile_ssid "${PROFILE}")"

    # Rimuove duplicati per la stessa rete
    for u in $(wifi_profiles); do
        [ "${u}" = "${PROFILE}" ] && continue
        s="$(profile_ssid "${u}")"
        if [ "${s}" = "${SSID_ACTIVE}" ]; then
            nm con delete "${u}" >/dev/null && bashio::log.info "Watchdog: eliminato profilo duplicato ${u} per ${s}"
        fi
    done

    # Impostazioni robuste sul profilo scelto
    args=(802-11-wireless.powersave 2 connection.autoconnect yes connection.autoconnect-retries 0
          ipv4.never-default yes)
    [ -n "${PSK}" ] && args+=(wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${PSK}")
    out="$(nm con modify "${PROFILE}" "${args[@]}")" \
        && bashio::log.info "Watchdog: profilo ${SSID_ACTIVE} (${PROFILE}): risparmio energetico disattivato, tentativi infiniti$([ -n "${PSK}" ] && echo ', password dalle opzioni')" \
        || bashio::log.warning "Watchdog: impossibile aggiornare il profilo: ${out}"
    return 0
}

# ------------------------------------------------------------------ stato
dev_state() { nm -g GENERAL.STATE dev show "${IFACE}" | grep -o "^[0-9]\+"; }

ap_line() {  # "CANALE:SEGNALE" della rete della stufa dalla cache (senza scansione)
    local inuse ssid chan sig
    nm -t -e no -f IN-USE,SSID,CHAN,SIGNAL dev wifi list ifname "${IFACE}" --rescan no \
        | awk -F: -v s="${SSID_ACTIVE}" '$2==s {print $3":"$4; exit}'
}

reconnect() {
    local out
    nm dev wifi rescan ifname "${IFACE}" >/dev/null
    sleep 4
    if [ -z "$(ap_line)" ]; then
        bashio::log.info "Watchdog: rete ${SSID_ACTIVE} non visibile, riprovo"
        return
    fi
    bashio::log.warning "Watchdog: rete ${SSID_ACTIVE} visibile, forzo la connessione"
    out="$(nm -w 30 con up "${PROFILE}" ifname "${IFACE}")"
    if echo "${out}" | grep -qi "success"; then
        bashio::log.info "Watchdog: connessione riuscita"
    else
        bashio::log.warning "Watchdog: connessione non riuscita: $(echo "${out}" | tail -1)"
        if echo "${out}" | grep -qiE "secrets|password"; then
            ensure_profile >/dev/null
        fi
    fi
}

# ------------------------------------------------------------------ avvio
if ! nm general status >/dev/null; then
    bashio::log.error "Watchdog: NetworkManager non raggiungibile via D-Bus"
fi
bashio::log.info "Watchdog Wi-Fi attivo su ${IFACE} (controllo ogni ${INTERVAL}s)"
until ensure_profile; do sleep 60; done

LAST_CH=""; LAST_STATE=""; DOWN_SINCE=""; DOWN_CHECKS=0
while true; do
    now="$(date +%s)"
    state="$(dev_state)"
    ap="$(ap_line)"
    ch="${ap%%:*}"; sig="${ap##*:}"
    [ -z "${ap}" ] && { ch="0"; sig="0"; }

    if [ "${ch}" != "${LAST_CH}" ]; then
        if [ "${ch}" = "0" ]; then
            bashio::log.warning "Watchdog: rete della stufa non visibile (era sul canale ${LAST_CH:-?})"
        elif [ -n "${LAST_CH}" ]; then
            bashio::log.warning "Watchdog: rete della stufa sul canale ${ch} (prima ${LAST_CH})"
        fi
        mqtt_pub "Wifi_Channel" "${ch}"
        LAST_CH="${ch}"
    fi
    if [ "${state}" = "100" ]; then mqtt_pub "Wifi_Signal" "${sig:-0}"; else mqtt_pub "Wifi_Signal" "0"; fi

    if [ "${state}" = "100" ]; then
        if [ -n "${LAST_STATE}" ] && [ "${LAST_STATE}" != "100" ]; then
            bashio::log.info "Watchdog: Wi-Fi stufa ricollegato (canale ${ch}) dopo $(( (now - ${DOWN_SINCE:-now}) / 60 )) min"
        fi
        DOWN_SINCE=""; DOWN_CHECKS=0
    else
        if [ -z "${LAST_STATE}" ] || [ "${LAST_STATE}" = "100" ]; then
            bashio::log.warning "Watchdog: Wi-Fi stufa scollegato (stato ${state:-?})"
            DOWN_SINCE="${now}"
        fi
        DOWN_CHECKS=$((DOWN_CHECKS + 1))
        # 40-90 = attivazione in corso: lasciamo lavorare NetworkManager per un po'
        if [ "${state:-0}" -lt 40 ] || [ "${state:-0}" -gt 90 ] || [ "${DOWN_CHECKS}" -ge 4 ]; then
            [ "${DOWN_CHECKS}" -ge 2 ] && { reconnect; DOWN_CHECKS=1; }
        fi
    fi
    LAST_STATE="${state}"
    sleep "${INTERVAL}"
done
