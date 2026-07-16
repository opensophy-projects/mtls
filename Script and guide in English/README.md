# mtls.sh — mTLS Certificate Manager v2.0

> **Opensophy** — open-source tool for managing mTLS certificates under Traefik.
> License: MIT
> Repository: [opensophy-projects](https://github.com/opensophy-projects)

**The script has been tested on Ubuntu with the Dokploy platform for Docker container management.**

---

## What's new in v2.0

- **CLI mode** — all operations available from the command line, no TUI required
- **Access control** — restrict who can run the script (root always bypasses; non-root users must be added to the allowed list)
- **Audit log** — every action is logged to `~/.mtls-manager.audit.jsonl` (JSONL format)
- **CA key encryption** — optional passphrase protection for the root CA private key
- **Per-service bundles** — `BUNDLE_MODE=per-service` creates a separate `clients-bundle-<service>.crt` per service instead of one shared bundle
- **Notifications** — webhook alerts for expiring/expired certificates
- **Backup & restore** — `ca backup` / `ca restore` for full CA + DB + config archival
- **Certificate renewal** — `cert renew` re-issues a certificate with the same name
- **Certificate verification** — `cert verify` checks the chain and prints details
- **Chain verification** — all newly signed certificates are verified against the full chain before storing
- **YAML validation** — generated Traefik config is structurally validated
- **DB locking** — `flock` prevents concurrent database corruption
- **Full service deletion** — `service delete-full` revokes all certs, removes files, intermediate CAs, Traefik blocks, and patches

---

## What the script does

`mtls.sh` is a bash manager for mTLS certificates for the **Traefik** reverse proxy. It allows you to:

- Create and manage a root CA (Certificate Authority)
- Issue, renew, revoke, and delete client certificates (`.crt`, `.key`, `.p12`)
- Automatically generate Traefik configuration with mTLS settings
- Work in two Traefik integration modes: creating a new router or patching an existing one
- Scan for expiring certificates and send notifications
- Backup and restore the entire CA + database
- Control who can use the script (access control list)

The script requires no third-party tools beyond `openssl` and `python3` — both are present in any modern Linux environment.

---

## How the script solves certificate revocation

**The problem:** Traefik has no built-in mechanism for revoking client certificates. Once a certificate is trusted via `caFiles`, there is no native way to invalidate a single client without removing the entire CA or restarting with a new configuration.

**The solution:** The script creates a **separate intermediate CA for each client certificate**. Instead of trusting individual client certs directly, Traefik trusts a **bundle file** (`clients-bundle.crt`) that contains only the intermediate CAs of *active* (non-revoked) clients.

**How revocation works in practice:**

1. When a certificate is issued, a unique intermediate CA is created and signed by the root CA. The client certificate is then signed by this intermediate CA. The intermediate CA is added to the bundle file.
2. When a certificate is revoked, the script simply **removes the corresponding intermediate CA from the bundle file**. The client's certificate is no longer trusted by Traefik — the connection is rejected immediately.
3. The Traefik config is regenerated and the bundle file is updated. With Traefik's file provider enabled, the change takes effect **without a restart** — Traefik watches the file and reloads automatically.

**Why this approach works:**

- No CRL or OCSP infrastructure needed — Traefik does not need to be configured for revocation checking
- Granular revocation — revoking one client does not affect any other client
- Immediate effect — the revoked client is blocked as soon as the bundle file is rebuilt
- No Traefik restart required — the file provider handles hot-reloading

This is the core design principle of the script: **per-client intermediate CAs + bundle file = revocation without CRL/OCSP and without Traefik restarts**.

---

## Dependencies and requirements

| Dependency | Used for | Required |
|---|---|---|
| `openssl` | Generating CA, CSR, signing certificates, CRL, PKCS#12 | Yes |
| `python3` | JSON database, YAML patching of Traefik configs, audit log | Yes |
| `bash` >= 4 | The script itself | Yes |
| `flock` | DB locking (prevents concurrent corruption) | Yes (usually in `util-linux`) |
| `curl` | Webhook notifications | Only for notifications |
| `ip` (iproute2) | Detecting host IP for Traefik target | No (fallback: `172.17.0.1`) |

On startup, the script automatically checks for `openssl` and `python3`. If missing, it offers to install them via `apt-get`, `yum`, `apk`, or `brew`.

---

## Running

### Interactive TUI

```bash
chmod +x mtls.sh
sudo ./mtls.sh
```

### CLI mode

```bash
sudo ./mtls.sh ca create --cn "My-CA" --days 3650
sudo ./mtls.sh service add --name myapp --domain myapp.example.com --target http://localhost:3000
sudo ./mtls.sh cert issue --service myapp --name alice --days 365 --note "iPhone Alice" --pass secret123
sudo ./mtls.sh cert list
```

> `sudo` is needed if CA and Traefik paths are in `/etc/`. For local testing (preset `p3`), `sudo` is not required.

---

## CLI commands

```
mtls.sh                                        Interactive TUI menu
mtls.sh <command> [options]                    CLI mode

COMMANDS:
  ca create [--cn NAME] [--days N] [--encrypt]
      Create root CA

  ca info
      Show CA details

  ca backup [--output FILE]
      Backup CA + DB + config to tar.gz

  ca restore --input FILE
      Restore from backup

  cert issue --service S --name N [--days D] [--note TEXT] [--pass P]
      Issue a new client certificate

  cert list [--json]
      List all certificates

  cert revoke --uid UID | --service S --name N
      Revoke a certificate (keeps files on disk)

  cert delete --uid UID | --service S --name N
      Revoke + delete certificate files from disk

  cert renew --uid UID [--days D]
      Renew an existing certificate (re-issue with same name)

  cert verify --uid UID | --service S --name N
      Verify certificate chain and show details

  cert scan
      Scan for expiring/expired certificates, send notifications

  service add --name N --domain D --target T [--mode new|patch]
      Add a service (for patch mode: --patch-file F --router R)

  service list
      List all services

  service delete --name N
      Delete a service (removes from DB, removes patch if patch mode)

  service delete-full --name N
      Full delete: revoke+delete all client certs, remove client files,
      remove generated Traefik router/service block, remove patch, remove service

  config show
      Show current configuration

  config set <key> <value>
      Set a config value

  gen
      Generate/update Traefik config

  audit [--last N]
      Show audit log entries

  users list
      Show who is in the allowed-users list

  users add <username>
      Add a user to the allowed list (root only)

  users remove <username>
      Remove a user from the allowed list (root only)

  users system
      Show all system users (UID >= 1000) and their access status

  help
      Show this help

ENVIRONMENT VARIABLES:
  MTLS_HOST_IP          Override detected host IP
  MTLS_CA_PASSPHRASE    CA key passphrase (for encrypted keys)
  MTLS_P12_PASSWORD     Default .p12 password (non-interactive issue)
  MTLS_NONINTERACTIVE   Set to 1 to skip all prompts
```

---

## Main menu (TUI)

```
mTLS Certificate Manager v2.0
/etc/traefik/dynamic
CA ✔   services: 2   certificates: 5

1)  Create certificate
2)  Certificate list
3)  Revoke / delete certificate
4)  Service management
5)  Create / recreate CA
6)  Path settings
7)  Update Traefik config
8)  Scan for expiring certificates
9)  Backup CA + database
10) Manage access (users)

0)  Exit
```

---

## Access control

By default, only **root** can use the script. Root can add non-root users to the allowed list:

```bash
sudo ./mtls.sh users add alice
sudo ./mtls.sh users add bob
./mtls.sh users list
./mtls.sh users system
```

Non-root users not in the list will see an access denied message with instructions.

In TUI mode, option **10) Manage access** provides an interactive interface for managing the allowed-users list (root only).

