# mtls.sh — mTLS Certificate Manager

> **Opensophy** — open-source tool for managing mTLS certificates under Traefik.
> License: MIT
> Repository: [opensophy-projects](https://github.com/opensophy-projects)

**The script has been tested on Ubuntu with the Dokploy platform for Docker container management.**

---

## What the script does

`mtls.sh` is an interactive bash manager for mTLS certificates for the **Traefik** reverse proxy. It allows you to:

- Create and manage a root CA (Certificate Authority)
- Issue client certificates (`.crt`, `.key`, `.p12`)
- Automatically generate Traefik configuration with mTLS settings
- Revoke and delete certificates
- Work in two Traefik integration modes: creating a new router or patching an existing one

The script requires no third-party tools beyond `openssl` and `python3` — both are present in any modern Linux environment.

> Run as root user

---

## Dependencies and requirements

| Dependency | Used for | Required |
|---|---|---|
| `openssl` | Generating CA, CSR, signing certificates, CRL, PKCS#12 | ✅ |
| `python3` | JSON database, YAML patching of Traefik configs | ✅ |
| `bash` ≥ 4 | The script itself | ✅ |
| `ip` (iproute2) | Detecting host IP for Traefik target | No (fallback: `172.17.0.1`) |

On startup, the script automatically checks for `openssl` and `python3`. If missing, it offers to install them via `apt-get`, `yum`, `apk`, or `brew`.

---

## Architecture and structure

```
mtls.sh
├── CONFIG        — load/save settings (~/.mtls-manager.conf)
├── DB            — JSON certificate database (~/.mtls-manager.db)
├── SERVICES      — JSON service list (~/.mtls-manager.services)
├── CA            — create root CA, CRL
├── INT_CA        — intermediate CA per client
├── BUNDLE        — assemble clients-bundle.crt from all active int-CAs
├── PATCH         — patch existing Traefik YAML configs
├── TRAEFIK       — generate mtls-manager.yml
└── UI            — interactive menu (header, hr, ask, menu_choice...)
```

Data is stored in three files in the user's home directory:

| File | Format | Contents |
|---|---|---|
| `~/.mtls-manager.conf` | KEY="value" | Paths, default validity period |
| `~/.mtls-manager.db` | JSON | Certificate metadata (name, service, dates, status, paths) |
| `~/.mtls-manager.services` | JSON array | List of registered services |

---

## Running

```bash
chmod +x mtls.sh
sudo ./mtls.sh
```

> `sudo` is needed if CA and Traefik paths are in `/etc/`. For local testing (preset `p3`), `sudo` is not required.

---

## Main menu

```
🔐  mTLS Certificate Manager
/etc/traefik/dynamic
CA ✔   services: 2   certificates: 5

1)  Create certificate
2)  List certificates
3)  Revoke / delete certificate

4)  Manage services

5)  Create / recreate CA
6)  Path settings
7)  Update Traefik config

0)  Exit
```

CA status and counters are updated every time the main menu is opened.

---

## Module: Service management

**Menu → 4**

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

---

## Module: Certificate creation

**Menu → 1**

Steps:

1. Select a service from the list
2. Set a certificate name (latin characters, no spaces — spaces are replaced with `-`)
3. Specify the validity period (default: value from settings, standard is 365 days)
4. Add a note (for whom / what it was issued)
5. Set a password for the `.p12` file (can be left empty)

The script sequentially executes:

```
openssl genrsa          → client.key (2048 bit)
openssl req -new        → client.csr
create_int_ca()         → intermediate CA for this client
sign_client_with_int_ca → client.crt (signed by intermediate CA)
openssl pkcs12          → client.p12 (key + certificate + root CA)
rebuild_bundle()        → update clients-bundle.crt
do_gen_traefik()        → update mtls-manager.yml
```

The finished `.p12` file can be imported into a browser, mobile device, or used with curl.

### Output file structure

```
/etc/traefik/certs/mtls/clients/
└── <service>/
    └── <cert-name>/
        ├── client.key   — client private key
        ├── client.crt   — client certificate
        └── client.p12   — bundle for import
```

> `client.csr` is deleted after signing — no need to store it.

---

## Module: Certificate list

**Menu → 2**

Displays a table of all certificates with columns:

```
#    Name                Service        Created     Expires     Status           Note
1    alice               myapp          2025-01-15  2026-01-15  ACTIVE           iPhone Alice
2    bob-laptop          myapp          2025-03-01  2025-04-01  EXPIRING (5d)    ...
3    old-cert            api            2024-01-01  2024-12-31  EXPIRED          ...
4    revoked             api            2024-06-01  2025-06-01  REVOKED          ...
```

Statuses:

| Status | Condition | Color |
|---|---|---|
| ACTIVE | Valid, > 30 days until expiry | Green |
| EXPIRING (Nd) | Expires in less than 30 days | Yellow |
| EXPIRED | Expiry date is in the past | Red |
| REVOKED | `revoked=1` field in the database | Red |

---

## Module: Revocation and deletion

**Menu → 3**

Deletion occurs in **two steps** (protection against accidental deletion):

**Step 1 — Revocation:**
Sets the `revoked=1` flag in the database, the client's intermediate CA is excluded from `clients-bundle.crt`, and the Traefik config is updated. The certificate stops working immediately — without restarting Traefik.

**Step 2 — File deletion (on re-entry):**
Deletes the directory containing `client.key`, `client.crt`, `client.p12`, the intermediate CA directory, and the database entry.

> This two-step process prevents accidental irreversible deletion.

---

## Module: CA creation

**Menu → 5**

Creates a root CA on first run or recreates it when needed.

```
CA name (CN)           → mTLS-Root-CA
Validity period (days) → 3650
```

Generates:
- `ca.key` (4096-bit RSA) — private key, permissions 600
- `ca.crt` — self-signed root certificate
- `index.txt`, `serial`, `index.txt.attr` — CA database for OpenSSL
- `crl.pem` — revocation list (initially empty)
- `openssl-ca.cnf` — OpenSSL configuration file

> ⚠️ Recreating the CA invalidates all previously issued certificates.

---

## Module: Path settings

**Menu → 6**

| Parameter | Default |
|---|---|
| Path to Traefik dynamic configs | `/etc/traefik/dynamic` |
| CA path | `/etc/traefik/certs/mtls` |
| Client certificate path | `/etc/traefik/certs/mtls/clients` |
| Output filename | `mtls-manager.yml` |
| Certificate validity (days) | `365` |

Settings are saved to `~/.mtls-manager.conf` with permissions 600.

---

## Internal mechanisms

### Database (db_*)

All metadata is stored in `~/.mtls-manager.db` — a JSON object where the key is `<service>__<certname>`.

```json
{
  "myapp__alice": {
    "name": "alice",
    "service": "myapp",
    "days": "365",
    "note": "iPhone Alice",
    "created": "2025-01-15",
    "expires": "2026-01-15",
    "revoked": "0",
    "path": "/etc/traefik/certs/mtls/clients/myapp/alice",
    "serial": "01",
    "int_ca_path": "/etc/traefik/certs/mtls/intermediates/myapp__alice"
  },
  "__ca__": {
    "cn": "mTLS-Root-CA",
    "days": "3650",
    "created": "2025-01-01 10:00:00"
  }
}
```

The `__ca__` entry stores root CA metadata and is excluded from client certificate lists (by the `__` prefix).

All database operations are implemented via built-in Python3 scripts (heredoc `<< 'PYEOF'`) — no external files.

### Bundle (clients-bundle.crt)

The key file for Traefik. Contains the chain of intermediate CAs for all **active** (non-revoked) clients. Traefik uses it to verify incoming client certificates.

```
rebuild_bundle():
  for each uid in the database:
    if revoked != 1:
      append int-ca.crt to bundle
  if bundle is empty → use ca.crt
```

Automatically updated on every change (issuance / revocation).

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
│   ├── clients-bundle.crt        ← bundle of active int-CAs
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

Int-CA parameters:

```
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
```

`pathlen:0` means the intermediate CA cannot sign other CAs — only end-entity certificates.

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

---

## Clearing browser certificate stores

Each time a new `.p12` is issued, the browser stores not only the client certificate but also the intermediate CA. This can lead to accumulation of outdated entries.

Brief instructions:

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

## Path presets

| Preset | Dynamic path | CA path |
|---|---|---|
| `p1` Dokploy | `/etc/dokploy/traefik/dynamic` | `/etc/dokploy/traefik/dynamic/certificates/ca` |
| `p2` Traefik | `/etc/traefik/dynamic` | `/etc/traefik/certs/ca` |
| `p3` Local | `./traefik-local/dynamic` | `./traefik-local/certs/ca` |

---

## Known limitations

- **No ECDSA support**: the script uses RSA (2048-bit for clients, 4096 for CA). ECDSA is not supported.
- **OCSP/CRL not configurable**: revocation is implemented via bundle, not through standard CRL/OCSP mechanisms.
- **Single bundle for all services**: all services share one `clients-bundle.crt`. Isolating bundles per service requires script modification.
- **Python3 YAML parsing**: patching Traefik configs is implemented via line-by-line parsing, not a yaml library. Non-standard YAML formats may not be handled correctly.
- **No expiry notifications**: the script shows EXPIRING status in the UI but does not send notifications automatically.
