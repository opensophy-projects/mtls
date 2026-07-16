#!/usr/bin/env bash
# =============================================================================
#  mtls.sh — Менеджер mTLS-сертификатов  v2.0
#  CLI + интерактивный TUI для управления mTLS-сертификатами под Traefik
#  Лицензия: MIT  —  opensophy-projects
# =============================================================================
set -euo pipefail
# Fallback for shopt on very old bash (we require bash >=4 anyway)
shopt -s nullglob 2>/dev/null || true

# -----------------------------------------------------------------------------
#  COLORS
# -----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
export RED GREEN YELLOW BLUE CYAN BOLD DIM RESET

# -----------------------------------------------------------------------------
#  PATHS & DEFAULTS
# -----------------------------------------------------------------------------
CONFIG_FILE="${MTLS_CONFIG_FILE:-${HOME}/.mtls-manager.conf}"
DB_FILE="${MTLS_DB_FILE:-${HOME}/.mtls-manager.db}"
SERVICES_FILE="${MTLS_SERVICES_FILE:-${HOME}/.mtls-manager.services}"
AUDIT_FILE="${MTLS_AUDIT_FILE:-${HOME}/.mtls-manager.audit.jsonl}"
LOCK_FILE="${DB_FILE}.lock"

TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"
CA_PATH="/etc/traefik/certs/mtls"
CLIENTS_PATH="/etc/traefik/certs/mtls/clients"
OUTPUT_FILE="mtls-manager.yml"
CERT_DAYS=365
EXPIRY_WARN_DAYS=30
CA_KEY_ENCRYPTED=0
BUNDLE_MODE="shared"   # shared | per-service
WEBHOOK_URL=""

NOTIFY_EXPIRY_DAYS=14
USERS_FILE="${MTLS_USERS_FILE:-${HOME}/.mtls-manager.users}"

# Non-interactive flag (set by CLI subcommands)
MTLS_NONINTERACTIVE=0

# =============================================================================
#  UI HELPERS (shared by TUI and CLI)
# =============================================================================
hr()      { echo -e "  ${DIM}──────────────────────────────────────────────────${RESET}"; }
info()    { echo -e "  ${CYAN}i${RESET}  $*" >&2; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $*" >&2; }
warn()    { echo -e "  ${YELLOW}!${RESET}  $*" >&2; }
err()     { echo -e "  ${RED}✖${RESET}  $*" >&2; }
section() { echo -e "  ${BOLD}$*${RESET}" >&2; hr >&2; echo "" >&2; }

# Machine-friendly output for CLI (no color codes, no prefix)
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
    case "${result:-n}" in y|Y|yes|YES|д|Д|да|ДА) return 0 ;; *) return 1 ;; esac
}

pause() {
    [ "$MTLS_NONINTERACTIVE" = "1" ] && return
    echo ""
    printf "  ${DIM}Enter — продолжить...${RESET}" >/dev/tty
    read -r _ </dev/tty
}

menu_choice() {
    printf "\n  Выбор: " >/dev/tty
    read -r MENU_CHOICE </dev/tty
    echo "$MENU_CHOICE"
}

# =============================================================================
#  CONFIG
# =============================================================================
load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    local key val
    while IFS='=' read -r key val; do
        val="${val//\"/}"
        case "$key" in
            TRAEFIK_DYNAMIC_PATH) TRAEFIK_DYNAMIC_PATH="$val" ;;
            CA_PATH)              CA_PATH="$val" ;;
            CLIENTS_PATH)         CLIENTS_PATH="$val" ;;
            OUTPUT_FILE)          OUTPUT_FILE="$val" ;;
            CERT_DAYS)            CERT_DAYS="$val" ;;
            EXPIRY_WARN_DAYS)     EXPIRY_WARN_DAYS="$val" ;;
            CA_KEY_ENCRYPTED)     CA_KEY_ENCRYPTED="$val" ;;
            BUNDLE_MODE)          BUNDLE_MODE="$val" ;;
            WEBHOOK_URL)          WEBHOOK_URL="$val" ;;

            NOTIFY_EXPIRY_DAYS)   NOTIFY_EXPIRY_DAYS="$val" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
TRAEFIK_DYNAMIC_PATH="$TRAEFIK_DYNAMIC_PATH"
CA_PATH="$CA_PATH"
CLIENTS_PATH="$CLIENTS_PATH"
OUTPUT_FILE="$OUTPUT_FILE"
CERT_DAYS="$CERT_DAYS"
EXPIRY_WARN_DAYS="$EXPIRY_WARN_DAYS"
CA_KEY_ENCRYPTED="$CA_KEY_ENCRYPTED"
BUNDLE_MODE="$BUNDLE_MODE"
WEBHOOK_URL="$WEBHOOK_URL"
NOTIFY_EXPIRY_DAYS="$NOTIFY_EXPIRY_DAYS"
EOF
    chmod 600 "$CONFIG_FILE"
}

# =============================================================================
#  LOCKING — prevents concurrent DB corruption
# =============================================================================
db_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -x -w 10 9; then
        err "Не удалось получить блокировку БД — возможно, запущен другой экземпляр."
        return 1
    fi
}

db_unlock() { flock -u 9 2>/dev/null || true; }

