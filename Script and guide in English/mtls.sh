#!/usr/bin/env bash
# =============================================================================
#  mtls.sh — mTLS Certificate Manager
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

CONFIG_FILE="${HOME}/.mtls-manager.conf"
DB_FILE="${HOME}/.mtls-manager.db"
SERVICES_FILE="${HOME}/.mtls-manager.services"

TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"
CA_PATH="/etc/traefik/certs/mtls"
CLIENTS_PATH="/etc/traefik/certs/mtls/clients"
OUTPUT_FILE="mtls-manager.yml"
CERT_DAYS=365

# =============================================================================
#  CONFIG
# =============================================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key val; do
            val="${val//\"/}"
            case "$key" in
                TRAEFIK_DYNAMIC_PATH) TRAEFIK_DYNAMIC_PATH="$val" ;;
                CA_PATH)              CA_PATH="$val" ;;
                CLIENTS_PATH)         CLIENTS_PATH="$val" ;;
                OUTPUT_FILE)          OUTPUT_FILE="$val" ;;
                CERT_DAYS)            CERT_DAYS="$val" ;;
            esac
        done < "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
TRAEFIK_DYNAMIC_PATH="$TRAEFIK_DYNAMIC_PATH"
CA_PATH="$CA_PATH"
CLIENTS_PATH="$CLIENTS_PATH"
OUTPUT_FILE="$OUTPUT_FILE"
CERT_DAYS="$CERT_DAYS"
EOF
    chmod 600 "$CONFIG_FILE"
}

# =============================================================================
#  DB
# =============================================================================
db_init() {
    [ -f "$DB_FILE" ]       || { echo '{}' > "$DB_FILE";  chmod 600 "$DB_FILE"; }
    [ -f "$SERVICES_FILE" ] || { echo '[]' > "$SERVICES_FILE"; chmod 600 "$SERVICES_FILE"; }
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

# =============================================================================
#  SERVICES
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
    local tmp; tmp=$(mktemp "${DB_FILE}.XXXXXX")
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
    'name': sys.argv[2],
    'domain': sys.argv[3],
    'target': sys.argv[4],
    'mode': sys.argv[5],
    'patch_file': sys.argv[6],
    'patch_router': sys.argv[7],
})
with open(sys.argv[8], 'w') as f:
    json.dump(svcs, f, indent=2)
PYEOF
    mv "$tmp" "$SERVICES_FILE"
}

svc_delete() {
    local name="$1"
    local tmp; tmp=$(mktemp "${DB_FILE}.XXXXXX")
    python3 - "$SERVICES_FILE" "$name" "$tmp" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    svcs = json.load(f)
svcs = [s for s in svcs if s['name'] != sys.argv[2]]
with open(sys.argv[3], 'w') as f:
    json.dump(svcs, f, indent=2)
PYEOF
    mv "$tmp" "$SERVICES_FILE"
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
    openssl genrsa -out "$(int_ca_key "$uid")" 2048 2>/dev/null
    chmod 600 "$(int_ca_key "$uid")"
    openssl req -new -key "$(int_ca_key "$uid")" \
        -out "${dir}/int-ca.csr" \
        -subj "/CN=${cert_name}-Client-CA/O=${service}/OU=mTLS-Manager/C=US" 2>/dev/null
    gen_ca_cnf
    openssl x509 -req -days "${CERT_DAYS}" \
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
) 2>/dev/null
    chmod 644 "$(int_ca_crt "$uid")"
    rm -f "${dir}/int-ca.csr" "${dir}/int-ca.srl"
    db_write "$uid" "int_ca_path" "$dir"
}

sign_client_with_int_ca() {
    local uid="$1" cert_dir="$2" days="$3"
    openssl x509 -req \
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
) 2>/dev/null
}

# =============================================================================
#  BUNDLE
# =============================================================================
bundle_file() { echo "${CA_PATH}/clients-bundle.crt"; }

rebuild_bundle() {
    local bundle; bundle=$(bundle_file)
    local tmp; tmp=$(mktemp "${CA_PATH}/bundle.XXXXXX")
    local count=0
    local names; names=$(db_list_names)
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
    openssl ca -config "$(ca_cnf)" -gencrl -out "$(ca_crl)" 2>/dev/null
    chmod 644 "$(ca_crl)"
}

