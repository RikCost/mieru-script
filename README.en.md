# mieru-script

[Русский](README.md) | **English**

One-command installer and interactive manager for the **mita** proxy server
(the server side of [enfein/mieru](https://github.com/enfein/mieru)) on a
Debian / Ubuntu / RHEL / Fedora / CentOS VPS.

You only provide profile names, passwords and ports — everything else
(installation, config, systemd service, firewall, client links, QR codes,
backups) is handled by the script.

```
curl -fsSL https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/install.sh | bash
```

After installation everything is managed with `mieru-manager`.

---

## Features

- Installs/manages `mita` from the official `.deb` / `.rpm` package (no manual build).
- Per-user port selection: choose **which ports go into each user's link**
  (all / specific).
- Automatic detection of the server's public IPv4.
- Interactive first-run wizard: ports → users → links.
- Single source of truth: `/root/mieru/state.json` (mode `600`).
- Generates **official** `mieru://` and `mierus://` client links using the real
  `mieru` client (downloaded to `/root/mieru/bin`, does not affect the server).
- Per-user client configs (`*.json`) and links (`*.txt`).
- QR code for a link (by default from the short `mierus://` — much more reliable
  to scan; a PNG is also saved to `clients/<name>.png`).
- Opens/closes ports in `ufw` and `firewalld`.
- Backup and restore.
- Update `mita` and `mieru-manager` itself.
- Status, per-user traffic and logs.

> The `mita` server **does not store plaintext passwords** — only a hash.
> Plaintext passwords and the source of truth for links live in
> `/root/mieru/state.json`. This file is a secret, never publish it.

---

## Installation

On the VPS as root:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/install.sh | bash
```

> `raw.githubusercontent.com` may serve a stale cached file (up to ~5 minutes).
> The installer and `mieru-manager self-update` fetch the latest revision by
> commit SHA, but `install.sh` itself is best fetched from jsDelivr.

Alternative via raw:

```bash
curl -fsSL https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh | bash
```

Or download and run it manually to see all messages:

```bash
curl -fsSL -o /tmp/install.sh https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/install.sh
bash /tmp/install.sh
```

What the script does:

1. installs dependencies (`curl`, `jq`, `qrencode`, `openssl`);
2. installs and enables the `mita` service;
3. detects the public IP;
4. runs the wizard: asks for ports and users;
5. applies the config, starts the proxy and prints the links.

---

## Menu

```
────────────────────────────────────────────────────────────────
             MIERU MANAGER 2.2.0
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
 19.  Порты пользователя (что попадёт в ссылку)
```

The menu UI itself is in Russian. The script's CLI commands and this document
cover everything the menu can do.

Start the menu with `mieru-manager` (or `sudo mieru-manager`).
Press `?` to redraw the item list, `0` to exit.

---

## Commands (no menu)

```bash
mieru-manager install                          # install / reconfigure
mieru-manager status                           # status + traffic
mieru-manager list-users                       # list users
mieru-manager add-user ivan                    # add (password generated, all ports)
mieru-manager add-user ivan 'MyPassword'       # add with a password
mieru-manager add-user ivan 'pass' all         # link includes all server ports
mieru-manager add-user ivan 'pass' 1,3         # link includes ports #1 and #3
mieru-manager add-user ivan 'pass' 443/tcp     # link includes only 443/TCP
mieru-manager set-user-ports ivan all          # change the ports in a user's link
mieru-manager set-user-ports ivan 8443/tcp,2012-2022/udp
mieru-manager delete-user ivan                 # delete a user
mieru-manager passwd ivan                      # change a password
mieru-manager list-ports                       # list ports
mieru-manager add-port 443 both                # port (tcp|udp|both)
mieru-manager add-port 2012-2022 both          # port range
mieru-manager delete-port 2053                 # delete a port
mieru-manager delete-port 2012-2022            # delete a port range
mieru-manager links                            # all links
mieru-manager links ivan                       # one user's links
mieru-manager qr ivan                          # QR (short mierus://)
mieru-manager qr ivan standard                 # QR of the mieru:// link
mieru-manager config                           # mita config
mieru-manager restart                          # restart mita
mieru-manager backup                           # create a backup
mieru-manager restore /root/mieru/backups/...  # restore a backup
mieru-manager update                           # update mita
mieru-manager self-update                      # update mieru-manager
mieru-manager self-check                       # diagnostics (tty, output)
mieru-manager logs                             # mita journal
```

---

## Files

```
/root/mieru/
├── state.json          # SOURCE OF TRUTH: users, passwords, ports (600)
├── server_config.json  # generated config for mita (600)
├── manager.log         # action log
├── bin/mieru           # mieru client (used to generate links)
├── clients/
│   ├── ivan.txt        # mieru:// and mierus:// links
│   └── ivan.json       # client config (can be imported manually)
└── backups/
    └── 20260101_120000/
        ├── state.json
        ├── server_config.json
        ├── clients/
        └── mita_describe_config.json
```

Permissions: directory `700`, files `600`.

---

## How it works

- The server side of mieru is called **mita**; its config is applied with
  `mita apply config <file>`, user-only changes with `mita reload`, and port
  changes require a restart (`mita stop` + `mita start`).
- `portBindings` are **replaced** entirely on apply, so ports always stay in
  sync with `state.json`. Both single ports and ranges
  (`"portRange": "2012-2022"`) are supported — type `2012-2022` in the menu or CLI.
- `users` are **merged by name**, so changing a password means re-applying the
  same name, while deletion uses `mita delete user`.
- Links are generated by the real `mieru` client in an isolated temporary
  `$HOME`, so they match the official format exactly:
  - `mieru://...` — standard link (full config in base64);
  - `mierus://user:pass@host?port=...&protocol=...` — simple link.
- If the `mieru` client is unavailable, the simple link is built manually so
  access is never lost.

---

## Per-user ports (what goes into the link)

Every user has their own port list stored in `state.json` as `users[].ports`.
It affects **only the client link/config** — only those ports are included.

```bash
# when adding a user (3rd argument): "all", indices from `list-ports`, or specs
mieru-manager add-user ivan 'pass' all
mieru-manager add-user ivan 'pass' 1,3
mieru-manager add-user ivan 'pass' 443/tcp,2012-2022/udp

# change later
mieru-manager set-user-ports ivan all
mieru-manager set-user-ports ivan 8443/tcp
```

In the menu use item `19. Порты пользователя`: pick a user and select ports by
comma-separated numbers (`Enter` — all ports).

When a server port is deleted, it is automatically removed from every user's
list. If a user is left with no ports, all server ports are re-enabled for them
(with a warning).

> **Important:** mita does not bind a user to a server port — any user can
> connect to any listening port. The port list only restricts what a client sees
> in its link/config. For hard isolation, use separate users on separate
> servers/ports.

---

## Clients

- Windows / macOS / Linux / Android — <https://github.com/enfein/mieru/releases>
- Clash.Meta / mihomo support the `mieru` proxy type.
- A link can be imported with `mieru import config <URL>`.

`mihomo` example:

```yaml
proxies:
  - name: server1
    type: mieru
    server: 203.0.113.10
    port: 443
    transport: TCP
    udp: true
    username: ivan
    password: "MyPassword"
    multiplexing: MULTIPLEXING_HIGH
  - name: server2
    type: mieru
    server: 203.0.113.10
    port-range: 2012-2022
    transport: TCP
    udp: true
    username: ivan
    password: "MyPassword"
    multiplexing: MULTIPLEXING_HIGH
```

> You cannot set both `port` and `port-range` in a single entry.

---

## Requirements

- Debian 11+/Ubuntu 20.04+ or RHEL/CentOS/Fedora/Rocky.
- root access.
- Ports opened in the cloud firewall (if the VPS is behind provider NAT).

---

## Troubleshooting

```bash
mieru-manager status           # service and traffic
mieru-manager logs             # journalctl -u mita
mita describe config           # current server config
mita get connections           # active connections
```

Common issues:

- **The menu item list is not visible** — on PuTTY the `clear` command sometimes
  wipes the screen. Screen clearing is now disabled by default. Enable it with
  `MIERU_CLEAR=1 mieru-manager`. Inside the menu press `?` to redraw the list.
  Full command list: `mieru-manager help`.
- **The script "hangs" after `curl | bash`** — most likely the VPS cannot
  download from `raw.githubusercontent.com`. Check:
  `curl -v --connect-timeout 10 -o /dev/null https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh`.
  Use the jsDelivr mirror (see above) or download `install.sh` to a file and run it.
- **Nothing happens after `[+] Устанавливаю зависимости`** — `apt-get update` is
  running (it may be waiting for the dpkg lock). Check in another window:
  `ps aux | grep -E 'apt|dpkg'` and `fuser -v /var/lib/dpkg/lock-frontend`.
- **A link does not import** — make sure the client sees the same port and
  protocol; client and server clocks must match (enable NTP).
- **A port is not listening** — `ss -lntup | grep <port>`, check the cloud firewall.
- **`mita apply config` fails** — `mita describe config` shows the current state;
  read the error output.

---

## Security

- `state.json` and `clients/*` contain plaintext passwords — keep them at `600`.
- The simple link `mierus://` contains the username and password in plaintext;
  the standard link contains the password in base64 (not encryption). Never
  publish a link.
- The script never sends passwords to third-party services.

---

## License

MIT
