#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
export RED GREEN YELLOW BLUE CYAN BOLD DIM RESET

CONFIG_FILE="${MTLS_CONFIG_FILE:-${HOME}/.mtls-manager.conf}"
DB_FILE="${MTLS_DB_FILE:-${HOME}/.mtls-manager.db}"
SERVICES_FILE="${MTLS_SERVICES_FILE:-${HOME}/.mtls-manager.services}"
AUDIT_FILE="${MTLS_AUDIT_FILE:-${HOME}/.mtls-manager.audit.jsonl}"
PRESETS_FILE="${MTLS_PRESETS_FILE:-${HOME}/.mtls-manager.presets}"
LOCK_FILE="${DB_FILE}.lock"

TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"
CA_PATH="/etc/traefik/certs/mtls"
CLIENTS_PATH="/etc/traefik/certs/mtls/clients"
OUTPUT_FILE="mtls-manager.yml"
CERT_DAYS=365
EXPIRY_WARN_DAYS=30
CA_KEY_ENCRYPTED=0
BUNDLE_MODE="shared"   # shared | per-service

REQUIRE_P12_PASSWORD=1

AUDIT_MAX_BYTES=10485760   # 10 MiB

MTLS_NONINTERACTIVE=0

MTLS_RUNTIME_DIR=""

hr()      { echo -e "  ${DIM}──────────────────────────────────────────────────${RESET}"; }
info()    { echo -e "  ${CYAN}i${RESET}  $*" >&2; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $*" >&2; }
warn()    { echo -e "  ${YELLOW}!${RESET}  $*" >&2; }
err()     { echo -e "  ${RED}✖${RESET}  $*" >&2; }
section() { echo -e "  ${BOLD}$*${RESET}" >&2; hr >&2; echo "" >&2; }

cli_ok()   { [ -t 1 ] && echo -e "  ${GREEN}✔${RESET}  $*" || echo "[OK] $*"; }
cli_info() { [ -t 1 ] && echo -e "  ${CYAN}i${RESET}  $*" || echo "[INFO] $*"; }
cli_warn() { [ -t 1 ] && echo -e "  ${YELLOW}!${RESET}  $*" || echo "[WARN] $*"; }
cli_err()  { [ -t 1 ] && echo -e "  ${RED}✖${RESET}  $*" || echo "[ERR] $*"; }

ask() {
    local prompt="$1" default="${2:-}" result
    if [ "$MTLS_NONINTERACTIVE" = "1" ]; then echo "$default"; return; fi
    if [ -n "$default" ]; then
        printf "  %s [%s]: " "$prompt" "$default" >/dev/tty
    else
        printf "  %s: " "$prompt" >/dev/tty
    fi
    read -r result </dev/tty
    [ -z "$result" ] && echo "$default" || echo "$result"
}

ask_secret() {
    local prompt="$1" result
    if [ "$MTLS_NONINTERACTIVE" = "1" ]; then echo "${MTLS_P12_PASSWORD:-}"; return; fi
    printf "  %s: " "$prompt" >/dev/tty
    read -rs result </dev/tty
    echo "" >/dev/tty
    echo "$result"
}

ask_yn() {
    local prompt="$1" result
    if [ "$MTLS_NONINTERACTIVE" = "1" ]; then return 0; fi
    printf "  %s [y/N]: " "$prompt" >/dev/tty
    read -r result </dev/tty
    case "${result:-n}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pause() {
    [ "$MTLS_NONINTERACTIVE" = "1" ] && return
    echo ""
    printf "  ${DIM}Press Enter to continue...${RESET}" >/dev/tty
    read -r _ </dev/tty
}

menu_choice() {
    printf "\n  Choice: " >/dev/tty
    read -r MENU_CHOICE </dev/tty
    echo "$MENU_CHOICE"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo ""
        echo -e "  ${RED}✖${RESET}  This script must be run as root only."
        echo -e "  ${DIM}It handles CA and client private keys — access is restricted on purpose.${RESET}"
        echo ""
        exit 1
    fi
}

mtls_runtime_dir() {
    if [ -z "$MTLS_RUNTIME_DIR" ] || [ ! -d "$MTLS_RUNTIME_DIR" ]; then
        MTLS_RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mtls-manager.XXXXXX")
        chmod 700 "$MTLS_RUNTIME_DIR"
    fi
    echo "$MTLS_RUNTIME_DIR"
}

mtls_cleanup_runtime() {
    if [ -n "$MTLS_RUNTIME_DIR" ] && [ -d "$MTLS_RUNTIME_DIR" ]; then
        rm -rf "$MTLS_RUNTIME_DIR"
    fi
}
trap mtls_cleanup_runtime EXIT INT TERM

write_passphrase_file() {
    local pass="$1"
    local dir; dir=$(mtls_runtime_dir)
    local f; f=$(mktemp "${dir}/pass.XXXXXX")
    chmod 600 "$f"
    printf '%s' "$pass" > "$f"
    echo "$f"
}

forget_passphrase_file() {
    local f="$1"
    [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    local key val
    while IFS='=' read -r key val; do
        val="${val//\"/}"
        case "$key" in
            TRAEFIK_DYNAMIC_PATH)   TRAEFIK_DYNAMIC_PATH="$val" ;;
            CA_PATH)                CA_PATH="$val" ;;
            CLIENTS_PATH)           CLIENTS_PATH="$val" ;;
            OUTPUT_FILE)            OUTPUT_FILE="$val" ;;
            CERT_DAYS)              CERT_DAYS="$val" ;;
            EXPIRY_WARN_DAYS)       EXPIRY_WARN_DAYS="$val" ;;
            CA_KEY_ENCRYPTED)       CA_KEY_ENCRYPTED="$val" ;;
            BUNDLE_MODE)            BUNDLE_MODE="$val" ;;
            REQUIRE_P12_PASSWORD)   REQUIRE_P12_PASSWORD="$val" ;;
            AUDIT_MAX_BYTES)        AUDIT_MAX_BYTES="$val" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    cat > "$tmp" <<EOF
TRAEFIK_DYNAMIC_PATH="$TRAEFIK_DYNAMIC_PATH"
CA_PATH="$CA_PATH"
CLIENTS_PATH="$CLIENTS_PATH"
OUTPUT_FILE="$OUTPUT_FILE"
CERT_DAYS="$CERT_DAYS"
EXPIRY_WARN_DAYS="$EXPIRY_WARN_DAYS"
CA_KEY_ENCRYPTED="$CA_KEY_ENCRYPTED"
BUNDLE_MODE="$BUNDLE_MODE"
REQUIRE_P12_PASSWORD="$REQUIRE_P12_PASSWORD"
AUDIT_MAX_BYTES="$AUDIT_MAX_BYTES"
EOF
    safe_replace "$tmp" "$CONFIG_FILE" 600
}

db_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -x -w 10 9; then
        err "Could not acquire the DB lock — another instance may be running."
        return 1
    fi
}

db_unlock() { flock -u 9 2>/dev/null || true; }


audit_rotate() {
    [ "${AUDIT_MAX_BYTES:-0}" = "0" ] && return 0
    [ -f "$AUDIT_FILE" ] || return 0
    local size
    size=$(wc -c < "$AUDIT_FILE" 2>/dev/null || echo 0)
    [ "$size" -le "$AUDIT_MAX_BYTES" ] 2>/dev/null && return 0

    local rotated="${AUDIT_FILE}.1.gz"
    local tmp_gz; tmp_gz=$(mktemp "${AUDIT_FILE}.rotate.XXXXXX")
    if gzip -c "$AUDIT_FILE" > "$tmp_gz" 2>/dev/null; then
        chmod 600 "$tmp_gz" 2>/dev/null || true
        mv -f "$tmp_gz" "$rotated"
        : > "$AUDIT_FILE"
        chmod 600 "$AUDIT_FILE" 2>/dev/null || true
    else
        rm -f "$tmp_gz"
    fi
}

audit_log() {
    local action="$1" detail="${2:-}"
    audit_rotate
    local ts actor
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    actor="${SUDO_USER:-${USER:-unknown}}"
    python3 -c "
import json, sys
ts, action, actor, detail = sys.argv[1:5]
entry = {'ts': ts, 'action': action, 'actor': actor}
if detail: entry['detail'] = detail
print(json.dumps(entry, ensure_ascii=False))
" "$ts" "$action" "$actor" "$detail" >> "$AUDIT_FILE" 2>/dev/null || true
}

db_init() {
    [ -f "$DB_FILE" ]       || { echo '{}' > "$DB_FILE";  chmod 600 "$DB_FILE"; }
    [ -f "$SERVICES_FILE" ] || { echo '[]' > "$SERVICES_FILE"; chmod 600 "$SERVICES_FILE"; }
    [ -f "$AUDIT_FILE" ]    || { touch "$AUDIT_FILE"; chmod 600 "$AUDIT_FILE"; }
    [ -f "$PRESETS_FILE" ]  || { echo '{}' > "$PRESETS_FILE"; chmod 600 "$PRESETS_FILE"; }
}

check_path_access() {
    local test_path="${1:-$CA_PATH}"
    local probe_dir="$test_path"

    if [ ! -d "$probe_dir" ]; then
        probe_dir="$test_path"
        while [ "$probe_dir" != "/" ] && [ ! -d "$probe_dir" ]; do
            probe_dir="$(dirname "$probe_dir")"
        done
        [ "$probe_dir" = "" ] && probe_dir="/"
    fi

    local made_dir=0
    if [ ! -d "$test_path" ]; then
        if ! mkdir -p "$test_path" 2>/dev/null; then
            echo ""
            echo -e "  ${RED}✖${RESET}  No permission to create: ${test_path}"
            echo -e "  ${DIM}Parent directory is not writable: ${probe_dir}${RESET}"
            echo ""
            return 1
        fi
        made_dir=1
    fi

    local probe_file
    probe_file="${test_path}/.mtls-write-probe.$$"
    if ! ( : > "$probe_file" ) 2>/dev/null; then
        echo ""
        echo -e "  ${RED}✖${RESET}  No write permission for: ${test_path}"
        echo -e "  ${DIM}The path exists but is not writable even for root (possibly a read-only mount, immutable flag, SELinux/AppArmor or NFS root_squash).${RESET}"
        echo ""
        [ "$made_dir" = "1" ] && rmdir "$test_path" 2>/dev/null
        return 1
    fi
    rm -f "$probe_file" 2>/dev/null
    return 0
}

check_all_paths() {
    local failed=0
    for p in "$CA_PATH" "$CLIENTS_PATH" "$TRAEFIK_DYNAMIC_PATH"; do
        if ! check_path_access "$p" >/dev/null 2>&1; then
            failed=1
        fi
    done
    [ "$failed" -eq 1 ] && return 1
    return 0
}

show_permission_error() {
    local path="$1"
    echo ""
    echo -e "  ${RED}✖${RESET}  Access denied: ${path}"
    echo -e "  ${DIM}The path is not writable even as root — check the mount and filesystem permissions.${RESET}"
    echo ""
}

safe_replace() {
    local tmp="$1" dest="$2" mode="${3:-600}"
    if [ -L "$dest" ]; then
        err "Refused: ${dest} is a symlink — write aborted for security reasons."
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest"
}