ca_exists() { [ -f "${CA_PATH}/ca.crt" ] && [ -f "${CA_PATH}/ca.key" ]; }

# =============================================================================
#  PATCH MODE
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
#  TRAEFIK CONFIG
# =============================================================================
do_gen_traefik() {
    local out="${TRAEFIK_DYNAMIC_PATH}/${OUTPUT_FILE}"
    mkdir -p "$TRAEFIK_DYNAMIC_PATH"
    if [ ! -f "${CA_PATH}/ca.crt" ]; then
        warn "CA not found — Traefik config was not updated."; return 1
    fi
    rebuild_bundle
    local bundle; bundle=$(bundle_file)
    local host_ip
    host_ip=$(ip route | grep default | awk '{print $3}' | head -1)
    [ -z "$host_ip" ] && host_ip="172.17.0.1"
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
    ok "Traefik config: ${out}"
    local active_count=0
    local all_names; all_names=$(db_list_names)
    if [ -n "$all_names" ]; then
        active_count=$(while IFS= read -r uid; do
            [ -z "$uid" ] && continue
            local r; r=$(db_read "$uid" "revoked")
            [ "$r" != "1" ] && echo "$uid"
        done <<< "$all_names" | wc -l)
    fi
    info "Bundle: ${active_count} intermediate CAs"
}

# =============================================================================
#  UI
# =============================================================================
header() {
    clear
    echo ""
    echo -e "  ${BOLD}${BLUE}🔐  mTLS Certificate Manager${RESET}"
    echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M')${RESET}"
    echo ""
}

hr()      { echo -e "  ${DIM}──────────────────────────────────────────────────${RESET}"; }
info()    { echo -e "  ${CYAN}i${RESET}  $*"; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET}  $*"; }
err()     { echo -e "  ${RED}✖${RESET}  $*"; }
section() { echo -e "  ${BOLD}$*${RESET}"; hr; echo ""; }

ask() {
    local prompt="$1" default="${2:-}" result
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
    printf "  %s: " "$prompt" >/dev/tty
    read -rs result </dev/tty
    echo "" >/dev/tty
    echo "$result"
}

ask_yn() {
    local prompt="$1" result
    printf "  %s [y/N]: " "$prompt" >/dev/tty
    read -r result </dev/tty
    case "${result:-n}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

pause() {
    echo ""
    printf "  ${DIM}Enter — continue...${RESET}" >/dev/tty
    read -r _ </dev/tty
}

menu_choice() {
    printf "\n  Choice: " >/dev/tty
    read -r MENU_CHOICE </dev/tty
    echo "$MENU_CHOICE"
}

# =============================================================================
#  DEPS
# =============================================================================
check_deps() {
    local need_openssl=0 need_python=0
    command -v openssl >/dev/null 2>&1 || need_openssl=1
    command -v python3 >/dev/null 2>&1 || need_python=1
    [ "$need_openssl" -eq 0 ] && [ "$need_python" -eq 0 ] && return 0
    header
    section "Dependency check"
    [ "$need_openssl" -eq 1 ] && warn "openssl not found"
    [ "$need_python"  -eq 1 ] && warn "python3 not found"
    echo ""
    ask_yn "Install automatically?" || { err "openssl and python3 are required."; exit 1; }
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
        err "Could not detect a package manager. Install manually."
        exit 1
    fi
    ok "Done."
}

# =============================================================================
#  CERT TABLE
# =============================================================================
cert_status() {
    local uid="$1"
    local revoked; revoked=$(db_read "$uid" "revoked")
    [ "$revoked" = "1" ] && echo "REVOKED" && return
    local expires; expires=$(db_read "$uid" "expires")
    local today exp diff
    today=$(date +%s 2>/dev/null || echo 0)
    exp=$(date -d "$expires" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$expires" +%s 2>/dev/null || echo 9999999999)
    diff=$(( (exp - today) / 86400 ))
    if   [ "$diff" -lt 0  ]; then echo "EXPIRED"
    elif [ "$diff" -le 30 ]; then echo "EXPIRING (${diff}d)"
    else                          echo "ACTIVE"
    fi
}

cert_status_color() {
    case "$1" in
        ACTIVE)  echo "$GREEN" ;;
        REVOKED)  echo "$RED" ;;
        EXPIRED)    echo "$RED" ;;
        *)        echo "$YELLOW" ;;
    esac
}