# =============================================================================
#  AUDIT LOG — JSONL append-only
# =============================================================================
audit_log() {
    local action="$1" detail="${2:-}"
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

# =============================================================================
#  DB (JSON via python3 — no external deps)
# =============================================================================
db_init() {
    [ -f "$DB_FILE" ]       || { echo '{}' > "$DB_FILE";  chmod 600 "$DB_FILE"; }
    [ -f "$SERVICES_FILE" ] || { echo '[]' > "$SERVICES_FILE"; chmod 600 "$SERVICES_FILE"; }
    [ -f "$AUDIT_FILE" ]    || { touch "$AUDIT_FILE"; chmod 600 "$AUDIT_FILE"; }
    [ -f "$USERS_FILE" ]    || { echo '[]' > "$USERS_FILE"; chmod 600 "$USERS_FILE"; }
}

# =============================================================================
#  ACCESS CONTROL — root always bypasses; non-root users must be in the list
# =============================================================================
acl_check() {
    # Root always allowed
    [ "$(id -u)" -eq 0 ] && return 0

    local current_user; current_user="${SUDO_USER:-${USER:-$(whoami)}}"

    # If no allowed-users list exists yet, only root can use the script
    [ -f "$USERS_FILE" ] || { return 1; }

    python3 - "$USERS_FILE" "$current_user" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    users = json.load(f)
sys.exit(0 if sys.argv[2] in users else 1)
PYEOF
}

acl_list() {
    [ -f "$USERS_FILE" ] || return 0
    python3 - "$USERS_FILE" << 'PYEOF' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    users = json.load(f)
for u in users:
    print(u)
PYEOF
}

acl_add() {
    local username="$1"
    local tmp; tmp=$(mktemp "${USERS_FILE}.XXXXXX")
    python3 - "$USERS_FILE" "$username" "$tmp" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    users = json.load(f)
if sys.argv[2] not in users:
    users.append(sys.argv[2])
with open(sys.argv[3], 'w') as f:
    json.dump(users, f, indent=2)
PYEOF
    mv "$tmp" "$USERS_FILE"
    chmod 600 "$USERS_FILE"
}

acl_remove() {
    local username="$1"
    local tmp; tmp=$(mktemp "${USERS_FILE}.XXXXXX")
    python3 - "$USERS_FILE" "$username" "$tmp" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    users = json.load(f)
users = [u for u in users if u != sys.argv[2]]
with open(sys.argv[3], 'w') as f:
    json.dump(users, f, indent=2)
PYEOF
    mv "$tmp" "$USERS_FILE"
    chmod 600 "$USERS_FILE"
}

# List real human users on the system (UID >= 1000, has a home dir, shell is not /nologin)
list_system_users() {
    while IFS=':' read -r login _ uid _ _ home shell; do
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        [[ "$shell" == *nologin* ]] && continue
        [[ "$shell" == */false ]] && continue
        echo "${login}"
    done < /etc/passwd
}

# Check if a given path is writable by the current user; if not, show guidance.
# Usage: check_path_access "/some/path"  OR  check_path_access  (defaults to $CA_PATH)
check_path_access() {
    local test_path="${1:-$CA_PATH}"
    # Root always passes
    [ "$(id -u)" -eq 0 ] && return 0

    # If path already exists, check writability directly
    if [ -d "$test_path" ]; then
        if [ ! -w "$test_path" ]; then
            echo ""
            echo -e "  ${RED}✖${RESET}  Нет прав на запись в: ${test_path}"
            echo ""
            echo -e "  ${YELLOW}Варианты:${RESET}"
            echo -e "    1. Запустите через sudo:  ${CYAN}sudo mtls.sh${RESET}"
            echo -e "    2. Измените пути в Настройках → локальный пресет (p3)"
            echo -e "    3. Попросите root добавить вас:  ${CYAN}sudo mtls.sh users add \$USER${RESET}"
            echo ""
            return 1
        fi
        return 0
    fi

    # Path does not exist — try to create it (walk up to first existing parent)
    local parent="$test_path"
    while [ "$parent" != "/" ] && [ ! -d "$parent" ]; do
        parent="$(dirname "$parent")"
    done
    if [ "$parent" = "/" ]; then parent="/"; fi
    if [ ! -w "$parent" ]; then
        echo ""
        echo -e "  ${RED}✖${RESET}  Нет прав на создание: ${test_path}"
        echo -e "  ${DIM}Родительский каталог не доступен для записи: ${parent}${RESET}"
        echo ""
        echo -e "  ${YELLOW}Варианты:${RESET}"
        echo -e "    1. Запустите через sudo:  ${CYAN}sudo mtls.sh${RESET}"
        echo -e "    2. Измените пути в Настройках → локальный пресет (p3)"
        echo -e "    3. Попросите root добавить вас:  ${CYAN}sudo mtls.sh users add \$USER${RESET}"
        echo ""
        return 1
    fi
    return 0
}

# Check all configured paths at once (called at startup and before operations)
check_all_paths() {
    local failed=0
    for p in "$CA_PATH" "$CLIENTS_PATH" "$TRAEFIK_DYNAMIC_PATH"; do
        if ! check_path_access "$p" >/dev/null 2>&1; then
            failed=1
        fi
    done
    if [ "$failed" -eq 1 ]; then
        return 1
    fi
    return 0
}

# Show a clear permission error for a specific path
show_permission_error() {
    local path="$1"
    echo ""
    echo -e "  ${RED}✖${RESET}  Доступ запрещён: ${path}"
    echo ""
    echo -e "  ${YELLOW}Варианты исправления:${RESET}"
    echo -e "    1. Запустите через sudo:      ${CYAN}sudo mtls.sh${RESET}"
    echo -e "    2. Используйте локальный пресет: запуск скрипта → 6 → p3"
    echo -e "    3. Попросите root добавить вас: ${CYAN}sudo mtls.sh users add \$USER${RESET}"
    echo ""
}

db_write() {
    local name="$1" field="$2" value="$3"
    local tmp; tmp=$(mktemp "${DB_FILE}.XXXXXX")
    python3 - "$DB_FILE" "$name" "$field" "$value" "$tmp" << 'PYEOF'
import sys, json
db_path, name, field, value, out = sys.argv[1:]
with open(db_path) as f:
    db = json.load(f)
if name not in db:
    db[name] = {}
db[name][field] = value
with open(out, 'w') as f:
    json.dump(db, f, indent=2, ensure_ascii=False)
PYEOF
    mv "$tmp" "$DB_FILE"
    chmod 600 "$DB_FILE"
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
    mv "$tmp" "$DB_FILE"
    chmod 600 "$DB_FILE"
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

# =============================================================================
#  SERVICES DB
# =============================================================================
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

svc_add() {
    local name="$1" domain="$2" target="$3" mode="${4:-new}" patch_file="${5:-}" patch_router="${6:-}"
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
    mv "$tmp" "$SERVICES_FILE"
    chmod 600 "$SERVICES_FILE"
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
    mv "$tmp" "$SERVICES_FILE"
    chmod 600 "$SERVICES_FILE"
}

# =============================================================================
#  OPENSSL WRAPPER — captures errors instead of swallowing them
# =============================================================================
run_openssl() {
    local stderr_capture rc
    stderr_capture=$(mktemp)
    set +e
    "$@" 2>"$stderr_capture"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        err "Ошибка команды openssl (код $rc):"
        cat "$stderr_capture" >&2 | head -5
        rm -f "$stderr_capture"
        return $rc
    fi
    rm -f "$stderr_capture"
    return 0
}

# =============================================================================
#  CA KEY ENCRYPTION HELPERS
# =============================================================================
ca_key_passphrase() {
    if [ "$CA_KEY_ENCRYPTED" = "1" ]; then
        if [ -n "${MTLS_CA_PASSPHRASE:-}" ]; then
            echo "-passin env:MTLS_CA_PASSPHRASE -passout env:MTLS_CA_PASSPHRASE"
        else
            echo "-passin stdin -passout stdin"
        fi
    else
        echo ""
    fi
}

ca_key_prompt_passphrase() {
    if [ "$CA_KEY_ENCRYPTED" = "1" ] && [ -z "${MTLS_CA_PASSPHRASE:-}" ]; then
        info "Ключ CA зашифрован — введите пароль:"
        local pass; pass=$(ask_secret "Пароль")
        export MTLS_CA_PASSPHRASE="$pass"
    fi
}

# Provide passphrase to openssl via stdin when env var is set
openssl_with_pass() {
    local cmd_args=("$@")
    if [ "$CA_KEY_ENCRYPTED" = "1" ] && [ -n "${MTLS_CA_PASSPHRASE:-}" ]; then
        printf '%s\n' "$MTLS_CA_PASSPHRASE" | openssl "${cmd_args[@]}" -passin stdin -passout stdin 2>/dev/null
    else
        openssl "${cmd_args[@]}" 2>/dev/null
    fi
}

# =============================================================================
#  INTERMEDIATE CA (per-client)
# =============================================================================
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

    if [ "$CA_KEY_ENCRYPTED" = "1" ]; then
        printf '%s\n' "${MTLS_CA_PASSPHRASE:-}" | openssl x509 -req -days "${CERT_DAYS}" \
            -in "${dir}/int-ca.csr" \
            -CA "${CA_PATH}/ca.crt" -CAkey "${CA_PATH}/ca.key" \
            -CAcreateserial -passin stdin \
            -out "$(int_ca_crt "$uid")" \
            -extfile <(cat <<EOF
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
) 2>/dev/null
    else
        run_openssl openssl x509 -req -days "${CERT_DAYS}" \
            -in "${dir}/int-ca.csr" \
            -CA "${CA_PATH}/ca.crt" -CAkey "${CA_PATH}/ca.key" \
            -CAcreateserial \
            -out "$(int_ca_crt "$uid")" \
            -extfile <(cat <<EOF
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
)
    fi
    local rc=$?
    [ $rc -ne 0 ] && { err "Не удалось подписать промежуточный CA."; return 1; }

    chmod 644 "$(int_ca_crt "$uid")"
    rm -f "${dir}/int-ca.csr" "${dir}/int-ca.srl"
    db_write "$uid" "int_ca_path" "$dir"
}

sign_client_with_int_ca() {
    local uid="$1" cert_dir="$2" days="$3"
    run_openssl openssl x509 -req \
        -in "${cert_dir}/client.csr" \
        -CA "$(int_ca_crt "$uid")" \
        -CAkey "$(int_ca_key "$uid")" \
        -CAcreateserial \
        -out "${cert_dir}/client.crt" \
        -days "${days}" \
        -extfile <(cat <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
)
}

# =============================================================================
#  CHAIN VERIFICATION — validates cert chains after signing
# =============================================================================
verify_chain() {
    local cert_dir="$1" uid="$2"
    local int_crt; int_crt=$(int_ca_crt "$uid")
    local ca_crt="${CA_PATH}/ca.crt"

    if [ ! -f "${cert_dir}/client.crt" ] || [ ! -f "$int_crt" ] || [ ! -f "$ca_crt" ]; then
        err "Проверка цепочки: отсутствуют файлы"
        return 1
    fi
    local chain_tmp; chain_tmp=$(mktemp)
    cat "$int_crt" "$ca_crt" > "$chain_tmp"
    if ! openssl verify -CAfile "$chain_tmp" "${cert_dir}/client.crt" >/dev/null 2>&1; then
        rm -f "$chain_tmp"
        err "Проверка цепочки НЕ ПРОЙДЕНА для ${cert_dir}/client.crt"
        return 1
    fi
    rm -f "$chain_tmp"
    return 0
}

# =============================================================================
#  BUNDLE (shared or per-service)
# =============================================================================
bundle_file() {
    if [ "$BUNDLE_MODE" = "per-service" ] && [ -n "${1:-}" ]; then
        echo "${CA_PATH}/clients-bundle-${1}.crt"
    else
        echo "${CA_PATH}/clients-bundle.crt"
    fi
}

rebuild_bundle() {
    local target_svc="${1:-}"
    local uid="" names; names=$(db_list_names)
    local count=0

    if [ "$BUNDLE_MODE" = "per-service" ]; then
        # Build a separate bundle for each service that has certs
        local services_done=""
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
        # Shared bundle — original behavior
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
        chmod 644 "$tmp"
        mv "$tmp" "$bundle"
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
    chmod 644 "$tmp"
    mv "$tmp" "$bundle"
    touch "$bundle"
}

# =============================================================================
#  CA
# =============================================================================
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
    if [ "$CA_KEY_ENCRYPTED" = "1" ]; then
        printf '%s\n' "${MTLS_CA_PASSPHRASE:-}" | openssl ca -config "$(ca_cnf)" -gencrl \
            -passin stdin -out "$(ca_crl)" 2>/dev/null
    else
        run_openssl openssl ca -config "$(ca_cnf)" -gencrl -out "$(ca_crl)"
    fi
    chmod 644 "$(ca_crl)"
}

ca_exists() { [ -f "${CA_PATH}/ca.crt" ] && [ -f "${CA_PATH}/ca.key" ]; }

# =============================================================================
#  HOST IP DETECTION — robust, multiple strategies
# =============================================================================
detect_host_ip() {
    local ip=""
    # 1. Explicit override
    ip="${MTLS_HOST_IP:-}"
    # 2. Docker bridge gateway (most common in container setups)
    [ -z "$ip" ] && ip=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    # 3. Fallback: docker0 bridge address
    [ -z "$ip" ] && ip=$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    # 4. Fallback: first non-loopback IPv4
    [ -z "$ip" ] && ip=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -1)
    # 5. Last resort
    [ -z "$ip" ] && ip="172.17.0.1"
    echo "$ip"
}

# =============================================================================
#  YAML VALIDATION — basic structural check after generation
# =============================================================================
validate_yaml() {
    local file="$1"
    [ -f "$file" ] || { err "YAML-файл не найден: $file"; return 1; }
    python3 - "$file" << 'PYEOF'
import sys
try:
    import json
    # Lightweight YAML structural validation without PyYAML:
    # check for basic indentation consistency and required keys
    with open(sys.argv[1]) as f:
        lines = f.readlines()
    has_tls = False
    has_http = False
    for line in lines:
        s = line.strip()
        if s.startswith('tls:'): has_tls = True
        if s.startswith('http:'): has_http = True
        # Check for tabs (YAML forbids tabs for indentation)
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

# =============================================================================
#  PATCH MODE (YAML modification for existing Traefik routers)
# =============================================================================
patch_apply() {
    local svc="$1" patch_file="$2" router_name="$3"
    local tls_opt="mtls-${svc}"
    python3 - "$patch_file" "$router_name" "$tls_opt" << 'PYEOF'
import sys
path, router, tls_opt = sys.argv[1:]
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
    with open(path, 'w') as f:
        f.write('\n'.join(out))
    print('patched')
else:
    print('not_found')
PYEOF
}

patch_remove() {
    local svc="$1" patch_file="$2" router_name="$3"
    local tls_opt="mtls-${svc}"
    python3 - "$patch_file" "$router_name" "$tls_opt" << 'PYEOF'
import sys
path, router, tls_opt = sys.argv[1:]
with open(path) as f:
    content = f.read()
if f'options: {tls_opt}' not in content:
    sys.exit(0)
lines = content.split('\n')
out = [line for line in lines if f'options: {tls_opt}' not in line]
with open(path, 'w') as f:
    f.write('\n'.join(out))
print('removed')
PYEOF
}

# =============================================================================
#  TRAEFIK CONFIG GENERATION
# =============================================================================
do_gen_traefik() {
    local out="${TRAEFIK_DYNAMIC_PATH}/${OUTPUT_FILE}"
    if ! check_path_access "$TRAEFIK_DYNAMIC_PATH" 2>/dev/null; then
        show_permission_error "$TRAEFIK_DYNAMIC_PATH"
        return 1
    fi
    mkdir -p "$TRAEFIK_DYNAMIC_PATH"
    if [ ! -f "${CA_PATH}/ca.crt" ]; then
        warn "CA не найден — конфиг Traefik не обновлён."; return 1
    fi
    rebuild_bundle
    local host_ip; host_ip=$(detect_host_ip)
    local svc_names; svc_names=$(svc_list_names)
    local has_new_svc=0
    if [ -n "$svc_names" ]; then
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            local mode; mode=$(svc_get "$svc" "mode")
            [ "$mode" = "new" ] && has_new_svc=1
        done <<< "$svc_names"
    fi
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
                target="${target//localhost/${host_ip}}"
                target="${target//127.0.0.1/${host_ip}}"
                echo "    ${svc}-mtls:"
                echo "      loadBalancer:"
                echo "        servers:"
                echo "          - url: \"${target}\""
            done <<< "$svc_names"
        fi
    } > "$out"
    chmod 644 "$out"; touch "$out"

    # Validate generated YAML
    if ! validate_yaml "$out"; then
        warn "Сгенерированный YAML может иметь структурные проблемы — проверьте: $out"
    fi

    ok "Конфиг Traefik: ${out}"
    local active_count=0
    local all_names; all_names=$(db_list_names)
    if [ -n "$all_names" ]; then
        active_count=$(while IFS= read -r _uid; do
            [ -z "$_uid" ] && continue
            local r; r=$(db_read "$_uid" "revoked")
            [ "$r" != "1" ] && echo "$_uid"
        done <<< "$all_names" | wc -l)
    fi
    info "Bundle: ${active_count} промежежуточных CA (режим: ${BUNDLE_MODE})"
}