db_write_many() {
    local name="$1"; shift
    local tmp; tmp=$(mktemp "${DB_FILE}.XXXXXX")
    local pairs_json
    pairs_json=$(python3 -c "
import json, sys
pairs = {}
for arg in sys.argv[1:]:
    k, _, v = arg.partition('=')
    pairs[k] = v
print(json.dumps(pairs))
" "$@")
    python3 - "$DB_FILE" "$name" "$pairs_json" "$tmp" << 'PYEOF'
import sys, json
db_path, name, pairs_json, out = sys.argv[1:]
with open(db_path) as f:
    db = json.load(f)
if name not in db:
    db[name] = {}
db[name].update(json.loads(pairs_json))
with open(out, 'w') as f:
    json.dump(db, f, indent=2, ensure_ascii=False)
PYEOF
    safe_replace "$tmp" "$DB_FILE" 600
}

db_write() {
    local name="$1" field="$2" value="$3"
    db_write_many "$name" "${field}=${value}"
}

db_read() {
    local name="$1" field="$2"
    python3 - "$DB_FILE" "$name" "$field" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    db = json.load(f)
print(db.get(sys.argv[2], {}).get(sys.argv[3], ''), end='')
PYEOF
}

db_delete() {
    local name="$1"
    local tmp; tmp=$(mktemp "${DB_FILE}.XXXXXX")
    python3 - "$DB_FILE" "$name" "$tmp" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    db = json.load(f)
db.pop(sys.argv[2], None)
with open(sys.argv[3], 'w') as f:
    json.dump(db, f, indent=2, ensure_ascii=False)
PYEOF
    safe_replace "$tmp" "$DB_FILE" 600
}

db_list_names() {
    python3 - "$DB_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    db = json.load(f)
for k in db:
    if not k.startswith('__'):
        print(k)
PYEOF
}

db_count() {
    python3 - "$DB_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    db = json.load(f)
print(len([k for k in db if not k.startswith('__')]))
PYEOF
}

db_all_json() {
    python3 - "$DB_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    db = json.load(f)
clients = {k:v for k,v in db.items() if not k.startswith('__')}
print(json.dumps(clients, indent=2, ensure_ascii=False))
PYEOF
}

svc_list_names() {
    python3 - "$SERVICES_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    svcs = json.load(f)
for s in svcs:
    print(s['name'])
PYEOF
}

svc_count() {
    python3 - "$SERVICES_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    svcs = json.load(f)
print(len(svcs))
PYEOF
}

svc_get() {
    local name="$1" field="$2"
    python3 - "$SERVICES_FILE" "$name" "$field" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    svcs = json.load(f)
for s in svcs:
    if s['name'] == sys.argv[2]:
        print(s.get(sys.argv[3], ''), end='')
        break
PYEOF
}

validate_domain() {
    local value="$1"
    [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || {
        cli_err "Invalid domain: $value"; return 1;
    }
}

validate_target() {
    local value="$1"
    [[ "$value" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~:/?#\[\]@!\$&()*+,;=%-]*)?$ ]] || {
        cli_err "Invalid upstream URL"; return 1;
    }
}

validate_patch_path() {
    local path="$1" current="$1"
    [ -n "$path" ] && [ -f "$path" ] && [ ! -L "$path" ] || {
        cli_err "Patch file must be a regular file: $path"; return 1;
    }
    while [ "$current" != "/" ] && [ -n "$current" ]; do
        [ ! -L "$current" ] || { cli_err "Patch path contains a symlink: $current"; return 1; }
        current="$(dirname -- "$current")"
    done
}

svc_add() {
    local name="$1" domain="$2" target="$3" mode="${4:-new}" patch_file="${5:-}" patch_router="${6:-}"
    validate_name "Service name" "$name" || return 1
    validate_domain "$domain" || return 1
    validate_target "$target" || return 1
    [ -z "$patch_file" ] || validate_patch_path "$patch_file" || return 1
    local tmp; tmp=$(mktemp "${SERVICES_FILE}.XXXXXX")
    python3 - "$SERVICES_FILE" "$name" "$domain" "$target" "$mode" "$patch_file" "$patch_router" "$tmp" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    svcs = json.load(f)
for s in svcs:
    if s['name'] == sys.argv[2]:
        s['domain'] = sys.argv[3]
        s['target'] = sys.argv[4]
        s['mode'] = sys.argv[5]
        s['patch_file'] = sys.argv[6]
        s['patch_router'] = sys.argv[7]
        with open(sys.argv[8], 'w') as f:
            json.dump(svcs, f, indent=2)
        sys.exit(0)
svcs.append({
    'name': sys.argv[2], 'domain': sys.argv[3], 'target': sys.argv[4],
    'mode': sys.argv[5], 'patch_file': sys.argv[6], 'patch_router': sys.argv[7],
})
with open(sys.argv[8], 'w') as f:
    json.dump(svcs, f, indent=2)
PYEOF
    safe_replace "$tmp" "$SERVICES_FILE" 600
}

svc_delete() {
    local name="$1"
    local tmp; tmp=$(mktemp "${SERVICES_FILE}.XXXXXX")
    python3 - "$SERVICES_FILE" "$name" "$tmp" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    svcs = json.load(f)
svcs = [s for s in svcs if s['name'] != sys.argv[2]]
with open(sys.argv[3], 'w') as f:
    json.dump(svcs, f, indent=2)
PYEOF
    safe_replace "$tmp" "$SERVICES_FILE" 600
}

preset_list_names() {
    python3 - "$PRESETS_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    p = json.load(f)
for k in p:
    print(k)
PYEOF
}

preset_get() {
    local name="$1" field="$2"
    python3 - "$PRESETS_FILE" "$name" "$field" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    p = json.load(f)
print(p.get(sys.argv[2], {}).get(sys.argv[3], ''), end='')
PYEOF
}

preset_save() {
    local name="$1" traefik_path="$2" ca_path="$3" clients_path="$4" output_file="$5"
    local tmp; tmp=$(mktemp "${PRESETS_FILE}.XXXXXX")
    python3 - "$PRESETS_FILE" "$name" "$traefik_path" "$ca_path" "$clients_path" "$output_file" "$tmp" << 'PYEOF'
import sys, json
db_path, name, tp, cap, clp, of, out = sys.argv[1:]
with open(db_path) as f:
    p = json.load(f)
p[name] = {
    'traefik_dynamic_path': tp,
    'ca_path': cap,
    'clients_path': clp,
    'output_file': of,
}
with open(out, 'w') as f:
    json.dump(p, f, indent=2, ensure_ascii=False)
PYEOF
    safe_replace "$tmp" "$PRESETS_FILE" 600
}

preset_delete() {
    local name="$1"
    local tmp; tmp=$(mktemp "${PRESETS_FILE}.XXXXXX")
    python3 - "$PRESETS_FILE" "$name" "$tmp" << 'PYEOF'
import sys, json
db_path, name, out = sys.argv[1:]
with open(db_path) as f:
    p = json.load(f)
p.pop(name, None)
with open(out, 'w') as f:
    json.dump(p, f, indent=2, ensure_ascii=False)
PYEOF
    safe_replace "$tmp" "$PRESETS_FILE" 600
}

preset_apply() {
    local name="$1"
    local tp cap clp of
    tp=$(preset_get "$name" "traefik_dynamic_path")
    cap=$(preset_get "$name" "ca_path")
    clp=$(preset_get "$name" "clients_path")
    of=$(preset_get "$name" "output_file")
    if [ -z "$tp" ] && [ -z "$cap" ] && [ -z "$clp" ]; then
        return 1
    fi
    TRAEFIK_DYNAMIC_PATH="$tp"
    CA_PATH="$cap"
    CLIENTS_PATH="$clp"
    [ -n "$of" ] && OUTPUT_FILE="$of"
    save_config
    return 0
}

run_openssl() {
    local stderr_capture rc
    stderr_capture=$(mktemp)
    set +e
    "$@" 2>"$stderr_capture"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        err "openssl command failed (code $rc):"
        head -5 "$stderr_capture" >&2
        rm -f "$stderr_capture"
        return $rc
    fi
    rm -f "$stderr_capture"
    return 0
}


int_ca_dir() { echo "${CA_PATH}/intermediates/${1}"; }
int_ca_crt() { echo "$(int_ca_dir "$1")/int-ca.crt"; }
int_ca_key() { echo "$(int_ca_dir "$1")/int-ca.key"; }

create_int_ca() {
    local uid="$1" cert_name="$2" service="$3"
    local dir; dir=$(int_ca_dir "$uid")
    [ -d "$dir" ] && rm -rf "$dir"
    mkdir -p "$dir"; chmod 700 "$dir"

    run_openssl openssl genrsa -out "$(int_ca_key "$uid")" 2048
    chmod 600 "$(int_ca_key "$uid")"

    run_openssl openssl req -new -key "$(int_ca_key "$uid")" \
        -out "${dir}/int-ca.csr" \
        -subj "/CN=${cert_name}-Client-CA/O=${service}/OU=mTLS-Manager/C=US"

    gen_ca_cnf

    local ext_file; ext_file=$(mktemp "${dir}/ext.XXXXXX")
    cat > "$ext_file" <<EOF
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

    local rc=0
    if [ "$CA_KEY_ENCRYPTED" = "1" ]; then
        local passfile; passfile=$(write_passphrase_file "${MTLS_CA_PASSPHRASE:-}")
        run_openssl openssl x509 -req -days "${CERT_DAYS}" \
            -in "${dir}/int-ca.csr" \
            -CA "${CA_PATH}/ca.crt" -CAkey "${CA_PATH}/ca.key" \
            -CAcreateserial -passin "file:${passfile}" \
            -out "$(int_ca_crt "$uid")" \
            -extfile "$ext_file" || rc=$?
        forget_passphrase_file "$passfile"
    else
        run_openssl openssl x509 -req -days "${CERT_DAYS}" \
            -in "${dir}/int-ca.csr" \
            -CA "${CA_PATH}/ca.crt" -CAkey "${CA_PATH}/ca.key" \
            -CAcreateserial \
            -out "$(int_ca_crt "$uid")" \
            -extfile "$ext_file" || rc=$?
    fi
    rm -f "$ext_file"

    if [ "$rc" -ne 0 ] || [ ! -s "$(int_ca_crt "$uid")" ]; then
        err "Failed to sign the intermediate CA."
        rm -rf "$dir"
        return 1
    fi

    chmod 644 "$(int_ca_crt "$uid")"
    rm -f "${dir}/int-ca.csr" "${dir}/int-ca.srl"
    db_write "$uid" "int_ca_path" "$dir"
}

sign_client_with_int_ca() {
    local uid="$1" cert_dir="$2" days="$3"
    local ext_file; ext_file=$(mktemp "${cert_dir}/ext.XXXXXX")
    cat > "$ext_file" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
    local rc=0
    run_openssl openssl x509 -req \
        -in "${cert_dir}/client.csr" \
        -CA "$(int_ca_crt "$uid")" \
        -CAkey "$(int_ca_key "$uid")" \
        -CAcreateserial \
        -out "${cert_dir}/client.crt" \
        -days "${days}" \
        -extfile "$ext_file" || rc=$?
    rm -f "$ext_file"
    return $rc
}

verify_chain() {
    local cert_dir="$1" uid="$2"
    local int_crt; int_crt=$(int_ca_crt "$uid")
    local ca_crt="${CA_PATH}/ca.crt"

    if [ ! -f "${cert_dir}/client.crt" ] || [ ! -f "$int_crt" ] || [ ! -f "$ca_crt" ]; then
        err "Chain verification: files are missing"
        return 1
    fi
    local chain_tmp; chain_tmp=$(mktemp)
    cat "$int_crt" "$ca_crt" > "$chain_tmp"
    if ! openssl verify -CAfile "$chain_tmp" "${cert_dir}/client.crt" >/dev/null 2>&1; then
        rm -f "$chain_tmp"
        err "Chain verification FAILED for ${cert_dir}/client.crt"
        return 1
    fi
    rm -f "$chain_tmp"
    return 0
}

bundle_file() {
    if [ "$BUNDLE_MODE" = "per-service" ] && [ -n "${1:-}" ]; then
        echo "${CA_PATH}/clients-bundle-${1}.crt"
    else
        echo "${CA_PATH}/clients-bundle.crt"
    fi
}

rebuild_bundle() {
    local uid="" names; names=$(db_list_names)
    local count=0

    if [ "$BUNDLE_MODE" = "per-service" ]; then
        local services_done="" uid=""
        if [ -n "$names" ]; then
            while IFS= read -r uid; do
                [ -z "$uid" ] && continue
                local svc; svc=$(db_read "$uid" "service")
                [ -z "$svc" ] && continue
                case "$services_done" in *"$svc"*) continue ;; esac
                services_done="${services_done} ${svc}"
                _rebuild_bundle_for_service "$svc" "$names"
            done <<< "$names"
        fi
    else
        local bundle; bundle=$(bundle_file)
        local tmp; tmp=$(mktemp "${CA_PATH}/bundle.XXXXXX")
        if [ -n "$names" ]; then
            while IFS= read -r uid; do
                [ -z "$uid" ] && continue
                local revoked; revoked=$(db_read "$uid" "revoked")
                [ "$revoked" = "1" ] && continue
                local int_crt; int_crt=$(int_ca_crt "$uid")
                if [ -f "$int_crt" ]; then
                    cat "$int_crt" >> "$tmp"
                    echo "" >> "$tmp"
                    count=$((count + 1))
                fi
            done <<< "$names"
        fi
        [ "$count" -eq 0 ] && cat "${CA_PATH}/ca.crt" > "$tmp"
        safe_replace "$tmp" "$bundle" 644
        touch "$bundle"
    fi
}

_rebuild_bundle_for_service() {
    local svc="$1" names="$2"
    local bundle; bundle=$(bundle_file "$svc")
    local tmp; tmp=$(mktemp "${CA_PATH}/bundle.XXXXXX")
    local count=0 uid=""
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        local uid_svc; uid_svc=$(db_read "$uid" "service")
        [ "$uid_svc" != "$svc" ] && continue
        local revoked; revoked=$(db_read "$uid" "revoked")
        [ "$revoked" = "1" ] && continue
        local int_crt; int_crt=$(int_ca_crt "$uid")
        if [ -f "$int_crt" ]; then
            cat "$int_crt" >> "$tmp"
            echo "" >> "$tmp"
            count=$((count + 1))
        fi
    done <<< "$names"
    [ "$count" -eq 0 ] && cat "${CA_PATH}/ca.crt" > "$tmp"
    safe_replace "$tmp" "$bundle" 644
    touch "$bundle"
}

ca_index()  { echo "${CA_PATH}/index.txt"; }
ca_serial() { echo "${CA_PATH}/serial"; }
ca_crl()    { echo "${CA_PATH}/crl.pem"; }
ca_cnf()    { echo "${CA_PATH}/openssl-ca.cnf"; }

ca_db_init() {
    local idx; idx=$(ca_index)
    local ser; ser=$(ca_serial)
    [ -f "$idx" ] || touch "$idx"
    [ -f "$ser" ] || echo "01" > "$ser"
    [ -f "${CA_PATH}/index.txt.attr" ] || echo "unique_subject = no" > "${CA_PATH}/index.txt.attr"
}

gen_ca_cnf() {
    cat > "$(ca_cnf)" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${CA_PATH}
database          = \$dir/index.txt
new_certs_dir     = \$dir
serial            = \$dir/serial
RANDFILE          = \$dir/.rand
certificate       = \$dir/ca.crt
private_key       = \$dir/ca.key
default_md        = sha256
default_days      = ${CERT_DAYS}
default_crl_days  = 3650
preserve          = no
policy            = policy_loose
copy_extensions   = none

[ policy_loose ]
countryName            = optional
stateOrProvinceName    = optional
localityName           = optional
organizationName       = optional
commonName             = supplied
emailAddress           = optional

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256

[ req_distinguished_name ]

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ client_cert ]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF
}

rebuild_crl() {
    gen_ca_cnf; ca_db_init
    local rc=0
    if [ "$CA_KEY_ENCRYPTED" = "1" ]; then
        local passfile; passfile=$(write_passphrase_file "${MTLS_CA_PASSPHRASE:-}")
        run_openssl openssl ca -config "$(ca_cnf)" -gencrl \
            -passin "file:${passfile}" -out "$(ca_crl)" || rc=$?
        forget_passphrase_file "$passfile"
    else
        run_openssl openssl ca -config "$(ca_cnf)" -gencrl -out "$(ca_crl)" || rc=$?
    fi
    [ "$rc" -ne 0 ] && { err "Failed to regenerate the CRL (crl.pem) — this does not affect actual revocation via Traefik: it uses the caFiles bundle, not the CRL. crl.pem is only needed by external consumers."; return 1; }
    chmod 644 "$(ca_crl)"
}

ca_exists() { [ -f "${CA_PATH}/ca.crt" ] && [ -f "${CA_PATH}/ca.key" ]; }

ca_key_prompt_passphrase() {
    if [ "$CA_KEY_ENCRYPTED" = "1" ] && [ -z "${MTLS_CA_PASSPHRASE:-}" ]; then
        info "The CA key is encrypted — enter the passphrase:"
        local pass; pass=$(ask_secret "Passphrase")
        MTLS_CA_PASSPHRASE="$pass"
    fi
}

detect_host_ip() {
    local ip=""
    ip="${MTLS_HOST_IP:-}"
    [ -z "$ip" ] && ip=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    [ -z "$ip" ] && ip=$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    [ -z "$ip" ] && ip=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -1)
    [ -z "$ip" ] && ip="172.17.0.1"
    echo "$ip"
}