print_cert_table() {
    local names="$1"
    [ -z "$names" ] && return
    printf "  ${BOLD}%-4s %-20s %-14s %-11s %-11s %-16s %-20s${RESET}\n" "#" "Name" "Service" "Created" "Expires" "Status" "Note"
    hr
    local i=1
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
#  MENU: CREATE CA
# =============================================================================
do_create_ca() {
    header; section "Create root CA"
    if ca_exists; then
        warn "CA already exists: ${CA_PATH}/ca.crt"
        echo ""; warn "WARNING: recreating CA invalidates ALL issued certificates!"; echo ""
        ask_yn "Recreate CA?" || return
    fi
    mkdir -p "$CA_PATH" "${CA_PATH}/intermediates"; chmod 700 "$CA_PATH"
    local cn days
    cn=$(ask "Name CA (CN)" "mTLS-Root-CA")
    days=$(ask "CA validity period (days)" "3650")
    echo ""
    info "Generating CA key (4096 bit)..."
    openssl genrsa -out "${CA_PATH}/ca.key" 4096 2>/dev/null; chmod 600 "${CA_PATH}/ca.key"
    info "Generating CA certificate..."
    openssl req -new -x509 -days "$days" -key "${CA_PATH}/ca.key" -out "${CA_PATH}/ca.crt" \
        -subj "/CN=${cn}/O=mTLS-Manager/C=US" 2>/dev/null
    info "Initializing CA database..."
    rm -f "${CA_PATH}/index.txt" "${CA_PATH}/index.txt.attr" "${CA_PATH}/serial"
    ca_db_init; rebuild_crl
    db_write "__ca__" "cn" "$cn"
    db_write "__ca__" "days" "$days"
    db_write "__ca__" "created" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""; ok "CA created!"
    echo -e "    ${DIM}Key : ${CA_PATH}/ca.key${RESET}"
    echo -e "    ${DIM}Cert : ${CA_PATH}/ca.crt${RESET}"
    do_gen_traefik; pause
}

ensure_ca() {
    if ! ca_exists; then
        warn "Root CA not found."; echo ""
        ask_yn "Create CA now?" || { err "CA is required."; pause; return 1; }
        do_create_ca
    fi
    return 0
}

# =============================================================================
#  MENU: CREATE CERT
# =============================================================================
menu_cert_create() {
    header; section "Create new certificate"
    ensure_ca || return
    local svc_names; svc_names=$(svc_list_names)
    if [ -z "$svc_names" ]; then warn "No services. Add a service first (option 4)."; pause; return; fi
    echo -e "  ${BOLD}Available services:${RESET}"; echo ""
    local i=1 svc_arr=()
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        local smode; smode=$(svc_get "$s" "mode")
        local label=""; [ "$smode" = "patch" ] && label="${DIM} [patch]${RESET}"
        echo -e "    ${CYAN}${i})${RESET}  $s${label}"
        svc_arr+=("$s"); i=$((i + 1))
    done <<< "$svc_names"; echo ""
    local svc_idx; svc_idx=$(ask "Select service (number)" "1")
    local service="${svc_arr[$((svc_idx - 1))]}"; if [ -z "$service" ]; then err "Invalid number."; pause; return; fi
    echo ""
    local cert_name; cert_name=$(ask "Certificate name (latin, no spaces)" "")
    cert_name="${cert_name// /-}"
    if [ -z "$cert_name" ]; then err "Name cannot be empty."; pause; return; fi
    local uid="${service}__${cert_name}"
    local existing; existing=$(db_read "$uid" "created")
    local ex_rev; ex_rev=$(db_read "$uid" "revoked")
    if [ -n "$existing" ] && [ "$ex_rev" != "1" ]; then
        warn "Certificate '${cert_name}' for '${service}' already exists."
        ask_yn "Recreate?" || { pause; return; }
        db_write "$uid" "revoked" "1"; rebuild_bundle
    fi
    local days note
    days=$(ask "Validity period (days)" "$CERT_DAYS")
    note=$(ask "Note (who/what for)" "")
    echo ""; echo -e "  ${BOLD}Password for .p12:${RESET}"
    local pass1 pass2
    pass1=$(ask_secret "Enter password")
    pass2=$(ask_secret "Repeat password")
    if [ "$pass1" != "$pass2" ]; then err "Passwords do not match."; pause; return; fi
    local cert_dir="${CLIENTS_PATH}/${service}/${cert_name}"
    mkdir -p "$cert_dir"; chmod 700 "$cert_dir"
    echo ""
    info "Generating key (2048 bit)..."
    openssl genrsa -out "${cert_dir}/client.key" 2048 2>/dev/null; chmod 600 "${cert_dir}/client.key"
    info "Creating CSR..."
    openssl req -new -key "${cert_dir}/client.key" -out "${cert_dir}/client.csr" \
        -subj "/CN=${cert_name}/O=${service}/C=US" 2>/dev/null
    info "Creating intermediate CA for ${cert_name}..."
    create_int_ca "$uid" "$cert_name" "$service"
    info "Signing client certificate..."
    sign_client_with_int_ca "$uid" "$cert_dir" "$days"
    if [ ! -f "${cert_dir}/client.crt" ]; then
        err "Signing error!"
        rm -rf "$cert_dir"
        [ -d "$(int_ca_dir "$uid")" ] && rm -rf "$(int_ca_dir "$uid")"
        pause; return
    fi
    rebuild_crl
    info "Creating .p12..."
    if [ -n "$pass1" ]; then
        openssl pkcs12 -export -out "${cert_dir}/client.p12" \
            -inkey "${cert_dir}/client.key" -in "${cert_dir}/client.crt" \
            -certfile "${CA_PATH}/ca.crt" -passout "pass:${pass1}" 2>/dev/null
    else
        openssl pkcs12 -export -out "${cert_dir}/client.p12" \
            -inkey "${cert_dir}/client.key" -in "${cert_dir}/client.crt" \
            -certfile "${CA_PATH}/ca.crt" -passout pass: 2>/dev/null
    fi
    rm -f "${cert_dir}/client.csr"
    local serial; serial=$(openssl x509 -serial -noout -in "${cert_dir}/client.crt" 2>/dev/null | cut -d= -f2)
    local expiry; expiry=$(openssl x509 -enddate -noout -in "${cert_dir}/client.crt" 2>/dev/null | cut -d= -f2)
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
    info "Updating bundle and Traefik config..."
    do_gen_traefik >/dev/null 2>&1
    local svc_mode; svc_mode=$(svc_get "$service" "mode")
    if [ "$svc_mode" = "patch" ]; then
        local pfile; pfile=$(svc_get "$service" "patch_file")
        local prouter; prouter=$(svc_get "$service" "patch_router")
        info "Applying patch to ${pfile} (router: ${prouter})..."
        local result; result=$(patch_apply "$service" "$pfile" "$prouter")
        case "$result" in
            patched)         ok "Patch applied." ;;
            already_patched) info "Patch already applied." ;;
            not_found)       warn "Router '${prouter}' not found in file." ;;
        esac
    fi
    echo ""; ok "Certificate created!"; hr
    echo -e "  ${DIM}${cert_dir}/client.p12${RESET}"
    echo -e "  Serial #  : $serial"
    echo -e "  Valid until     : $expiry"
    echo -e "  Note     : $note_val"
    [ -n "$pass1" ] && echo -e "  P12 password : ${GREEN}set${RESET}" || echo -e "  P12 password : ${YELLOW}not set${RESET}"
    pause
}