# =============================================================================
#  BACKUP / RESTORE
# =============================================================================
do_backup() {
    local dest="${1:-${HOME}/mtls-backup-$(date '+%Y%m%d-%H%M%S').tar.gz}"
    local tmp_list; tmp_list=$(mktemp)
    {
        echo "$CONFIG_FILE"
        echo "$DB_FILE"
        echo "$SERVICES_FILE"
        echo "$AUDIT_FILE"
        [ -f "$CA_PATH/ca.crt" ] && find "$CA_PATH" -type f 2>/dev/null
    } > "$tmp_list"
    tar czf "$dest" -T "$tmp_list" 2>/dev/null
    rm -f "$tmp_list"
    chmod 600 "$dest"
    ok "Резервная копия создана: $dest"
    audit_log "backup" "$dest"
}

do_restore() {
    local src="$1"
    [ -f "$src" ] || { err "Файл резервной копии не найден: $src"; return 1; }
    warn "Это перезапишет CA, БД и конфиг. Продолжить?"
    ask_yn "Восстановить из $src?" || { info "Отменено."; return 0; }
    local tmp_dir; tmp_dir=$(mktemp -d)
    tar xzf "$src" -C "$tmp_dir" 2>/dev/null
    # Restore state files
    [ -f "${tmp_dir}${CONFIG_FILE}" ] && cp "${tmp_dir}${CONFIG_FILE}" "$CONFIG_FILE"
    [ -f "${tmp_dir}${DB_FILE}" ] && cp "${tmp_dir}${DB_FILE}" "$DB_FILE"
    [ -f "${tmp_dir}${SERVICES_FILE}" ] && cp "${tmp_dir}${SERVICES_FILE}" "$SERVICES_FILE"
    [ -f "${tmp_dir}${AUDIT_FILE}" ] && cp "${tmp_dir}${AUDIT_FILE}" "$AUDIT_FILE"
    # Restore CA files
    if [ -d "${tmp_dir}${CA_PATH}" ]; then
        mkdir -p "$CA_PATH"
        cp -r "${tmp_dir}${CA_PATH}/"* "$CA_PATH/" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
    load_config
    ok "Восстановлено из: $src"
    audit_log "restore" "$src"
}

# =============================================================================
#  NOTIFICATIONS
# =============================================================================
send_notification() {
    local title="$1" body="$2"
    # Webhook
    if [ -n "$WEBHOOK_URL" ]; then
        curl -sS -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"title\": \"$title\", \"body\": \"$body\"}" \
            >/dev/null 2>&1 || true
    fi
}

# =============================================================================
#  CERT STATUS
# =============================================================================
cert_status() {
    local uid="$1"
    local revoked; revoked=$(db_read "$uid" "revoked")
    [ "$revoked" = "1" ] && echo "ОТОЗВАН" && return
    local expires; expires=$(db_read "$uid" "expires")
    local today exp diff
    today=$(date +%s 2>/dev/null || echo 0)
    exp=$(date -d "$expires" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$expires" +%s 2>/dev/null || echo 9999999999)
    diff=$(( (exp - today) / 86400 ))
    if   [ "$diff" -lt 0  ]; then echo "ИСТЁК"
    elif [ "$diff" -le "${EXPIRY_WARN_DAYS:-30}" ]; then echo "СКОРО (${diff}д)"
    else                          echo "АКТИВЕН"
    fi
}

cert_status_color() {
    case "$1" in
        АКТИВЕН)  echo "$GREEN" ;;
        ОТОЗВАН)  echo "$RED" ;;
        ИСТЁК)    echo "$RED" ;;
        *)        echo "$YELLOW" ;;
    esac
}

print_cert_table() {
    local names="$1"
    [ -z "$names" ] && return
    printf "  ${BOLD}%-4s %-20s %-14s %-11s %-11s %-16s %-20s${RESET}\n" "#" "Имя" "Сервис" "Создан" "Истекает" "Статус" "Заметка"
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

# =============================================================================
#  DEPS CHECK
# =============================================================================
check_deps() {
    local need_openssl=0 need_python=0
    command -v openssl >/dev/null 2>&1 || need_openssl=1
    command -v python3 >/dev/null 2>&1 || need_python=1
    [ "$need_openssl" -eq 0 ] && [ "$need_python" -eq 0 ] && return 0

    [ "$MTLS_NONINTERACTIVE" = "1" ] && {
        [ "$need_openssl" -eq 1 ] && cli_err "openssl не найден"
        [ "$need_python"  -eq 1 ] && cli_err "python3 не найден"
        exit 1
    }

    header
    section "Проверка зависимостей"
    [ "$need_openssl" -eq 1 ] && warn "openssl не найден"
    [ "$need_python"  -eq 1 ] && warn "python3 не найден"
    echo ""
    ask_yn "Установить автоматически?" || { err "openssl и python3 обязательны."; exit 1; }
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        [ "$need_openssl" -eq 1 ] && sudo apt-get install -y openssl
        [ "$need_python"  -eq 1 ] && sudo apt-get install -y python3
    elif command -v yum >/dev/null 2>&1; then
        [ "$need_openssl" -eq 1 ] && sudo yum install -y openssl
        [ "$need_python"  -eq 1 ] && sudo yum install -y python3
    elif command -v apk >/dev/null 2>&1; then
        [ "$need_openssl" -eq 1 ] && sudo apk add --no-cache openssl
        [ "$need_python"  -eq 1 ] && sudo apk add --no-cache python3
    elif command -v brew >/dev/null 2>&1; then
        [ "$need_openssl" -eq 1 ] && brew install openssl
        [ "$need_python"  -eq 1 ] && brew install python3
    else
        err "Не удалось определить пакетный менеджер. Установите вручную."
        exit 1
    fi
    ok "Готово."
}

# =============================================================================
#  CORE OPERATIONS (shared by TUI and CLI)
# =============================================================================
core_create_ca() {
    local cn="${1:-mTLS-Root-CA}" days="${2:-3650}" encrypt="${3:-0}"
    if ca_exists; then
        warn "CA уже существует: ${CA_PATH}/ca.crt"
        warn "Пересоздание CA аннулирует ВСЕ выпущенные сертификаты!"
        ask_yn "Пересоздать CA?" || return 1
    fi

    # Check if we can write to the CA path and Traefik dynamic path
    if ! check_path_access "$CA_PATH"; then return 1; fi
    if ! check_path_access "$TRAEFIK_DYNAMIC_PATH"; then return 1; fi

    mkdir -p "$CA_PATH" "${CA_PATH}/intermediates" 2>/dev/null || true
    chmod 700 "$CA_PATH" 2>/dev/null || true

    info "Генерация ключа CA (4096 бит)..."
    if [ "$encrypt" = "1" ]; then
        CA_KEY_ENCRYPTED=1
        if [ -z "${MTLS_CA_PASSPHRASE:-}" ]; then
            local pass; pass=$(ask_secret "Пароль для ключа CA")
            export MTLS_CA_PASSPHRASE="$pass"
        fi
        printf '%s\n' "${MTLS_CA_PASSPHRASE}" | openssl genrsa -aes256 -out "${CA_PATH}/ca.key" -passout stdin 4096 2>/dev/null
    else
        openssl genrsa -out "${CA_PATH}/ca.key" 4096 2>/dev/null || run_openssl openssl genrsa -out "${CA_PATH}/ca.key" 4096
    fi
    chmod 600 "${CA_PATH}/ca.key"

    info "Генерация сертификата CA..."
    if [ "$encrypt" = "1" ]; then
        printf '%s\n' "$MTLS_CA_PASSPHRASE" | openssl req -new -x509 -days "$days" \
            -key "${CA_PATH}/ca.key" -passin stdin \
            -out "${CA_PATH}/ca.crt" \
            -subj "/CN=${cn}/O=mTLS-Manager/C=US" 2>/dev/null
    else
        openssl req -new -x509 -days "$days" -key "${CA_PATH}/ca.key" -out "${CA_PATH}/ca.crt" \
            -subj "/CN=${cn}/O=mTLS-Manager/C=US" 2>/dev/null
    fi

    info "Инициализация базы данных CA..."
    rm -f "${CA_PATH}/index.txt" "${CA_PATH}/index.txt.attr" "${CA_PATH}/serial"
    ca_db_init; rebuild_crl

    db_write "__ca__" "cn" "$cn"
    db_write "__ca__" "days" "$days"
    db_write "__ca__" "created" "$(date '+%Y-%m-%d %H:%M:%S')"
    save_config

    echo ""
    ok "CA создан!"
    echo -e "    ${DIM}Ключ : ${CA_PATH}/ca.key${RESET}"
    echo -e "    ${DIM}Серт : ${CA_PATH}/ca.crt${RESET}"
    audit_log "ca_create" "cn=${cn} days=${days} encrypted=${encrypt}"
    do_gen_traefik
}

core_issue_cert() {
    local service="$1" cert_name="$2" days="${3:-$CERT_DAYS}" note="${4:-}" p12_pass="${5:-}"
    local uid="${service}__${cert_name}"
    local existing; existing=$(db_read "$uid" "created")
    local ex_rev; ex_rev=$(db_read "$uid" "revoked")

    if [ -n "$existing" ] && [ "$ex_rev" != "1" ]; then
        warn "Сертификат '${cert_name}' для '${service}' уже существует."
        ask_yn "Пересоздать?" || return 1
        db_write "$uid" "revoked" "1"; rebuild_bundle
    fi

    # Check write access to CLIENTS_PATH and CA_PATH (intermediate CA is
    # created under $CA_PATH/intermediates/) before generating any files.
    if ! check_path_access "$CLIENTS_PATH"; then
        return 1
    fi
    if ! check_path_access "$CA_PATH"; then
        return 1
    fi

    local cert_dir="${CLIENTS_PATH}/${service}/${cert_name}"
    mkdir -p "$cert_dir"; chmod 700 "$cert_dir" 2>/dev/null || true

    info "Генерация ключа (2048 бит)..."
    openssl genrsa -out "${cert_dir}/client.key" 2048 2>/dev/null; chmod 600 "${cert_dir}/client.key"

    info "Создание CSR..."
    openssl req -new -key "${cert_dir}/client.key" -out "${cert_dir}/client.csr" \
        -subj "/CN=${cert_name}/O=${service}/C=US" 2>/dev/null

    info "Создание промежуточного CA для ${cert_name}..."
    create_int_ca "$uid" "$cert_name" "$service" || return 1

    info "Подписание клиентского сертификата..."
    sign_client_with_int_ca "$uid" "$cert_dir" "$days"
    if [ ! -f "${cert_dir}/client.crt" ]; then
        err "Ошибка подписания!"
        rm -rf "$cert_dir"
        [ -d "$(int_ca_dir "$uid")" ] && rm -rf "$(int_ca_dir "$uid")"
        return 1
    fi

    # Chain verification
    if ! verify_chain "$cert_dir" "$uid"; then
        err "Проверка цепочки сертификата не пройдена — отмена."
        rm -rf "$cert_dir"
        rm -rf "$(int_ca_dir "$uid")"
        return 1
    fi
    ok "Цепочка проверена."

    rebuild_crl

    info "Создание .p12..."
    if [ -n "$p12_pass" ]; then
        openssl pkcs12 -export -out "${cert_dir}/client.p12" \
            -inkey "${cert_dir}/client.key" -in "${cert_dir}/client.crt" \
            -certfile "${CA_PATH}/ca.crt" -passout "pass:${p12_pass}" 2>/dev/null
    else
        openssl pkcs12 -export -out "${cert_dir}/client.p12" \
            -inkey "${cert_dir}/client.key" -in "${cert_dir}/client.crt" \
            -certfile "${CA_PATH}/ca.crt" -passout pass: 2>/dev/null
    fi
    rm -f "${cert_dir}/client.csr"

    local serial expiry
    serial=$(openssl x509 -serial -noout -in "${cert_dir}/client.crt" 2>/dev/null | cut -d= -f2)
    expiry=$(openssl x509 -enddate -noout -in "${cert_dir}/client.crt" 2>/dev/null | cut -d= -f2)
    expiry=$(date -d "$expiry" '+%Y-%m-%d' 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" '+%Y-%m-%d' 2>/dev/null || echo "$expiry")

    local note_val="${note}"; [ -z "$note_val" ] && note_val="—"
    db_write "$uid" "name" "$cert_name"
    db_write "$uid" "service" "$service"
    db_write "$uid" "days" "$days"
    db_write "$uid" "note" "$note_val"
    db_write "$uid" "created" "$(date '+%Y-%m-%d')"
    db_write "$uid" "expires" "$expiry"
    db_write "$uid" "revoked" "0"
    db_write "$uid" "path" "$cert_dir"
    db_write "$uid" "serial" "$serial"

    info "Обновление bundle и конфига Traefik..."
    do_gen_traefik >/dev/null 2>&1 || true

    # Apply patch if service is in patch mode
    local svc_mode; svc_mode=$(svc_get "$service" "mode")
    if [ "$svc_mode" = "patch" ]; then
        local pfile; pfile=$(svc_get "$service" "patch_file")
        local prouter; prouter=$(svc_get "$service" "patch_router")
        info "Применение патча к ${pfile} (роутер: ${prouter})..."
        local result; result=$(patch_apply "$service" "$pfile" "$prouter")
        case "$result" in
            patched)         ok "Патч применён." ;;
            already_patched) info "Патч уже был применён." ;;
            not_found)       warn "Роутер '${prouter}' не найден в файле." ;;
        esac
    fi

    echo ""
    ok "Сертификат создан!"
    hr
    echo -e "  ${DIM}${cert_dir}/client.p12${RESET}"
    echo -e "  Серийный №   : $serial"
    echo -e "  Годен до     : $expiry"
    echo -e "  Заметка      : $note_val"
    [ -n "$p12_pass" ] && echo -e "  Пароль P12   : ${GREEN}задан${RESET}" || echo -e "  Пароль P12   : ${YELLOW}не задан${RESET}"

    audit_log "cert_create" "uid=${uid} service=${service} expires=${expiry}"
    return 0
}