validate_yaml() {
    local file="$1"
    [ -f "$file" ] || { err "YAML file not found: $file"; return 1; }
    python3 - "$file" << 'PYEOF'
import sys
try:
    with open(sys.argv[1]) as f:
        lines = f.readlines()
    has_tls = False
    has_http = False
    for line in lines:
        s = line.strip()
        if s.startswith('tls:'): has_tls = True
        if s.startswith('http:'): has_http = True
        if '\t' in line:
            print(f"YAML validation: tab found in line: {line.rstrip()}", file=sys.stderr)
            sys.exit(1)
    if not has_tls:
        print("YAML validation: missing 'tls:' section", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
except Exception as e:
    print(f"YAML validation error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

_patch_validate_and_commit() {
    local orig="$1" tmp_result="$2"
    python3 - "$orig" "$tmp_result" << 'PYEOF'
import sys
orig, tmp = sys.argv[1:]

def keys_top_level(text):
    keys = set()
    for line in text.split('\n'):
        if line and not line[0].isspace() and ':' in line and not line.lstrip().startswith('#'):
            keys.add(line.split(':', 1)[0].strip())
    return keys

with open(orig) as f:
    orig_text = f.read()
with open(tmp) as f:
    new_text = f.read()

if '\t' in new_text:
    print('invalid: tab character present'); sys.exit(1)

try:
    import yaml
    yaml.safe_load(new_text)
except ImportError:
    if keys_top_level(orig_text) != keys_top_level(new_text):
        print('invalid: top-level structure changed (no PyYAML available to fully verify)')
        sys.exit(1)
except Exception as e:
    print(f'invalid: does not parse as YAML: {e}')
    sys.exit(1)

print('valid')
PYEOF
}

patch_apply() {
    local svc="$1" patch_file="$2" router_name="$3"
    validate_name "Service name" "$svc" || return 1
    validate_patch_path "$patch_file" || return 1
    local tls_opt="mtls-${svc}"
    local tmp_result; tmp_result=$(mktemp "${patch_file}.patchtmp.XXXXXX")

    local py_status
    py_status=$(python3 - "$patch_file" "$router_name" "$tls_opt" "$tmp_result" << 'PYEOF'
import sys
path, router, tls_opt, out_path = sys.argv[1:]
with open(path) as f:
    content = f.read()
if f'options: {tls_opt}' in content:
    print('already_patched'); sys.exit(0)
lines = content.split('\n')
out = []; i = 0
router_indent = None; in_router = False; tls_indent = None; in_tls = False; patched = False
while i < len(lines):
    line = lines[i]; stripped = line.lstrip(); indent = len(line) - len(stripped)
    if stripped.rstrip(':') == router and not in_router:
        router_indent = indent; in_router = True; in_tls = False; tls_indent = None
        out.append(line); i += 1; continue
    if in_router:
        if stripped and indent <= router_indent:
            in_router = False; in_tls = False
        elif stripped == 'tls:' and not in_tls:
            tls_indent = indent; in_tls = True; out.append(line); i += 1
            while i < len(lines):
                tline = lines[i]; tstripped = tline.lstrip(); tindent = len(tline) - len(tstripped)
                if tstripped and tindent <= tls_indent:
                    if not patched:
                        out.append(' ' * (tls_indent + 2) + f'options: {tls_opt}'); patched = True
                    break
                if tstripped.startswith('options:'):
                    out.append(' ' * tindent + f'options: {tls_opt}'); patched = True; i += 1; continue
                out.append(tline); i += 1
            continue
    out.append(line); i += 1
if patched:
    with open(out_path, 'w') as f:
        f.write('\n'.join(out))
    print('patched')
else:
    print('not_found')
PYEOF
)
    case "$py_status" in
        already_patched|not_found)
            rm -f "$tmp_result"
            echo "$py_status"
            return 0
            ;;
        patched)
            local validation; validation=$(_patch_validate_and_commit "$patch_file" "$tmp_result")
            if [ "$validation" != "valid" ]; then
                err "Patch rejected — the result failed validation: ${validation}"
                err "The original file was not modified: ${patch_file}"
                rm -f "$tmp_result"
                echo "invalid_result"
                return 1
            fi
            cp -p "$patch_file" "${patch_file}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
            safe_replace "$tmp_result" "$patch_file" 644
            echo "patched"
            return 0
            ;;
        *)
            rm -f "$tmp_result"
            echo "invalid_result"
            return 1
            ;;
    esac
}

patch_remove() {
    local svc="$1" patch_file="$2" router_name="$3"
    validate_name "Service name" "$svc" || return 1
    validate_patch_path "$patch_file" || return 1
    local tls_opt="mtls-${svc}"
    local tmp_result; tmp_result=$(mktemp "${patch_file}.patchtmp.XXXXXX")

    local py_status
    py_status=$(python3 - "$patch_file" "$router_name" "$tls_opt" "$tmp_result" << 'PYEOF'
import sys
path, router, tls_opt, out_path = sys.argv[1:]
with open(path) as f:
    content = f.read()
if f'options: {tls_opt}' not in content:
    print('not_found'); sys.exit(0)
lines = content.split('\n')
out = [line for line in lines if f'options: {tls_opt}' not in line]
with open(out_path, 'w') as f:
    f.write('\n'.join(out))
print('removed')
PYEOF
)
    case "$py_status" in
        not_found)
            rm -f "$tmp_result"
            return 0
            ;;
        removed)
            local validation; validation=$(_patch_validate_and_commit "$patch_file" "$tmp_result")
            if [ "$validation" != "valid" ]; then
                err "Patch removal rejected — the result failed validation: ${validation}"
                err "The original file was not modified: ${patch_file}"
                rm -f "$tmp_result"
                return 1
            fi
            cp -p "$patch_file" "${patch_file}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
            safe_replace "$tmp_result" "$patch_file" 644
            echo "removed"
            return 0
            ;;
        *)
            rm -f "$tmp_result"
            return 1
            ;;
    esac
}

do_gen_traefik() {
    local out="${TRAEFIK_DYNAMIC_PATH}/${OUTPUT_FILE}"
    if ! check_path_access "$TRAEFIK_DYNAMIC_PATH" 2>/dev/null; then
        show_permission_error "$TRAEFIK_DYNAMIC_PATH"
        return 1
    fi
    mkdir -p "$TRAEFIK_DYNAMIC_PATH"
    if [ ! -f "${CA_PATH}/ca.crt" ]; then
        warn "CA not found — Traefik config was not updated."; return 1
    fi
    rebuild_bundle
    local host_ip; host_ip=$(detect_host_ip)
    local svc=""
    local svc_names; svc_names=$(svc_list_names)
    local has_new_svc=0
    if [ -n "$svc_names" ]; then
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            local mode; mode=$(svc_get "$svc" "mode")
            [ "$mode" = "new" ] && has_new_svc=1
        done <<< "$svc_names"
    fi
    local gen_tmp; gen_tmp=$(mktemp "${out}.XXXXXX")
    {
        echo "# Generated by mtls-manager — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# DO NOT EDIT MANUALLY"
        echo ""
        echo "tls:"
        echo "  options:"
        local printed_any=0
        if [ -n "$svc_names" ]; then
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                local bundle
                if [ "$BUNDLE_MODE" = "per-service" ]; then
                    bundle=$(bundle_file "$svc")
                else
                    bundle=$(bundle_file)
                fi
                echo "    mtls-${svc}:"
                echo "      clientAuth:"
                echo "        caFiles:"
                echo "          - \"${bundle}\""
                echo "        clientAuthType: RequireAndVerifyClientCert"
                echo "      minVersion: VersionTLS12"
                printed_any=1
            done <<< "$svc_names"
        fi
        if [ "$printed_any" -eq 0 ]; then
            echo "    mtls-placeholder:"
            echo "      minVersion: VersionTLS12"
        fi
        if [ "$has_new_svc" -eq 1 ]; then
            echo ""; echo "http:"; echo "  routers:"
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                local mode; mode=$(svc_get "$svc" "mode")
                [ "$mode" != "new" ] && continue
                local domain; domain=$(svc_get "$svc" "domain")
                validate_domain "$domain" || { err "Service $svc has an invalid domain; YAML was not created."; return 1; }
                echo "    ${svc}-mtls:"
                echo "      rule: \"Host(\`${domain}\`)\""
                echo "      entryPoints:"
                echo "        - websecure"
                echo "      service: ${svc}-mtls"
                echo "      tls:"
                echo "        options: mtls-${svc}"
            done <<< "$svc_names"
            echo ""; echo "  services:"
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                local mode; mode=$(svc_get "$svc" "mode")
                [ "$mode" != "new" ] && continue
                local target; target=$(svc_get "$svc" "target")
                validate_target "$target" || { err "Service $svc has an invalid upstream; YAML was not created."; return 1; }
                target="${target//localhost/${host_ip}}"
                target="${target//127.0.0.1/${host_ip}}"
                echo "    ${svc}-mtls:"
                echo "      loadBalancer:"
                echo "        servers:"
                echo "          - url: \"${target}\""
            done <<< "$svc_names"
        fi
    } > "$gen_tmp"
    safe_replace "$gen_tmp" "$out" 644
    touch "$out"

    if ! validate_yaml "$out"; then
        warn "The generated YAML may have structural problems — check: $out"
    fi

    ok "Traefik config: ${out}"
    local active_count=0
    local all_names; all_names=$(db_list_names)
    if [ -n "$all_names" ]; then
        active_count=$(while IFS= read -r _uid; do
            [ -z "$_uid" ] && continue
            local r; r=$(db_read "$_uid" "revoked")
            [ "$r" != "1" ] && echo "$_uid"
        done <<< "$all_names" | wc -l)
    fi
    info "Bundle: ${active_count} intermediate CAs (mode: ${BUNDLE_MODE})"
}

do_backup() {
    local dest="${1:-${HOME}/mtls-backup-$(date '+%Y%m%d-%H%M%S').tar.gz}"
    local tmp_list; tmp_list=$(mktemp)
    {
        echo "$CONFIG_FILE"
        echo "$DB_FILE"
        echo "$SERVICES_FILE"
        echo "$AUDIT_FILE"
        [ -f "${AUDIT_FILE}.1.gz" ] && echo "${AUDIT_FILE}.1.gz"
        echo "$PRESETS_FILE"
        [ -f "$CA_PATH/ca.crt" ] && find "$CA_PATH" -type f 2>/dev/null
    } > "$tmp_list"
    if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
        rm -f "$tmp_list"
        err "Invalid backup path: $dest"
        return 1
    fi
    local tmp_dest; tmp_dest=$(mktemp "${dest}.XXXXXX")
    if ! tar czf "$tmp_dest" -T "$tmp_list" 2>/dev/null; then
        rm -f "$tmp_list" "$tmp_dest"
        return 1
    fi
    rm -f "$tmp_list"
    chmod 600 "$tmp_dest"
    safe_replace "$tmp_dest" "$dest" 600
    ok "Backup created: $dest"
    audit_log "backup" "$dest"
}