---

## Service management

**Menu → 4** or `service` CLI commands.

A service is a logical unit to which certificates are issued. Each service corresponds to one protected resource in Traefik.

### Mode `new`

Creates a new router and service in the Traefik config:

```
Service name   → myapp
Domain         → myapp.example.com
Target URL     → http://localhost:3000
```

The generated `mtls-manager.yml` will contain:

```yaml
http:
  routers:
    myapp-mtls:
      rule: "Host(`myapp.example.com`)"
      entryPoints:
        - websecure
      service: myapp-mtls
      tls:
        options: mtls-myapp

  services:
    myapp-mtls:
      loadBalancer:
        servers:
          - url: "http://172.17.0.1:3000"
```

> `localhost` and `127.0.0.1` in the target are automatically replaced with the host gateway IP (determined via `ip route`).

### Mode `patch`

Adds an mTLS option to an **already existing** router in another Traefik YAML file (e.g., a Dokploy config).

```
Config file   → /etc/dokploy/traefik/dynamic/dokploy.yml
Router        → my-existing-router
```

When the first certificate for this service is created, the script patches the specified file:

```yaml
# Before patching:
my-existing-router:
  tls: {}

# After patching:
my-existing-router:
  tls:
    options: mtls-myapp
```

When a service is deleted, the patch is automatically removed.