# =============================================================================
#  MENU: REVOKE + DELETE
# =============================================================================
menu_cert_delete() {
    header; section "Revoke and delete certificate"
    local names; names=$(db_list_names)
    if [ -z "$names" ]; then warn "No certificates."; pause; return; fi
    print_cert_table "$names"; echo ""

    # Build uid array in advance
    local cert_arr=()
    while IFS= read -r uid; do
        [ -z "$uid" ] && continue
        cert_arr+=("$uid")
    done <<< "$names"

    echo -e "  ${BOLD}0)${RESET}  Back"; echo ""
    local choice; choice=$(ask "Select certificate number" "")
    [ "$choice" = "0" ] || [ -z "$choice" ] && return

    local idx=$(( choice - 1 ))
    local uid="${cert_arr[$idx]}"
    if [ -z "$uid" ]; then err "Invalid number."; pause; return; fi

    # Read all data BEFORE any DB changes
    local cname csvc cpath crevoked cint_dir
    cname=$(db_read "$uid" "name")
    csvc=$(db_read "$uid" "service")
    cpath=$(db_read "$uid" "path")
    crevoked=$(db_read "$uid" "revoked")
    cint_dir=$(db_read "$uid" "int_ca_path")

    echo ""
    echo -e "  ${BOLD}Selected:${RESET} ${cname:-<unknown>}  ${DIM}(service: ${csvc:-<unknown>})${RESET}"
    echo ""

    if [ "$crevoked" != "1" ]; then
        # ── STEP 1: revocation only ──────────────────────────────────────────────
        warn "The certificate will now be REVOKED (access will be blocked)."
        warn "Come back here again to DELETE files from disk."
        echo ""
        ask_yn "Revoke certificate '${cname}'?" || { pause; return; }
        db_write "$uid" "revoked" "1"
        info "Updating bundle..."
        do_gen_traefik >/dev/null 2>&1
        ok "Certificate revoked. Come back again to delete files."
    else
        # ── STEP 2: delete files (already revoked) ────────────────────────────
        warn "Certificate is already revoked. Files will now be deleted from disk."
        echo ""
        ask_yn "Delete files '${cname}' from disk? (irreversible)" || { ok "Files kept."; pause; return; }

        # 1. Client files
        if [ -n "$cpath" ] && [ -d "$cpath" ]; then
            rm -rf "$cpath"
            ok "Certificate files deleted: ${cpath}"
        else
            warn "Certificate folder not found, skipping."
        fi

        # 2. Intermediate CA
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
        else
            info "Intermediate CA not found (already removed or not created)."
        fi

        # 3. DB record — last
        db_delete "$uid"
        ok "Record removed from database."
    fi

    pause
}