do_restore() {
    local src="$1"
    [ -f "$src" ] || { err "Backup file not found: $src"; return 1; }
    warn "This will overwrite the CA, database and config. Continue?"
    ask_yn "Restore from $src?" || { info "Cancelled."; return 0; }
    local tmp_dir; tmp_dir=$(mktemp -d)
    if ! python3 - "$src" "$tmp_dir" <<'PYEOF'
import os, sys, tarfile
src, dest = sys.argv[1:]
root = os.path.realpath(dest) + os.sep
with tarfile.open(src, "r:gz") as archive:
    for member in archive.getmembers():
        name = member.name
        target = os.path.realpath(os.path.join(dest, name))
        if not target.startswith(root) or member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise SystemExit("unsafe backup member: " + name)
    archive.extractall(dest)
PYEOF
    then
        rm -rf -- "$tmp_dir"
        err "Unsafe backup rejected."
        return 1
    fi
    for destination in "$CONFIG_FILE" "$DB_FILE" "$SERVICES_FILE" "$AUDIT_FILE" "$PRESETS_FILE" "${AUDIT_FILE}.1.gz"; do
        [ -L "$destination" ] && { rm -rf -- "$tmp_dir"; err "Restore rejected: symlink $destination"; return 1; }
    done
    [ -f "${tmp_dir}${CONFIG_FILE}" ] && safe_replace "${tmp_dir}${CONFIG_FILE}" "$CONFIG_FILE" 600
    [ -f "${tmp_dir}${DB_FILE}" ] && safe_replace "${tmp_dir}${DB_FILE}" "$DB_FILE" 600
    [ -f "${tmp_dir}${SERVICES_FILE}" ] && safe_replace "${tmp_dir}${SERVICES_FILE}" "$SERVICES_FILE" 600
    [ -f "${tmp_dir}${AUDIT_FILE}" ] && safe_replace "${tmp_dir}${AUDIT_FILE}" "$AUDIT_FILE" 600
    [ -f "${tmp_dir}${AUDIT_FILE}.1.gz" ] && safe_replace "${tmp_dir}${AUDIT_FILE}.1.gz" "${AUDIT_FILE}.1.gz" 600
    [ -f "${tmp_dir}${PRESETS_FILE}" ] && safe_replace "${tmp_dir}${PRESETS_FILE}" "$PRESETS_FILE" 600
    if [ -d "${tmp_dir}${CA_PATH}" ]; then
        mkdir -p -- "$CA_PATH"
        cp -r -- "${tmp_dir}${CA_PATH}/." "$CA_PATH/"
    fi
    rm -rf "$tmp_dir"
    load_config
    ok "Restored from: $src"
    audit_log "restore" "$src"
}

cert_status() {
    local uid="$1"
    local revoked; revoked=$(db_read "$uid" "revoked")
    [ "$revoked" = "1" ] && echo "REVOKED" && return
    local expires; expires=$(db_read "$uid" "expires")
    if [ -z "$expires" ]; then
        echo "UNKNOWN"; return
    fi
    local today exp
    today=$(date +%s 2>/dev/null) || { echo "UNKNOWN"; return; }
    if exp=$(date -d "$expires" +%s 2>/dev/null); then
        :
    elif exp=$(date -j -f "%Y-%m-%d" "$expires" +%s 2>/dev/null); then
        :
    else
        echo "UNKNOWN"; return
    fi
    local diff=$(( (exp - today) / 86400 ))
    if   [ "$diff" -lt 0  ]; then echo "EXPIRED"
    elif [ "$diff" -le "${EXPIRY_WARN_DAYS:-30}" ]; then echo "SOON (${diff}d)"
    else                          echo "ACTIVE"
    fi
}

cert_status_color() {
    case "$1" in
        ACTIVE)    echo "$GREEN" ;;
        REVOKED)   echo "$RED" ;;
        EXPIRED)   echo "$RED" ;;
        UNKNOWN)   echo "$RED" ;;
        *)         echo "$YELLOW" ;;
    esac
}

print_cert_table() {
    local names="$1"
    [ -z "$names" ] && return
    printf "  ${BOLD}%-4s %-20s %-14s %-11s %-11s %-16s %-20s${RESET}\n" "#" "Name" "Service" "Created" "Expires" "Status" "Note"
    hr
    local i=1 uid=""
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        local cname csvc ccreated cexp cnote status col
        cname=$(db_read "$uid" "name"); csvc=$(db_read "$uid" "service")
        ccreated=$(db_read "$uid" "created"); cexp=$(db_read "$uid" "expires"); cnote=$(db_read "$uid" "note")
        status=$(cert_status "$uid"); col=$(cert_status_color "$status")
        printf "  ${CYAN}%-4s${RESET} %-20s %-14s %-11s %-11s ${col}%-16s${RESET} %-20s\n" \
            "$i" "${cname:0:20}" "${csvc:0:14}" "${ccreated:0:10}" "${cexp:0:10}" "$status" "${cnote:0:20}"
        i=$((i + 1))
    done <<< "$names"
    hr
}

check_deps() {
    local need_openssl=0 need_python=0
    command -v openssl >/dev/null 2>&1 || need_openssl=1
    command -v python3 >/dev/null 2>&1 || need_python=1
    [ "$need_openssl" -eq 0 ] && [ "$need_python" -eq 0 ] && return 0

    [ "$MTLS_NONINTERACTIVE" = "1" ] && {
        [ "$need_openssl" -eq 1 ] && cli_err "openssl not found"
        [ "$need_python"  -eq 1 ] && cli_err "python3 not found"
        exit 1
    }

    header
    section "Dependency check"
    [ "$need_openssl" -eq 1 ] && warn "openssl not found"
    [ "$need_python"  -eq 1 ] && warn "python3 not found"
    echo ""
    ask_yn "Install automatically?" || { err "openssl and python3 are required."; exit 1; }
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        [ "$need_openssl" -eq 1 ] && apt-get install -y openssl
        [ "$need_python"  -eq 1 ] && apt-get install -y python3
    elif command -v yum >/dev/null 2>&1; then
        [ "$need_openssl" -eq 1 ] && yum install -y openssl
        [ "$need_python"  -eq 1 ] && yum install -y python3
    elif command -v apk >/dev/null 2>&1; then
        [ "$need_openssl" -eq 1 ] && apk add --no-cache openssl
        [ "$need_python"  -eq 1 ] && apk add --no-cache python3
    elif command -v brew >/dev/null 2>&1; then
        [ "$need_openssl" -eq 1 ] && brew install openssl
        [ "$need_python"  -eq 1 ] && brew install python3
    else
        err "Could not detect a package manager. Please install manually."
        exit 1
    fi
    ok "Done."
}

validate_output_file() {
    local value="$1"
    if [ -z "$value" ] || [ "${#value}" -gt 128 ] || [[ "$value" == -* ]] || [[ "$value" == *"/"* ]] || [[ "$value" == *".."* ]] || ! [[ "$value" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]]; then
        cli_err "OUTPUT_FILE must be a basename with a .yml or .yaml extension."
        return 1
    fi
}

validate_name() {
    local field_label="$1" value="$2"
    if [ -z "$value" ]; then
        cli_err "${field_label} must not be empty."
        return 1
    fi
    if [ ${#value} -gt 128 ]; then
        cli_err "${field_label} is too long (max 128 characters): ${value}"
        return 1
    fi
    case "$value" in
        -*)
            cli_err "${field_label} must not start with '-': ${value}"
            return 1
            ;;
    esac
    case "$value" in
        *__*)
            cli_err "${field_label} must not contain '__' (used as an internal separator): ${value}"
            return 1
            ;;
    esac
    if [[ "$value" == *".."* ]] || [[ "$value" == *"/"* ]]; then
        cli_err "${field_label} must not contain '/' or '..': ${value}"
        return 1
    fi
    if ! [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        cli_err "${field_label} may only contain Latin letters, digits, '.', '_' and '-': ${value}"
        return 1
    fi
    return 0
}

core_create_ca() {
    local cn="${1:-mTLS-Root-CA}" days="${2:-3650}" encrypt="${3:-0}"
    if ca_exists; then
        warn "CA already exists: ${CA_PATH}/ca.crt"
        warn "Recreating the CA invalidates ALL issued certificates!"
        ask_yn "Recreate the CA?" || return 1
    fi

    if ! check_path_access "$CA_PATH"; then return 1; fi
    if ! check_path_access "$TRAEFIK_DYNAMIC_PATH"; then return 1; fi

    mkdir -p "$CA_PATH" "${CA_PATH}/intermediates" 2>/dev/null || true
    chmod 700 "$CA_PATH" 2>/dev/null || true

    info "Generating CA key (4096 bits)..."
    local rc=0
    if [ "$encrypt" = "1" ]; then
        CA_KEY_ENCRYPTED=1
        if [ -z "${MTLS_CA_PASSPHRASE:-}" ]; then
            local pass; pass=$(ask_secret "CA key passphrase")
            MTLS_CA_PASSPHRASE="$pass"
        fi
        local passfile; passfile=$(write_passphrase_file "$MTLS_CA_PASSPHRASE")
        run_openssl openssl genrsa -aes256 -out "${CA_PATH}/ca.key" -passout "file:${passfile}" 4096 || rc=$?
        forget_passphrase_file "$passfile"
    else
        run_openssl openssl genrsa -out "${CA_PATH}/ca.key" 4096 || rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ ! -s "${CA_PATH}/ca.key" ]; then
        err "Failed to generate the CA key."
        return 1
    fi
    chmod 600 "${CA_PATH}/ca.key"

    info "Generating CA certificate..."
    rc=0
    if [ "$encrypt" = "1" ]; then
        local passfile2; passfile2=$(write_passphrase_file "$MTLS_CA_PASSPHRASE")
        run_openssl openssl req -new -x509 -days "$days" \
            -key "${CA_PATH}/ca.key" -passin "file:${passfile2}" \
            -out "${CA_PATH}/ca.crt" \
            -subj "/CN=${cn}/O=mTLS-Manager/C=US" || rc=$?
        forget_passphrase_file "$passfile2"
        MTLS_CA_PASSPHRASE=""
        unset MTLS_CA_PASSPHRASE
    else
        run_openssl openssl req -new -x509 -days "$days" -key "${CA_PATH}/ca.key" -out "${CA_PATH}/ca.crt" \
            -subj "/CN=${cn}/O=mTLS-Manager/C=US" || rc=$?
    fi
    if [ "$rc" -ne 0 ] || [ ! -s "${CA_PATH}/ca.crt" ]; then
        err "Failed to generate the CA certificate."
        rm -f "${CA_PATH}/ca.key"
        return 1
    fi

    info "Initializing the CA database..."
    rm -f "${CA_PATH}/index.txt" "${CA_PATH}/index.txt.attr" "${CA_PATH}/serial"
    ca_db_init
    if ! rebuild_crl; then
        warn "Could not build the CRL (crl.pem) right after creating the CA — you can retry later. This does not affect the CA or certificate issuance; the CRL is only used by external consumers, not Traefik."
    fi

    db_write_many "__ca__" "cn=${cn}" "days=${days}" "created=$(date '+%Y-%m-%d %H:%M:%S')"
    save_config

    echo ""
    ok "CA created!"
    echo -e "    ${DIM}Key  : ${CA_PATH}/ca.key${RESET}"
    echo -e "    ${DIM}Cert : ${CA_PATH}/ca.crt${RESET}"
    audit_log "ca_create" "cn=${cn} days=${days} encrypted=${encrypt}"
    do_gen_traefik
}