### Full delete

`service delete-full` (or menu → 4 → 5) performs a complete cleanup:
- Revoke and delete ALL client certificates for the service
- Remove client files from disk
- Remove ALL intermediate CA directories for the service
- Remove the generated Traefik router/service block (new mode)
- Remove the mTLS patch from the external config (patch mode)
- Remove the service from the database

---

## Certificate operations

### Issue a certificate

**Menu → 1** or `cert issue`.

Steps:
1. Select a service from the list
2. Set a certificate name (latin characters, no spaces — spaces are replaced with `-`)
3. Specify the validity period (default: value from settings, standard is 365 days)
4. Add a note (for whom / what it was issued)
5. Set a password for the `.p12` file (can be left empty)

The script then:
1. Generates a 2048-bit RSA client key
2. Creates a CSR
3. Creates an intermediate CA for this client (signed by root CA)
4. Signs the client certificate with the intermediate CA
5. Verifies the certificate chain
6. Creates a `.p12` bundle (key + certificate + root CA)
7. Rebuilds the bundle file
8. Updates the Traefik config
9. Applies the patch (if the service is in patch mode)

### Output file structure

```
/etc/traefik/certs/mtls/clients/
└── <service>/
    └── <cert-name>/
        ├── client.key   — client private key
        ├── client.crt   — client certificate
        └── client.p12   — bundle for import
```

### Renew a certificate

`cert renew --uid UID [--days D]` or no TUI equivalent (CLI only).

Revokes the old certificate and re-issues a new one with the same name and service. The note and password are preserved.

### Verify a certificate

`cert verify --uid UID` or no TUI equivalent (CLI only).

Shows certificate details (serial, subject, issuer, validity dates) and verifies the chain against the intermediate CA + root CA.

### Revoke and delete

**Menu → 3** or `cert revoke` / `cert delete`.

Deletion occurs in **two steps** (protection against accidental deletion):

**Step 1 — Revocation:**
Sets the `revoked=1` flag in the database, the client's intermediate CA is excluded from `clients-bundle.crt`, and the Traefik config is updated. The certificate stops working immediately — without restarting Traefik.

**Step 2 — File deletion (on re-entry or `cert delete`):**
Deletes the directory containing `client.key`, `client.crt`, `client.p12`, the intermediate CA directory, and the database entry.

### Certificate statuses

| Status | Condition | Color |
|---|---|---|
| ACTIVE | Valid, > 30 days until expiry | Green |
| EXPIRING (Nd) | Expires in less than 30 days | Yellow |
| EXPIRED | Expiry date is in the past | Red |
| REVOKED | `revoked=1` field in the database | Red |

---

## Expiry scanning and notifications

**Menu → 8** or `cert scan`.

Scans all non-revoked certificates and reports expiring (within `EXPIRY_WARN_DAYS`) and expired ones. If a webhook notification URL is configured, an alert is sent.

Notification settings (menu → 6 → 8 or `config set`):
- `WEBHOOK_URL` — POST JSON `{title, body}` to this URL

---

## CA creation

