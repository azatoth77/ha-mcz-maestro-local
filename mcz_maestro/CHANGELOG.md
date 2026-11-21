# Changelog

## 1.5.3
- Watchdog: canale e segnale Wi-Fi della stufa pubblicati come sensori; log dei cambi di
  canale e delle disconnessioni/riconnessioni con durata.

## 1.4.x
- Selettore **Modalità** (Manuale, Dynamic, Overnight, Comfort, Power), mappatura
  verificata con l'app ufficiale.
- Mappatura ventole corretta (Fan_State / DuctedFan1 / DuctedFan2).

## 1.3.0
- Stato come sensore *enum*; ore di funzionamento in ore numeriche (anche per livello di
  potenza); sensori diagnostici Profilo / Modalità controllo / Active.

## 1.1.0 – 1.2.x
- Watchdog Wi-Fi via D-Bus per sbloccare NetworkManager (`no-secrets`).
- Ripubblicazione degli stati dopo la discovery.

## 1.0.0
- Prima versione: maestrogateway + MQTT discovery (termostato, ventole, potenza,
  interruttori, sensori).