core_issue_cert() {
    local service="$1" cert_name="$2" days="${3:-$CERT_DAYS}" note="${4:-}" p12_pass="${5:-}"

    validate_name "Service name" "$service" || return 1
    validate_name "Certificate name" "$cert_name" || return 1

    local uid="${service}__${cert_name}"
    local existing; existing=$(db_read "$uid" "created")
    local ex_rev; ex_rev=$(db_read "$uid" "revoked")
    local is_recreate=0

    if [ -n "$existing" ] && [ "$ex_rev" != "1" ]; then
        warn "Certificate '${cert_name}' for '${service}' already exists."
        ask_yn "Recreate it?" || return 1
        is_recreate=1
    fi

    if [ -z "$p12_pass" ] && [ "$REQUIRE_P12_PASSWORD" = "1" ]; then
        if [ "$MTLS_NONINTERACTIVE" = "1" ]; then
            cli_err "A .p12 password is required (pass --pass or MTLS_P12_PASSWORD), or set REQUIRE_P12_PASSWORD=0 in the config if you really need a .p12 without a password."
            return 1
        fi
        warn "A .p12 without a password protects the client private key WORSE than one with a password."
        if ask_yn "Continue WITHOUT a .p12 password?"; then
            p12_pass=""
        else
            info "Enter a password for the .p12:"
            local pass1 pass2
            pass1=$(ask_secret "Password"); pass2=$(ask_secret "Repeat password")
            if [ "$pass1" != "$pass2" ] || [ -z "$pass1" ]; then
                err "Passwords do not match or are empty — cancelled."
                return 1
            fi
            p12_pass="$pass1"
        fi
    fi

    if ! check_path_access "$CLIENTS_PATH"; then
        return 1
    fi
    if ! check_path_access "$CA_PATH"; then
        return 1
    fi

    local cert_dir="${CLIENTS_PATH}/${service}/${cert_name}"
    local staging_dir="${cert_dir}.new.$$"
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"; chmod 700 "$staging_dir" 2>/dev/null || true

    info "Generating key (2048 bits)..."
    if ! run_openssl openssl genrsa -out "${staging_dir}/client.key" 2048; then
        rm -rf "$staging_dir"; return 1
    fi
    chmod 600 "${staging_dir}/client.key"

    info "Creating CSR..."
    if ! run_openssl openssl req -new -key "${staging_dir}/client.key" -out "${staging_dir}/client.csr" \
        -subj "/CN=${cert_name}/O=${service}/C=US"; then
        rm -rf "$staging_dir"; return 1
    fi

    info "Creating intermediate CA for ${cert_name}..."
    local staging_uid="${uid}__staging_$$"
    if ! create_int_ca "$staging_uid" "$cert_name" "$service"; then
        rm -rf "$staging_dir"
        rm -rf "$(int_ca_dir "$staging_uid")"
        return 1
    fi

    info "Signing the client certificate..."
    if ! sign_client_with_int_ca "$staging_uid" "$staging_dir" "$days" || [ ! -s "${staging_dir}/client.crt" ]; then
        err "Signing failed!"
        rm -rf "$staging_dir"
        rm -rf "$(int_ca_dir "$staging_uid")"
        return 1
    fi

    if ! verify_chain "$staging_dir" "$staging_uid"; then
        err "Certificate chain verification failed — cancelled, no files were saved."
        rm -rf "$staging_dir"
        rm -rf "$(int_ca_dir "$staging_uid")"
        return 1
    fi
    ok "Chain verified."

    info "Creating .p12..."
    local p12passfile; p12passfile=$(write_passphrase_file "$p12_pass")
    run_openssl openssl pkcs12 -export -out "${staging_dir}/client.p12" \
        -inkey "${staging_dir}/client.key" -in "${staging_dir}/client.crt" \
        -certfile "${CA_PATH}/ca.crt" -passout "file:${p12passfile}"
    forget_passphrase_file "$p12passfile"
    if [ ! -s "${staging_dir}/client.p12" ]; then
        err "Failed to create the .p12 — cancelled, no files were saved."
        rm -rf "$staging_dir"
        rm -rf "$(int_ca_dir "$staging_uid")"
        return 1
    fi
    rm -f "${staging_dir}/client.csr"

    if [ "$is_recreate" = "1" ]; then
        db_write "$uid" "revoked" "1"
        rebuild_bundle
        [ -d "$cert_dir" ] && rm -rf "$cert_dir"
        [ -d "$(int_ca_dir "$uid")" ] && rm -rf "$(int_ca_dir "$uid")"
    fi

    mkdir -p "$(dirname "$cert_dir")"
    mv "$staging_dir" "$cert_dir"
    mv "$(int_ca_dir "$staging_uid")" "$(int_ca_dir "$uid")"
    db_delete "$staging_uid" 2>/dev/null || true

    if ! rebuild_crl; then
        warn "Could not regenerate the CRL (crl.pem) after issuing the certificate — this does not affect the certificate itself or the Traefik bundle."
    fi

    local serial expiry
    serial=$(openssl x509 -serial -noout -in "${cert_dir}/client.crt" 2>/dev/null | cut -d= -f2)
    expiry=$(openssl x509 -enddate -noout -in "${cert_dir}/client.crt" 2>/dev/null | cut -d= -f2)
    expiry=$(date -d "$expiry" '+%Y-%m-%d' 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" '+%Y-%m-%d' 2>/dev/null || echo "$expiry")

    local note_val="${note}"; [ -z "$note_val" ] && note_val="—"

    db_write_many "$uid" \
        "name=${cert_name}" \
        "service=${service}" \
        "days=${days}" \
        "note=${note_val}" \
        "created=$(date '+%Y-%m-%d')" \
        "expires=${expiry}" \
        "revoked=0" \
        "path=${cert_dir}" \
        "int_ca_path=$(int_ca_dir "$uid")" \
        "serial=${serial}"

    info "Updating the bundle and Traefik config..."
    do_gen_traefik >/dev/null 2>&1 || true

    local svc_mode; svc_mode=$(svc_get "$service" "mode")
    if [ "$svc_mode" = "patch" ]; then
        local pfile; pfile=$(svc_get "$service" "patch_file")
        local prouter; prouter=$(svc_get "$service" "patch_router")
        info "Applying patch to ${pfile} (router: ${prouter})..."
        local result; result=$(patch_apply "$service" "$pfile" "$prouter")
        case "$result" in
            patched)         ok "Patch applied." ;;
            already_patched) info "Patch was already applied." ;;
            not_found)       warn "Router '${prouter}' not found in the file." ;;
            invalid_result)  err "Patch NOT applied — the result failed YAML structure validation. File ${pfile} was not modified." ;;
        esac
    fi

    echo ""
    ok "Certificate created!"
    hr
    echo -e "  ${DIM}${cert_dir}/client.p12${RESET}"
    echo -e "  Serial no.   : $serial"
    echo -e "  Valid until  : $expiry"
    echo -e "  Note         : $note_val"
    [ -n "$p12_pass" ] && echo -e "  P12 password : ${GREEN}set${RESET}" || echo -e "  P12 password : ${RED}NOT set (knowingly confirmed)${RESET}"

    audit_log "cert_create" "uid=${uid} service=${service} expires=${expiry} p12_password_set=$([ -n "$p12_pass" ] && echo 1 || echo 0)"
    return 0
}

core_revoke_cert() {
    local uid="$1"
    local crevoked; crevoked=$(db_read "$uid" "revoked")
    if [ "$crevoked" = "1" ]; then
        warn "Certificate is already revoked."
        return 1
    fi
    db_write "$uid" "revoked" "1"
    rebuild_bundle
    do_gen_traefik >/dev/null 2>&1 || true
    local cname; cname=$(db_read "$uid" "name")
    ok "Certificate '${cname}' revoked."
    audit_log "cert_revoke" "uid=${uid}"
}

core_delete_cert() {
    local uid="$1"
    local crevoked; crevoked=$(db_read "$uid" "revoked")
    if [ "$crevoked" != "1" ]; then
        warn "The certificate is not revoked yet — revoking first."
        core_revoke_cert "$uid" || true
    fi
    local cpath cint_dir cname
    cpath=$(db_read "$uid" "path")
    cint_dir=$(db_read "$uid" "int_ca_path")
    cname=$(db_read "$uid" "name")

    if [ -n "$cpath" ] && [ -d "$cpath" ]; then
        rm -rf "$cpath"
        ok "Certificate files removed: ${cpath}"
    fi
    local int_dir_to_remove=""
    if [ -n "$cint_dir" ] && [ -d "$cint_dir" ]; then
        int_dir_to_remove="$cint_dir"
    else
        local fallback="${CA_PATH}/intermediates/${uid}"
        [ -d "$fallback" ] && int_dir_to_remove="$fallback"
    fi
    if [ -n "$int_dir_to_remove" ]; then
        rm -rf "$int_dir_to_remove"
        ok "Intermediate CA removed: ${int_dir_to_remove}"
    fi
    db_delete "$uid"
    ok "Record removed from the database."
    audit_log "cert_delete" "uid=${uid} name=${cname}"
}

core_delete_service_full() {
    local svc="$1"
    [ -z "$svc" ] && { err "Service name is required."; return 1; }
    validate_name "Service name" "$svc" || return 1

    local svc_mode; svc_mode=$(svc_get "$svc" "mode")
    local deleted_certs=0 uid=""
    local all_names; all_names=$(db_list_names)

    if [ -n "$all_names" ]; then
        while IFS= read -r uid; do
            [ -z "$uid" ] && continue
            local uid_svc; uid_svc=$(db_read "$uid" "service")
            [ "$uid_svc" != "$svc" ] && continue
            local crevoked; crevoked=$(db_read "$uid" "revoked")
            [ "$crevoked" != "1" ] && core_revoke_cert "$uid" >/dev/null 2>&1 || true
            core_delete_cert "$uid" >/dev/null 2>&1 || true
            deleted_certs=$((deleted_certs + 1))
        done <<< "$all_names"
    fi
    [ "$deleted_certs" -gt 0 ] && ok "Deleted ${deleted_certs} certificate(s) for '${svc}'."

    if [ "$svc_mode" = "patch" ]; then
        local dpf dpr
        dpf=$(svc_get "$svc" "patch_file")
        dpr=$(svc_get "$svc" "patch_router")
        if [ -n "$dpf" ] && [ -f "$dpf" ]; then
            info "Removing patch from ${dpf} (router: ${dpr})..."
            patch_remove "$svc" "$dpf" "$dpr"
            ok "Patch removed from ${dpf##*/}."
        fi
    fi

    local svc_dir="${CLIENTS_PATH}/${svc}"
    if [ -d "$svc_dir" ]; then
        rm -rf "$svc_dir"
        ok "Client directory removed: ${svc_dir}"
    fi

    local int_base="${CA_PATH}/intermediates"
    if [ -d "$int_base" ]; then
        local orphaned=0
        while IFS= read -r -d '' int_dir; do
            local base; base=$(basename "$int_dir")
            case "$base" in
                "${svc}__"*) rm -rf "$int_dir"; orphaned=$((orphaned + 1)) ;;
            esac
        done < <(find "$int_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
        [ "$orphaned" -gt 0 ] && ok "Removed ${orphaned} orphaned intermediate CA directories."
    fi

    svc_delete "$svc"
    do_gen_traefik >/dev/null 2>&1 || true

    ok "Service '${svc}' fully removed."
    audit_log "service_delete_full" "name=${svc} certs=${deleted_certs} mode=${svc_mode}"
    return 0
}

core_renew_cert() {
    local uid="$1" days="${2:-$CERT_DAYS}" p12_pass="${3:-}"
    local cname csvc note
    cname=$(db_read "$uid" "name")
    csvc=$(db_read "$uid" "service")
    note=$(db_read "$uid" "note")
    [ -z "$cname" ] && { err "Certificate not found: $uid"; return 1; }

    info "Renewing '${cname}' for service '${csvc}' (${days} days)..."
    [ -z "$p12_pass" ] && p12_pass="${MTLS_P12_PASSWORD:-}"
    core_issue_cert "$csvc" "$cname" "$days" "$note" "$p12_pass"
    audit_log "cert_renew" "uid=${uid} days=${days}"
}

core_scan_expiry() {
    local names; names=$(db_list_names)
    [ -z "$names" ] && { info "No certificates to scan."; return 0; }
    local expiring="" expired="" unknown="" uid=""
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        local revoked; revoked=$(db_read "$uid" "revoked")
        [ "$revoked" = "1" ] && continue
        local status; status=$(cert_status "$uid")
        local cname csvc cexp
        cname=$(db_read "$uid" "name"); csvc=$(db_read "$uid" "service"); cexp=$(db_read "$uid" "expires")
        case "$status" in
            EXPIRED)
                expired="${expired}- ${cname} (${csvc}) expired ${cexp}\n"
                ;;
            SOON*)
                expiring="${expiring}- ${cname} (${csvc}) expires ${cexp}\n"
                ;;
            UNKNOWN)
                unknown="${unknown}- ${cname} (${csvc}) expiry date not recognized: '${cexp}'\n"
                ;;
        esac
    done <<< "$names"

    if [ -n "$expiring" ] || [ -n "$expired" ] || [ -n "$unknown" ]; then
        if [ -n "$expired" ]; then
            cli_warn "EXPIRED certificates:"
            echo -ne "$expired" >&2
        fi
        if [ -n "$expiring" ]; then
            cli_warn "Certificates expiring within ${EXPIRY_WARN_DAYS} days:"
            echo -ne "$expiring" >&2
        fi
        if [ -n "$unknown" ]; then
            cli_warn "Certificates with an unrecognized expiry date (need manual review):"
            echo -ne "$unknown" >&2
        fi
        audit_log "scan_expiry" "expired=$(echo -ne "$expired" | wc -l) expiring=$(echo -ne "$expiring" | wc -l) unknown=$(echo -ne "$unknown" | wc -l)"
        return 1
    else
        ok "All certificates are fine."
        return 0
    fi
}

core_verify_cert() {
    local uid="$1"
    local cpath; cpath=$(db_read "$uid" "path")
    local cname; cname=$(db_read "$uid" "name")
    [ -z "$cpath" ] && { err "Certificate not found: $uid"; return 1; }
    local cert_file="${cpath}/client.crt"
    [ -f "$cert_file" ] || { err "Certificate file is missing: $cert_file"; return 1; }

    echo -e "  ${BOLD}Certificate:${RESET} ${cname}"
    echo -e "  ${BOLD}Serial no.:${RESET}  $(openssl x509 -serial -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
    echo -e "  ${BOLD}Subject:${RESET}     $(openssl x509 -subject -noout -in "$cert_file" 2>/dev/null | sed 's/subject=//')"
    echo -e "  ${BOLD}Issuer:${RESET}      $(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | sed 's/issuer=//')"
    echo -e "  ${BOLD}Valid from:${RESET}  $(openssl x509 -startdate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
    echo -e "  ${BOLD}Valid until:${RESET} $(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"

    local int_crt; int_crt=$(int_ca_crt "$uid")
    local chain_tmp; chain_tmp=$(mktemp)
    cat "$int_crt" "${CA_PATH}/ca.crt" > "$chain_tmp"
    if openssl verify -CAfile "$chain_tmp" "$cert_file" >/dev/null 2>&1; then
        ok "Chain verification: PASSED"
    else
        err "Chain verification: FAILED"
    fi
    rm -f "$chain_tmp"
    echo ""
    echo -e "  ${BOLD}Fingerprint (SHA-256):${RESET}"
    openssl x509 -fingerprint -sha256 -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 | tr -d ' '
}

header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}${BLUE}mTLS Certificate Manager${RESET} ${DIM}v2.4${RESET}  ${DIM}(root)${RESET}"
    echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"
    echo ""
}

menu_cert_create() {
    header; section "Create a new certificate"
    ensure_ca || return
    local svc_names; svc_names=$(svc_list_names)
    if [ -z "$svc_names" ]; then warn "No services. Add a service first (item 4)."; pause; return; fi
    echo -e "  ${BOLD}Available services:${RESET}"; echo ""
    local i=1 svc_arr=()
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        local smode; smode=$(svc_get "$s" "mode")
        local label=""; [ "$smode" = "patch" ] && label="${DIM} [patch]${RESET}"
        echo -e "    ${CYAN}${i})${RESET}  $s${label}"
        svc_arr+=("$s"); i=$((i + 1))
    done <<< "$svc_names"; echo ""
    local svc_idx; svc_idx=$(ask "Choose a service (number)" "1")
    local service="${svc_arr[$((svc_idx - 1))]}"; if [ -z "$service" ]; then err "Invalid number."; pause; return; fi
    echo ""
    local cert_name; cert_name=$(ask "Certificate name (Latin letters, no spaces)" "")
    cert_name="${cert_name// /-}"
    if ! validate_name "Certificate name" "$cert_name"; then pause; return; fi
    local days note
    days=$(ask "Validity (days)" "$CERT_DAYS")
    note=$(ask "Note (who/what it's for)" "")
    echo ""; echo -e "  ${BOLD}Password for the .p12:${RESET}"
    local pass1 pass2 p12_pass=""
    if ask_yn "Set a password for the .p12 (recommended)?"; then
        pass1=$(ask_secret "Enter password")
        pass2=$(ask_secret "Repeat password")
        if [ "$pass1" != "$pass2" ] || [ -z "$pass1" ]; then err "Passwords do not match or are empty."; pause; return; fi
        p12_pass="$pass1"
    else
        warn "A .p12 without a password protects the client private key worse."
        ask_yn "Really continue without a password?" || { info "Cancelled."; pause; return; }
    fi
    core_issue_cert "$service" "$cert_name" "$days" "$note" "$p12_pass"
    pause
}

