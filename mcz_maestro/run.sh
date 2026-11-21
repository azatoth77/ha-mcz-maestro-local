#!/usr/bin/with-contenv bashio
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
set -e

if ! bashio::services.available "mqtt"; then
    bashio::exit.nok "Servizio MQTT non disponibile: installa e avvia l'add-on Mosquitto."
fi

PREFIX="$(bashio::config 'topic_prefix')"

export MQTT_ip="$(bashio::services mqtt 'host')"
export MQTT_port="$(bashio::services mqtt 'port')"
export MQTT_user="$(bashio::services mqtt 'username')"
export MQTT_pass="$(bashio::services mqtt 'password')"
export MQTT_authentication="True"
export MQTT_TOPIC_PUB="${PREFIX}/"
export MQTT_TOPIC_SUB="${PREFIX}/Command/"
export MQTT_PAYLOAD_TYPE="TOPIC"
export MCZip="$(bashio::config 'mcz_ip')"
export MCZport="$(bashio::config 'mcz_port')"
export DEVICE_NAME="$(bashio::config 'device_name')"
export TOPIC_PREFIX="${PREFIX}"

bashio::log.info "Stufa: ${MCZip}:${MCZport} - MQTT: ${MQTT_ip}:${MQTT_port} - topic: ${PREFIX}/"

python3 -u /app/discovery.py &

if bashio::config.true 'wifi_watchdog'; then
    /wifi_watchdog.sh &
fi

cd /tmp
exec python3 -u /app/maestro.py
