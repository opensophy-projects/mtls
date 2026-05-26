#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/commands/mtls/config.sh"
source "$ROOT_DIR/commands/mtls/db.sh"
source "$ROOT_DIR/commands/mtls/docker.sh"

show_menu(){
  local ca="✖"; [ -f "$CA_PATH/ca.crt" ] && ca="✔"
  header "🔐 mTLS Certificate Manager (os mtls)"
  echo "$TRAEFIK_DYNAMIC_PATH"
  echo "CA $ca   services: $(svc_count)   certificates: $(db_count)"
  hr
  echo "1) Manage services"
  echo "2) 🐳 Docker"
  echo "3) Path settings"
  echo "0) Exit"
}

manage_services(){
  while true; do
    header "Services"
    svc_list
    hr
    echo "1) Add/update service"
    echo "0) Back"
    c=$(ask "> " "0")
    case "$c" in
      1)
        n=$(ask "Service name: ")
        d=$(ask "Domain: ")
        t=$(ask "Target URL: " "http://localhost:3000")
        m=$(ask "Mode (new|patch): " "new")
        svc_add "$n" "$d" "$t" "$m"
        ok "Saved"
        pause
      ;;
      0) return;;
    esac
  done
}

settings_menu(){
  header "Path settings"
  TRAEFIK_DYNAMIC_PATH=$(ask "TRAEFIK_DYNAMIC_PATH: " "$TRAEFIK_DYNAMIC_PATH")
  CA_PATH=$(ask "CA_PATH: " "$CA_PATH")
  CLIENTS_PATH=$(ask "CLIENTS_PATH: " "$CLIENTS_PATH")
  OUTPUT_FILE=$(ask "OUTPUT_FILE: " "$OUTPUT_FILE")
  CERT_DAYS=$(ask "CERT_DAYS: " "$CERT_DAYS")
  save_config
  ok "Config saved"
  pause
}

main(){
  load_config; db_init
  while true; do
    show_menu
    c=$(ask "> " "0")
    case "$c" in
      1) manage_services;;
      2) docker_menu;;
      3) settings_menu;;
      0) exit 0;;
    esac
  done
}
main "$@"