core_revoke_cert() {
    local uid="$1"
    local crevoked; crevoked=$(db_read "$uid" "revoked")
    if [ "$crevoked" = "1" ]; then
        warn "Сертификат уже отозван."
        return 1
    fi
    db_write "$uid" "revoked" "1"
    rebuild_bundle
    do_gen_traefik >/dev/null 2>&1 || true
    local cname; cname=$(db_read "$uid" "name")
    ok "Сертификат '${cname}' отозван."
    audit_log "cert_revoke" "uid=${uid}"
}

core_delete_cert() {
    local uid="$1"
    local crevoked; crevoked=$(db_read "$uid" "revoked")
    if [ "$crevoked" != "1" ]; then
        warn "Сертификат ещё не отозван — сначала отзыв."
        core_revoke_cert "$uid" || true
    fi
    local cpath cint_dir cname
    cpath=$(db_read "$uid" "path")
    cint_dir=$(db_read "$uid" "int_ca_path")
    cname=$(db_read "$uid" "name")

    if [ -n "$cpath" ] && [ -d "$cpath" ]; then
        rm -rf "$cpath"
        ok "Файлы сертификата удалены: ${cpath}"
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
        ok "Промежуточный CA удалён: ${int_dir_to_remove}"
    fi
    db_delete "$uid"
    ok "Запись удалена из базы данных."
    audit_log "cert_delete" "uid=${uid} name=${cname}"
}

# Full service removal: revoke + delete all client certificates, remove generated
# Traefik router/service block, remove patch from external file, delete the service
# folder on disk, and finally remove the service from the services DB.
# Usage: core_delete_service_full <service_name>
core_delete_service_full() {
    local svc="$1"
    [ -z "$svc" ] && { err "Требуется имя сервиса."; return 1; }

    local svc_mode; svc_mode=$(svc_get "$svc" "mode")
    local deleted_certs=0
    local all_names; all_names=$(db_list_names)

    # 1. Revoke + delete every certificate that belongs to this service
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
    [ "$deleted_certs" -gt 0 ] && ok "Удалено ${deleted_certs} сертификат(ов) для '${svc}'."

    # 2. Remove patch from external file (patch mode)
    if [ "$svc_mode" = "patch" ]; then
        local dpf dpr
        dpf=$(svc_get "$svc" "patch_file")
        dpr=$(svc_get "$svc" "patch_router")
        if [ -n "$dpf" ] && [ -f "$dpf" ]; then
            info "Удаление патча из ${dpf} (роутер: ${dpr})..."
            patch_remove "$svc" "$dpf" "$dpr"
            ok "Патч удалён из ${dpf##*/}."
        fi
    fi

    # 3. Remove the generated Traefik config block for this service (new mode).
    #    The simplest reliable way is to regenerate the whole file after the
    #    service is gone from the DB — do_gen_traefik() handles that.
    # 4. Remove the service folder on disk (client certs)
    local svc_dir="${CLIENTS_PATH}/${svc}"
    if [ -d "$svc_dir" ]; then
        rm -rf "$svc_dir"
        ok "Удалён каталог клиентов: ${svc_dir}"
    fi

    # 4b. Remove any orphaned intermediate CA directories for this service.
    #     Intermediate CAs are stored as $CA_PATH/intermediates/<service>__<name>
    #     and may not always have an int_ca_path recorded in the DB (e.g. if the
    #     DB entry was lost). Scan the folder to be thorough.
    local int_base="${CA_PATH}/intermediates"
    if [ -d "$int_base" ]; then
        local orphaned=0
        while IFS= read -r -d '' int_dir; do
            local base; base=$(basename "$int_dir")
            # intermediate dirs are named <service>__<certname>
            case "$base" in
                "${svc}__"*) rm -rf "$int_dir"; orphaned=$((orphaned + 1)) ;;
            esac
        done < <(find "$int_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
        [ "$orphaned" -gt 0 ] && ok "Удалено ${orphaned} осиротевших каталогов промежуточных CA."
    fi

    # 5. Remove the service from the services DB
    svc_delete "$svc"

    # 6. Regenerate Traefik config (router/service block disappears)
    do_gen_traefik >/dev/null 2>&1 || true

    ok "Сервис '${svc}' полностью удалён."
    audit_log "service_delete_full" "name=${svc} certs=${deleted_certs} mode=${svc_mode}"
    return 0
}

core_renew_cert() {
    local uid="$1" days="${2:-$CERT_DAYS}"
    local cname csvc note
    cname=$(db_read "$uid" "name")
    csvc=$(db_read "$uid" "service")
    note=$(db_read "$uid" "note")
    [ -z "$cname" ] && { err "Сертификат не найден: $uid"; return 1; }

    info "Продление '${cname}' для сервиса '${csvc}' (${days} дней)..."
    # Revoke old, then re-issue with same name
    db_write "$uid" "revoked" "1"
    rebuild_bundle
    local p12_pass="${MTLS_P12_PASSWORD:-}"
    core_issue_cert "$csvc" "$cname" "$days" "$note" "$p12_pass"
    audit_log "cert_renew" "uid=${uid} days=${days}"
}

