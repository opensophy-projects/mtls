#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${HOME}/.mtls-manager.conf"
DB_FILE="${HOME}/.mtls-manager.db"
SERVICES_FILE="${HOME}/.mtls-manager.services"

TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"
CA_PATH="/etc/traefik/certs/mtls"
CLIENTS_PATH="/etc/traefik/certs/mtls/clients"
OUTPUT_FILE="mtls-manager.yml"
CERT_DAYS=365

load_config(){
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS='=' read -r k v; do
    v="${v//\"/}"
    case "$k" in
      TRAEFIK_DYNAMIC_PATH) TRAEFIK_DYNAMIC_PATH="$v";;
      CA_PATH) CA_PATH="$v";;
      CLIENTS_PATH) CLIENTS_PATH="$v";;
      OUTPUT_FILE) OUTPUT_FILE="$v";;
      CERT_DAYS) CERT_DAYS="$v";;
    esac
  done < "$CONFIG_FILE"
}
save_config(){ cat > "$CONFIG_FILE" <<EOC
TRAEFIK_DYNAMIC_PATH="$TRAEFIK_DYNAMIC_PATH"
CA_PATH="$CA_PATH"
CLIENTS_PATH="$CLIENTS_PATH"
OUTPUT_FILE="$OUTPUT_FILE"
CERT_DAYS="$CERT_DAYS"
EOC
chmod 600 "$CONFIG_FILE"; }
