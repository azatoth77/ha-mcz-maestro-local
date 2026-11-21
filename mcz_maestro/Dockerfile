# SPDX-License-Identifier: GPL-3.0-or-later
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

RUN apk add --no-cache python3 py3-pip networkmanager-cli mosquitto-clients \
 && pip3 install --break-system-packages --no-cache-dir \
      paho-mqtt==1.6.1 \
      websocket-client==1.8.0

COPY app /app
COPY run.sh /run.sh
COPY wifi_watchdog.sh /wifi_watchdog.sh
RUN chmod a+x /run.sh /wifi_watchdog.sh

WORKDIR /tmp
CMD [ "/run.sh" ]
