#!/usr/bin/env bash
set -euo pipefail

docker_labels_table(){
  if ! command -v docker >/dev/null 2>&1; then warn "docker CLI not found"; return 1; fi
  docker ps --format '{{.Names}}|{{.ID}}' | while IFS='|' read -r n id; do
    labels=$(docker inspect "$id" --format '{{json .Config.Labels}}' 2>/dev/null || true)
    echo "$labels" | python3 - "$n" <<'PY'
import json,sys
name=sys.argv[1]
raw=sys.stdin.read().strip()
if not raw or raw=='null': raise SystemExit
l=json.loads(raw)
if l.get('mtls.enable')!='true': raise SystemExit
print(f"{name}|{l.get('mtls.service','')}|{l.get('mtls.domain','')}|{l.get('mtls.router','')}")
PY
  done
}

docker_sync_services(){
  local rows; rows="$(docker_labels_table || true)"
  [ -n "$rows" ] || { warn "No containers with mtls.enable=true"; return; }
  while IFS='|' read -r _ service domain _; do
    [ -n "$service" ] || continue
    svc_add "$service" "$domain" "http://localhost:3000" "new"
  done <<< "$rows"
  ok "Docker labels synced to services"
}

docker_menu(){
  while true; do
    header "🐳 Docker mTLS labels"
    echo "Container | Service | Domain | Router"
    hr
    docker_labels_table || true
    hr
    echo "1) Sync labels -> services"
    echo "0) Back"
    c=$(ask "> " "0")
    case "$c" in
      1) docker_sync_services; pause;;
      0) return;;
    esac
  done
}
