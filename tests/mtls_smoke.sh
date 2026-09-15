#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/mtls.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_mtls() {
  sudo -n env HOME="$TMP/home" \
    MTLS_CONFIG_FILE="$TMP/state.conf" \
    MTLS_DB_FILE="$TMP/state.db" \
    MTLS_SERVICES_FILE="$TMP/services" \
    MTLS_AUDIT_FILE="$TMP/audit.jsonl" \
    MTLS_PRESETS_FILE="$TMP/presets.json" \
    bash "$SCRIPT" "$@"
}

mkdir -p "$TMP/home" "$TMP/traefik" "$TMP/ca" "$TMP/clients"
run_mtls help >/dev/null
run_mtls config set TRAEFIK_DYNAMIC_PATH "$TMP/traefik" >/dev/null
run_mtls config set CA_PATH "$TMP/ca" >/dev/null
run_mtls config set CLIENTS_PATH "$TMP/clients" >/dev/null
run_mtls ca create --cn ci-test-ca --days 30 >/dev/null
run_mtls preset save --name ci --traefik-path "$TMP/traefik" --ca-path "$TMP/ca" --clients-path "$TMP/clients" --output-file ci.yml >/dev/null
run_mtls preset list | grep -q '^ci '
run_mtls preset apply --name ci >/dev/null
run_mtls gen >/dev/null

# Static security invariants: no notification/network path and no shell eval.
! grep -Eq 'WEBHOOK_URL|send_notification|NOTIFY_EXPIRY_DAYS|curl |wget |eval ' "$SCRIPT"
grep -q 'safe_replace' "$SCRIPT"
grep -q 'require_root' "$SCRIPT"
grep -q 'passout file:' "$SCRIPT"

# State files and generated output must not be group/world-readable.
for file in "$TMP/state.conf" "$TMP/state.db" "$TMP/services" "$TMP/audit.jsonl" "$TMP/presets.json"; do
  test -f "$file"
  test "$(stat -c '%a' "$file")" = 600
done

echo "mtls smoke/security tests passed"
