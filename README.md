# mtls.sh

<div align="center">

**Безопасный CLI/TUI-менеджер mTLS-сертификатов для Traefik**

[![CI](https://github.com/opensophy-projects/mtls/actions/workflows/ci.yml/badge.svg)](https://github.com/opensophy-projects/mtls/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f.svg)](LICENSE)

Управляйте CA, клиентскими сертификатами, PKCS#12, отзывом и Traefik-конфигурацией из одного Bash-скрипта — без сетевых уведомлений и без передачи паролей через argv.

</div>

## Возможности

- создание и просмотр собственного CA;
- выпуск, продление, проверка, отзыв и удаление клиентских сертификатов;
- защищённые `.p12`-файлы и зашифрованный ключ CA;
- shared или per-service CA bundle — отзыв в Traefik выполняется пересборкой bundle;
- сервисы в режимах `new` и `patch`;
- сохранение и применение именованных пресетов путей;
- JSONL-аудит с ограниченной ротацией;
- неинтерактивный CLI для автоматизации;
- CI с Bash syntax check, ShellCheck и smoke/security tests.

## Требования

- Linux;
- Bash 4+;
- OpenSSL, Python 3, `flock`, `gzip`;
- запуск от `root` — скрипт работает с приватным материалом.

## Быстрый старт

```bash
sudo ./mtls.sh help
sudo ./mtls.sh ca create --cn my-root-ca
sudo ./mtls.sh service add --name api --domain api.example.test --target http://127.0.0.1:8080
sudo ./mtls.sh gen
sudo ./mtls.sh cert issue --service api --name alice --pass 'use-a-strong-password'
sudo ./mtls.sh cert verify --service api --name alice
```

Для production не передавайте секреты в командной строке: значение `--pass` может попасть в history или process list. Используйте интерактивный режим либо контролируемое окружение CI с защищёнными секретами.

## CLI

```text
ca create|info|backup|restore
cert issue|list|revoke|delete|renew|verify|scan
service add|list|delete|delete-full
preset save|apply|list|delete
config show|set
gen
audit [--last N]
```

Полная справка доступна командой `sudo ./mtls.sh help`.

### Пресеты

```bash
sudo ./mtls.sh preset save --name staging \
  --traefik-path /etc/traefik/dynamic \
  --ca-path /etc/traefik/certs/mtls \
  --clients-path /etc/traefik/certs/mtls/clients \
  --output-file mtls-manager.yml
sudo ./mtls.sh preset apply --name staging
sudo ./mtls.sh preset list
```

Имена проходят строгую валидацию: запрещены `/`, `..`, `__` и shell-метасимволы.

## Модель безопасности

- state-файлы создаются с mode `0600`, каталоги с `0700`;
- запись выполняется атомарно, а symlink в destination отклоняется;
- все внешние имена проходят whitelist-валидацию;
- пароль OpenSSL передаётся через временный файл `0600`, а не через argv;
- CA и клиентский ключевой материал доступен только root;
- блокировка БД предотвращает конкурентную порчу состояния;
- audit log не отправляется по сети и ротируется после заданного лимита;
- перед заменой Traefik YAML результат валидируется, исходный файл сохраняется как `.bak`;
- `crl.pem` — дополнительный артефакт для внешних потребителей. Traefik использует bundle `caFiles`, поэтому отзыв в этом инструменте реализован исключением сертификата из bundle.

Это не заменяет hardening хоста: защищайте `/etc/traefik`, домашний каталог root, резервные копии и права доступа к CI secrets.

## Конфигурация и файлы состояния

По умолчанию используются:

| Файл | Назначение |
|---|---|
| `~/.mtls-manager.conf` | конфигурация |
| `~/.mtls-manager.db` | записи сертификатов |
| `~/.mtls-manager.services` | сервисы |
| `~/.mtls-manager.presets` | пресеты путей |
| `~/.mtls-manager.audit.jsonl` | audit log |

Для тестов и изолированных установок доступны `MTLS_CONFIG_FILE`, `MTLS_DB_FILE`, `MTLS_SERVICES_FILE`, `MTLS_PRESETS_FILE`, `MTLS_AUDIT_FILE`.

## CI/CD

Workflow `.github/workflows/ci.yml` запускается на push и pull request и выполняет:

1. `bash -n`;
2. ShellCheck;
3. smoke-тест CLI;
4. security invariants: отсутствие webhook/network/eval-пути, root guard, safe replace и файловых прав.

Локальный запуск:

```bash
bash -n mtls.sh tests/mtls_smoke.sh
bash tests/mtls_smoke.sh
```

## Лицензия

MIT — opensophy-projects.
