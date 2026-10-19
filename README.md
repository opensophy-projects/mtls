# mtls.sh

<div align="center">

**CLI/TUI-менеджер mTLS-сертификатов для Traefik — одним Bash-скриптом**

[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-2.4-blue)

Корневой CA, клиентские сертификаты, `.p12`, мгновенный отзыв и готовый конфиг Traefik — без CRL, OCSP, сетевых уведомлений и без паролей в argv.

</div>

---

## Содержание

- [Зачем это нужно](#зачем-это-нужно)
- [Как работает отзыв](#как-работает-отзыв)
- [Возможности](#возможности)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Подключение к Traefik](#подключение-к-traefik)
- [Использование клиентского сертификата](#использование-клиентского-сертификата)
- [Режимы сервисов: `new` и `patch`](#режимы-сервисов-new-и-patch)
- [Режимы bundle: `shared` и `per-service`](#режимы-bundle-shared-и-per-service)
- [Справочник CLI](#справочник-cli)
- [Интерактивное меню](#интерактивное-меню)
- [Конфигурация](#конфигурация)
- [Переменные окружения](#переменные-окружения)
- [Файлы и структура каталогов](#файлы-и-структура-каталогов)
- [Резервные копии](#резервные-копии)
- [Журнал аудита](#журнал-аудита)
- [Модель безопасности](#модель-безопасности)
- [Ограничения и нюансы](#ограничения-и-нюансы)
- [CI и тесты](#ci-и-тесты)
- [Лицензия](#лицензия)

---

## Зачем это нужно

- **Traefik не умеет отзывать клиентские сертификаты.** В `clientAuth` есть только `caFiles`: сертификат проходит, если его подписал один из доверенных CA. Опции `crlFile` нет, штатного способа заблокировать одного клиента, не трогая остальных, тоже.
- **CRL/OCSP — избыточно** для 5–20 клиентских сертификатов на домашнем сервере или в небольшой команде.
- **Ручной `openssl` не масштабируется.** Команды на память, файлы разбросаны по серверу, нет истории: кто, когда и зачем выпустил сертификат.

`mtls.sh` решает это так: каждому клиенту выпускается **собственный промежуточный CA**, и в `caFiles` Traefik попадает bundle из этих промежуточных CA. Убрали CA клиента из bundle — клиент больше не проходит. Перезапуск Traefik не нужен: он сам перечитывает dynamic-конфиг.

## Как работает отзыв

```text
Root CA  (ca.crt / ca.key)
 ├── int-ca  alice   ──►  client.crt (alice)   ← лежит в bundle
 ├── int-ca  bob     ──►  client.crt (bob)     ← лежит в bundle
 └── int-ca  carol   ──►  client.crt (carol)   ← лежит в bundle
```

1. **Выпуск** — `cert issue` создаёт ключ клиента и CSR, отдельный промежуточный CA для клиента (подписан корневым), подписывает им клиентский сертификат, проверяет цепочку, собирает `client.p12` и добавляет промежуточный CA в bundle.
2. **Отзыв** — `cert revoke` помечает клиента отозванным в базе, пересобирает bundle **без** его CA и заново записывает `mtls-manager.yml`.
3. **Результат** — Traefik перечитывает конфиг и больше не находит доверенный CA для сертификата клиента: рукопожатие не проходит.

```text
clients-bundle.crt (до)         clients-bundle.crt (после cert revoke для bob)
├─ int-ca.crt  alice            ├─ int-ca.crt  alice
└─ int-ca.crt  bob              └─ (bob убран)
```

## Возможности

- **Корневой CA**: создание (RSA 4096), необязательное шифрование ключа паролем (AES-256), просмотр, резервное копирование и восстановление.
- **Клиентские сертификаты**: выпуск, перевыпуск (renew), проверка цепочки, отзыв, удаление файлов, сканирование сроков.
- **PKCS#12**: `.p12` с обязательным паролем по умолчанию.
- **Traefik**: автогенерация `mtls-manager.yml` (TLS-опции, роутеры, сервисы) и патчинг существующих роутеров в чужих yml-файлах (например, Dokploy).
- **Bundle**: общий (`shared`) или отдельный на каждый сервис (`per-service`).
- **Пресеты путей**: встроенные (Dokploy, Traefik, локальный) и собственные.
- **Аудит**: JSONL-журнал с ротацией в `.gz`.
- **Два режима работы**: интерактивное TUI-меню и неинтерактивный CLI для автоматизации.
- **Безопасная запись**: атомарная замена файлов, отказ от symlink, блокировка через `flock`, валидация имён.

> Интерфейс скрипта (меню, сообщения) — на русском языке.

## Требования

- Linux (частично работает на macOS — есть fallback для `date -j`, но проект ориентирован на Linux);
- Bash 4+;
- `openssl`, `python3`, `flock`, `gzip`, `tar`;
- (необязательно) PyYAML для более строгой проверки результата при патчинге чужих yml-файлов;
- **запуск строго от root** — скрипт работает с приватными ключами CA и клиентов. Запуск от обычного пользователя завершается ошибкой.

Если `openssl` или `python3` не найдены, в интерактивном режиме скрипт предложит установить их через `apt-get`, `yum`, `apk` или `brew`; в неинтерактивном — завершится с ошибкой.

## Быстрый старт

```bash
git clone https://github.com/opensophy-projects/mtls.git
cd mtls
chmod +x mtls.sh
```

**1. Создать корневой CA** (ключ CA рекомендуется зашифровать):

```bash
sudo ./mtls.sh ca create --cn my-root-ca --days 3650 --encrypt
```

**2. Добавить сервис** (новый домен и upstream):

```bash
sudo ./mtls.sh service add \
  --name api \
  --domain api.example.com \
  --target http://127.0.0.1:8080
```

**3. Выпустить клиентский сертификат:**

```bash
# пароль .p12 безопаснее передавать через переменную окружения, а не --pass
export MTLS_P12_PASSWORD='use-a-strong-password'
sudo -E ./mtls.sh cert issue --service api --name alice --days 365 --note "ноутбук Алисы"
```

**4. Проверить:**

```bash
sudo ./mtls.sh cert verify --service api --name alice
sudo ./mtls.sh cert list
```

**5. Отозвать, когда нужно:**

```bash
sudo ./mtls.sh cert revoke --service api --name alice
```

Без аргументов скрипт открывает интерактивное меню:

```bash
sudo ./mtls.sh
```

## Подключение к Traefik

Скрипт записывает конфиг в `${TRAEFIK_DYNAMIC_PATH}/${OUTPUT_FILE}` (по умолчанию `/etc/traefik/dynamic/mtls-manager.yml`). Traefik должен читать этот каталог через file provider с включённым наблюдением:

```yaml
# traefik.yml (статический конфиг)
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

Если Traefik работает в Docker, примонтируйте каталог динамических конфигов **и** каталог с CA (пути в `caFiles` должны существовать внутри контейнера):

```yaml
services:
  traefik:
    volumes:
      - /etc/traefik/dynamic:/etc/traefik/dynamic:ro
      - /etc/traefik/certs/mtls:/etc/traefik/certs/mtls:ro
```

Пример сгенерированного файла (режим `new`, `BUNDLE_MODE=shared`):

```yaml
# Generated by mtls-manager — 2026-10-19 17:48:00
# DO NOT EDIT MANUALLY

tls:
  options:
    mtls-api:
      clientAuth:
        caFiles:
          - "/etc/traefik/certs/mtls/clients-bundle.crt"
        clientAuthType: RequireAndVerifyClientCert
      minVersion: VersionTLS12

http:
  routers:
    api-mtls:
      rule: "Host(`api.example.com`)"
      entryPoints:
        - websecure
      service: api-mtls
      tls:
        options: mtls-api

  services:
    api-mtls:
      loadBalancer:
        servers:
          - url: "http://172.17.0.1:8080"
```

Заметки:

- В `target` адреса `localhost` и `127.0.0.1` автоматически заменяются на IP хоста (его видно из контейнера Traefik). IP определяется так: `MTLS_HOST_IP` → шлюз по умолчанию → `docker0` → первый не-loopback адрес → `172.17.0.1`.
- Если сервисов нет, пишется заглушка `mtls-placeholder`, чтобы файл оставался валидным.
- Файл конфига «трогается» после каждой пересборки bundle — это гарантирует, что Traefik перечитает изменившийся bundle.
- Не редактируйте `mtls-manager.yml` вручную: он перезаписывается целиком.

## Использование клиентского сертификата

Готовые файлы лежат в `${CLIENTS_PATH}/<service>/<name>/`: `client.key`, `client.crt`, `client.p12`. Клиенту передаётся **только `client.p12`** и его пароль — по защищённому каналу.

**curl:**

```bash
curl --cert-type P12 --cert client.p12:'пароль' https://api.example.com/
```

**curl через PEM:**

```bash
openssl pkcs12 -in client.p12 -clcerts -nokeys -out client.pem
openssl pkcs12 -in client.p12 -nocerts -nodes -out client.key.pem
curl --cert client.pem --key client.key.pem https://api.example.com/
```

**Браузер:** импортируйте `.p12` в хранилище сертификатов ОС или браузера (Firefox: Настройки → Приватность и защита → Сертификаты → Просмотр сертификатов → Ваши сертификаты → Импорт).

## Режимы сервисов: `new` и `patch`

| Режим | Что делает скрипт |
|---|---|
| `new` | Создаёт в `mtls-manager.yml` роутер `<имя>-mtls` с правилом `Host(...)`, entrypoint `websecure` и сервис `<имя>-mtls` с upstream из `--target`. |
| `patch` | Не создаёт роутер, а добавляет `tls.options: mtls-<имя>` в **существующий** роутер из другого yml-файла (например, Dokploy). Патч применяется автоматически при первом выпуске сертификата для сервиса. |

Пример `patch`-режима:

```bash
sudo ./mtls.sh service add \
  --name panel \
  --mode patch \
  --patch-file /etc/dokploy/traefik/dynamic/dokploy.yml \
  --router dokploy-router
```

Как скрипт обращается с чужими файлами:

- патч-файл должен быть обычным файлом, без symlink в самом файле и в любом каталоге пути;
- результат патча валидируется до замены (отсутствие табов, разбор через PyYAML, а без него — сравнение структуры верхнего уровня);
- перед заменой делается резервная копия `<файл>.bak.<YYYYMMDDHHMMSS>`;
- `service delete` и `service delete-full` снимают патч.

Удаление сервиса:

| Команда | Эффект |
|---|---|
| `service delete` | Удаляет сервис из базы, снимает патч (для `patch`), перегенерирует конфиг. Сертификаты **не удаляются**. |
| `service delete-full` | Отзывает и удаляет **все** сертификаты сервиса, их файлы и промежуточные CA, снимает патч, удаляет блок Traefik и запись сервиса. Необратимо. |

## Режимы bundle: `shared` и `per-service`

| Режим | Файл bundle | Поведение |
|---|---|---|
| `shared` (по умолчанию) | `clients-bundle.crt` | Один bundle на все сервисы. Сертификат, выпущенный для одного сервиса, проходит и на остальных. |
| `per-service` | `clients-bundle-<сервис>.crt` | Отдельный bundle на каждый сервис — клиенты изолированы друг от друга. |

Переключение: `sudo ./mtls.sh config set BUNDLE_MODE per-service`, затем `sudo ./mtls.sh gen`.

## Справочник CLI

Любой вызов с аргументами работает в неинтерактивном режиме (`MTLS_NONINTERACTIVE=1`): вопросы не задаются, подтверждения принимаются автоматически (см. [нюансы](#ограничения-и-нюансы)).

```text
ca create [--cn ИМЯ] [--days N] [--encrypt]
ca info
ca backup [--output ФАЙЛ]
ca restore --input ФАЙЛ

cert issue  --service S --name N [--days D] [--note ТЕКСТ] [--pass P]
cert list   [--json]
cert revoke --uid UID | --service S --name N
cert delete --uid UID | --service S --name N
cert renew  --uid UID | --service S --name N [--days D] [--pass P]
cert verify --uid UID | --service S --name N
cert scan

service add --name N --domain D --target T [--mode new|patch]
            [--patch-file F --router R]
service list
service delete --name N
service delete-full --name N

preset save --name N [--traefik-path P] [--ca-path P]
                     [--clients-path P] [--output-file F]
preset apply  --name N
preset list
preset delete --name N

config show
config set <КЛЮЧ> <ЗНАЧЕНИЕ>

gen
audit [--last N]
menu
help
```

### Идентификаторы

Сертификат однозначно определяется **UID** вида `<service>__<name>` (например, `api__alice`). Везде, где есть `--uid UID`, можно вместо него указать пару `--service S --name N`.

### Правила имён

Имена сервисов, сертификатов и пресетов:

- только латиница, цифры, `.`, `_`, `-`;
- не длиннее 128 символов;
- не начинаются с `-`;
- не содержат `__` (внутренний разделитель), `/` и `..`.

### Подробнее о командах

**`ca create`** — создаёт корневой CA: ключ RSA 4096, самоподписанный сертификат на `--days` (по умолчанию 3650), инициализирует базу CA, строит `crl.pem` и генерирует конфиг Traefik. С `--encrypt` ключ шифруется AES-256; пароль берётся из `MTLS_CA_PASSPHRASE` или запрашивается.

**`cert issue`** — выпуск сертификата. Если `REQUIRE_P12_PASSWORD=1` (по умолчанию), пароль `.p12` обязателен: передайте `--pass` или `MTLS_P12_PASSWORD`. Выпуск идёт через временный каталог: при любой ошибке существующие файлы не затрагиваются.

**`cert renew`** — перевыпускает сертификат под тем же именем: новый ключ, новый промежуточный CA, новый `.p12`. Старый сертификат отзывается только после успешного выпуска нового. Клиенту нужно передать новый `.p12`.

**`cert revoke`** — помечает сертификат отозванным, пересобирает bundle и конфиг Traefik. Файлы остаются на диске.

**`cert delete`** — отзывает (если ещё не отозван) и удаляет файлы сертификата, его промежуточный CA и запись в базе.

**`cert verify`** — показывает серийный номер, субъект, эмитента, срок действия, SHA-256 отпечаток и результат проверки цепочки.

**`cert scan`** — находит истёкшие, истекающие в течение `EXPIRY_WARN_DAYS` и сертификаты с нераспознанной датой. Если есть что показать, завершается с **ненулевым кодом** — удобно для cron и мониторинга. Внешних уведомлений скрипт не отправляет.

```bash
# пример для cron: раз в сутки проверять сроки и писать в syslog
0 9 * * * root /opt/mtls/mtls.sh cert scan 2>&1 | logger -t mtls
```

**`cert list --json`** — выводит базу сертификатов в JSON (без служебной записи CA).

Статусы в таблице: `АКТИВЕН`, `СКОРО (Nд)`, `ИСТЁК`, `ОТОЗВАН`, `НЕИЗВЕСТНО`.

**`preset`** — сохраняет и применяет наборы путей (`traefik_dynamic_path`, `ca_path`, `clients_path`, `output_file`). Непереданные пути при `preset save` берутся из текущей конфигурации.

**`gen`** — пересобирает bundle и перезаписывает `mtls-manager.yml`.

## Интерактивное меню

Запуск: `sudo ./mtls.sh` (или `sudo ./mtls.sh menu`).

```text
1) Создать сертификат
2) Список сертификатов
3) Отозвать / удалить сертификат
4) Управление сервисами
5) Создать / пересоздать CA
6) Настройка путей
7) Обновить конфиг Traefik
8) Проверить истекающие сертификаты
9) Резервная копия CA + базы
0) Выход
```

В меню «Отозвать / удалить» работает двухшаговая схема: первый вход отзывает сертификат, повторный — удаляет файлы с диска. В «Настройке путей» доступны встроенные пресеты:

| Пресет | Traefik dynamic | CA |
|---|---|---|
| `p1` Dokploy | `/etc/dokploy/traefik/dynamic` | `/etc/dokploy/traefik/dynamic/certificates/ca` |
| `p2` Traefik | `/etc/traefik/dynamic` | `/etc/traefik/certs/mtls` |
| `p3` Локально | `./traefik-local/dynamic` | `./traefik-local/certs/mtls` |

## Конфигурация

Конфиг хранится в `~/.mtls-manager.conf` (права `0600`). Смотреть: `config show`, менять: `config set <КЛЮЧ> <ЗНАЧЕНИЕ>`.

| Ключ | По умолчанию | Описание |
|---|---|---|
| `TRAEFIK_DYNAMIC_PATH` | `/etc/traefik/dynamic` | Каталог dynamic-конфигов Traefik |
| `CA_PATH` | `/etc/traefik/certs/mtls` | Каталог корневого CA, bundle и промежуточных CA |
| `CLIENTS_PATH` | `/etc/traefik/certs/mtls/clients` | Каталог клиентских сертификатов |
| `OUTPUT_FILE` | `mtls-manager.yml` | Имя генерируемого конфига (только basename `*.yml`/`*.yaml`) |
| `CERT_DAYS` | `365` | Срок действия сертификатов по умолчанию, дней |
| `EXPIRY_WARN_DAYS` | `30` | За сколько дней предупреждать об истечении |
| `CA_KEY_ENCRYPTED` | `0` | `1` — ключ CA зашифрован паролем |
| `BUNDLE_MODE` | `shared` | `shared` или `per-service` |
| `REQUIRE_P12_PASSWORD` | `1` | `1` — `.p12` без пароля не создаётся молча |
| `AUDIT_MAX_BYTES` | `10485760` | Порог ротации журнала аудита (10 МиБ), `0` — отключить |

## Переменные окружения

| Переменная | Назначение |
|---|---|
| `MTLS_CONFIG_FILE`, `MTLS_DB_FILE`, `MTLS_SERVICES_FILE`, `MTLS_PRESETS_FILE`, `MTLS_AUDIT_FILE` | Переопределяют расположение файлов состояния (удобно для тестов и изолированных установок) |
| `MTLS_HOST_IP` | Принудительно задаёт IP хоста для подстановки вместо `localhost`/`127.0.0.1` в `target` |
| `MTLS_CA_PASSPHRASE` | Пароль зашифрованного ключа CA. Если не задан, скрипт спросит его сам и сохранит только в обычной (не экспортируемой) переменной |
| `MTLS_P12_PASSWORD` | Пароль `.p12` по умолчанию для неинтерактивного выпуска и renew |
| `MTLS_NONINTERACTIVE` | `1` — не задавать вопросов (включается автоматически при любом CLI-вызове) |
| `TMPDIR` | Базовый каталог для временного каталога `mtls-manager.XXXXXX` |

## Файлы и структура каталогов

Файлы состояния (в домашнем каталоге root, права `0600`):

| Файл | Содержимое |
|---|---|
| `~/.mtls-manager.conf` | конфигурация |
| `~/.mtls-manager.db` | записи сертификатов и служебная запись CA (JSON) |
| `~/.mtls-manager.services` | список сервисов (JSON) |
| `~/.mtls-manager.presets` | пресеты путей (JSON) |
| `~/.mtls-manager.audit.jsonl` | журнал аудита (+ `.1.gz` после ротации) |
| `~/.mtls-manager.db.lock` | файл блокировки |

Каталоги с ключевым материалом (значения по умолчанию):

```text
/etc/traefik/certs/mtls/
├── ca.key                     # приватный ключ корневого CA (600)
├── ca.crt                     # сертификат корневого CA
├── crl.pem                    # CRL для внешних потребителей (Traefik его не использует)
├── index.txt, serial, ...     # база OpenSSL CA
├── openssl-ca.cnf
├── clients-bundle.crt         # bundle (shared) или clients-bundle-<svc>.crt (per-service)
├── intermediates/
│   └── <service>__<name>/
│       ├── int-ca.crt
│       └── int-ca.key
└── clients/
    └── <service>/
        └── <name>/
            ├── client.key
            ├── client.crt
            └── client.p12

/etc/traefik/dynamic/
└── mtls-manager.yml           # генерируется скриптом
```

## Резервные копии

```bash
sudo ./mtls.sh ca backup --output /root/backups/mtls-$(date +%F).tar.gz
sudo ./mtls.sh ca restore --input /root/backups/mtls-2026-10-19.tar.gz
```

- В архив входят конфиг, база, сервисы, пресеты, журнал аудита (и `.1.gz`) и **весь** каталог `CA_PATH` со всеми ключами.
- Архив создаётся с правами `0600`. **Он содержит приватные ключи CA и клиентов** — храните его зашифрованным и вне сервера.
- Без `--output` архив кладётся в `~/mtls-backup-<дата-время>.tar.gz`.
- `restore` перезаписывает CA, базу и конфиг, запрашивает подтверждение и **отклоняет небезопасные архивы**: пути за пределами каталога, symlink, hardlink и специальные файлы.

## Журнал аудита

Каждое значимое действие пишется в `~/.mtls-manager.audit.jsonl` в формате JSON Lines:

```json
{"ts": "2026-10-19T10:48:00Z", "action": "cert_create", "actor": "admin", "detail": "uid=api__alice service=api expires=2027-10-19 p12_password_set=1"}
```

- `actor` — `SUDO_USER`, а при его отсутствии `USER`.
- Фиксируются: `ca_create`, `cert_create`, `cert_renew`, `cert_revoke`, `cert_delete`, `scan_expiry`, `service_add`, `service_delete`, `service_delete_full`, `preset_save`, `preset_apply`, `preset_delete`, `config_set`, `backup`, `restore`.
- Пароли и ключи в журнал не попадают (для `.p12` пишется только факт `p12_password_set=0|1`).
- При превышении `AUDIT_MAX_BYTES` журнал архивируется в `.1.gz` (предыдущий архив заменяется), после чего начинается новый файл.
- Просмотр: `sudo ./mtls.sh audit --last 20`.

## Модель безопасности

- **Только root.** Скрипт завершается, если UID ≠ 0. Многопользовательского режима нет.
- **Права:** state-файлы `0600`, каталоги CA и клиентов `0700`, закрытые ключи `0600`.
- **Секреты не в argv.** Пароли передаются в `openssl` через временные файлы `0600` в каталоге `0700`, который удаляется при выходе (`EXIT`, `INT`, `TERM`). Пароль из `--pass` всё же виден в history и `ps` — используйте `MTLS_P12_PASSWORD` или интерактивный ввод.
- **Атомарная запись и защита от symlink.** Файлы состояния и конфиги заменяются через временный файл и `mv`; запись в symlink отклоняется. При старте скрипт отказывается работать, если любой из его файлов состояния — symlink.
- **Валидация входных данных:** имена (whitelist), домены, upstream URL, имя выходного файла, пути патчей.
- **Безопасный патчинг чужих конфигов:** проверка результата до замены, `.bak` с меткой времени.
- **Блокировка** через `flock` на время выполнения команды защищает базу от конкурентной порчи.
- **Нет сети.** Скрипт не отправляет уведомления, не использует webhook и `eval`.
- Промежуточные CA выпускаются с `pathlen:0`, клиентские сертификаты — с `extendedKeyUsage = clientAuth`.

Это не заменяет защиту хоста: ограничьте доступ к `/etc/traefik`, домашнему каталогу root, резервным копиям и секретам CI.

## Ограничения и нюансы

- **Отзыв = исключение из bundle.** Он действует, как только Traefik перечитает конфиг. Запись об отзыве в `index.txt` OpenSSL **не добавляется**, поэтому `crl.pem` — пустой CRL, пригодный лишь как формальный артефакт; не рассчитывайте на него для блокировки клиентов.
- **Подтверждения в CLI принимаются автоматически.** В неинтерактивном режиме `ask_yn` всегда отвечает «да»: `ca create` поверх существующего CA пересоздаст его (аннулируя **все** выпущенные сертификаты), `cert delete` удалит файлы без вопроса, а `cert issue` для уже существующего неотозванного сертификата перевыпустит его. Используйте CLI осознанно.
- **Срок промежуточного CA** задаётся значением `CERT_DAYS`, а не `--days` конкретного сертификата. Если выпускаете клиентский сертификат на срок, превышающий `CERT_DAYS`, увеличьте `CERT_DAYS` заранее — иначе промежуточный CA истечёт раньше клиента.
- **Пустой bundle.** Если не осталось ни одного активного сертификата, bundle содержит корневой CA, чтобы файл оставался валидным.
- **`per-service` bundle** создаётся только для сервисов, у которых есть хотя бы один сертификат в базе.
- **Пересоздание CA** делает недействительными все ранее выпущенные сертификаты — их придётся выпустить заново.
- Скрипт не перезапускает Traefik; для перечитывания конфига нужен включённый `watch: true` в file provider.

## CI и тесты

Workflow `.github/workflows/ci.yml` запускается на push и pull request:

1. `bash -n` — проверка синтаксиса;
2. ShellCheck;
3. smoke-тест CLI;
4. security-инварианты: отсутствие webhook/сетевых путей и `eval`, root guard, safe replace, файловые права.

Локальный запуск:

```bash
bash -n mtls.sh tests/mtls_smoke.sh
bash tests/mtls_smoke.sh
```

## Лицензия

MIT — [opensophy-projects](https://github.com/opensophy-projects/mtls).