core_scan_expiry() {
    local names; names=$(db_list_names)
    [ -z "$names" ] && { info "Нет сертификатов для сканирования."; return 0; }
    local expiring="" expired="" alerts="" uid=""
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        local revoked; revoked=$(db_read "$uid" "revoked")
        [ "$revoked" = "1" ] && continue
        local status; status=$(cert_status "$uid")
        local cname csvc cexp
        cname=$(db_read "$uid" "name"); csvc=$(db_read "$uid" "service"); cexp=$(db_read "$uid" "expires")
        case "$status" in
            ИСТЁК)
                expired="${expired}- ${cname} (${csvc}) истёк ${cexp}\n"
                ;;
            СКОРО*)
                expiring="${expiring}- ${cname} (${csvc}) истекает ${cexp}\n"
                ;;
        esac
    done <<< "$names"

    if [ -n "$expiring" ] || [ -n "$expired" ]; then
        if [ -n "$expired" ]; then
            cli_warn "ИСТЕКШИЕ сертификаты:"
            echo -ne "$expired" >&2
        fi
        if [ -n "$expiring" ]; then
            cli_warn "Истекающие сертификаты (в течение ${EXPIRY_WARN_DAYS} дней):"
            echo -ne "$expiring" >&2
        fi
        if [ -n "$WEBHOOK_URL" ]; then
            alerts="${expired}${expiring}"
            send_notification "mTLS: предупреждение об истечении" "$(echo -ne "$alerts" | tr -d '\n')"
            ok "Уведомления отправлены."
        fi
        audit_log "scan_expiry" "expired=$(echo -ne "$expired" | wc -l) expiring=$(echo -ne "$expiring" | wc -l)"
        return 1
    else
        ok "Все сертификаты в порядке."
        return 0
    fi
}

core_verify_cert() {
    local uid="$1"
    local cpath; cpath=$(db_read "$uid" "path")
    local cname; cname=$(db_read "$uid" "name")
    [ -z "$cpath" ] && { err "Сертификат не найден: $uid"; return 1; }
    local cert_file="${cpath}/client.crt"
    [ -f "$cert_file" ] || { err "Файл сертификата отсутствует: $cert_file"; return 1; }

    echo -e "  ${BOLD}Сертификат:${RESET} ${cname}"
    echo -e "  ${BOLD}Серийный №:${RESET} $(openssl x509 -serial -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
    echo -e "  ${BOLD}Субъект:${RESET}    $(openssl x509 -subject -noout -in "$cert_file" 2>/dev/null | sed 's/subject=//')"
    echo -e "  ${BOLD}Эмитент:${RESET}   $(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null | sed 's/issuer=//')"
    echo -e "  ${BOLD}Действует с:${RESET} $(openssl x509 -startdate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
    echo -e "  ${BOLD}Действует до:${RESET} $(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"

    local int_crt; int_crt=$(int_ca_crt "$uid")
    local chain_tmp; chain_tmp=$(mktemp)
    cat "$int_crt" "${CA_PATH}/ca.crt" > "$chain_tmp"
    if openssl verify -CAfile "$chain_tmp" "$cert_file" >/dev/null 2>&1; then
        ok "Проверка цепочки: ПРОЙДЕНА"
    else
        err "Проверка цепочки: НЕ ПРОЙДЕНА"
    fi
    rm -f "$chain_tmp"
    echo ""
    echo -e "  ${BOLD}Отпечаток (SHA-256):${RESET}"
    openssl x509 -fingerprint -sha256 -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 | tr -d ' '
}

# =============================================================================
#  HEADER (TUI only)
# =============================================================================
header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "  ${BOLD}${BLUE}Менеджер mTLS-сертификатов${RESET} ${DIM}v2.0${RESET}"
    echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"
    echo ""
}

# =============================================================================
#  TUI MENUS
# =============================================================================
menu_cert_create() {
    header; section "Создать новый сертификат"
    ensure_ca || return
    local svc_names; svc_names=$(svc_list_names)
    if [ -z "$svc_names" ]; then warn "Нет сервисов. Сначала добавьте сервис (пункт 4)."; pause; return; fi
    echo -e "  ${BOLD}Доступные сервисы:${RESET}"; echo ""
    local i=1 svc_arr=()
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        local smode; smode=$(svc_get "$s" "mode")
        local label=""; [ "$smode" = "patch" ] && label="${DIM} [patch]${RESET}"
        echo -e "    ${CYAN}${i})${RESET}  $s${label}"
        svc_arr+=("$s"); i=$((i + 1))
    done <<< "$svc_names"; echo ""
    local svc_idx; svc_idx=$(ask "Выберите сервис (номер)" "1")
    local service="${svc_arr[$((svc_idx - 1))]}"; if [ -z "$service" ]; then err "Неверный номер."; pause; return; fi
    echo ""
    local cert_name; cert_name=$(ask "Имя сертификата (латиница, без пробелов)" "")
    cert_name="${cert_name// /-}"
    if [ -z "$cert_name" ]; then err "Имя не может быть пустым."; pause; return; fi
    local days note
    days=$(ask "Срок действия (дней)" "$CERT_DAYS")
    note=$(ask "Заметка (для кого/чего)" "")
    echo ""; echo -e "  ${BOLD}Пароль для .p12:${RESET}"
    local pass1 pass2
    pass1=$(ask_secret "Введите пароль")
    pass2=$(ask_secret "Повторите пароль")
    if [ "$pass1" != "$pass2" ]; then err "Пароли не совпадают."; pause; return; fi
    core_issue_cert "$service" "$cert_name" "$days" "$note" "$pass1"
    pause
}

menu_cert_delete() {
    header; section "Отозвать и удалить сертификат"
    local names; names=$(db_list_names)
    if [ -z "$names" ]; then warn "Нет сертификатов."; pause; return; fi
    print_cert_table "$names"; echo ""

    local cert_arr=() uid=""
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        cert_arr+=("$uid")
    done <<< "$names"

    echo -e "  ${BOLD}0)${RESET}  Назад"; echo ""
    local choice; choice=$(ask "Выберите номер сертификата" "")
    [ "$choice" = "0" ] || [ -z "$choice" ] && return

    local idx=$(( choice - 1 ))
    local uid="${cert_arr[$idx]}"
    if [ -z "$uid" ]; then err "Неверный номер."; pause; return; fi

    local cname csvc crevoked
    cname=$(db_read "$uid" "name")
    csvc=$(db_read "$uid" "service")
    crevoked=$(db_read "$uid" "revoked")

    echo ""
    echo -e "  ${BOLD}Выбран:${RESET} ${cname:-<неизвестно>}  ${DIM}(сервис: ${csvc:-<неизвестно>})${RESET}"
    echo ""

    if [ "$crevoked" != "1" ]; then
        warn "Сертификат будет ОТРОЗВАН (доступ будет заблокирован)."
        warn "Вернитесь сюда снова, чтобы УДАЛИТЬ файлы с диска."
        echo ""
        ask_yn "Отозвать сертификат '${cname}'?" || { pause; return; }
        core_revoke_cert "$uid"
        ok "Сертификат отозван. Вернитесь снова для удаления файлов."
    else
        warn "Сертификат уже отозван. Файлы будут удалены с диска."
        echo ""
        ask_yn "Удалить файлы '${cname}' с диска? (необратимо)" || { ok "Файлы сохранены."; pause; return; }
        core_delete_cert "$uid"
    fi
    pause
}

menu_cert_list() {
    header; section "Список сертификатов"
    local names; names=$(db_list_names)
    if [ -z "$names" ]; then warn "Нет сертификатов."; pause; return; fi
    print_cert_table "$names"
    local total; total=$(db_count)
    echo ""; echo -e "  ${DIM}Всего: $total${RESET}"; echo ""
    if ca_exists; then
        local ca_cn ca_created
        ca_cn=$(db_read "__ca__" "cn"); ca_created=$(db_read "__ca__" "created")
        echo -e "  ${DIM}CA     : $ca_cn  (создан: $ca_created)${RESET}"
        local bundle_path; bundle_path=$(bundle_file)
        if [ -f "$bundle_path" ]; then
            local bundle_count; bundle_count=$(grep -c "BEGIN CERTIFICATE" "$bundle_path" 2>/dev/null || echo "?")
            echo -e "  ${DIM}Bundle : ${bundle_path}  ${GREEN}✔${RESET}  ${DIM}(${bundle_count} промежуточных CA)${RESET}"
        fi
    fi
    pause
}