menu_cert_delete() {
    header; section "Revoke and delete a certificate"
    local names; names=$(db_list_names)
    if [ -z "$names" ]; then warn "No certificates."; pause; return; fi
    print_cert_table "$names"; echo ""

    local cert_arr=() uid=""
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        cert_arr+=("$uid")
    done <<< "$names"

    echo -e "  ${BOLD}0)${RESET}  Back"; echo ""
    local choice; choice=$(ask "Choose a certificate number" "")
    [ "$choice" = "0" ] || [ -z "$choice" ] && return

    local idx=$(( choice - 1 ))
    local uid="${cert_arr[$idx]}"
    if [ -z "$uid" ]; then err "Invalid number."; pause; return; fi

    local cname csvc crevoked
    cname=$(db_read "$uid" "name")
    csvc=$(db_read "$uid" "service")
    crevoked=$(db_read "$uid" "revoked")

    echo ""
    echo -e "  ${BOLD}Selected:${RESET} ${cname:-<unknown>}  ${DIM}(service: ${csvc:-<unknown>})${RESET}"
    echo ""

    if [ "$crevoked" != "1" ]; then
        warn "The certificate will be REVOKED (access will be blocked)."
        warn "Come back here again to DELETE the files from disk."
        echo ""
        ask_yn "Revoke certificate '${cname}'?" || { pause; return; }
        core_revoke_cert "$uid"
        ok "Certificate revoked. Come back again to delete the files."
    else
        warn "The certificate is already revoked. The files will be deleted from disk."
        echo ""
        ask_yn "Delete files of '${cname}' from disk? (irreversible)" || { ok "Files kept."; pause; return; }
        core_delete_cert "$uid"
    fi
    pause
}

menu_cert_list() {
    header; section "Certificate list"
    local names; names=$(db_list_names)
    if [ -z "$names" ]; then warn "No certificates."; pause; return; fi
    print_cert_table "$names"
    local total; total=$(db_count)
    echo ""; echo -e "  ${DIM}Total: $total${RESET}"; echo ""
    if ca_exists; then
        local ca_cn ca_created
        ca_cn=$(db_read "__ca__" "cn"); ca_created=$(db_read "__ca__" "created")
        echo -e "  ${DIM}CA     : $ca_cn  (created: $ca_created)${RESET}"
        local bundle_path; bundle_path=$(bundle_file)
        if [ -f "$bundle_path" ]; then
            local bundle_count; bundle_count=$(grep -c "BEGIN CERTIFICATE" "$bundle_path" 2>/dev/null || echo "?")
            echo -e "  ${DIM}Bundle : ${bundle_path}  ${GREEN}✔${RESET}  ${DIM}(${bundle_count} intermediate CAs)${RESET}"
        fi
    fi
    pause
}

menu_services() {
    while true; do
        header; section "Service management"
        local svc_names; svc_names=$(svc_list_names)
        if [ -n "$svc_names" ]; then
            printf "  ${BOLD}%-4s %-18s %-8s %-26s %-20s${RESET}\n" "#" "Name" "Mode" "Domain/File" "Router/Target"; hr
            local i=1
            while IFS= read -r s; do
                [ -z "$s" ] && continue
                local sd st sm spf spr
                sd=$(svc_get "$s" "domain"); st=$(svc_get "$s" "target"); sm=$(svc_get "$s" "mode")
                spf=$(svc_get "$s" "patch_file"); spr=$(svc_get "$s" "patch_router")
                if [ "$sm" = "patch" ]; then
                    printf "  ${CYAN}%-4s${RESET} %-18s ${YELLOW}%-8s${RESET} %-26s %-20s\n" "$i" "$s" "patch" "${spf##*/}" "$spr"
                else
                    printf "  ${CYAN}%-4s${RESET} %-18s ${GREEN}%-8s${RESET} %-26s %-20s\n" "$i" "$s" "new" "$sd" "$st"
                fi
                i=$((i + 1))
            done <<< "$svc_names"; hr; echo ""
        else
            warn "No services added."; echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  Add service [new]    — new domain"
        echo -e "  ${BOLD}2)${RESET}  Add service [patch]  — existing router"
        echo -e "  ${BOLD}3)${RESET}  Delete service       — from the DB only"
        echo -e "  ${BOLD}4)${RESET}  Update Traefik config"
        echo -e "  ${BOLD}5)${RESET}  Full service removal — revoke+delete all certificates, remove files and the Traefik block"
        echo -e "  ${BOLD}0)${RESET}  Back"
        local c; c=$(menu_choice)
        case "$c" in
            1)
                echo ""
                local sname sdomain starget
                sname=$(ask "Service name" ""); sname="${sname// /-}"
                sdomain=$(ask "Domain (e.g.: myapp.example.com)" "")
                starget=$(ask "Target URL  (e.g.: http://localhost:3000)" "")
                if ! validate_name "Service name" "$sname"; then
                    :
                elif [ -z "$sdomain" ] || [ -z "$starget" ]; then
                    err "All fields are required."
                else
                    svc_add "$sname" "$sdomain" "$starget" "new" "" ""
                    do_gen_traefik; ok "Service '${sname}' added."
                fi
                pause ;;
            2)
                echo ""
                echo -e "  ${DIM}Files in ${TRAEFIK_DYNAMIC_PATH}/:${RESET}"
                ls "${TRAEFIK_DYNAMIC_PATH}"/*.yml "${TRAEFIK_DYNAMIC_PATH}"/*.yaml 2>/dev/null \
                    | while read -r f; do echo -e "    ${CYAN}${f##*/}${RESET}"; done
                echo ""
                local sname spf spr
                sname=$(ask "Service name (will be mtls-<name>)" ""); sname="${sname// /-}"
                spf=$(ask "Config file (full path)" "${TRAEFIK_DYNAMIC_PATH}/dokploy.yml")
                echo ""; echo -e "  ${DIM}Routers in the file:${RESET}"
                python3 - "$spf" << 'PYEOF' 2>/dev/null
import sys
try:
    with open(sys.argv[1]) as f: content = f.read()
    in_routers = False
    for line in content.split('\n'):
        s = line.lstrip(); indent = len(line) - len(s)
        if s.rstrip(':') == 'routers': in_routers = True; continue
        if in_routers:
            if indent == 4 and s.endswith(':') and not s.startswith('#'): print(f"    {s.rstrip(':')}")
            elif indent <= 2 and s and not s.startswith('#'): in_routers = False
except: pass
PYEOF
                echo ""
                spr=$(ask "Router name (exactly as in the file)" "")
                if ! validate_name "Service name" "$sname"; then
                    :
                elif [ -z "$spf" ] || [ -z "$spr" ]; then
                    err "All fields are required."
                elif [ ! -f "$spf" ]; then
                    err "File not found: $spf"
                else
                    svc_add "$sname" "" "" "patch" "$spf" "$spr"
                    do_gen_traefik
                    ok "Service '${sname}' added [patch]. Create a certificate — the patch will be applied automatically."
                fi
                pause ;;
            3)
                [ -z "$svc_names" ] && { warn "No services."; pause; continue; }
                echo ""
                local s_arr=()
                while IFS= read -r s; do [ -z "$s" ] && continue; s_arr+=("$s"); done <<< "$svc_names"
                local sc; sc=$(ask "Service number to delete" "")
                [ -z "$sc" ] && { pause; continue; }
                local sdel="${s_arr[$((sc - 1))]}"
                if [ -n "$sdel" ] && ask_yn "Delete service '$sdel'?"; then
                    local dm; dm=$(svc_get "$sdel" "mode")
                    if [ "$dm" = "patch" ]; then
                        local dpf; dpf=$(svc_get "$sdel" "patch_file")
                        local dpr; dpr=$(svc_get "$sdel" "patch_router")
                        info "Removing patch from ${dpf}..."
                        patch_remove "$sdel" "$dpf" "$dpr"; ok "Patch removed."
                    fi
                    svc_delete "$sdel"; do_gen_traefik; ok "Deleted."
                fi
                pause ;;
            4) do_gen_traefik; pause ;;
            5)
                [ -z "$svc_names" ] && { warn "No services."; pause; continue; }
                echo ""
                local s_arr5=()
                while IFS= read -r s; do [ -z "$s" ] && continue; s_arr5+=("$s"); done <<< "$svc_names"
                local sc5; sc5=$(ask "Service number for full removal" "")
                [ -z "$sc5" ] && { pause; continue; }
                local sdel5="${s_arr5[$((sc5 - 1))]}"
                if [ -z "$sdel5" ]; then err "Invalid number."; pause; continue; fi
                echo ""
                warn "FULL REMOVAL:"
                warn "  - revoke and delete ALL client certificates for '${sdel5}'"
                warn "  - delete client files from disk (${CLIENTS_PATH}/${sdel5})"
                warn "  - delete ALL intermediate CAs for '${sdel5}' (${CA_PATH}/intermediates/${sdel5}__*)"
                warn "  - remove the generated Traefik router/service block (new mode)"
                warn "  - remove the mTLS patch from the external config (patch mode)"
                warn "  - remove the service from the database"
                echo ""
                ask_yn "Proceed with FULL removal of '${sdel5}'? (irreversible)" || { ok "Cancelled."; pause; continue; }
                core_delete_service_full "$sdel5"
                pause ;;
            0) return ;;
        esac
    done
}

menu_presets() {
    while true; do
        header; section "Custom path presets"
        local pnames; pnames=$(preset_list_names)
        if [ -n "$pnames" ]; then
            printf "  ${BOLD}%-4s %-16s %-30s %-30s${RESET}\n" "#" "Name" "Traefik dynamic" "CA path"; hr
            local i=1
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                local ptp pcap
                ptp=$(preset_get "$p" "traefik_dynamic_path")
                pcap=$(preset_get "$p" "ca_path")
                printf "  ${CYAN}%-4s${RESET} %-16s %-30s %-30s\n" "$i" "$p" "$ptp" "$pcap"
                i=$((i + 1))
            done <<< "$pnames"; hr; echo ""
        else
            warn "No saved presets."; echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  Save current paths as a preset"
        echo -e "  ${BOLD}2)${RESET}  Apply a preset"
        echo -e "  ${BOLD}3)${RESET}  Delete a preset"
        echo -e "  ${BOLD}0)${RESET}  Back"
        local c; c=$(menu_choice)
        case "$c" in
            1)
                echo ""
                echo -e "  ${DIM}Current paths:${RESET}"
                echo -e "    TRAEFIK_DYNAMIC_PATH = ${TRAEFIK_DYNAMIC_PATH}"
                echo -e "    CA_PATH               = ${CA_PATH}"
                echo -e "    CLIENTS_PATH          = ${CLIENTS_PATH}"
                echo -e "    OUTPUT_FILE           = ${OUTPUT_FILE}"
                echo ""
                local pname; pname=$(ask "Preset name" "")
                if ! validate_name "Preset name" "$pname"; then pause; continue; fi
                preset_save "$pname" "$TRAEFIK_DYNAMIC_PATH" "$CA_PATH" "$CLIENTS_PATH" "$OUTPUT_FILE"
                ok "Preset '${pname}' saved."
                pause ;;
            2)
                [ -z "$pnames" ] && { warn "No presets."; pause; continue; }
                echo ""
                local p_arr=()
                while IFS= read -r p; do [ -z "$p" ] && continue; p_arr+=("$p"); done <<< "$pnames"
                local pc; pc=$(ask "Preset number to apply" "")
                [ -z "$pc" ] && { pause; continue; }
                local papply="${p_arr[$((pc - 1))]}"
                if [ -z "$papply" ]; then err "Invalid number."; pause; continue; fi
                if preset_apply "$papply"; then
                    ok "Preset '${papply}' applied."
                    audit_log "preset_apply" "name=${papply}"
                else
                    err "Failed to apply preset '${papply}'."
                fi
                pause ;;
            3)
                [ -z "$pnames" ] && { warn "No presets."; pause; continue; }
                echo ""
                local p_arr3=()
                while IFS= read -r p; do [ -z "$p" ] && continue; p_arr3+=("$p"); done <<< "$pnames"
                local pc3; pc3=$(ask "Preset number to delete" "")
                [ -z "$pc3" ] && { pause; continue; }
                local pdel="${p_arr3[$((pc3 - 1))]}"
                if [ -n "$pdel" ] && ask_yn "Delete preset '$pdel'?"; then
                    preset_delete "$pdel"
                    ok "Preset '${pdel}' deleted."
                    audit_log "preset_delete" "name=${pdel}"
                fi
                pause ;;
            0) return ;;
        esac
    done
}