# =============================================================================
#  MENU: LIST CERTS
# =============================================================================
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

# =============================================================================
#  MENU: SERVICES
# =============================================================================
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
        echo -e "  ${BOLD}3)${RESET}  Delete service"
        echo -e "  ${BOLD}4)${RESET}  Update Traefik config"
        echo -e "  ${BOLD}0)${RESET}  Back"
        local c; c=$(menu_choice)
        case "$c" in
            1)
                echo ""
                local sname sdomain starget
                sname=$(ask "Service name" ""); sname="${sname// /-}"
                sdomain=$(ask "Domain (e.g.: myapp.example.com)" "")
                starget=$(ask "Target URL  (e.g.: http://localhost:3000)" "")
                if [ -z "$sname" ] || [ -z "$sdomain" ] || [ -z "$starget" ]; then
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
                echo ""; echo -e "  ${DIM}Routers in file:${RESET}"
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
                spr=$(ask "Router name (exactly as in file)" "")
                if [ -z "$sname" ] || [ -z "$spf" ] || [ -z "$spr" ]; then
                    err "All fields are required."
                elif [ ! -f "$spf" ]; then
                    err "File not found: $spf"
                else
                    svc_add "$sname" "" "" "patch" "$spf" "$spr"
                    do_gen_traefik
                    ok "Service '${sname}' added [patch]. Create certificate — patch will apply automatically."
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
            0) return ;;
        esac
    done
}

