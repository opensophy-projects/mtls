<div align="center">

# 🔐 mtls.sh

### mTLS-сертификаты для Traefik — одним Bash-скриптом

Корневой CA · клиентские сертификаты · `.p12` · мгновенный отзыв · готовый конфиг Traefik.<br>
Без CRL, без OCSP, без сетевых уведомлений и без паролей в argv.

<br>

![Version](https://img.shields.io/badge/version-2.4-2563eb?style=for-the-badge)
![Bash](https://img.shields.io/badge/Bash-4%2B-4eaa25?style=for-the-badge&logo=gnubash&logoColor=white)
![OpenSSL](https://img.shields.io/badge/OpenSSL-required-721412?style=for-the-badge&logo=openssl&logoColor=white)
![Traefik](https://img.shields.io/badge/Traefik-file%20provider-24a1c1?style=for-the-badge&logo=traefikproxy&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-2ea44f?style=for-the-badge)

<br>

</div>

---

## ✨ Возможности

| | |
|---|---|
| 🏛️ **Корневой CA** | Создание (RSA 4096), шифрование ключа паролем (AES-256), просмотр, бэкап и restore |
| 🪪 **Клиентские сертификаты** | Выпуск, перевыпуск, проверка цепочки, отзыв, удаление, сканирование сроков |
| 📦 **PKCS#12** | `.p12` с обязательным паролем по умолчанию |
| 🚦 **Отзыв без перезапуска** | У каждого клиента свой промежуточный CA — убрали из bundle, и доступ закрыт |
| 🧩 **Traefik** | Автогенерация `mtls-manager.yml` и патчинг существующих роутеров (Dokploy и др.) |
| 🗂️ **Bundle** | Общий (`shared`) или отдельный на каждый сервис (`per-service`) |
| 🎛️ **Пресеты путей** | Встроенные (Dokploy, Traefik, локальный) и собственные |
| 📜 **Аудит** | JSONL-журнал с ротацией в `.gz` |
| 🖥️ **Два режима** | Интерактивное TUI-меню и неинтерактивный CLI для автоматизации |
| 🛡️ **Безопасная запись** | Атомарная замена файлов, отказ от symlink, `flock`, валидация имён |

> [!NOTE]
> Интерфейс скрипта (меню и сообщения) — на русском языке.

---

## 🤔 Зачем это нужно

- **Traefik не умеет отзывать клиентские сертификаты.** В `clientAuth` есть только `caFiles`: сертификат проходит, если его подписал один из доверенных CA. Опции `crlFile` нет, а штатного способа заблокировать одного клиента, не трогая остальных, тоже.
- **CRL/OCSP — избыточно** для 5–20 клиентских сертификатов на homelab-сервере или в небольшой команде.
- **Ручной `openssl` не масштабируется.** Команды на память, файлы разбросаны по серверу, нет истории: кто, когда и зачем выпустил сертификат.

---

## 🔄 Как работает отзыв

Каждому клиенту выпускается **собственный промежуточный CA**, и в `caFiles` Traefik попадает bundle из этих промежуточных CA. Убрали CA клиента из bundle — клиент больше не проходит.

| Шаг | Команда | Что происходит |
|:---:|---|---|
| **1** | `cert issue` | Создаётся ключ клиента, промежуточный CA, подпись, проверка цепочки, `.p12`. Промежуточный CA добавляется в bundle |
| **2** | `cert revoke` | Клиент помечается отозванным, bundle пересобирается **без** его CA, `mtls-manager.yml` перезаписывается |
| **3** | — | Traefik перечитывает конфиг и не находит CA для сертификата клиента. **Перезапуск не нужен** |

```text
clients-bundle.crt (до)          clients-bundle.crt (после cert revoke bob)
├─ int-ca.crt  alice             ├─ int-ca.crt  alice
└─ int-ca.crt  bob               └─ ✂ bob убран
```

---

## 📋 Требования

- 🐧 Linux (есть fallback для `date -j` на macOS, но проект ориентирован на Linux)
- Bash 4+
- `openssl`, `python3`, `flock`, `gzip`, `tar`
- *(необязательно)* PyYAML — для более строгой проверки при патчинге чужих yml-файлов
- **root** — скрипт работает с приватными ключами CA и клиентов; от обычного пользователя он завершится с ошибкой

> [!TIP]
> Если `openssl` или `python3` не найдены, в интерактивном режиме скрипт предложит установить их через `apt-get`, `yum`, `apk` или `brew`.

---

## 🚀 Быстрый старт

```bash
git clone https://github.com/opensophy-projects/mtls.git
cd mtls
chmod +x mtls.sh
```

**1️⃣ Создать корневой CA** (ключ рекомендуется зашифровать):

```bash
sudo ./mtls.sh ca create --cn my-root-ca --days 3650 --encrypt
```

**2️⃣ Добавить сервис:**

```bash
sudo ./mtls.sh service add \
  --name api \
  --domain api.example.com \
  --target http://127.0.0.1:8080
```

**3️⃣ Выпустить клиентский сертификат:**

```bash
export MTLS_P12_PASSWORD='use-a-strong-password'
sudo -E ./mtls.sh cert issue --service api --name alice --days 365 --note "ноутбук Алисы"
```

**4️⃣ Проверить:**

```bash
sudo ./mtls.sh cert verify --service api --name alice
sudo ./mtls.sh cert list
```

**5️⃣ Отозвать, когда нужно:**

```bash
sudo ./mtls.sh cert revoke --service api --name alice
```

Без аргументов скрипт открывает интерактивное меню: `sudo ./mtls.sh`

> [!WARNING]
> Не передавайте пароль через `--pass`: он виден в history и `ps`. Используйте `MTLS_P12_PASSWORD` или интерактивный ввод.

---

## 🌐 Подключение к Traefik

Скрипт пишет конфиг в `${TRAEFIK_DYNAMIC_PATH}/${OUTPUT_FILE}` (по умолчанию `/etc/traefik/dynamic/mtls-manager.yml`). Traefik должен читать этот каталог через file provider **с включённым наблюдением**:

```yaml
# traefik.yml (статический конфиг)
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

Если Traefik работает в Docker, примонтируйте и каталог конфигов, и каталог с CA — пути из `caFiles` должны существовать внутри контейнера:

```yaml
services:
  traefik:
    volumes:
      - /etc/traefik/dynamic:/etc/traefik/dynamic:ro
      - /etc/traefik/certs/mtls:/etc/traefik/certs/mtls:ro
```

<details>
<summary><b>📄 Пример сгенерированного mtls-manager.yml</b></summary>

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

</details>

- В `target` адреса `localhost` и `127.0.0.1` автоматически заменяются на IP хоста. Он определяется так: `MTLS_HOST_IP` → шлюз по умолчанию → `docker0` → первый не-loopback адрес → `172.17.0.1`.
- Если сервисов нет, пишется заглушка `mtls-placeholder`, чтобы файл оставался валидным.
- После каждой пересборки bundle файл конфига «трогается», чтобы Traefik гарантированно перечитал изменения.
- Не редактируйте `mtls-manager.yml` вручную — он перезаписывается целиком.

---

## 💻 Использование клиентского сертификата

Готовые файлы лежат в `${CLIENTS_PATH}/<service>/<name>/`: `client.key`, `client.crt`, `client.p12`. Клиенту передаётся **только `client.p12`** и его пароль — по защищённому каналу.

**curl (PKCS#12):**

```bash
curl --cert-type P12 --cert client.p12:'пароль' https://api.example.com/
```

**curl (PEM):**

```bash
openssl pkcs12 -in client.p12 -clcerts -nokeys -out client.pem
openssl pkcs12 -in client.p12 -nocerts -nodes -out client.key.pem
curl --cert client.pem --key client.key.pem https://api.example.com/
```

**Браузер:** импортируйте `.p12` в хранилище сертификатов ОС или браузера.
Firefox: *Настройки → Приватность и защита → Сертификаты → Просмотр сертификатов → Ваши сертификаты → Импорт*.

---

## 🧱 Режимы сервисов

| Режим | Что делает скрипт |
|:---:|---|
| 🆕 **`new`** | Создаёт в `mtls-manager.yml` роутер `<имя>-mtls` с `Host(...)`, entrypoint `websecure` и сервис `<имя>-mtls` с upstream из `--target` |
| 🩹 **`patch`** | Добавляет `tls.options: mtls-<имя>` в **существующий** роутер из другого yml-файла (например, Dokploy). Применяется автоматически при первом выпуске сертификата |

```bash
sudo ./mtls.sh service add \
  --name panel \
  --mode patch \
  --patch-file /etc/dokploy/traefik/dynamic/dokploy.yml \
  --router dokploy-router
```

<details>
<summary><b>🔎 Как скрипт обращается с чужими файлами</b></summary>

- патч-файл должен быть обычным файлом, без symlink в самом файле и в любом каталоге пути;
- результат патча валидируется до замены (нет табов, разбор через PyYAML, а без него — сравнение структуры верхнего уровня);
- перед заменой делается копия `<файл>.bak.<YYYYMMDDHHMMSS>`;
- `service delete` и `service delete-full` снимают патч.

</details>

**Удаление сервиса:**

| Команда | Эффект |
|---|---|
| `service delete` | Удаляет сервис из базы, снимает патч, перегенерирует конфиг. Сертификаты **остаются** |
| `service delete-full` | Отзывает и удаляет **все** сертификаты сервиса, их файлы и промежуточные CA, снимает патч, удаляет блок Traefik и запись сервиса. ⚠️ Необратимо |

---

## 🗂️ Режимы bundle

| Режим | Файл | Поведение |
|:---:|---|---|
| **`shared`** *(по умолчанию)* | `clients-bundle.crt` | Один bundle на все сервисы. Сертификат одного сервиса проходит и на остальных |
| **`per-service`** | `clients-bundle-<сервис>.crt` | Отдельный bundle на сервис — клиенты изолированы друг от друга |

```bash
sudo ./mtls.sh config set BUNDLE_MODE per-service
sudo ./mtls.sh gen
```

---

## 📚 Справочник CLI

Любой вызов с аргументами работает в неинтерактивном режиме: вопросы не задаются, подтверждения принимаются автоматически (см. [нюансы](#%EF%B8%8F-ограничения-и-нюансы)).

```text
ca       create [--cn ИМЯ] [--days N] [--encrypt] | info | backup [--output ФАЙЛ] | restore --input ФАЙЛ
cert     issue | list [--json] | revoke | delete | renew | verify | scan
service  add | list | delete | delete-full
preset   save | apply | list | delete
config   show | set <КЛЮЧ> <ЗНАЧЕНИЕ>
gen      audit [--last N]      menu      help
```

<details>
<summary><b>📖 Полный синтаксис команд</b></summary>

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
```

</details>

### Идентификаторы и имена

Сертификат определяется **UID** вида `<service>__<name>` (например, `api__alice`). Везде, где есть `--uid UID`, можно указать пару `--service S --name N`.

Имена сервисов, сертификатов и пресетов: только латиница, цифры, `.`, `_`, `-`; не длиннее 128 символов; не начинаются с `-`; не содержат `__`, `/` и `..`.

### Команды подробнее

| Команда | Описание |
|---|---|
| **`ca create`** | Ключ RSA 4096, самоподписанный сертификат на `--days` (по умолчанию 3650), база CA, `crl.pem`, конфиг Traefik. С `--encrypt` ключ шифруется AES-256; пароль берётся из `MTLS_CA_PASSPHRASE` или запрашивается |
| **`cert issue`** | При `REQUIRE_P12_PASSWORD=1` пароль `.p12` обязателен (`--pass` или `MTLS_P12_PASSWORD`). Выпуск идёт через временный каталог: при ошибке существующие файлы не затрагиваются |
| **`cert renew`** | Новый ключ, новый промежуточный CA и новый `.p12` под тем же именем. Старый отзывается только после успешного выпуска нового. Клиенту нужен новый `.p12` |
| **`cert revoke`** | Помечает сертификат отозванным, пересобирает bundle и конфиг. Файлы остаются на диске |
| **`cert delete`** | Отзывает (если ещё не отозван) и удаляет файлы, промежуточный CA и запись в базе |
| **`cert verify`** | Серийный номер, субъект, эмитент, срок, SHA-256 отпечаток и результат проверки цепочки |
| **`cert scan`** | Ищет истёкшие, истекающие за `EXPIRY_WARN_DAYS` и сертификаты с нераспознанной датой. Если есть что показать — **ненулевой код выхода** |
| **`cert list --json`** | База сертификатов в JSON (без служебной записи CA) |
| **`preset`** | Наборы путей: `traefik_dynamic_path`, `ca_path`, `clients_path`, `output_file`. Непереданные пути берутся из текущей конфигурации |
| **`gen`** | Пересобирает bundle и перезаписывает `mtls-manager.yml` |

Статусы в таблице: 🟢 `АКТИВЕН` · 🟡 `СКОРО (Nд)` · 🔴 `ИСТЁК` · 🔴 `ОТОЗВАН` · 🔴 `НЕИЗВЕСТНО`

```bash
# cron: раз в сутки проверять сроки и писать в syslog
0 9 * * * root /opt/mtls/mtls.sh cert scan 2>&1 | logger -t mtls
```

---

## 🖥️ Интерактивное меню

Запуск: `sudo ./mtls.sh` (или `sudo ./mtls.sh menu`)

```text
  Менеджер mTLS-сертификатов v2.4 (root)
  ──────────────────────────────────────────────
  1)  Создать сертификат
  2)  Список сертификатов
  3)  Отозвать / удалить сертификат
  4)  Управление сервисами
  5)  Создать / пересоздать CA
  6)  Настройка путей
  7)  Обновить конфиг Traefik
  8)  Проверить истекающие сертификаты
  9)  Резервная копия CA + базы
  0)  Выход
```

В пункте «Отозвать / удалить» работает двухшаговая схема: первый вход отзывает сертификат, повторный удаляет файлы с диска.

**Встроенные пресеты путей** (меню «Настройка путей»):

| Пресет | Traefik dynamic | CA |
|:---:|---|---|
| `p1` Dokploy | `/etc/dokploy/traefik/dynamic` | `/etc/dokploy/traefik/dynamic/certificates/ca` |
| `p2` Traefik | `/etc/traefik/dynamic` | `/etc/traefik/certs/mtls` |
| `p3` Локально | `./traefik-local/dynamic` | `./traefik-local/certs/mtls` |

---

## ⚙️ Конфигурация

Конфиг хранится в `~/.mtls-manager.conf` (права `0600`). Смотреть: `config show`, менять: `config set <КЛЮЧ> <ЗНАЧЕНИЕ>`.

| Ключ | По умолчанию | Описание |
|---|---|---|
| `TRAEFIK_DYNAMIC_PATH` | `/etc/traefik/dynamic` | Каталог dynamic-конфигов Traefik |
| `CA_PATH` | `/etc/traefik/certs/mtls` | Корневой CA, bundle и промежуточные CA |
| `CLIENTS_PATH` | `/etc/traefik/certs/mtls/clients` | Клиентские сертификаты |
| `OUTPUT_FILE` | `mtls-manager.yml` | Имя генерируемого конфига (только basename `*.yml` / `*.yaml`) |
| `CERT_DAYS` | `365` | Срок сертификатов по умолчанию, дней |
| `EXPIRY_WARN_DAYS` | `30` | За сколько дней предупреждать об истечении |
| `CA_KEY_ENCRYPTED` | `0` | `1` — ключ CA зашифрован паролем |
| `BUNDLE_MODE` | `shared` | `shared` или `per-service` |
| `REQUIRE_P12_PASSWORD` | `1` | `1` — `.p12` без пароля не создаётся молча |
| `AUDIT_MAX_BYTES` | `10485760` | Порог ротации аудит-лога (10 МиБ); `0` — выключено |

### Переменные окружения

| Переменная | Назначение |
|---|---|
| `MTLS_CONFIG_FILE`, `MTLS_DB_FILE`, `MTLS_SERVICES_FILE`, `MTLS_PRESETS_FILE`, `MTLS_AUDIT_FILE` | Переопределяют расположение файлов состояния (для тестов и изолированных установок) |
| `MTLS_HOST_IP` | Принудительный IP хоста для подстановки вместо `localhost` / `127.0.0.1` в `target` |
| `MTLS_CA_PASSPHRASE` | Пароль зашифрованного ключа CA. Если не задан, скрипт спросит сам и сохранит только в обычной (не экспортируемой) переменной |
| `MTLS_P12_PASSWORD` | Пароль `.p12` по умолчанию для неинтерактивного выпуска и renew |
| `MTLS_NONINTERACTIVE` | `1` — не задавать вопросов (включается автоматически при любом CLI-вызове) |
| `TMPDIR` | Базовый каталог для временного каталога `mtls-manager.XXXXXX` |

---

## 📁 Файлы и структура каталогов

**Файлы состояния** (в домашнем каталоге root, права `0600`):

| Файл | Содержимое |
|---|---|
| `~/.mtls-manager.conf` | конфигурация |
| `~/.mtls-manager.db` | записи сертификатов и служебная запись CA (JSON) |
| `~/.mtls-manager.services` | список сервисов (JSON) |
| `~/.mtls-manager.presets` | пресеты путей (JSON) |
| `~/.mtls-manager.audit.jsonl` | журнал аудита (+ `.1.gz` после ротации) |
| `~/.mtls-manager.db.lock` | файл блокировки |

**Каталоги с ключевым материалом** (значения по умолчанию):

```text
/etc/traefik/certs/mtls/
├── ca.key                      🔑 приватный ключ корневого CA (600)
├── ca.crt                      сертификат корневого CA
├── crl.pem                     CRL для внешних потребителей (Traefik его не использует)
├── index.txt, serial, …        база OpenSSL CA
├── openssl-ca.cnf
├── clients-bundle.crt          bundle (shared) или clients-bundle-<svc>.crt (per-service)
├── intermediates/
│   └── <service>__<name>/
│       ├── int-ca.crt
│       └── int-ca.key
└── clients/
    └── <service>/
        └── <name>/
            ├── client.key
            ├── client.crt
            └── client.p12      ← это файл для клиента

/etc/traefik/dynamic/
└── mtls-manager.yml            генерируется скриптом
```

---

## 💾 Резервные копии

```bash
sudo ./mtls.sh ca backup  --output /root/backups/mtls-$(date +%F).tar.gz
sudo ./mtls.sh ca restore --input  /root/backups/mtls-2026-10-19.tar.gz
```

- В архив входят конфиг, база, сервисы, пресеты, журнал аудита (и `.1.gz`) и **весь** каталог `CA_PATH`.
- Права архива — `0600`. Без `--output` он создаётся в `~/mtls-backup-<дата-время>.tar.gz`.
- `restore` перезаписывает CA, базу и конфиг, запрашивает подтверждение и **отклоняет небезопасные архивы**: пути за пределами каталога, symlink, hardlink и специальные файлы.

> [!CAUTION]
> Архив содержит **приватные ключи CA и клиентов**. Храните его зашифрованным и вне сервера.

---

## 📜 Журнал аудита

Каждое значимое действие пишется в `~/.mtls-manager.audit.jsonl` (JSON Lines):

```json
{"ts": "2026-10-19T10:48:00Z", "action": "cert_create", "actor": "admin", "detail": "uid=api__alice service=api expires=2027-10-19 p12_password_set=1"}
```

- `actor` — это `SUDO_USER`, а при его отсутствии `USER`.
- Фиксируются: `ca_create`, `cert_create`, `cert_renew`, `cert_revoke`, `cert_delete`, `scan_expiry`, `service_add`, `service_delete`, `service_delete_full`, `preset_save`, `preset_apply`, `preset_delete`, `config_set`, `backup`, `restore`.
- Пароли и ключи в журнал не попадают — для `.p12` пишется только факт `p12_password_set=0|1`.
- При превышении `AUDIT_MAX_BYTES` журнал архивируется в `.1.gz` (прежний архив заменяется), затем начинается новый файл.
- Просмотр: `sudo ./mtls.sh audit --last 20`

---

## 🛡️ Модель безопасности

| | |
|---|---|
| 👤 **Только root** | UID ≠ 0 — скрипт завершается. Многопользовательского режима нет |
| 🔒 **Права** | state-файлы `0600`, каталоги CA и клиентов `0700`, закрытые ключи `0600` |
| 🤫 **Секреты не в argv** | Пароли идут в `openssl` через временные файлы `0600` в каталоге `0700`; он удаляется при выходе (`EXIT`, `INT`, `TERM`) |
| ⚛️ **Атомарная запись** | Временный файл + `mv`; запись в symlink отклоняется. Если любой файл состояния — symlink, скрипт не стартует |
| ✅ **Валидация** | Имена (whitelist), домены, upstream URL, имя выходного файла, пути патчей |
| 🩹 **Патчинг чужих конфигов** | Проверка результата до замены, `.bak` с меткой времени |
| 🔐 **Блокировка** | `flock` на время команды защищает базу от конкурентной порчи |
| 📴 **Нет сети** | Никаких уведомлений, webhook и `eval` |
| 🧾 **Ограничения ключей** | Промежуточные CA — `pathlen:0`, клиентские сертификаты — `extendedKeyUsage = clientAuth` |

> [!IMPORTANT]
> Это не заменяет защиту хоста: ограничьте доступ к `/etc/traefik`, домашнему каталогу root, резервным копиям и секретам.

---

## ⚠️ Ограничения и нюансы

- **Отзыв = исключение из bundle.** Он действует, как только Traefik перечитает конфиг. Запись об отзыве в `index.txt` OpenSSL **не добавляется**, поэтому `crl.pem` — пустой CRL и нужен лишь как формальный артефакт. Не рассчитывайте на него для блокировки клиентов.
- **Подтверждения в CLI принимаются автоматически.** В неинтерактивном режиме `ask_yn` всегда отвечает «да»: `ca create` поверх существующего CA пересоздаст его (аннулируя **все** сертификаты), `cert delete` удалит файлы без вопроса, `cert issue` для существующего неотозванного сертификата перевыпустит его.
- **Срок промежуточного CA** задаётся `CERT_DAYS`, а не `--days` конкретного сертификата. Если клиентский сертификат должен жить дольше `CERT_DAYS`, увеличьте его заранее — иначе промежуточный CA истечёт раньше клиента.
- **Пустой bundle.** Если активных сертификатов не осталось, в bundle кладётся корневой CA, чтобы файл оставался валидным.
- **`per-service` bundle** создаётся только для сервисов, у которых есть хотя бы один сертификат в базе.
- **Пересоздание CA** делает недействительными все ранее выпущенные сертификаты.
- Скрипт **не перезапускает Traefik** — для перечитывания конфига нужен `watch: true` в file provider.

---

<div align="center">

## 📄 Лицензия

MIT — [opensophy-projects](https://github.com/opensophy-projects/mtls)

<sub>Сделано для тех, кому нужен mTLS на Traefik без лишней инфраструктуры.</sub>

</div>