menu_settings() {
    while true; do
        header; section "Path settings"
        echo -e "  ${BOLD}1)${RESET}  Traefik dynamic configs\n     ${CYAN}${TRAEFIK_DYNAMIC_PATH}${RESET}\n"
        echo -e "  ${BOLD}2)${RESET}  CA directory\n     ${CYAN}${CA_PATH}${RESET}\n"
        echo -e "  ${BOLD}3)${RESET}  Client certificates directory\n     ${CYAN}${CLIENTS_PATH}${RESET}\n"
        echo -e "  ${BOLD}4)${RESET}  Config file name\n     ${CYAN}${OUTPUT_FILE}${RESET}\n"
        echo -e "  ${BOLD}5)${RESET}  Default validity (days)\n     ${CYAN}${CERT_DAYS}${RESET}\n"
        echo -e "  ${BOLD}6)${RESET}  Expiry warning (days)\n     ${CYAN}${EXPIRY_WARN_DAYS}${RESET}\n"
        echo -e "  ${BOLD}7)${RESET}  Bundle mode\n     ${CYAN}${BUNDLE_MODE}${RESET} ${DIM}(shared | per-service)${RESET}\n"
        echo -e "  ${BOLD}8)${RESET}  CA key encryption\n     ${CYAN}${CA_KEY_ENCRYPTED}${RESET} ${DIM}(0=off 1=on)${RESET}\n"
        echo -e "  ${BOLD}9)${RESET}  Require a .p12 password\n     ${CYAN}${REQUIRE_P12_PASSWORD}${RESET} ${DIM}(0=off 1=on, 1 recommended)${RESET}\n"
        echo -e "  ${BOLD}11)${RESET} Audit log rotation (bytes)\n     ${CYAN}${AUDIT_MAX_BYTES}${RESET} ${DIM}(0=off; when exceeded — .1.gz)${RESET}\n"
        hr
        echo -e "  ${DIM}Built-in presets:${RESET}"
        echo -e "  ${BOLD}p1)${RESET} Dokploy   /etc/dokploy/traefik/dynamic"
        echo -e "  ${BOLD}p2)${RESET} Traefik   /etc/traefik/dynamic"
        echo -e "  ${BOLD}p3)${RESET} Local     ./traefik-local"
        echo -e "  ${BOLD}10)${RESET} Custom presets — save/apply/delete your own path sets"
        hr; echo ""
        echo -e "  ${BOLD}0)${RESET}  Back"
        local c; c=$(menu_choice)
        case "$c" in
            1) TRAEFIK_DYNAMIC_PATH=$(ask "New path" "$TRAEFIK_DYNAMIC_PATH"); save_config; ok "Saved."; pause ;;
            2) CA_PATH=$(ask "New path" "$CA_PATH"); save_config; ok "Saved."; pause ;;
            3) CLIENTS_PATH=$(ask "New path" "$CLIENTS_PATH"); save_config; ok "Saved."; pause ;;
            4) OUTPUT_FILE=$(ask "New file name" "$OUTPUT_FILE"); save_config; ok "Saved."; pause ;;
            5) CERT_DAYS=$(ask "Days" "$CERT_DAYS"); save_config; ok "Saved."; pause ;;
            6) EXPIRY_WARN_DAYS=$(ask "Days" "$EXPIRY_WARN_DAYS"); save_config; ok "Saved."; pause ;;
            7) BUNDLE_MODE=$(ask "Bundle mode (shared | per-service)" "$BUNDLE_MODE"); save_config; ok "Saved."; pause ;;
            8)
                echo ""
                CA_KEY_ENCRYPTED=$(ask "Encrypt the CA key? (0=off 1=on)" "$CA_KEY_ENCRYPTED")
                save_config; ok "Saved."; pause ;;
            9)
                echo ""
                REQUIRE_P12_PASSWORD=$(ask "Require a .p12 password? (0=off 1=on)" "$REQUIRE_P12_PASSWORD")
                save_config; ok "Saved."; pause ;;
            p1) TRAEFIK_DYNAMIC_PATH="/etc/dokploy/traefik/dynamic"; CA_PATH="/etc/dokploy/traefik/dynamic/certificates/ca"; CLIENTS_PATH="/etc/dokploy/traefik/dynamic/certificates/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Dokploy preset applied."; pause ;;
            p2) TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"; CA_PATH="/etc/traefik/certs/mtls"; CLIENTS_PATH="/etc/traefik/certs/mtls/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Traefik preset applied."; pause ;;
            p3) TRAEFIK_DYNAMIC_PATH="$(pwd)/traefik-local/dynamic"; CA_PATH="$(pwd)/traefik-local/certs/mtls"; CLIENTS_PATH="$(pwd)/traefik-local/certs/mtls/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Local preset applied."; pause ;;
            10) menu_presets ;;
            11)
                echo ""
                AUDIT_MAX_BYTES=$(ask "Max audit log size in bytes (0=off)" "$AUDIT_MAX_BYTES")
                save_config; ok "Saved."; pause ;;
            0) return ;;
        esac
    done
}

do_create_ca_tui() {
    header; section "Create root CA"
    local cn days encrypt
    cn=$(ask "CA name (CN)" "mTLS-Root-CA")
    days=$(ask "CA validity (days)" "3650")
    echo ""
    ask_yn "Encrypt the CA key with a passphrase?" && encrypt="1" || encrypt="0"
    echo ""
    core_create_ca "$cn" "$days" "$encrypt"
    pause
}

ensure_ca() {
    if ! ca_exists; then
        warn "Root CA not found."; echo ""
        ask_yn "Create the CA now?" || { err "A CA is required."; pause; return 1; }
        do_create_ca_tui
    fi
    ca_key_prompt_passphrase
    return 0
}

main_menu() {
    while true; do
        header
        local ca_status
        ca_exists && ca_status="${GREEN}CA ✔${RESET}" || ca_status="${RED}CA ✖ not created${RESET}"
        local svc_count_val cert_count_val
        svc_count_val=$(svc_count); cert_count_val=$(db_count)
        echo -e "  ${DIM}${TRAEFIK_DYNAMIC_PATH}${RESET}"
        echo -e "  ${ca_status}   ${DIM}services: ${svc_count_val}   certificates: ${cert_count_val}${RESET}"
        hr; echo ""
        echo -e "  ${BOLD}1)${RESET}  Create a certificate"
        echo -e "  ${BOLD}2)${RESET}  List certificates"
        echo -e "  ${BOLD}3)${RESET}  Revoke / delete a certificate"
        echo -e "  ${BOLD}4)${RESET}  Manage services"
        echo -e "  ${BOLD}5)${RESET}  Create / recreate CA"
        echo -e "  ${BOLD}6)${RESET}  Path settings"
        echo -e "  ${BOLD}7)${RESET}  Update Traefik config"
        echo -e "  ${BOLD}8)${RESET}  Check expiring certificates"
        echo -e "  ${BOLD}9)${RESET}  Backup CA + database"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ${DIM}Exit${RESET}"
        local c; c=$(menu_choice)
        case "$c" in
            1) menu_cert_create ;;
            2) menu_cert_list ;;
            3) menu_cert_delete ;;
            4) menu_services ;;
            5) do_create_ca_tui ;;
            6) menu_settings ;;
            7) do_gen_traefik; pause ;;
            8) core_scan_expiry; pause ;;
            9) do_backup; pause ;;
            0) echo ""; exit 0 ;;
        esac
    done
}

cli_usage() {
    cat <<'USAGE'
mtls.sh v2.4 — mTLS Certificate Manager (root only)

USAGE:
  sudo mtls.sh                       Interactive TUI menu
  sudo mtls.sh <command> [options]   CLI mode

COMMANDS:
  ca create [--cn NAME] [--days N] [--encrypt]
      Create the root CA

  ca info
      Show CA information
      Note: certificate revocation in this script works through the
      caFiles bundle (the client's intermediate CA is dropped from the
      bundle), not through a CRL — Traefik does not support crlFile in
      clientAuth. The crl.pem file is generated additionally as a
      standard artifact for external consumers (not Traefik) that
      understand CRLs.

  ca backup [--output FILE]
      Backup CA + DB + config (+ presets) to a tar.gz

  ca restore --input FILE
      Restore from a backup

  cert issue --service S --name N [--days D] [--note TEXT] [--pass P]
      Issue a new client certificate.
      S and N may only contain Latin letters, digits, '.', '_' and '-',
      without "__" and without "/" or ".." (otherwise the command fails)
      — this protects against writing files outside the expected
      directories and against name collisions.
      If --pass is not given and REQUIRE_P12_PASSWORD=1 (default), the
      command fails in non-interactive mode — a .p12 without a
      password is never created silently.
      WARNING: --pass is visible in shell history and in `ps` output
      while the command runs. Prefer passing the password via the
      MTLS_P12_PASSWORD environment variable (it should still be
      considered readable by anyone who can read /proc/<pid>/environ
      of this process — on a root-only host that is only root).

  cert list [--json]
      List all certificates

  cert revoke --uid UID | --service S --name N
      Revoke a certificate (files stay on disk)

  cert delete --uid UID | --service S --name N
      Revoke + delete the certificate files from disk

  cert renew --uid UID [--days D] [--pass P]
  cert renew --service S --name N [--days D] [--pass P]
      Renew an existing certificate (reissue under the same name).
      If --pass is not given, MTLS_P12_PASSWORD is used; otherwise the
      REQUIRE_P12_PASSWORD rule applies as for cert issue.

  cert verify --uid UID | --service S --name N
      Verify the certificate chain and show details

  cert scan
      Check for expiring/expired/unrecognized-date certificates and
      print the result (no external notifications)

  service add --name N --domain D --target T [--mode new|patch]
      Add a service (for patch: --patch-file F --router R).
      N may only contain Latin letters, digits, '.', '_' and '-',
      without "__" and without "/" or "..".

  service list
      List all services

  service delete --name N
      Delete a service (remove from the DB, remove the patch in patch mode)

  service delete-full --name N
      Full removal: revoke+delete all client certificates, delete
      client files, remove the generated Traefik router/service block,
      remove the patch, delete the service

  preset save --name N [--traefik-path P] [--ca-path P] [--clients-path P] [--output-file F]
      Save a custom path preset under the name N. Any path not given
      is taken from the current config.

  preset apply --name N
      Apply the saved preset N (overwrites the current paths and
      saves them to the config).

  preset list
      List saved presets

  preset delete --name N
      Delete the saved preset N

  config show
      Show the current configuration

  config set <key> <value>
      Set a configuration value (including REQUIRE_P12_PASSWORD)

  gen
      Generate/update the Traefik config

  audit [--last N]
      Show audit log entries

  help
      Show this help

ACCESS:
  The script works only as root. Run it via sudo or directly as root.
  There is no longer a multi-user mode — secret material (CA and
  client keys) must not be accessible to anyone else.

ENVIRONMENT VARIABLES:
  MTLS_HOST_IP          Override the detected host IP
  MTLS_CA_PASSPHRASE    CA key passphrase (for encrypted keys).
                        If preset by the operator as an env var, that
                        is at their discretion. If the script asks for
                        the passphrase interactively, it is kept only
                        as a regular (NOT exported) shell variable —
                        not in the process environ — and is passed to
                        openssl through a 0600 temporary file, not
                        via stdin/arguments.
  MTLS_P12_PASSWORD     Default .p12 password (non-interactive issuance)
  MTLS_NONINTERACTIVE   Set to 1 to skip all prompts

USAGE
}

cli_ca() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        create)
            local cn="mTLS-Root-CA" days="3650" encrypt="0"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --cn)      cn="$2"; shift 2 ;;
                    --days)    days="$2"; shift 2 ;;
                    --encrypt) encrypt="1"; shift ;;
                    *) err "Unknown option: $1"; exit 1 ;;
                esac
            done
            if [ "$encrypt" = "1" ] && [ -z "${MTLS_CA_PASSPHRASE:-}" ]; then
                info "CA key encryption is enabled — enter the passphrase:"
                MTLS_CA_PASSPHRASE=$(ask_secret "Passphrase")
            fi
            core_create_ca "$cn" "$days" "$encrypt"
            unset MTLS_CA_PASSPHRASE 2>/dev/null || true
            ;;
        info)
            if ! ca_exists; then cli_err "CA not found."; exit 1; fi
            local ca_cn ca_created ca_days
            ca_cn=$(db_read "__ca__" "cn"); ca_created=$(db_read "__ca__" "created")
            ca_days=$(db_read "__ca__" "days")
            echo "  CA: ${ca_cn}"
            echo "  Created: ${ca_created}"
            echo "  Validity: ${ca_days} days"
            echo "  Path: ${CA_PATH}"
            echo "  Encrypted: ${CA_KEY_ENCRYPTED}"
            echo "  Bundle mode: ${BUNDLE_MODE}"
            local bundle_path; bundle_path=$(bundle_file)
            if [ -f "$bundle_path" ]; then
                local bc; bc=$(grep -c "BEGIN CERTIFICATE" "$bundle_path" 2>/dev/null || echo 0)
                echo "  Bundle: ${bundle_path} (${bc} CAs)"
            fi
            ;;
        backup)
            local out=""
            while [ $# -gt 0 ]; do
                case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac
            done
            do_backup "$out"
            ;;
        restore)
            local inp=""
            while [ $# -gt 0 ]; do
                case "$1" in --input) inp="$2"; shift 2 ;; *) shift ;; esac
            done
            [ -z "$inp" ] && { cli_err "--input FILE is required"; exit 1; }
            do_restore "$inp"
            ;;
        *) cli_err "Unknown ca subcommand: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_cert() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        issue)
            local service="" name="" days="" note="" pass=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --service) service="$2"; shift 2 ;;
                    --name)    name="$2"; shift 2 ;;
                    --days)    days="$2"; shift 2 ;;
                    --note)    note="$2"; shift 2 ;;
                    --pass)    pass="$2"; shift 2 ;;
                    *) err "Unknown option: $1"; exit 1 ;;
                esac
            done
            [ -z "$service" ] && { cli_err "--service is required"; exit 1; }
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            [ -z "$days" ] && days="$CERT_DAYS"
            [ -z "$pass" ] && pass="${MTLS_P12_PASSWORD:-}"
            ensure_ca || exit 1
            core_issue_cert "$service" "$name" "$days" "$note" "$pass"
            ;;
        list)
            local use_json=0
            [ "${1:-}" = "--json" ] && use_json=1
            if [ "$use_json" = "1" ]; then
                db_all_json
            else
                local names; names=$(db_list_names)
                if [ -z "$names" ]; then cli_info "No certificates."; exit 0; fi
                print_cert_table "$names"
                local total; total=$(db_count)
                echo ""; echo -e "  ${DIM}Total: $total${RESET}"
            fi
            ;;
        revoke)
            local uid; uid=$(cli_resolve_uid "$@") || exit 1
            core_revoke_cert "$uid"
            ;;
        delete)
            local uid; uid=$(cli_resolve_uid "$@") || exit 1
            ask_yn "Delete files from disk? (irreversible)" || exit 0
            core_delete_cert "$uid"
            ;;
        renew)
            cli_cert_renew "$@"
            ;;
        verify)
            local uid; uid=$(cli_resolve_uid "$@") || exit 1
            core_verify_cert "$uid"
            ;;
        scan)
            core_scan_expiry
            ;;
        *) cli_err "Unknown cert subcommand: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_resolve_uid() {
    local uid="" service="" name=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --uid)     uid="$2"; shift 2 ;;
            --service) service="$2"; shift 2 ;;
            --name)    name="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -n "$uid" ]; then
        case "$uid" in
            *__*)
                local uid_service="${uid%%__*}" uid_name="${uid#*__}"
                [ "$uid_service" != "$uid" ] && [ -n "$uid_name" ] || { cli_err "Invalid UID."; return 1; }
                validate_name "UID service" "$uid_service" || return 1
                validate_name "UID name" "$uid_name" || return 1
                ;;
            *) cli_err "Invalid UID: expected SERVICE__NAME"; return 1 ;;
        esac
        echo "$uid"; return 0
    fi
    if [ -n "$service" ] && [ -n "$name" ]; then
        validate_name "Service name" "$service" || return 1
        validate_name "Certificate name" "$name" || return 1
        echo "${service}__${name}"; return 0
    fi
    cli_err "Specify --uid UID or --service S --name N"
    return 1
}