**Menu → 5** or `ca create`.

Creates a root CA on first run or recreates it when needed.

```
CA name (CN)           → mTLS-Root-CA
Validity period (days) → 3650
Encrypt key?           → yes/no
```

Generates:
- `ca.key` (4096-bit RSA) — private key, permissions 600
- `ca.crt` — self-signed root certificate
- `index.txt`, `serial`, `index.txt.attr` — CA database for OpenSSL
- `crl.pem` — revocation list (initially empty)
- `openssl-ca.cnf` — OpenSSL configuration file

> Recreating the CA invalidates all previously issued certificates.

### CA key encryption

If encryption is enabled, the CA private key is protected with a passphrase (AES-256). The passphrase must be provided via:
- Interactive prompt (TUI / `ca create --encrypt`)
- `MTLS_CA_PASSPHRASE` environment variable (for CLI / automation)

---

## Backup and restore

**Menu → 9** or `ca backup` / `ca restore`.

```bash
sudo ./mtls.sh ca backup --output /tmp/my-backup.tar.gz
sudo ./mtls.sh ca restore --input /tmp/my-backup.tar.gz
```

The backup includes:
- Config file (`~/.mtls-manager.conf`)
- Certificate database (`~/.mtls-manager.db`)
- Services list (`~/.mtls-manager.services`)
- Audit log (`~/.mtls-manager.audit.jsonl`)
- All CA files (certificates, keys, intermediate CAs, CRL, etc.)

---

## Audit log

Every action (CA creation, certificate issue/revoke/delete, service add/delete, config changes, user management, backup/restore) is logged to `~/.mtls-manager.audit.jsonl` in JSONL format.

```bash
sudo ./mtls.sh audit
sudo ./mtls.sh audit --last 10
```

Each entry contains: timestamp, action, actor (username), and optional detail.

---

## Path settings

**Menu → 6** or `config show` / `config set`.

| Parameter | Default |
|---|---|
| Traefik dynamic configs path | `/etc/traefik/dynamic` |
| CA path | `/etc/traefik/certs/mtls` |
| Client certificate path | `/etc/traefik/certs/mtls/clients` |
| Output filename | `mtls-manager.yml` |
| Certificate validity (days) | `365` |
| Expiry warning (days) | `30` |
| Bundle mode | `shared` |
| CA key encryption | `0` (off) |
| Webhook URL | (empty) |


Settings are saved to `~/.mtls-manager.conf` with permissions 600.

### Presets

| Preset | Dynamic path | CA path |
|---|---|---|
| `p1` Dokploy | `/etc/dokploy/traefik/dynamic` | `/etc/dokploy/traefik/dynamic/certificates/ca` |
| `p2` Traefik | `/etc/traefik/dynamic` | `/etc/traefik/certs/mtls` |
| `p3` Local | `./traefik-local/dynamic` | `./traefik-local/certs/mtls` |

---

## Bundle modes

### `shared` (default)

All services share one `clients-bundle.crt` containing intermediate CAs from all active (non-revoked) clients.

### `per-service`

Each service gets its own bundle file `clients-bundle-<service>.crt` containing only the intermediate CAs of clients belonging to that service. This provides isolation between services.

---

## Data files

| File | Format | Contents |
|---|---|---|
| `~/.mtls-manager.conf` | KEY="value" | Paths, default validity, notification settings |
| `~/.mtls-manager.db` | JSON | Certificate metadata (name, service, dates, status, paths) |
| `~/.mtls-manager.services` | JSON array | List of registered services |
| `~/.mtls-manager.audit.jsonl` | JSONL | Audit log (append-only) |
| `~/.mtls-manager.users` | JSON array | Allowed users list (for access control) |

All files are created with permissions 600.

---

## On-disk file structure

