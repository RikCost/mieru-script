# mieru-script

Автоматическая установка и управление прокси-сервером **mita** (серверная часть
[enfein/mieru](https://github.com/enfein/mieru)) на VPS под Debian / Ubuntu /
RHEL / Fedora / CentOS.

Вам нужно ввести только имена профилей, пароли и порты — всё остальное
(установка, конфиг, служба, firewall, клиентские ссылки, QR-коды, бэкапы)
скрипт делает сам.

```
curl -fsSL https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh | bash
```

После установки управление доступно командой `mieru-manager`.

---

## Возможности

- Установка `mita` официальным `.deb` / `.rpm` пакетом (без ручной компиляции).
- Автоматическое определение внешнего IPv4 сервера.
- Интерактивный мастер первого запуска: порты → пользователи → ссылки.
- Единый файл состояния `/root/mieru/state.json` (права `600`).
- Генерация **официальных** клиентских ссылок `mieru://` и `mierus://`
  настоящим клиентом `mieru` (скачивается в `/root/mieru/bin`, на работу
  сервера не влияет).
- Клиентские конфиги (`*.json`) и ссылки (`*.txt`) для каждого пользователя.
- QR-код ссылки (`qrencode`).
- Открытие/закрытие портов в `ufw` и `firewalld`.
- Резервное копирование и восстановление конфигурации.
- Обновление `mita` и самого `mieru-manager`.
- Просмотр статуса, активного трафика пользователей и логов.

> Сервер `mita` **не хранит пароли в открытом виде** — только хеш.
> Поэтому открытые пароли и источник истины для ссылок лежат в
> `/root/mieru/state.json`. Этот файл — секрет, не публикуйте его.

---

## Установка

На VPS от root:

```bash
curl -fsSL https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh | bash
```

Если `raw.githubusercontent.com` с вашего VPS недоступен (частая проблема),
используйте зеркало:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/install.sh | bash
```

Или скачайте и запустите вручную, чтобы видеть все сообщения:

```bash
curl -fsSL -o /tmp/install.sh https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/install.sh
bash /tmp/install.sh
```

Скрипт:

1. поставит зависимости (`curl`, `jq`, `qrencode`, `openssl`);
2. поставит и включит службу `mita`;
3. определит внешний IP;
4. запустит мастер: попросит порты и пользователей;
5. применит конфиг, запустит прокси и покажет ссылки.

---

## Меню

```
────────────────────────────────────────────────────────────────
             MIERU MANAGER 2.0.0
────────────────────────────────────────────────────────────────
  Сервер:  203.0.113.10
  Mita:    ● RUNNING
  Юзеров:  3
  Портов:  2
────────────────────────────────────────────────────────────────
  1.  Добавить пользователя          9.  Показать все ссылки
  2.  Удалить пользователя          10.  QR-код пользователя
  3.  Изменить пароль               11.  Backup
  4.  Список пользователей          12.  Восстановить backup
  5.  Добавить порт                 13.  Обновить mita
  6.  Удалить порт                  14.  Перезапустить mita
  7.  Список портов                 15.  Статус
  8.  Ссылка пользователя           16.  Логи
                                    17.  Показать конфигурацию
  0.  Выход                         18.  Обновить mieru-manager
```

Запуск меню: `mieru-manager` (или `sudo mieru-manager`).

---

## Команды (без меню)

```bash
mieru-manager install                          # установить/перенастроить
mieru-manager status                           # статус, трафик
mieru-manager list-users                       # список пользователей
mieru-manager add-user ivan                    # добавить (пароль сгенерируется)
mieru-manager add-user ivan 'МойПароль'        # добавить с паролем
mieru-manager delete-user ivan                 # удалить
mieru-manager passwd ivan                      # сменить пароль
mieru-manager list-ports                       # список портов
mieru-manager add-port 443 both               # порт (tcp|udp|both)
mieru-manager add-port 2012-2022 both         # диапазон портов
mieru-manager delete-port 2053                # удалить порт
mieru-manager delete-port 2012-2022           # удалить диапазон
mieru-manager links                            # все ссылки
mieru-manager links ivan                       # ссылки одного пользователя
mieru-manager qr ivan                          # QR-код
mieru-manager config                           # конфиг mita
mieru-manager restart                          # перезапустить
mieru-manager backup                           # резервная копия
mieru-manager restore /root/mieru/backups/...  # восстановить
mieru-manager update                           # обновить mita
mieru-manager self-update                      # обновить mieru-manager
mieru-manager logs                             # журнал mita
```

---

## Файлы

```
/root/mieru/
├── state.json          # ИСТИНА: пользователи, пароли, порты (600)
├── server_config.json  # сгенерированный конфиг для mita (600)
├── manager.log         # журнал действий
├── bin/mieru           # клиент mieru (для генерации ссылок)
├── clients/
│   ├── ivan.txt        # ссылки mieru:// и mierus://
│   └── ivan.json       # клиентский конфиг (можно импортировать вручную)
└── backups/
    └── 20260101_120000/
        ├── state.json
        ├── server_config.json
        ├── clients/
        └── mita_describe_config.json
```

Права: каталог `700`, файлы `600`.

---

## Как это работает

- Серверная часть mieru называется **mita**; конфиг ставится командой
  `mita apply config <file>`, изменения только пользователей применяются
  `mita reload`, изменение портов требует перезапуска (`mita stop` + `mita start`).
- `portBindings` при применении **заменяются** целиком, поэтому порты всегда
  синхронизируются с `state.json`. Поддерживаются как отдельные порты, так и
  диапазоны (`"portRange": "2012-2022"`) — в меню и CLI можно вводить
  `2012-2022`.
- `users` **мержатся по имени**, поэтому смена пароля — это повторное
  применение того же имени, а удаление делается командой `mita delete user`.
- Ссылки генерирует настоящий клиент `mieru` в изолированном временном
  `$HOME`, поэтому ссылки бит-в-бит совпадают с официальным форматом:
  - `mieru://...` — стандартная ссылка (полный конфиг в base64);
  - `mierus://user:pass@host?port=...&protocol=...` — простая ссылка.
- Если клиент `mieru` недоступен, простая ссылка собирается вручную, чтобы
  доступ не потерялся.

---

## Клиенты

- Windows / macOS / Linux / Android — <https://github.com/enfein/mieru/releases>
- Clash.Meta / mihomo поддерживают тип `mieru`.
- Ссылку можно импортировать командой `mieru import config <URL>`.

Пример `mihomo`:

```yaml
proxies:
  - name: server1
    type: mieru
    server: 203.0.113.10
    port: 443
    transport: TCP
    udp: true
    username: ivan
    password: "МойПароль"
    multiplexing: MULTIPLEXING_HIGH
  - name: server2
    type: mieru
    server: 203.0.113.10
    port-range: 2012-2022
    transport: TCP
    udp: true
    username: ivan
    password: "МойПароль"
    multiplexing: MULTIPLEXING_HIGH
```

> В одной записи нельзя указывать одновременно `port` и `port-range`.

---

## Требования

- Debian 11+/Ubuntu 20.04+ или RHEL/CentOS/Fedora/Rocky.
- root-доступ.
- Открытые в облачном firewall порты (если VPS за NAT провайдера).

---

## Диагностика

```bash
mieru-manager status           # служба и трафик
mieru-manager logs             # journalctl -u mita
mita describe config           # текущий конфиг сервера
mita get connections           # активные соединения
```

Частые проблемы:

- **Скрипт «висит» после запуска через `curl | bash`** — скорее всего, VPS не может
  скачать файл с `raw.githubusercontent.com`. Проверьте:
  `curl -v --connect-timeout 10 -o /dev/null https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh`.
  Используйте зеркало jsDelivr (см. выше) или скачайте `install.sh` в файл и запустите.
- **Ничего не происходит после `[+] Устанавливаю зависимости`** — идёт `apt-get update`
  (может ждать блокировку dpkg). Проверьте в другом окне:
  `ps aux | grep -E 'apt|dpkg'` и `fuser -v /var/lib/dpkg/lock-frontend`.
- **Ссылка не импортируется** — проверьте, что клиент видит порт и протокол;
  время на клиенте и сервере должно совпадать (включите NTP).
- **Порт не слушается** — `ss -lntup | grep <порт>`, проверьте облачный firewall.
- **`mita apply config` не проходит** — `mita describe config` покажет текущее
  состояние; смотрите вывод ошибки.

---

## Безопасность

- `state.json`, `clients/*` содержат открытые пароли — держите их `600`.
- Простая ссылка `mierus://` содержит логин и пароль в открытом виде,
  стандартная — пароль в base64 (не шифрование). Ссылку нельзя публиковать.
- Скрипт не отправляет пароли на сторонние сервисы.

---

## Лицензия

MIT