cli_service() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        add)
            local name="" domain="" target="" mode="new" patch_file="" router=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)       name="$2"; shift 2 ;;
                    --domain)     domain="$2"; shift 2 ;;
                    --target)     target="$2"; shift 2 ;;
                    --mode)       mode="$2"; shift 2 ;;
                    --patch-file) patch_file="$2"; shift 2 ;;
                    --router)     router="$2"; shift 2 ;;
                    *) err "Unknown option: $1"; exit 1 ;;
                esac
            done
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            validate_name "Service name" "$name" || exit 1
            if [ "$mode" = "new" ]; then
                [ -z "$domain" ] && { cli_err "--domain is required for new mode"; exit 1; }
                [ -z "$target" ] && { cli_err "--target is required for new mode"; exit 1; }
            elif [ "$mode" = "patch" ]; then
                [ -z "$patch_file" ] && { cli_err "--patch-file is required for patch mode"; exit 1; }
                [ -z "$router" ] && { cli_err "--router is required for patch mode"; exit 1; }
            fi
            svc_add "$name" "$domain" "$target" "$mode" "$patch_file" "$router"
            do_gen_traefik
            cli_ok "Service '${name}' added [${mode}]."
            audit_log "service_add" "name=${name} mode=${mode}"
            ;;
        list)
            local svc_names; svc_names=$(svc_list_names)
            if [ -z "$svc_names" ]; then cli_info "No services."; exit 0; fi
            printf "%-20s %-8s %-26s %-20s\n" "NAME" "MODE" "DOMAIN/FILE" "ROUTER/TARGET"
            while IFS= read -r s; do
                [ -z "$s" ] && continue
                local sd st sm spf spr
                sd=$(svc_get "$s" "domain"); st=$(svc_get "$s" "target"); sm=$(svc_get "$s" "mode")
                spf=$(svc_get "$s" "patch_file"); spr=$(svc_get "$s" "patch_router")
                if [ "$sm" = "patch" ]; then
                    printf "%-20s %-8s %-26s %-20s\n" "$s" "patch" "${spf##*/}" "$spr"
                else
                    printf "%-20s %-8s %-26s %-20s\n" "$s" "new" "$sd" "$st"
                fi
            done <<< "$svc_names"
            ;;
        delete)
            local name=""
            while [ $# -gt 0 ]; do
                case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
            done
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            local dm; dm=$(svc_get "$name" "mode")
            if [ "$dm" = "patch" ]; then
                local dpf; dpf=$(svc_get "$name" "patch_file")
                local dpr; dpr=$(svc_get "$name" "patch_router")
                patch_remove "$name" "$dpf" "$dpr"
            fi
            svc_delete "$name"; do_gen_traefik
            cli_ok "Service '${name}' deleted."
            audit_log "service_delete" "name=${name}"
            ;;
        delete-full)
            local name=""
            while [ $# -gt 0 ]; do
                case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
            done
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            cli_info "Full removal: revoking + deleting all certificates, removing files and the Traefik block for '${name}'..."
            core_delete_service_full "$name"
            ;;
        *) cli_err "Unknown service subcommand: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_preset() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        save)
            local name="" tp="" cap="" clp="" of=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)          name="$2"; shift 2 ;;
                    --traefik-path)  tp="$2"; shift 2 ;;
                    --ca-path)       cap="$2"; shift 2 ;;
                    --clients-path)  clp="$2"; shift 2 ;;
                    --output-file)   of="$2"; shift 2 ;;
                    *) err "Unknown option: $1"; exit 1 ;;
                esac
            done
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            validate_name "Preset name" "$name" || exit 1
            [ -z "$tp" ] && tp="$TRAEFIK_DYNAMIC_PATH"
            [ -z "$cap" ] && cap="$CA_PATH"
            [ -z "$clp" ] && clp="$CLIENTS_PATH"
            [ -z "$of" ] && of="$OUTPUT_FILE"
            validate_output_file "$of" || exit 1
            preset_save "$name" "$tp" "$cap" "$clp" "$of"
            cli_ok "Preset '${name}' saved."
            audit_log "preset_save" "name=${name}"
            ;;
        apply)
            local name=""
            while [ $# -gt 0 ]; do
                case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
            done
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            if preset_apply "$name"; then
                cli_ok "Preset '${name}' applied."
                audit_log "preset_apply" "name=${name}"
            else
                cli_err "Preset '${name}' not found."
                exit 1
            fi
            ;;
        list)
            local pnames; pnames=$(preset_list_names)
            if [ -z "$pnames" ]; then cli_info "No saved presets."; exit 0; fi
            printf "%-16s %-30s %-30s %-30s %-16s\n" "NAME" "TRAEFIK_DYNAMIC_PATH" "CA_PATH" "CLIENTS_PATH" "OUTPUT_FILE"
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                local ptp pcap pclp pof
                ptp=$(preset_get "$p" "traefik_dynamic_path")
                pcap=$(preset_get "$p" "ca_path")
                pclp=$(preset_get "$p" "clients_path")
                pof=$(preset_get "$p" "output_file")
                printf "%-16s %-30s %-30s %-30s %-16s\n" "$p" "$ptp" "$pcap" "$pclp" "$pof"
            done <<< "$pnames"
            ;;
        delete)
            local name=""
            while [ $# -gt 0 ]; do
                case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
            done
            [ -z "$name" ] && { cli_err "--name is required"; exit 1; }
            preset_delete "$name"
            cli_ok "Preset '${name}' deleted."
            audit_log "preset_delete" "name=${name}"
            ;;
        *) cli_err "Unknown preset subcommand: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_config() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        show)
            echo "  TRAEFIK_DYNAMIC_PATH  = $TRAEFIK_DYNAMIC_PATH"
            echo "  CA_PATH               = $CA_PATH"
            echo "  CLIENTS_PATH          = $CLIENTS_PATH"
            echo "  OUTPUT_FILE           = $OUTPUT_FILE"
            echo "  CERT_DAYS             = $CERT_DAYS"
            echo "  EXPIRY_WARN_DAYS      = $EXPIRY_WARN_DAYS"
            echo "  CA_KEY_ENCRYPTED      = $CA_KEY_ENCRYPTED"
            echo "  BUNDLE_MODE           = $BUNDLE_MODE"
            echo "  REQUIRE_P12_PASSWORD  = $REQUIRE_P12_PASSWORD"
            echo "  AUDIT_MAX_BYTES       = $AUDIT_MAX_BYTES"
            ;;
        set)
            local key="${1:-}" val="${2:-}"
            [ -z "$key" ] && { cli_err "Usage: config set <key> <value>"; exit 1; }
            case "$key" in
                TRAEFIK_DYNAMIC_PATH)  [ -n "$val" ] && [[ "$val" != *$'\n'* ]] || { cli_err "Invalid path"; exit 1; }; TRAEFIK_DYNAMIC_PATH="$val" ;;
                CA_PATH)               [ -n "$val" ] && [[ "$val" != *$'\n'* ]] || { cli_err "Invalid path"; exit 1; }; CA_PATH="$val" ;;
                CLIENTS_PATH)          [ -n "$val" ] && [[ "$val" != *$'\n'* ]] || { cli_err "Invalid path"; exit 1; }; CLIENTS_PATH="$val" ;;
                OUTPUT_FILE)           validate_output_file "$val" || exit 1; OUTPUT_FILE="$val" ;;
                CERT_DAYS)             CERT_DAYS="$val" ;;
                EXPIRY_WARN_DAYS)      EXPIRY_WARN_DAYS="$val" ;;
                CA_KEY_ENCRYPTED)      CA_KEY_ENCRYPTED="$val" ;;
                BUNDLE_MODE)           BUNDLE_MODE="$val" ;;
                REQUIRE_P12_PASSWORD)  REQUIRE_P12_PASSWORD="$val" ;;
                AUDIT_MAX_BYTES)       AUDIT_MAX_BYTES="$val" ;;
                *) cli_err "Unknown key: $key"; exit 1 ;;
            esac
            save_config
            cli_ok "Set ${key} = ${val}"
            audit_log "config_set" "${key}=${val}"
            ;;
        *) cli_err "Unknown config subcommand: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_audit() {
    [ -f "$AUDIT_FILE" ] || { cli_info "The audit log is empty."; exit 0; }
    local last="${1:-0}"
    if [ "$last" = "--last" ]; then
        last="$2"
        tail -n "$last" "$AUDIT_FILE" | while IFS= read -r line; do
            python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(f\"  {d['ts']}  {d['action']:20s}  {d.get('actor',''):12s}  {d.get('detail','')}\")" "$line" 2>/dev/null
        done
    else
        cat "$AUDIT_FILE" | while IFS= read -r line; do
            python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(f\"  {d['ts']}  {d['action']:20s}  {d.get('actor',''):12s}  {d.get('detail','')}\")" "$line" 2>/dev/null
        done
    fi
}

cli_cert_renew() {
    local uid="" days="" service="" name="" pass=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --uid)     uid="$2"; shift 2 ;;
            --days)    days="$2"; shift 2 ;;
            --service) service="$2"; shift 2 ;;
            --name)    name="$2"; shift 2 ;;
            --pass)    pass="$2"; shift 2 ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done
    if [ -z "$uid" ]; then
        if [ -n "$service" ] && [ -n "$name" ]; then
            validate_name "Service name" "$service" || exit 1
            validate_name "Certificate name" "$name" || exit 1
            uid="${service}__${name}"
        else
            cli_err "--uid UID or --service S --name N is required"; exit 1
        fi
    else
        case "$uid" in
            *__*) validate_name "UID service" "${uid%%__*}" || exit 1; validate_name "UID name" "${uid#*__}" || exit 1 ;;
            *) cli_err "Invalid UID"; exit 1 ;;
        esac
    fi
    [ -z "$days" ] && days="$CERT_DAYS"
    ensure_ca || exit 1
    core_renew_cert "$uid" "$days" "$pass"
}

require_root

for _guarded_path in "$CONFIG_FILE" "$DB_FILE" "$SERVICES_FILE" "$AUDIT_FILE" "$PRESETS_FILE"; do
    if [ -L "$_guarded_path" ]; then
        echo "" >&2
        echo -e "  ${RED}✖${RESET}  Refused: ${_guarded_path} is a symlink." >&2
        echo -e "  ${DIM}For security reasons the script will not read/write its state files through symlink paths. Remove the symlink and try again.${RESET}" >&2
        echo "" >&2
        exit 1
    fi
done
unset _guarded_path

load_config
validate_output_file "$OUTPUT_FILE" || exit 1
db_init
check_deps

if [ $# -ge 1 ]; then
    MTLS_NONINTERACTIVE=1
    export MTLS_NONINTERACTIVE
    _cmd="$1"; shift

    db_lock
    case "$_cmd" in
        ca)       cli_ca "$@" ;;
        cert)     cli_cert "$@" ;;
        service)  cli_service "$@" ;;
        preset)   cli_preset "$@" ;;
        config)   cli_config "$@" ;;
        gen)      do_gen_traefik ;;
        audit)    cli_audit "$@" ;;
        help|--help|-h) cli_usage ;;
        menu)     MTLS_NONINTERACTIVE=0; db_unlock; main_menu ;;
        *)        cli_err "Unknown command: $_cmd"; echo ""; cli_usage; exit 1 ;;
    esac
    db_unlock
    exit 0
fi

db_lock
main_menu
db_unlock