# =============================================================================
#  MENU: SETTINGS
# =============================================================================
menu_settings() {
    while true; do
        header; section "Path settings"
        echo -e "  ${BOLD}1)${RESET}  Traefik dynamic configs\n     ${CYAN}${TRAEFIK_DYNAMIC_PATH}${RESET}\n"
        echo -e "  ${BOLD}2)${RESET}  CA folder\n     ${CYAN}${CA_PATH}${RESET}\n"
        echo -e "  ${BOLD}3)${RESET}  Client certificates folder\n     ${CYAN}${CLIENTS_PATH}${RESET}\n"
        echo -e "  ${BOLD}4)${RESET}  Config filename\n     ${CYAN}${OUTPUT_FILE}${RESET}\n"
        echo -e "  ${BOLD}5)${RESET}  Default validity (days)\n     ${CYAN}${CERT_DAYS}${RESET}\n"
        hr
        echo -e "  ${DIM}Presets:${RESET}"
        echo -e "  ${BOLD}p1)${RESET} Dokploy   /etc/dokploy/traefik/dynamic"
        echo -e "  ${BOLD}p2)${RESET} Traefik   /etc/traefik/dynamic"
        echo -e "  ${BOLD}p3)${RESET} Local  ./traefik-local"
        hr; echo ""
        echo -e "  ${BOLD}0)${RESET}  Back"
        local c; c=$(menu_choice)
        case "$c" in
            1) TRAEFIK_DYNAMIC_PATH=$(ask "New path" "$TRAEFIK_DYNAMIC_PATH"); save_config; ok "Saved."; pause ;;
            2) CA_PATH=$(ask "New path" "$CA_PATH"); save_config; ok "Saved."; pause ;;
            3) CLIENTS_PATH=$(ask "New path" "$CLIENTS_PATH"); save_config; ok "Saved."; pause ;;
            4) OUTPUT_FILE=$(ask "New filename" "$OUTPUT_FILE"); save_config; ok "Saved."; pause ;;
            5) CERT_DAYS=$(ask "Days" "$CERT_DAYS"); save_config; ok "Saved."; pause ;;
            p1) TRAEFIK_DYNAMIC_PATH="/etc/dokploy/traefik/dynamic"; CA_PATH="/etc/dokploy/traefik/dynamic/certificates/ca"; CLIENTS_PATH="/etc/dokploy/traefik/dynamic/certificates/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Dokploy preset applied."; pause ;;
            p2) TRAEFIK_DYNAMIC_PATH="/etc/traefik/dynamic"; CA_PATH="/etc/traefik/certs/ca"; CLIENTS_PATH="/etc/traefik/certs/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Traefik preset applied."; pause ;;
            p3) TRAEFIK_DYNAMIC_PATH="$(pwd)/traefik-local/dynamic"; CA_PATH="$(pwd)/traefik-local/certs/ca"; CLIENTS_PATH="$(pwd)/traefik-local/certs/clients"; OUTPUT_FILE="mtls-manager.yml"; save_config; ok "Local preset applied."; pause ;;
            0) return ;;
        esac
    done
}

# =============================================================================
#  MAIN MENU
# =============================================================================
main_menu() {
    while true; do
        header
        local ca_status
        ca_exists && ca_status="${GREEN}CA ✔${RESET}" || ca_status="${RED}CA ✖ not created${RESET}"
        local svc_count cert_count
        svc_count=$(svc_count); cert_count=$(db_count)
        echo -e "  ${DIM}${TRAEFIK_DYNAMIC_PATH}${RESET}"
        echo -e "  ${ca_status}   ${DIM}services: ${svc_count}   certificates: ${cert_count}${RESET}"
        hr; echo ""
        echo -e "  ${BOLD}1)${RESET}  Create certificate"
        echo -e "  ${BOLD}2)${RESET}  Certificate list"
        echo -e "  ${BOLD}3)${RESET}  Revoke / delete certificate"
        echo ""
        echo -e "  ${BOLD}4)${RESET}  Service management"
        echo ""
        echo -e "  ${BOLD}5)${RESET}  Create / recreate CA"
        echo -e "  ${BOLD}6)${RESET}  Path settings"
        echo -e "  ${BOLD}7)${RESET}  Update Traefik config"
        echo ""
        echo -e "  ${BOLD}0)${RESET}  ${DIM}Exit${RESET}"
        local c; c=$(menu_choice)
        case "$c" in
            1) menu_cert_create ;;
            2) menu_cert_list ;;
            3) menu_cert_delete ;;
            4) menu_services ;;
            5) do_create_ca ;;
            6) menu_settings ;;
            7) do_gen_traefik; pause ;;
            0) echo ""; exit 0 ;;
        esac
    done
}

# =============================================================================
#  ENTRY
# =============================================================================
load_config; db_init; check_deps; main_menu