```
/etc/traefik/
├── certs/mtls/
│   ├── ca.key                    ← CA private key (600)
│   ├── ca.crt                    ← root CA certificate
│   ├── crl.pem                   ← revocation list
│   ├── openssl-ca.cnf            ← OpenSSL config
│   ├── index.txt                 ← CA database
│   ├── serial                    ← serial counter
│   ├── clients-bundle.crt        ← bundle of active int-CAs (shared mode)
│   ├── clients-bundle-<svc>.crt  ← per-service bundle (per-service mode)
│   ├── intermediates/
│   │   └── <service>__<name>/
│   │       ├── int-ca.key        ← intermediate CA key
│   │       └── int-ca.crt        ← intermediate CA certificate
│   └── clients/
│       └── <service>/
│           └── <name>/
│               ├── client.key
│               ├── client.crt
│               └── client.p12
└── dynamic/
    └── mtls-manager.yml          ← generated Traefik config
```

---

## Intermediate CAs (per-client)

A **separate intermediate CA** is created for each client certificate, signed by the root CA.

Trust chain:
```
Root CA  →  Int-CA (alice)  →  client.crt (alice)
Root CA  →  Int-CA (bob)    →  client.crt (bob)
```

Why this is needed:

1. **Granular revocation**: when revoking alice's certificate, `int-ca-alice.crt` is simply excluded from the bundle. Bob is unaffected.
2. **No CRL on the Traefik side**: no need to configure CRL verification — just rebuild the bundle.
3. **Immediate effect**: Traefik picks up the updated bundle without a restart (with the file provider enabled).

---

## Patch mode

When adding a service in `patch` mode, the script modifies the specified Traefik YAML file.

**Patch algorithm** (implemented in Python3 via heredoc):

1. Parses YAML line by line (no dependencies — standard Python only)
2. Finds the `routers:` section and within it the router with the given name
3. Inside the router, finds the `tls:` block
4. Adds the line `options: mtls-<service>` (or replaces an existing one)

When a service is deleted, the `options: mtls-<service>` line is removed from the file.

Possible patch results: `patched`, `already_patched`, `not_found`.

---

## Traefik config generation

The `do_gen_traefik()` function creates the file `<TRAEFIK_DYNAMIC_PATH>/<OUTPUT_FILE>` with the following structure:

```yaml
# Generated by mtls-manager — 2025-01-15 10:00:00
# DO NOT EDIT MANUALLY

tls:
  options:
    mtls-myapp:
      clientAuth:
        caFiles:
          - "/etc/traefik/certs/mtls/clients-bundle.crt"
        clientAuthType: RequireAndVerifyClientCert
      minVersion: VersionTLS12

http:
  routers:
    myapp-mtls:
      rule: "Host(`myapp.example.com`)"
      entryPoints:
        - websecure
      service: myapp-mtls
      tls:
        options: mtls-myapp

  services:
    myapp-mtls:
      loadBalancer:
        servers:
          - url: "http://172.17.0.1:3000"
```

The `http.routers` and `http.services` sections are generated **only** for services in `new` mode. For `patch` services, only the `tls.options` block is created.

After generation, the YAML is structurally validated (checks for `tls:` section, no tabs, etc.).

---

## Clearing browser certificate stores

Each time a new `.p12` is issued, the browser stores not only the client certificate but also the intermediate CA. This can lead to accumulation of outdated entries.

**Linux (Chrome):**
```bash
apt install libnss3-tools
certutil -L -d /home/<user>/.local/share/pki/nssdb/
certutil -D -d /home/<user>/.local/share/pki/nssdb/ -n "opensophy - mTLS-Manager"
```

**Windows (Chrome/Edge):**
```powershell
Get-ChildItem -Path Cert:\CurrentUser\CA | Where-Object { $_.Subject -like "*opensophy*" } | Remove-Item
```

---

## Known limitations

- **No ECDSA support**: the script uses RSA (2048-bit for clients, 4096 for CA). ECDSA is not supported.
- **OCSP/CRL not configurable**: revocation is implemented via bundle, not through standard CRL/OCSP mechanisms.
- **Python3 YAML parsing**: patching Traefik configs is implemented via line-by-line parsing, not a yaml library. Non-standard YAML formats may not be handled correctly.
- **Notifications are manual**: `cert scan` must be run manually or via cron — the script does not run as a daemon.