menu_services() {
    while true; do
        header; section "Управление сервисами"
        local svc_names; svc_names=$(svc_list_names)
        if [ -n "$svc_names" ]; then
            printf "  ${BOLD}%-4s %-18s %-8s %-26s %-20s${RESET}\n" "#" "Имя" "Режим" "Домен/Файл" "Роутер/Target"; hr
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
            warn "Сервисы не добавлены."; echo ""
        fi
        echo -e "  ${BOLD}1)${RESET}  Добавить сервис [new]    — новый домен"
        echo -e "  ${BOLD}2)${RESET}  Добавить сервис [patch]  — существующий роутер"
        echo -e "  ${BOLD}3)${RESET}  Удалить сервис           — только из БД"
        echo -e "  ${BOLD}4)${RESET}  Обновить конфиг Traefik"
        echo -e "  ${BOLD}5)${RESET}  Полное удаление сервиса  — отзыв+удаление всех сертификатов, удаление файлов и блока Traefik"
        echo -e "  ${BOLD}0)${RESET}  Назад"
        local c; c=$(menu_choice)
        case "$c" in
            1)
                echo ""
                local sname sdomain starget
                sname=$(ask "Имя сервиса" ""); sname="${sname// /-}"
                sdomain=$(ask "Домен (напр.: myapp.example.com)" "")
                starget=$(ask "Target URL  (напр.: http://localhost:3000)" "")
                if [ -z "$sname" ] || [ -z "$sdomain" ] || [ -z "$starget" ]; then
                    err "Все поля обязательны."
                else
                    svc_add "$sname" "$sdomain" "$starget" "new" "" ""
                    do_gen_traefik; ok "Сервис '${sname}' добавлен."
                fi
                pause ;;
            2)
                echo ""
                echo -e "  ${DIM}Файлы в ${TRAEFIK_DYNAMIC_PATH}/:${RESET}"
                ls "${TRAEFIK_DYNAMIC_PATH}"/*.yml "${TRAEFIK_DYNAMIC_PATH}"/*.yaml 2>/dev/null \
                    | while read -r f; do echo -e "    ${CYAN}${f##*/}${RESET}"; done
                echo ""
                local sname spf spr
                sname=$(ask "Имя сервиса (будет mtls-<имя>)" ""); sname="${sname// /-}"
                spf=$(ask "Файл конфига (полный путь)" "${TRAEFIK_DYNAMIC_PATH}/dokploy.yml")
                echo ""; echo -e "  ${DIM}Роутеры в файле:${RESET}"
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
                spr=$(ask "Имя роутера (точно как в файле)" "")
                if [ -z "$sname" ] || [ -z "$spf" ] || [ -z "$spr" ]; then
                    err "Все поля обязательны."
                elif [ ! -f "$spf" ]; then
                    err "Файл не найден: $spf"
                else
                    svc_add "$sname" "" "" "patch" "$spf" "$spr"
                    do_gen_traefik
                    ok "Сервис '${sname}' добавлен [patch]. Создайте сертификат — патч применится автоматически."
                fi
                pause ;;
            3)
                [ -z "$svc_names" ] && { warn "Нет сервисов."; pause; continue; }
                echo ""
                local s_arr=()
                while IFS= read -r s; do [ -z "$s" ] && continue; s_arr+=("$s"); done <<< "$svc_names"
                local sc; sc=$(ask "Номер сервиса для удаления" "")
                [ -z "$sc" ] && { pause; continue; }
                local sdel="${s_arr[$((sc - 1))]}"
                if [ -n "$sdel" ] && ask_yn "Удалить сервис '$sdel'?"; then
                    local dm; dm=$(svc_get "$sdel" "mode")
                    if [ "$dm" = "patch" ]; then
                        local dpf; dpf=$(svc_get "$sdel" "patch_file")
                        local dpr; dpr=$(svc_get "$sdel" "patch_router")
                        info "Удаление патча из ${dpf}..."
                        patch_remove "$sdel" "$dpf" "$dpr"; ok "Патч удалён."
                    fi
                    svc_delete "$sdel"; do_gen_traefik; ok "Удалён."
                fi
                pause ;;
            4) do_gen_traefik; pause ;;
            5)
                [ -z "$svc_names" ] && { warn "Нет сервисов."; pause; continue; }
                echo ""
                local s_arr5=()
                while IFS= read -r s; do [ -z "$s" ] && continue; s_arr5+=("$s"); done <<< "$svc_names"
                local sc5; sc5=$(ask "Номер сервиса для полного удаления" "")
                [ -z "$sc5" ] && { pause; continue; }
                local sdel5="${s_arr5[$((sc5 - 1))]}"
                if [ -z "$sdel5" ]; then err "Неверный номер."; pause; continue; fi
                echo ""
                warn "ПОЛНОЕ УДАЛЕНИЕ:"
                warn "  - отозвать и удалить ВСЕ клиентские сертификаты для '${sdel5}'"
                warn "  - удалить клиентские файлы с диска (${CLIENTS_PATH}/${sdel5})"
                warn "  - удалить ВСЕ промежуточные CA для '${sdel5}' (${CA_PATH}/intermediates/${sdel5}__*)"
                warn "  - удалить сгенерированный блок роутера/сервиса Traefik (режим new)"
                warn "  - удалить mTLS-патч из внешнего конфига (режим patch)"
                warn "  - удалить сервис из базы данных"
                echo ""
                ask_yn "Продолжить ПОЛНОЕ удаление '${sdel5}'? (необратимо)" || { ok "Отменено."; pause; continue; }
                core_delete_service_full "$sdel5"
                pause ;;
            0) return ;;
        esac
    done
}

menu_settings() {
    while true; do
        header; section "Настройка путей"
        echo -e "  ${BOLD}1)${RESET}  Dynamic-конфиги Traefik\n     ${CYAN}${TRAEFIK_DYNAMIC_PATH}${RESET}\n"
        echo -e "  ${BOLD}2)${RESET}  Каталог CA\n     ${CYAN}${CA_PATH}${RESET}\n"
        echo -e "  ${BOLD}3)${RESET}  Каталог клиентских сертификатов\n     ${CYAN}${CLIENTS_PATH}${RESET}\n"
        echo -e "  ${BOLD}4)${RESET}  Имя файла конфига\n     ${CYAN}${OUTPUT_FILE}${RESET}\n"
        echo -e "  ${BOLD}5)${RESET}  Срок по умолчанию (дней)\n     ${CYAN}${CERT_DAYS}${RESET}\n"
        echo -e "  ${BOLD}6)${RESET}  Предупреждение об истечении (дней)\n     ${CYAN}${EXPIRY_WARN_DAYS}${RESET}\n"
        echo -e "  ${BOLD}7)${RESET}  Режим bundle\n     ${CYAN}${BUNDLE_MODE}${RESET} ${DIM}(shared | per-service)${RESET}\n"
        echo -e "  ${BOLD}8)${RESET}  Уведомления\n     ${CYAN}webhook=${WEBHOOK_URL:-нет}${RESET}\n"
        echo -e "  ${BOLD}9)${RESET}  Шифрование ключа CA\n     ${CYAN}${CA_KEY_ENCRYPTED}${RESET} ${DIM}(0=выкл 1=вкл)${RESET}\n"
        hr
        echo -e "  ${DIM}Пресеты:${RESET}"
        echo -e "  ${BOLD}p1)${RESET} Dokploy   /etc/dokploy/traefik/dynamic"
        echo -e "  ${BOLD}p2)${RESET} Traefik   /etc/traefik/dynamic"
        echo -e "  ${BOLD}p3)${RESET} Локально  ./traefik-local"
        hr; echo ""
        echo -e "  ${BOLD}0)${RESET}  Назад"
        local c; c=$(menu_choice)
        case "$c" in
            1) TRAEFIK_DYNAMIC_PATH=$(ask "Новый путь" "$TRAEFIK_DYNAMIC_PATH"); save_config; ok "Сохранено."; pause ;;
            2) CA_PATH=$(ask "Новый путь" "$CA_PATH"); save_config; ok "Сохранено."; pause ;;
            3) CLIENTS_PATH=$(ask "Новый путь" "$CLIENTS_PATH"); save_config; ok "Сохранено."; pause ;;
            4) OUTPUT_FILE=$(ask "Новое имя файла" "$OUTPUT_FILE"); save_config; ok "Сохранено."; pause ;;
            5) CERT_DAYS=$(ask "Дней" "$CERT_DAYS"); save_config; ok "Сохранено."; pause ;;
            6) EXPIRY_WARN_DAYS=$(ask "Дней" "$EXPIRY_WARN_DAYS"); save_config; ok "Сохранено."; pause ;;
            7) BUNDLE_MODE=$(ask "Режим bundle (shared | per-service)" "$BUNDLE_MODE"); save_config; ok "Сохранено."; pause ;;
            8)
                echo ""
                WEBHOOK_URL=$(ask "URL webhook (пусто=выкл)" "$WEBHOOK_URL")
                save_config; ok "Настройки уведомлений сохранены."; pause ;;
            9)
                echo ""
                CA_KEY_ENCRYPTED=$(ask "Шифровать ключ CA? (0=выкл 1=вкл)" "$CA_KEY_ENCRYPTED")
                save_config; ok "Сохранено."; pause ;;
            p1) TRAEFIK_DYNAMIC_PATH="/etc/dokploy/traefik/dynamic"; CA_PATH="/etc/dokploy/traefik/dynamic/certificates/ca"; CLIENTS_PATH="/etc/dokploy/traefik/dynamic/certificates/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Пресет Dokploy применён."; pause ;;
            p2) TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"; CA_PATH="/etc/traefik/certs/mtls"; CLIENTS_PATH="/etc/traefik/certs/mtls/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Пресет Traefik применён."; pause ;;
            p3) TRAEFIK_DYNAMIC_PATH="$(pwd)/traefik-local/dynamic"; CA_PATH="$(pwd)/traefik-local/certs/mtls"; CLIENTS_PATH="$(pwd)/traefik-local/certs/mtls/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Локальный пресет применён."; pause ;;
            0) return ;;
        esac
    done
}

do_create_ca_tui() {
    header; section "Создать корневой CA"
    local cn days encrypt
    cn=$(ask "Имя CA (CN)" "mTLS-Root-CA")
    days=$(ask "Срок действия CA (дней)" "3650")
    echo ""
    ask_yn "Шифровать ключ CA паролем?" && encrypt="1" || encrypt="0"
    echo ""
    core_create_ca "$cn" "$days" "$encrypt"
    pause
}

menu_access() {
    while true; do
        header; section "Управление доступом — кто может использовать скрипт"
        local is_root=0
        [ "$(id -u)" -eq 0 ] && is_root=1

        if [ "$is_root" -eq 1 ]; then
            echo -e "  ${GREEN}Запущено от root — полный доступ${RESET}"
        else
            local current_user; current_user="${SUDO_USER:-${USER:-$(whoami)}}"
            if acl_check; then
                echo -e "  ${GREEN}У вас (${current_user}) есть доступ${RESET}"
            else
                echo -e "  ${RED}У вас (${current_user}) НЕТ доступа${RESET}"
                echo -e "  ${DIM}Попросите root добавить вас: sudo mtls.sh users add ${current_user}${RESET}"
            fi
        fi
        echo ""

        # Show currently allowed users
        local allowed; allowed=$(acl_list)
        if [ -n "$allowed" ]; then
            echo -e "  ${BOLD}Разрешённые пользователи:${RESET}"
            while IFS= read -r u; do
                echo -e "    ${GREEN}✔${RESET}  $u"
            done <<< "$allowed"
        else
            echo -e "  ${DIM}Пользователи ещё не добавлены — только root может использовать скрипт.${RESET}"
        fi
        echo ""

        # Only root can manage the list
        if [ "$is_root" -eq 1 ]; then
            echo -e "  ${BOLD}1)${RESET}  Добавить пользователя"
            echo -e "  ${BOLD}2)${RESET}  Удалить пользователя"
            echo -e "  ${BOLD}3)${RESET}  Показать всех системных пользователей"
            echo -e "  ${BOLD}0)${RESET}  Назад"
            local c; c=$(menu_choice)
            case "$c" in
                1)
                    echo ""
                    echo -e "  ${DIM}Системные пользователи (UID >= 1000):${RESET}"
                    local sys_users; sys_users=$(list_system_users)
                    if [ -z "$sys_users" ]; then
                        warn "Обычные пользователи не найдены (UID >= 1000)."
                        echo -e "  ${DIM}Вы можете ввести имя вручную.${RESET}"
                        echo ""
                        local uname; uname=$(ask "Имя пользователя для добавления" "")
                        [ -n "$uname" ] && { acl_add "$uname"; ok "Пользователь '${uname}' добавлен."; audit_log "user_add" "$uname"; }
                    else
                        local i=1 user_arr=()
                        while IFS= read -r u; do
                            local mark=" "
                            local already; already=$(acl_list)
                            case "$already" in *"$u"*) mark="${GREEN}✔${RESET}" ;; esac
                            echo -e "    ${CYAN}${i})${RESET} ${mark}  $u"
                            user_arr+=("$u"); i=$((i + 1))
                        done <<< "$sys_users"
                        echo -e "    ${CYAN}m)${RESET}      Ручной ввод"
                        echo ""
                        local choice; choice=$(ask "Выберите пользователя (номер или 'm')" "")
                        if [ "$choice" = "m" ]; then
                            local uname; uname=$(ask "Имя пользователя" "")
                            [ -n "$uname" ] && { acl_add "$uname"; ok "Пользователь '${uname}' добавлен."; audit_log "user_add" "$uname"; }
                        elif [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#user_arr[@]}" ]; then
                            local selected="${user_arr[$((choice - 1))]}"
                            acl_add "$selected"; ok "Пользователь '${selected}' добавлен."; audit_log "user_add" "$selected"
                        else
                            err "Неверный выбор."
                        fi
                    fi
                    pause ;;
                2)
                    echo ""
                    [ -z "$allowed" ] && { warn "Список пользователей пуст."; pause; continue; }
                    echo -e "  ${BOLD}Разрешённые пользователи:${RESET}"
                    local i=1 u_arr=()
                    while IFS= read -r u; do
                        echo -e "    ${CYAN}${i})${RESET}  $u"
                        u_arr+=("$u"); i=$((i + 1))
                    done <<< "$allowed"
                    echo ""
                    local choice; choice=$(ask "Выберите пользователя для удаления" "")
                    if [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#u_arr[@]}" ]; then
                        local selected="${u_arr[$((choice - 1))]}"
                        acl_remove "$selected"; ok "Пользователь '${selected}' удалён."; audit_log "user_remove" "$selected"
                    else
                        err "Неверный выбор."
                    fi
                    pause ;;
                3)
                    echo ""
                    echo -e "  ${BOLD}Все системные пользователи (UID >= 1000):${RESET}"
                    echo ""
                    local sys_users; sys_users=$(list_system_users)
                    if [ -z "$sys_users" ]; then
                        warn "Обычные пользователи не найдены."
                    else
                        while IFS= read -r u; do
                            local mark=" "
                            local already; already=$(acl_list)
                            case "$already" in *"$u"*) mark="${GREEN}✔${RESET}" ;; esac
                            printf "    %-20s %s\n" "$u" "$mark"
                        done <<< "$sys_users"
                    fi
                    echo ""
                    pause ;;
                0) return ;;
            esac
        else
            echo -e "  ${DIM}Только root может управлять списком доступа.${RESET}"
            echo ""
            pause
            return
        fi
    done
}

