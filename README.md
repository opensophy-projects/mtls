# opensophy-cli (os)

`os` is a modular CLI for OpenSophy tools.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/opensophy-projects/opensophy-cli/main/install.sh | bash
```

## Commands

- `os mtls` — interactive mTLS manager TUI with Docker labels support.

## Architecture

```text
bin/os                 - command dispatcher
lib/core.sh            - shared UI and helper functions
commands/mtls/main.sh  - mTLS command entrypoint and main menu
commands/mtls/config.sh- config load/save
commands/mtls/db.sh    - metadata storage and service CRUD
commands/mtls/docker.sh- Docker labels discovery and sync
install.sh             - bootstrap installer
```

## Docker labels

Supported labels:

- `mtls.enable=true`
- `mtls.service=<service_name>`
- `mtls.domain=<service_domain>`
- `mtls.router=<router_name>`

In TUI: `os mtls` → `🐳 Docker` → `Sync labels -> services`.