ensure_ca() {
    if ! ca_exists; then
        warn "Корневой CA не найден."; echo ""
        ask_yn "Создать CA сейчас?" || { err "CA обязателен."; pause; return 1; }
        do_create_ca_tui
    fi
    ca_key_prompt_passphrase
    return 0
}

main_menu() {
    while true; do
        header
        local ca_status
        ca_exists && ca_status="${GREEN}CA ✔${RESET}" || ca_status="${RED}CA ✖ не создан${RESET}"
        local svc_count_val cert_count_val
        svc_count_val=$(svc_count); cert_count_val=$(db_count)
        echo -e "  ${DIM}${TRAEFIK_DYNAMIC_PATH}${RESET}"
        echo -e "  ${ca_status}   ${DIM}сервисов: ${svc_count_val}   сертификатов: ${cert_count_val}${RESET}"
        hr; echo ""
        echo -e "  ${BOLD}1)${RESET}  Создать сертификат"
        echo -e "  ${BOLD}2)${RESET}  Список сертификатов"
        echo -e "  ${BOLD}3)${RESET}  Отозвать / удалить сертификат"
        echo -e "  ${BOLD}4)${RESET}  Управление сервисами"
        echo -e "  ${BOLD}5)${RESET}  Создать / пересоздать CA"
        echo -e "  ${BOLD}6)${RESET}  Настройка путей"
        echo -e "  ${BOLD}7)${RESET}  Обновить конфиг Traefik"
        echo -e "  ${BOLD}8)${RESET}  Проверить истекающие сертификаты"
        echo -e "  ${BOLD}9)${RESET}  Резервная копия CA + базы"
        echo -e "  ${BOLD}10)${RESET} Управление доступом (пользователи)"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ${DIM}Выход${RESET}"
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
            10) menu_access ;;
            0) echo ""; exit 0 ;;
        esac
    done
}

# =============================================================================
#  CLI DISPATCHER
# =============================================================================
cli_usage() {
    cat <<'USAGE'
mtls.sh v2.0 — Менеджер mTLS-сертификатов

ИСПОЛЬЗОВАНИЕ:
  mtls.sh                            Интерактивное TUI-меню
  mtls.sh <команда> [опции]          CLI-режим

КОМАНДЫ:
  ca create [--cn ИМЯ] [--days N] [--encrypt]
      Создать корневой CA

  ca info
      Показать информацию о CA

  ca backup [--output ФАЙЛ]
      Резервная копия CA + БД + конфига в tar.gz

  ca restore --input ФАЙЛ
      Восстановление из резервной копии

  cert issue --service S --name N [--days D] [--note ТЕКСТ] [--pass P]
      Выпустить новый клиентский сертификат

  cert list [--json]
      Список всех сертификатов

  cert revoke --uid UID | --service S --name N
      Отозвать сертификат (файлы остаются на диске)

  cert delete --uid UID | --service S --name N
      Отозвать + удалить файлы сертификата с диска

  cert renew --uid UID [--days D]
      Продлить существующий сертификат (перевыпуск с тем же именем)

  cert verify --uid UID | --service S --name N
      Проверить цепочку сертификата и показать детали

  cert scan
      Проверить истекающие/истёкшие сертификаты, отправить уведомления

  service add --name N --domain D --target T [--mode new|patch]
      Добавить сервис (для patch: --patch-file F --router R)

  service list
      Список всех сервисов

  service delete --name N
      Удалить сервис (удалить из БД, снять patch если patch-режим)

  service delete-full --name N
      Полное удаление: отозвать+удалить все клиентские сертификаты,
      удалить клиентские файлы, удалить сгенерированный блок роутера/сервиса Traefik,
      снять patch, удалить сервис

  config show
      Показать текущую конфигурацию

  config set <ключ> <значение>
      Установить значение конфигурации

  gen
      Сгенерировать/обновить конфиг Traefik

  audit [--last N]
      Показать записи журнала аудита

  users list
      Показать список разрешённых пользователей

  users add <username>
      Добавить пользователя в список доступа (только root)

  users remove <username>
      Удалить пользователя из списка доступа (только root)

  users system
      Показать всех системных пользователей (UID >= 1000) и их статус доступа

  help
      Показать эту справку

ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ:
  MTLS_HOST_IP          Переопределить определённый IP хоста
  MTLS_CA_PASSPHRASE    Пароль ключа CA (для зашифрованных ключей)
  MTLS_P12_PASSWORD     Пароль .p12 по умолчанию (неинтерактивный выпуск)
  MTLS_NONINTERACTIVE   Установите в 1 для пропуска всех запросов

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
                    *) err "Неизвестная опция: $1"; exit 1 ;;
                esac
            done
            if [ "$encrypt" = "1" ] && [ -z "${MTLS_CA_PASSPHRASE:-}" ]; then
                info "Шифрование ключа CA включено — введите пароль:"
                export MTLS_CA_PASSPHRASE; MTLS_CA_PASSPHRASE=$(ask_secret "Пароль")
            fi
            core_create_ca "$cn" "$days" "$encrypt"
            ;;
        info)
            if ! ca_exists; then cli_err "CA не найден."; exit 1; fi
            local ca_cn ca_created ca_days
            ca_cn=$(db_read "__ca__" "cn"); ca_created=$(db_read "__ca__" "created")
            ca_days=$(db_read "__ca__" "days")
            echo "  CA: ${ca_cn}"
            echo "  Создан: ${ca_created}"
            echo "  Срок действия: ${ca_days} дней"
            echo "  Путь: ${CA_PATH}"
            echo "  Зашифрован: ${CA_KEY_ENCRYPTED}"
            echo "  Режим bundle: ${BUNDLE_MODE}"
            local bundle_path; bundle_path=$(bundle_file)
            if [ -f "$bundle_path" ]; then
                local bc; bc=$(grep -c "BEGIN CERTIFICATE" "$bundle_path" 2>/dev/null || echo 0)
                echo "  Bundle: ${bundle_path} (${bc} CA)"
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
            [ -z "$inp" ] && { cli_err "Требуется --input ФАЙЛ"; exit 1; }
            do_restore "$inp"
            ;;
        *) cli_err "Неизвестная подкоманда ca: ${subcmd}"; cli_usage; exit 1 ;;
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
                    *) err "Неизвестная опция: $1"; exit 1 ;;
                esac
            done
            [ -z "$service" ] && { cli_err "Требуется --service"; exit 1; }
            [ -z "$name" ] && { cli_err "Требуется --name"; exit 1; }
            [ -z "$days" ] && days="$CERT_DAYS"
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
                if [ -z "$names" ]; then cli_info "Нет сертификатов."; exit 0; fi
                print_cert_table "$names"
                local total; total=$(db_count)
                echo ""; echo -e "  ${DIM}Всего: $total${RESET}"
            fi
            ;;
        revoke)
            local uid; uid=$(cli_resolve_uid "$@") || exit 1
            core_revoke_cert "$uid"
            ;;
        delete)
            local uid; uid=$(cli_resolve_uid "$@") || exit 1
            ask_yn "Удалить файлы с диска? (необратимо)" || exit 0
            core_delete_cert "$uid"
            ;;
        renew)
            shift
            cli_cert_renew "$@"
            ;;
        verify)
            local uid; uid=$(cli_resolve_uid "$@") || exit 1
            core_verify_cert "$uid"
            ;;
        scan)
            core_scan_expiry
            ;;
        *) cli_err "Неизвестная подкоманда cert: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

# Resolve --uid or --service+--name to a uid
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
        echo "$uid"; return 0
    fi
    if [ -n "$service" ] && [ -n "$name" ]; then
        echo "${service}__${name}"; return 0
    fi
    cli_err "Укажите --uid UID или --service S --name N"
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
                    *) err "Неизвестная опция: $1"; exit 1 ;;
                esac
            done
            [ -z "$name" ] && { cli_err "Требуется --name"; exit 1; }
            if [ "$mode" = "new" ]; then
                [ -z "$domain" ] && { cli_err "--domain обязателен для режима new"; exit 1; }
                [ -z "$target" ] && { cli_err "--target обязателен для режима new"; exit 1; }
            elif [ "$mode" = "patch" ]; then
                [ -z "$patch_file" ] && { cli_err "--patch-file обязателен для режима patch"; exit 1; }
                [ -z "$router" ] && { cli_err "--router обязателен для режима patch"; exit 1; }
            fi
            svc_add "$name" "$domain" "$target" "$mode" "$patch_file" "$router"
            do_gen_traefik
            cli_ok "Сервис '${name}' добавлен [${mode}]."
            audit_log "service_add" "name=${name} mode=${mode}"
            ;;
        list)
            local svc_names; svc_names=$(svc_list_names)
            if [ -z "$svc_names" ]; then cli_info "Нет сервисов."; exit 0; fi
            printf "%-20s %-8s %-26s %-20s\n" "ИМЯ" "РЕЖИМ" "ДОМЕН/ФАЙЛ" "РОУТЕР/TARGET"
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
            [ -z "$name" ] && { cli_err "Требуется --name"; exit 1; }
            local dm; dm=$(svc_get "$name" "mode")
            if [ "$dm" = "patch" ]; then
                local dpf; dpf=$(svc_get "$name" "patch_file")
                local dpr; dpr=$(svc_get "$name" "patch_router")
                patch_remove "$name" "$dpf" "$dpr"
            fi
            svc_delete "$name"; do_gen_traefik
            cli_ok "Сервис '${name}' удалён."
            audit_log "service_delete" "name=${name}"
            ;;
        delete-full)
            local name=""
            while [ $# -gt 0 ]; do
                case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
            done
            [ -z "$name" ] && { cli_err "Требуется --name"; exit 1; }
            cli_info "Полное удаление: отзыв + удаление всех сертификатов, удаление файлов и блока Traefik для '${name}'..."
            core_delete_service_full "$name"
            ;;
        *) cli_err "Неизвестная подкоманда service: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_config() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        show)
            echo "  TRAEFIK_DYNAMIC_PATH = $TRAEFIK_DYNAMIC_PATH"
            echo "  CA_PATH              = $CA_PATH"
            echo "  CLIENTS_PATH         = $CLIENTS_PATH"
            echo "  OUTPUT_FILE          = $OUTPUT_FILE"
            echo "  CERT_DAYS            = $CERT_DAYS"
            echo "  EXPIRY_WARN_DAYS     = $EXPIRY_WARN_DAYS"
            echo "  CA_KEY_ENCRYPTED     = $CA_KEY_ENCRYPTED"
            echo "  BUNDLE_MODE          = $BUNDLE_MODE"
            echo "  WEBHOOK_URL          = ${WEBHOOK_URL:-<не задан>}"
            echo "  NOTIFY_EXPIRY_DAYS   = $NOTIFY_EXPIRY_DAYS"
            ;;
        set)
            local key="${1:-}" val="${2:-}"
            [ -z "$key" ] && { cli_err "Использование: config set <ключ> <значение>"; exit 1; }
            case "$key" in
                TRAEFIK_DYNAMIC_PATH) TRAEFIK_DYNAMIC_PATH="$val" ;;
                CA_PATH)              CA_PATH="$val" ;;
                CLIENTS_PATH)         CLIENTS_PATH="$val" ;;
                OUTPUT_FILE)          OUTPUT_FILE="$val" ;;
                CERT_DAYS)            CERT_DAYS="$val" ;;
                EXPIRY_WARN_DAYS)     EXPIRY_WARN_DAYS="$val" ;;
                CA_KEY_ENCRYPTED)     CA_KEY_ENCRYPTED="$val" ;;
                BUNDLE_MODE)          BUNDLE_MODE="$val" ;;
                WEBHOOK_URL)          WEBHOOK_URL="$val" ;;

                NOTIFY_EXPIRY_DAYS)   NOTIFY_EXPIRY_DAYS="$val" ;;
                *) cli_err "Неизвестный ключ: $key"; exit 1 ;;
            esac
            save_config
            cli_ok "Установлено ${key} = ${val}"
            audit_log "config_set" "${key}=${val}"
            ;;
        *) cli_err "Неизвестная подкоманда config: ${subcmd}"; cli_usage; exit 1 ;;
    esac
}

cli_audit() {
    [ -f "$AUDIT_FILE" ] || { cli_info "Журнал аудита пуст."; exit 0; }
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

# Proper renew parser — implemented separately to avoid arg consumption issues
cli_cert_renew() {
    local uid="" days=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --uid)   uid="$2"; shift 2 ;;
            --days)  days="$2"; shift 2 ;;
            --service) uid="${2}__"; shift 2 ;;
            --name)    uid="${uid}$(echo "$2" | tr ' ' '-')"; shift 2 ;;
            *) err "Неизвестная опция: $1"; exit 1 ;;
        esac
    done
    [ -z "$uid" ] && { cli_err "Требуется --uid UID или --service S --name N"; exit 1; }
    [ -z "$days" ] && days="$CERT_DAYS"
    ensure_ca || exit 1
    core_renew_cert "$uid" "$days"
}

cli_users() {
    local subcmd="${1:-}"; shift || true
    case "$subcmd" in
        list)
            local allowed; allowed=$(acl_list)
            if [ -z "$allowed" ]; then
                cli_info "Список доступа пуст — только root может использовать скрипт."
                exit 0
            fi
            echo "  Разрешённые пользователи:"
            while IFS= read -r u; do echo "    $u"; done <<< "$allowed"
            ;;
        add)
            local username="${1:-}"
            [ -z "$username" ] && { cli_err "Использование: users add <username>"; exit 1; }
            if [ "$(id -u)" -ne 0 ]; then
                cli_err "Только root может добавлять пользователей. Запустите: sudo mtls.sh users add $username"
                exit 1
            fi
            acl_add "$username"
            cli_ok "Пользователь '${username}' добавлен в список доступа."
            audit_log "user_add" "$username"
            ;;
        remove)
            local username="${1:-}"
            [ -z "$username" ] && { cli_err "Использование: users remove <username>"; exit 1; }
            if [ "$(id -u)" -ne 0 ]; then
                cli_err "Только root может удалять пользователей. Запустите: sudo mtls.sh users remove $username"
                exit 1
            fi
            acl_remove "$username"
            cli_ok "Пользователь '${username}' удалён из списка доступа."
            audit_log "user_remove" "$username"
            ;;
        system)
            cli_info "Системные пользователи (UID >= 1000):"
            local sys_users; sys_users=$(list_system_users)
            if [ -z "$sys_users" ]; then
                cli_info "  Обычные пользователи не найдены."
            else
                while IFS= read -r u; do
                    local mark=" "
                    local already; already=$(acl_list)
                    case "$already" in *"$u"*) mark="  [разрешён]" ;; esac
                    printf "    %-20s %s\n" "$u" "$mark"
                done <<< "$sys_users"
            fi
            ;;
        *) cli_err "Использование: users <list|add|remove|system>"; exit 1 ;;
    esac
}

# =============================================================================
#  STARTUP PATH CHECK — warn early if configured paths are not writable
# =============================================================================
warn_path_access() {
    [ "$(id -u)" -eq 0 ] && return 0
    local failed=0
    for p in "$CA_PATH" "$CLIENTS_PATH" "$TRAEFIK_DYNAMIC_PATH"; do
        if ! check_path_access "$p" >/dev/null 2>&1; then
            failed=1
        fi
    done
    if [ "$failed" -eq 1 ]; then
        echo ""
        echo -e "  ${YELLOW}!${RESET}  ${BOLD}Предупреждение: некоторые настроенные пути недоступны для записи вашим пользователем.${RESET}"
        echo -e "  ${DIM}Путь CA          : ${CA_PATH}${RESET}"
        echo -e "  ${DIM}Путь клиентов    : ${CLIENTS_PATH}${RESET}"
        echo -e "  ${DIM}Dynamic Traefik  : ${TRAEFIK_DYNAMIC_PATH}${RESET}"
        echo ""
        echo -e "  ${YELLOW}Варианты исправления:${RESET}"
        echo -e "    1. Запустите через sudo:      ${CYAN}sudo mtls.sh${RESET}"
        echo -e "    2. Используйте локальный пресет: запуск скрипта → 6 → p3"
        echo -e "    3. Попросите root добавить вас: ${CYAN}sudo mtls.sh users add \$USER${RESET}"
        echo ""
    fi
    return 0
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
load_config
db_init
check_deps

# CLI mode: first arg is a command
if [ $# -ge 1 ]; then
    MTLS_NONINTERACTIVE=1
    export MTLS_NONINTERACTIVE
    _cmd="$1"; shift

    # Access control: skip for 'users' and 'help' so non-root can at least
    # check the list and see help. Root always bypasses.
    case "$_cmd" in
        users|help|--help|-h) ;;
        *)
            if ! acl_check; then
                cli_err "Доступ запрещён. Вас нет в списке разрешённых пользователей."
                echo ""
                echo "  Попросите root добавить вас:  sudo mtls.sh users add ${SUDO_USER:-${USER:-$(whoami)}}"
                echo "  Или запустите через sudo:     sudo mtls.sh $*"
                exit 1
            fi
            ;;
    esac

    db_lock
    case "$_cmd" in
        ca)       cli_ca "$@" ;;
        cert)
            if [ "${1:-}" = "renew" ]; then
                shift; cli_cert_renew "$@"
            else
                cli_cert "$@"
            fi ;;
        service)  cli_service "$@" ;;
        config)   cli_config "$@" ;;
        gen)      do_gen_traefik ;;
        audit)    cli_audit "$@" ;;
        users)    cli_users "$@" ;;
        help|--help|-h) cli_usage ;;
        menu)     MTLS_NONINTERACTIVE=0; db_unlock; warn_path_access; main_menu ;;
        *)        cli_err "Неизвестная команда: $_cmd"; echo ""; cli_usage; exit 1 ;;
    esac
    db_unlock
    exit 0
fi

# TUI mode (no arguments)
if ! acl_check; then
    header
    section "Доступ запрещён"
    _current_user="${SUDO_USER:-${USER:-$(whoami)}}"
    err "Вас (${_current_user}) нет в списке разрешённых пользователей."
    echo ""
    echo -e "  ${YELLOW}Варианты:${RESET}"
    echo -e "    1. Запустите через sudo:  ${CYAN}sudo mtls.sh${RESET}"
    echo -e "    2. Попросите root добавить вас:  ${CYAN}sudo mtls.sh users add ${_current_user}${RESET}"
    echo ""
    exit 1
fi
warn_path_access
db_lock
main_menu
db_unlock
