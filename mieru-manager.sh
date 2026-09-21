#!/usr/bin/env bash
# =============================================================================
#  mieru-manager — установка и управление прокси-сервером mita (mieru) на VPS
# =============================================================================
#  Репозиторий : https://github.com/RikCost/mieru-script
#  Лицензия    : MIT
#  Проект mieru: https://github.com/enfein/mieru
#
#  Быстрый запуск (Debian / Ubuntu / RHEL / Fedora / CentOS):
#
#     curl -fsSL https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh | bash
#
#  После установки:
#
#     mieru-manager            # интерактивное меню
#     mieru-manager help       # список всех команд
#
#  Что делает скрипт:
#    * ставит mita (серверную часть mieru) официальным deb/rpm пакетом;
#    * сам определяет внешний IPv4 сервера;
#    * хранит ВСЁ состояние (пользователи, пароли, порты) в /root/mieru;
#    * применяет конфиг через `mita apply config`, перезапускает службу;
#    * открывает порты в ufw / firewalld;
#    * генерирует официальные клиентские ссылки mieru:// и mierus://
#      (через настоящий клиент mieru, скачанный в /root/mieru/bin);
#    * показывает QR-код, делает и восстанавливает резервные копии.
#
#  ВАЖНО: сервер mita НЕ хранит пароли в открытом виде (только хеш).
#  Поэтому источником истины для ссылок служит файл состояния:
#      /root/mieru/state.json   (права 600, только для root)
# =============================================================================

set -uo pipefail

APP_NAME="mieru-manager"
APP_VERSION="2.1.0"
REPO_RAW="${MIERU_REPO_RAW:-https://raw.githubusercontent.com/RikCost/mieru-script/main}"
GITHUB_REPO="enfein/mieru"

BASE_DIR="${MIERU_MANAGER_BASE:-/root/mieru}"
STATE_FILE="$BASE_DIR/state.json"
SERVER_JSON="$BASE_DIR/server_config.json"
CLIENTS_DIR="$BASE_DIR/clients"
BACKUP_DIR="$BASE_DIR/backups"
BIN_DIR="$BASE_DIR/bin"
MIERU_BIN="$BIN_DIR/mieru"

# ---------------------------------------------------------------------------
# Цвета
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RST=$'\033[0m'
    C_BLD=$'\033[1m'
    C_RED=$'\033[0;31m'
    C_GRN=$'\033[0;32m'
    C_YEL=$'\033[0;33m'
    C_BLU=$'\033[0;36m'
    C_MAG=$'\033[0;35m'
else
    C_RST=""; C_BLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""
fi

# ---------------------------------------------------------------------------
# Ввод/вывод
# ---------------------------------------------------------------------------
info() { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[-]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

# stdin может быть занят скриптом при `curl | bash`.
# НЕ меняем fd 0 через exec: при `curl | bash` bash читает сам скрипт из fd 0,
# и переключение его на /dev/tty заставляет bash зависнуть, ожидая продолжения
# скрипта с терминала. Вместо этого все интерактивные чтения идут из /dev/tty.
HAS_TTY=0
if [[ -t 0 ]]; then
    HAS_TTY=1
elif [[ -e /dev/tty ]] && ( exec </dev/tty ) 2>/dev/null; then
    HAS_TTY=1
fi

ask() { # ask VAR "prompt" [default]
    local __var="$1" __prompt="$2" __default="${3-}" __val=""
    if [[ "$HAS_TTY" -ne 1 ]]; then printf -v "$__var" '%s' "$__default"; return 0; fi
    read -r -p "$__prompt" __val </dev/tty || true
    [[ -z "$__val" && -n "$__default" ]] && __val="$__default"
    printf -v "$__var" '%s' "$__val"
}

ask_secret() { # ask_secret VAR "prompt"
    local __var="$1" __prompt="$2" __val=""
    if [[ "$HAS_TTY" -ne 1 ]]; then printf -v "$__var" '%s' ""; return 0; fi
    read -rs -p "$__prompt" __val </dev/tty || true
    printf '\n' >&2
    printf -v "$__var" '%s' "$__val"
}

confirm() { # confirm "question" -> 0 = да
    [[ "$HAS_TTY" -ne 1 ]] && return 0
    local a
    read -r -p "$1 [y/N]: " a </dev/tty || true
    [[ "$a" =~ ^[YyДд]$ ]]
}

pause() {
    [[ "$HAS_TTY" -ne 1 ]] && return 0
    read -r -p "$(printf '%s' "${C_BLU}Нажмите Enter для продолжения...${C_RST}")" _ </dev/tty || true
}

# ---------------------------------------------------------------------------
# Разное
# ---------------------------------------------------------------------------
sanitize_filename() { printf '%s' "${1//[^A-Za-z0-9_.@-]/_}"; }

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-20
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20
    fi
    printf '\n'
}

os_id() { ( . /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-}" "${ID_LIKE:-}" ); }
is_debian() { local s; s="$(os_id)"; [[ "$s" == *debian* || "$s" == *ubuntu* ]]; }
is_rhel()   { local s; s="$(os_id)"; [[ "$s" == *rhel* || "$s" == *fedora* || "$s" == *centos* ]]; }

deb_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; *) return 1;; esac; }
rpm_arch() { case "$(uname -m)" in x86_64|amd64) echo x86_64;; aarch64|arm64) echo aarch64;; *) return 1;; esac; }
tar_arch() { case "$(uname -m)" in x86_64|amd64) echo amd64;; aarch64|arm64) echo arm64;; armv7l|armv7) echo armv7;; *) return 1;; esac; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Запустите от root: sudo $APP_NAME $*"
}

ensure_base_dirs() {
    mkdir -p "$BASE_DIR" "$CLIENTS_DIR" "$BACKUP_DIR" "$BIN_DIR"
    chmod 700 "$BASE_DIR" "$CLIENTS_DIR" "$BACKUP_DIR" "$BIN_DIR" 2>/dev/null || true
    touch "$BASE_DIR/manager.log" && chmod 600 "$BASE_DIR/manager.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Состояние (единственный источник истины)
# ---------------------------------------------------------------------------
state_exists() { [[ -f "$STATE_FILE" ]]; }

state_get() { # state_get [jq-опции] 'фильтр'
    state_exists || return 1
    jq "$@" "$STATE_FILE" | tr -d '\r'
}

state_update() { # state_update [jq-опции] 'фильтр'
    local tmp
    tmp="$(mktemp "$BASE_DIR/.state.XXXXXX")" || return 1
    if jq "$@" "$STATE_FILE" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

get_public_ip() {
    local ip svc
    for svc in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        ip="$(curl -4 -fsS --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

state_init() {
    ensure_base_dirs
    [[ -f "$STATE_FILE" ]] && return 0

    local ip
    ip="$(get_public_ip || true)"
    if [[ -z "$ip" ]]; then
        if [[ "$HAS_TTY" -eq 1 ]]; then
            ask ip "Введите внешний IPv4 сервера вручную (можно оставить пустым): " ""
        fi
        [[ -z "$ip" ]] && ip="YOUR_SERVER_IP"
    fi

    jq -n --arg ip "$ip" --arg ts "$(date -Is)" '{
        version: 2,
        serverAddress: $ip,
        mtu: 1400,
        loggingLevel: "INFO",
        multiplexing: "MULTIPLEXING_HIGH",
        handshakeMode: "HANDSHAKE_STANDARD",
        dns: { dualStack: "PREFER_IPv4" },
        ports: [],
        users: [],
        mitaVersion: "",
        createdAt: $ts,
        updatedAt: $ts
    }' >"$STATE_FILE"
    chmod 600 "$STATE_FILE"
    info "Создан файл состояния: $STATE_FILE"
}

state_touch() { state_update --arg ts "$(date -Is)" '.updatedAt = $ts' || true; }

# ---------------------------------------------------------------------------
# JSON конфигурации
# ---------------------------------------------------------------------------
generate_server_config() {
    state_exists || { err "Нет файла состояния."; return 1; }
    local tmp
    tmp="$(mktemp "$BASE_DIR/.server.XXXXXX")" || return 1
    if jq '{
            portBindings: [ .ports[] | (if .portRange then { portRange: .portRange, protocol: .protocol } else { port: .port, protocol: .protocol } end) ],
            users:        [ .users[]  | { name: .name, password: .password } ],
            loggingLevel: .loggingLevel,
            mtu:          .mtu,
            dns:          .dns
        }' "$STATE_FILE" >"$tmp"; then
        mv "$tmp" "$SERVER_JSON"
        chmod 600 "$SERVER_JSON"
    else
        rm -f "$tmp"
        return 1
    fi
}

# jq-выражение: вычисляет эффективный набор портов пользователя $name.
# Если у пользователя нет своего списка (.ports) — берутся все порты сервера.
# Результат — массив объектов портов в переменной $final.
USER_PORTS_JQ='
  (.users[] | select(.name == $name)) as $usr
  | (.ports // []) as $allPorts
  | ( if (($usr.ports // []) | length) > 0 then $usr.ports else $allPorts end ) as $wanted
  | [ $wanted[] as $w
      | select(any($allPorts[];
          .protocol == $w.protocol
          and ( (($w.port // null) != null and (.port == $w.port))
                or (($w.portRange // null) != null and (.portRange == $w.portRange)) )))
      | $w ] as $sel
  | ( if ($sel | length) > 0 then $sel else $allPorts end ) as $final
'

global_ports_list() { state_get -r '.ports[] | "\(.port // .portRange)\t\(.protocol)"'; }

user_ports_tsv() { # <user> -> построчно "<порт>\t<протокол>" (эффективные порты)
    state_get -r --arg name "$1" "$USER_PORTS_JQ"' | $final[] | "\(.port // .portRange)\t\(.protocol)"'
}

# Разбор селектора портов: "all" | "1,3" | "443/tcp,2012-2022/udp" -> JSON-массив. [] = все.
select_ports_from_arg() {
    local arg="${1:-}" items=() sel=() i p t tok sp pr found
    mapfile -t items < <(global_ports_list)
    if [[ -z "$arg" || "$arg" == "all" || "$arg" == "*" ]]; then printf '[]'; return 0; fi
    local oldifs="$IFS"
    IFS=','
    for tok in $arg; do
        IFS="$oldifs"
        tok="${tok// /}"
        [[ -z "$tok" ]] && continue
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            if (( tok >= 1 && tok <= ${#items[@]} )); then
                sel+=("$((tok-1))")
            else
                warn "Нет порта с номером $tok"
            fi
            continue
        fi
        sp="$tok"; pr="tcp"
        if [[ "$tok" == */* ]]; then sp="${tok%/*}"; pr="${tok##*/}"; fi
        pr="$(printf '%s' "$pr" | tr 'a-z' 'A-Z')"
        found=0
        for i in "${!items[@]}"; do
            IFS=$'\t' read -r p t <<<"${items[$i]}"
            if [[ "$p" == "$sp" && "$t" == "$pr" ]]; then sel+=("$i"); found=1; break; fi
        done
        (( found )) || warn "Порт $sp/$pr не найден среди портов сервера"
    done
    IFS="$oldifs"
    if (( ${#sel[@]} == 0 )); then printf '[]'; return 0; fi
    local idx_json="[$(printf '%s,' "${sel[@]}" | sed 's/,$//')]"
    state_get --argjson idx "$idx_json" '.ports as $all | [ $idx[] | $all[.] ]'
}

choose_ports_interactive() { # -> JSON-массив портов пользователя ([] = все)
    local items=() i p t ans
    mapfile -t items < <(global_ports_list)
    if (( ${#items[@]} <= 1 )); then printf '[]'; return 0; fi
    echo >&2
    echo "  Порты сервера — какие включить в ссылку этого пользователя:" >&2
    for i in "${!items[@]}"; do
        IFS=$'\t' read -r p t <<<"${items[$i]}"
        printf '   %2d) %s %s\n' "$((i+1))" "$p" "$t" >&2
    done
    ask ans "  Номера через запятую (Enter — все порты): " ""
    if [[ -z "$ans" ]]; then printf '[]'; return 0; fi
    select_ports_from_arg "$ans"
}

# --- Привязка портов пользователя (для ссылок) ---
users_using_port() { # <spec> <proto> -> имена пользователей через запятую
    state_get -r --arg v "$1" --arg t "$2" '
        [ .users[] | select((.ports // []) | length > 0)
          | select(any(.ports[]; .protocol == $t and ((.port|tostring) == $v or .portRange == $v)))
          | .name ] | join(", ")'
}

prune_user_ports() { # <spec> <proto> — убрать порт из списков пользователей
    state_update --arg v "$1" --arg t "$2" '
        .users |= map(
          if ((.ports // []) | length) > 0 then
            (.ports |= map(select(.protocol != $t or ((.port|tostring) != $v and .portRange != $v))))
            | (if (.ports | length) == 0 then del(.ports) else . end)
          else . end)' || true
}

build_client_config() { # build_client_config <user> -> JSON в stdout
    local u="$1"
    jq --arg name "$u" "$USER_PORTS_JQ"'
        | {
            profiles: [ {
                profileName: $name,
                user: { name: $usr.name, password: $usr.password },
                servers: [ {
                    ipAddress: .serverAddress,
                    domainName: "",
                    portBindings: [ $final[] | (if .portRange then { portRange: .portRange, protocol: .protocol } else { port: .port, protocol: .protocol } end) ]
                } ],
                mtu: .mtu,
                multiplexing: { level: .multiplexing },
                handshakeMode: .handshakeMode
            } ],
            activeProfile: $name,
            rpcPort: 8964,
            socks5Port: 1080,
            httpProxyPort: 8080,
            loggingLevel: "INFO",
            socks5ListenLAN: false,
            httpProxyListenLAN: false
        }' "$STATE_FILE"
}

build_simple_link() { # build_simple_link <user> -> mierus://...
    local u="$1" pw ip host enc_u enc_p q="" p proto
    pw="$(state_get -r --arg name "$u" '.users[] | select(.name == $name) | .password')"
    ip="$(state_get -r '.serverAddress')"
    [[ "$ip" == *:* ]] && host="[$ip]" || host="$ip"

    enc_u="$(jq -rn --arg s "$u" '$s | @uri')"
    enc_p="$(jq -rn --arg s "$pw" '$s | @uri')"

    q="profile=$(jq -rn --arg s "$u" '$s | @uri')"
    q+="&mtu=$(state_get -r '.mtu')"
    q+="&multiplexing=$(state_get -r '.multiplexing')"
    q+="&handshake-mode=$(state_get -r '.handshakeMode')"
    while IFS=$'\t' read -r p proto; do
        p="${p%$'\r'}"; proto="${proto%$'\r'}"
        [[ -z "$p" ]] && continue
        q+="&port=${p}&protocol=${proto}"
    done < <(user_ports_tsv "$u")

    printf 'mierus://%s:%s@%s?%s\n' "$enc_u" "$enc_p" "$host" "$q"
}

# ---------------------------------------------------------------------------
# Установка зависимостей и mita
# ---------------------------------------------------------------------------
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    local a
    case "$(uname -m)" in
        x86_64|amd64) a="amd64" ;;
        aarch64|arm64) a="arm64" ;;
        armv7l|armv7) a="armhf" ;;
        *) return 1 ;;
    esac
    warn "jq не найден — скачиваю статический бинарник..."
    curl -fsSL -o /usr/local/bin/jq \
        "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${a}" \
        && chmod 0755 /usr/local/bin/jq
}

install_deps() {
    local pkgs=(curl ca-certificates jq qrencode openssl)
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        info "Обновляю списки пакетов (apt-get update). Может занять до минуты..."
        apt-get update -qq
        info "Устанавливаю зависимости: ${pkgs[*]}"
        apt-get install -y -qq "${pkgs[@]}" || true
    elif command -v dnf >/dev/null 2>&1; then
        info "Устанавливаю зависимости (dnf): ${pkgs[*]}"
        dnf install -y -q "${pkgs[@]}" || true
    elif command -v yum >/dev/null 2>&1; then
        info "Устанавливаю зависимости (yum): ${pkgs[*]}"
        yum install -y -q "${pkgs[@]}" || true
    else
        warn "Не найден менеджер пакетов — проверяю зависимости вручную."
    fi
    ensure_jq
    command -v jq >/dev/null 2>&1 || die "Не удалось установить jq."
    command -v curl >/dev/null 2>&1 || die "Не удалось установить curl."
}

latest_mita_version() {
    curl -fsSL --max-time 15 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//'
}

download_and_install_mita() { # download_and_install_mita [version]
    local ver="${1:-}" a tmp f url
    [[ -z "$ver" ]] && ver="$(latest_mita_version)"
    [[ -n "$ver" && "$ver" != "null" ]] || die "Не удалось определить версию mita."

    tmp="$(mktemp -d)"
    info "Устанавливаю mita v${ver}..."

    if is_debian; then
        a="$(deb_arch)" || die "Неподдерживаемая архитектура для deb."
        f="mita_${ver}_${a}.deb"
        url="https://github.com/${GITHUB_REPO}/releases/download/v${ver}/${f}"
        curl -fL --retry 3 --connect-timeout 15 --max-time 900 -o "$tmp/$f" "$url" \
            || { rm -rf "$tmp"; die "Не удалось скачать $f"; }
        dpkg -i "$tmp/$f" >/dev/null 2>&1 || true
        apt-get -f install -y >/dev/null 2>&1 || true
    elif is_rhel; then
        a="$(rpm_arch)" || die "Неподдерживаемая архитектура для rpm."
        f="mita-${ver}-1.${a}.rpm"
        url="https://github.com/${GITHUB_REPO}/releases/download/v${ver}/${f}"
        curl -fL --retry 3 --connect-timeout 15 --max-time 900 -o "$tmp/$f" "$url" \
            || { rm -rf "$tmp"; die "Не удалось скачать $f"; }
        rpm -Uvh --force "$tmp/$f" >/dev/null 2>&1 || true
    else
        rm -rf "$tmp"
        die "Поддерживаются Debian/Ubuntu и RHEL/Fedora/CentOS."
    fi
    rm -rf "$tmp"

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable mita >/dev/null 2>&1 || true
    systemctl start mita >/dev/null 2>&1 || true
    sleep 1

    command -v mita >/dev/null 2>&1 || die "Команда mita не найдена после установки."
    state_exists && state_update --arg v "$ver" '.mitaVersion = $v' >/dev/null 2>&1 || true
    info "mita v${ver} установлен."
}

mita_ensure_daemon() {
    systemctl start mita >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5; do
        mita status >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 0
}

mita_proxy_running() { mita status 2>&1 | grep -q 'RUNNING'; }

mita_current_users() {
    mita get users 2>&1 | awk 'NR>1 && NF>0 {print $1}' | grep -E '^[A-Za-z0-9_.@-]+$' | grep -v '^User$' | sort -u
}

apply_server_config() {
    generate_server_config || return 1
    if [[ "$(state_get -r '.users | length')" -eq 0 ]]; then
        warn "В конфигурации нет пользователей — пропускаю применение."
        return 1
    fi
    mita_ensure_daemon >/dev/null 2>&1 || true
    mita apply config "$SERVER_JSON" >/dev/null
}

mita_soft_apply() { # изменились только пользователи/логирование
    apply_server_config || return 1
    if mita_proxy_running; then
        mita reload >/dev/null 2>&1 || mita stop >/dev/null 2>&1 && mita start >/dev/null 2>&1
    else
        mita start >/dev/null 2>&1
    fi
}

mita_hard_apply() { # изменились порты / mtu — нужен перезапуск
    mita_ensure_daemon >/dev/null 2>&1 || true
    mita stop >/dev/null 2>&1 || true
    apply_server_config || return 1
    mita start >/dev/null 2>&1
}

# Мягкий вариант: если пользователей ещё нет, просто сохраняем состояние.
try_hard_apply() {
    if [[ "$(state_get -r '.users | length' 2>/dev/null || echo 0)" -eq 0 ]]; then
        warn "Пользователей пока нет — конфигурация сохранена и будет применена позже."
        return 0
    fi
    mita_hard_apply
}

# ---------------------------------------------------------------------------
# Клиент mieru (для официальных ссылок) и генерация ссылок
# ---------------------------------------------------------------------------
ensure_mieru_bin() {
    [[ -x "$MIERU_BIN" ]] && return 0
    ensure_base_dirs
    local a ver url tmp found
    a="$(tar_arch)" || { warn "Архитектура $(uname -m) не поддерживается для клиента mieru."; return 1; }
    ver="$(state_get -r '.mitaVersion // empty' 2>/dev/null || true)"
    [[ -z "$ver" ]] && ver="$(latest_mita_version)"
    [[ -n "$ver" && "$ver" != "null" ]] || return 1

    tmp="$(mktemp -d)"
    url="https://github.com/${GITHUB_REPO}/releases/download/v${ver}/mieru_${ver}_linux_${a}.tar.gz"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 -o "$tmp/mieru.tar.gz" "$url" >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 1
    fi
    if ! tar -xzf "$tmp/mieru.tar.gz" -C "$tmp" >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 1
    fi
    found="$(find "$tmp" -type f -name mieru -print -quit 2>/dev/null)"
    if [[ -z "$found" ]]; then rm -rf "$tmp"; return 1; fi
    install -m 0755 "$found" "$MIERU_BIN" 2>/dev/null || cp "$found" "$MIERU_BIN"
    chmod 0755 "$MIERU_BIN" 2>/dev/null || true
    rm -rf "$tmp"
    [[ -x "$MIERU_BIN" ]]
}

generate_user_links() { # -> "STANDARD=...\nSIMPLE=..."
    local u="$1" cfg tmp std="" simple=""
    ensure_base_dirs
    cfg="$(build_client_config "$u")"
    [[ -n "$cfg" ]] || return 1

    if ensure_mieru_bin; then
        tmp="$(mktemp -d)"; chmod 700 "$tmp"
        printf '%s' "$cfg" >"$tmp/client.json"
        if ( export HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" USERPROFILE="$tmp"; \
             "$MIERU_BIN" apply config "$tmp/client.json" ) >/dev/null 2>&1; then
            std="$( ( export HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" USERPROFILE="$tmp"; \
                      "$MIERU_BIN" export config ) 2>&1 \
                    | grep -oE 'mieru://[^[:space:]]+' | head -n1 )"
            simple="$( ( export HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" USERPROFILE="$tmp"; \
                         "$MIERU_BIN" export config simple ) 2>&1 \
                       | grep -oE 'mierus://[^[:space:]]+' | head -n1 )"
        fi
        rm -rf "$tmp"
    fi

    [[ -z "$simple" ]] && simple="$(build_simple_link "$u")"
    printf 'STANDARD=%s\nSIMPLE=%s\n' "$std" "$simple"
}

write_client_files() { # <user> <standard> <simple>
    local u="$1" std="$2" simple="$3" safe f
    ensure_base_dirs
    safe="$(sanitize_filename "$u")"
    f="$CLIENTS_DIR/$safe"
    {
        echo "# mieru client: $u"
        echo "# server : $(state_get -r '.serverAddress')"
        echo "# updated: $(date -Is)"
        echo
        echo "# Стандартная ссылка (для импорта на новом устройстве):"
        [[ -n "$std" ]] && echo "$std"
        echo
        echo "# Простая ссылка (mierus://):"
        [[ -n "$simple" ]] && echo "$simple"
    } >"$f.txt"
    chmod 600 "$f.txt"
    build_client_config "$u" >"$f.json" 2>/dev/null && chmod 600 "$f.json" || true
}

save_user_links() { # <user> -> печатает ссылки и сохраняет файлы
    local u="$1" out std simple
    out="$(generate_user_links "$u")" || { warn "Не удалось сгенерировать ссылки для $u"; return 1; }
    std="$(printf '%s\n' "$out" | sed -n 's/^STANDARD=//p')"
    simple="$(printf '%s\n' "$out" | sed -n 's/^SIMPLE=//p')"
    write_client_files "$u" "$std" "$simple"
    printf '%s\n' "$std" "$simple"
}

regenerate_all_links() {
    ensure_base_dirs
    local u
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        save_user_links "$u" >/dev/null || warn "Ссылки для $u не обновлены."
    done < <(state_get -r '.users[].name')
    info "Клиентские ссылки обновлены в $CLIENTS_DIR"
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
firewall_allow_port() {
    local spec="$1" proto="$2" lp ufw_spec
    lp="$(printf '%s' "$proto" | tr 'A-Z' 'a-z')"
    if [[ "$spec" == *-* ]]; then ufw_spec="${spec/-/:}"; else ufw_spec="$spec"; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${ufw_spec}/${lp}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${spec}/${lp}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

firewall_deny_port() {
    local spec="$1" proto="$2" lp ufw_spec
    lp="$(printf '%s' "$proto" | tr 'A-Z' 'a-z')"
    if [[ "$spec" == *-* ]]; then ufw_spec="${spec/-/:}"; else ufw_spec="$spec"; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${ufw_spec}/${lp}" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${spec}/${lp}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Операции: пользователи
# ---------------------------------------------------------------------------
valid_user_name() { [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]; }

op_add_user_interactive() {
    local name pw pw2 ports_json
    echo
    hr
    printf '%s              ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ%s\n' "$C_BLD" "$C_RST"
    hr

    while :; do
        ask name "Имя пользователя: " ""
        if [[ -z "$name" ]]; then warn "Имя не может быть пустым."; continue; fi
        if ! valid_user_name "$name"; then
            warn "Допустимы латиница, цифры и символы _ . @ - (до 64 символов)."
            continue
        fi
        if state_get -e --arg n "$name" '.users[] | select(.name == $n)' 2>/dev/null | grep -q .; then
            warn "Пользователь '$name' уже существует."
            continue
        fi
        break
    done

    ask_secret pw "Пароль (Enter = сгенерировать автоматически): "
    if [[ -z "$pw" ]]; then
        pw="$(gen_password)"
        info "Сгенерирован пароль: ${C_BLD}${pw}${C_RST}"
    else
        ask_secret pw2 "Повторите пароль: "
        [[ "$pw" == "$pw2" ]] || { err "Пароли не совпадают."; return 1; }
    fi
    if (( ${#pw} > 64 )); then err "Пароль длиннее 64 байт — mita его не примет."; return 1; fi

    ports_json="$(choose_ports_interactive)"
    if [[ "$ports_json" == "[]" ]]; then
        state_update --arg n "$name" --arg p "$pw" \
            '.users += [{name:$n, password:$p}]' || { err "Не удалось сохранить состояние."; return 1; }
    else
        state_update --arg n "$name" --arg p "$pw" --argjson ports "$ports_json" \
            '.users += [{name:$n, password:$p, ports:$ports}]' || { err "Не удалось сохранить состояние."; return 1; }
    fi
    state_touch

    if ! mita_soft_apply; then
        warn "Конфигурация не применилась. Проверьте: mita describe config"
        return 1
    fi
    info "Пользователь '${name}' добавлен, mita перезагружен."

    echo
    local out
    out="$(save_user_links "$name")"
    printf '%sСсылки:%s\n%s\n' "$C_BLD" "$C_RST" "$out"
    echo
    info "Сохранено: $CLIENTS_DIR/$(sanitize_filename "$name").txt"
}

op_delete_user_interactive() {
    local names=() i name
    mapfile -t names < <(state_get -r '.users[].name' 2>/dev/null)
    if (( ${#names[@]} == 0 )); then warn "Пользователей нет."; return 0; fi

    echo
    hr
    printf '%s               УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ%s\n' "$C_BLD" "$C_RST"
    hr
    for i in "${!names[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${names[$i]}"; done
    echo

    local choice
    ask choice "Номер пользователя (0 — отмена): " "0"
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Неверный ввод."; return 1; }
    (( choice >= 1 && choice <= ${#names[@]} )) || { info "Отменено."; return 0; }
    name="${names[$((choice-1))]}"

    confirm "Удалить пользователя '$name'?" || { info "Отменено."; return 0; }

    mita_ensure_daemon >/dev/null 2>&1 || true
    mita delete user "$name" >/dev/null 2>&1 || warn "mita delete user вернул ошибку."
    state_update --arg n "$name" '.users = [ .users[] | select(.name != $n) ]' \
        || { err "Не удалось обновить состояние."; return 1; }
    state_touch
    if mita_proxy_running; then mita reload >/dev/null 2>&1 || true; fi

    rm -f "$CLIENTS_DIR/$(sanitize_filename "$name").txt" "$CLIENTS_DIR/$(sanitize_filename "$name").json"
    info "Пользователь '${name}' удалён."
}

op_change_password_interactive() {
    local names=() i name pw pw2 choice
    mapfile -t names < <(state_get -r '.users[].name' 2>/dev/null)
    if (( ${#names[@]} == 0 )); then warn "Пользователей нет."; return 0; fi

    echo
    hr
    printf '%s               СМЕНА ПАРОЛЯ%s\n' "$C_BLD" "$C_RST"
    hr
    for i in "${!names[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${names[$i]}"; done
    echo
    ask choice "Номер пользователя (0 — отмена): " "0"
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Неверный ввод."; return 1; }
    (( choice >= 1 && choice <= ${#names[@]} )) || { info "Отменено."; return 0; }
    name="${names[$((choice-1))]}"

    ask_secret pw "Новый пароль (Enter = сгенерировать): "
    if [[ -z "$pw" ]]; then
        pw="$(gen_password)"
        info "Сгенерирован пароль: ${C_BLD}${pw}${C_RST}"
    else
        ask_secret pw2 "Повторите пароль: "
        [[ "$pw" == "$pw2" ]] || { err "Пароли не совпадают."; return 1; }
    fi
    (( ${#pw} <= 64 )) || { err "Пароль длиннее 64 байт."; return 1; }

    state_update --arg n "$name" --arg p "$pw" \
        '(.users[] | select(.name == $n) | .password) = $p' \
        || { err "Не удалось обновить состояние."; return 1; }
    state_touch

    mita_soft_apply || { warn "Конфигурация не применилась."; return 1; }
    info "Пароль пользователя '${name}' изменён."
    save_user_links "$name" >/dev/null
}

op_list_users() {
    local names=()
    mapfile -t names < <(state_get -r '.users[].name' 2>/dev/null)
    echo
    hr
    printf '%s                    ПОЛЬЗОВАТЕЛИ%s\n' "$C_BLD" "$C_RST"
    hr
    if (( ${#names[@]} == 0 )); then
        warn "Пользователей нет."
    else
        local n p fp
        printf '  %-18s %-22s %-26s %s\n' "ИМЯ" "ПАРОЛЬ" "ПОРТЫ (в ссылке)" "ФАЙЛ"
        hr
        for n in "${names[@]}"; do
            p="$(state_get -r --arg name "$n" '.users[] | select(.name == $name) | .password')"
            fp="$(user_ports_tsv "$n" | awk '{printf "%s/%s ", $1, $2}')"
            [[ -z "$fp" ]] && fp="все"
            printf '  %-18s %-22s %-26s %s\n' "$n" "$p" "$fp" "$(sanitize_filename "$n").txt"
        done
    fi
    hr
    echo
    info "Трафик (mita get users):"
    mita get users 2>&1 | sed 's/^/  /' || true
}

# ---------------------------------------------------------------------------
# Операции: порты
# ---------------------------------------------------------------------------
valid_port_num() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_port_spec() {
    local s="$1" a b
    valid_port_num "$s" && return 0
    if [[ "$s" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
        valid_port_num "$a" && valid_port_num "$b" && (( 10#$a <= 10#$b )) && return 0
    fi
    return 1
}
is_port_range() { [[ "$1" == *-* ]]; }

# $1 = спецификация (443 или 2012-2022), $2 = протокол
port_exists() {
    state_get -e --arg v "$1" --arg t "$2" \
        '.ports[] | select(.protocol == $t and ((.port | tostring) == $v or .portRange == $v))' 2>/dev/null | grep -q .
}

add_port_to_state() {
    state_update --arg v "$1" --arg t "$2" \
        'if ($v | test("-")) then .ports += [{portRange:$v, protocol:$t}] else .ports += [{port:($v|tonumber), protocol:$t}] end'
}

remove_port_from_state() {
    state_update --arg v "$1" --arg t "$2" \
        '.ports = [ .ports[] | select(.protocol != $t or (((.port | tostring) != $v) and (.portRange != $v))) ]'
}

op_add_port_interactive() {
    local spec proto choice
    echo
    hr
    printf '%s                 ДОБАВЛЕНИЕ ПОРТА%s\n' "$C_BLD" "$C_RST"
    hr
    ask spec "Порт или диапазон (443 или 2012-2022): " ""
    valid_port_spec "$spec" || { err "Некорректный порт/диапазон. Пример: 443 или 2012-2022."; return 1; }
    ask choice "Протокол: 1) TCP  2) UDP  3) TCP+UDP  [1]: " "1"

    local list=()
    case "$choice" in
        1|"") list=(TCP) ;;
        2)     list=(UDP) ;;
        3)     list=(TCP UDP) ;;
        *)     err "Неверный выбор."; return 1 ;;
    esac

    local added=0 p
    for p in "${list[@]}"; do
        if port_exists "$spec" "$p"; then
            warn "Порт ${spec}/${p} уже добавлен."
            continue
        fi
        add_port_to_state "$spec" "$p" || return 1
        firewall_allow_port "$spec" "$p"
        info "Добавлен ${spec}/${p}"
        added=1
    done
    [[ "$added" -eq 0 ]] && return 0

    state_touch
    if ! try_hard_apply; then warn "Не удалось перезапустить mita."; return 1; fi
    info "mita перезапущен с новыми портами."
    regenerate_all_links
}

op_delete_port_interactive() {
    local items=() i p t choice
    mapfile -t items < <(state_get -r '.ports[] | "\(.port // .portRange)\t\(.protocol)"' 2>/dev/null)
    if (( ${#items[@]} == 0 )); then warn "Портов нет."; return 0; fi

    echo
    hr
    printf '%s                   УДАЛЕНИЕ ПОРТА%s\n' "$C_BLD" "$C_RST"
    hr
    for i in "${!items[@]}"; do
        IFS=$'\t' read -r p t <<<"${items[$i]}"
        printf '  %2d) %s %s\n' "$((i+1))" "$p" "$t"
    done
    echo
    ask choice "Номер порта (0 — отмена): " "0"
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Неверный ввод."; return 1; }
    (( choice >= 1 && choice <= ${#items[@]} )) || { info "Отменено."; return 0; }
    IFS=$'\t' read -r p t <<<"${items[$((choice-1))]}"

    confirm "Удалить порт ${p}/${t}?" || { info "Отменено."; return 0; }

    remove_port_from_state "$p" "$t" || return 1
    state_touch
    firewall_deny_port "$p" "$t"
    local affected; affected="$(users_using_port "$p" "$t")"
    prune_user_ports "$p" "$t"
    if [[ -n "$affected" ]]; then
        warn "Порт ${p}/${t} убран из ссылок пользователей: $affected"
        warn "(если у кого-то не осталось портов — снова включены все порты сервера)"
    fi
    if ! try_hard_apply; then warn "Не удалось перезапустить mita."; return 1; fi
    info "Порт ${p}/${t} удалён, mita перезапущен."
    regenerate_all_links
}

op_set_user_ports_interactive() { # какие порты попадят в ссылку пользователя
    local names=() i name choice ports_json
    mapfile -t names < <(state_get -r '.users[].name' 2>/dev/null)
    if (( ${#names[@]} == 0 )); then warn "Пользователей нет."; return 0; fi

    echo
    hr
    printf '%s           ПОРТЫ ПОЛЬЗОВАТЕЛЯ (для ссылки)%s\n' "$C_BLD" "$C_RST"
    hr
    for i in "${!names[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${names[$i]}"; done
    echo
    ask choice "Номер пользователя (0 — отмена): " "0"
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Неверный ввод."; return 1; }
    (( choice >= 1 && choice <= ${#names[@]} )) || { info "Отменено."; return 0; }
    name="${names[$((choice-1))]}"

    ports_json="$(choose_ports_interactive)"
    if [[ "$ports_json" == "[]" ]]; then
        state_update --arg name "$name" '.users |= map(if .name == $name then del(.ports) else . end)' || return 1
        info "Пользователю '$name' назначены ВСЕ порты."
    else
        state_update --arg name "$name" --argjson ports "$ports_json" \
            '.users |= map(if .name == $name then .ports = $ports else . end)' || return 1
        info "Пользователю '$name' назначены выбранные порты."
    fi
    state_touch
    save_user_links "$name" >/dev/null && info "Ссылка обновлена: $CLIENTS_DIR/$(sanitize_filename "$name").txt"
}

op_list_ports() {
    local items=()
    mapfile -t items < <(state_get -r '.ports[] | "\(.port // .portRange)\t\(.protocol)"' 2>/dev/null)
    echo
    hr
    printf '%s                      ПОРТЫ%s\n' "$C_BLD" "$C_RST"
    hr
    if (( ${#items[@]} == 0 )); then
        warn "Портов нет."
    else
        local i p t state check
        printf '  %-6s %-14s %-8s %s\n' "ID" "ПОРТ" "ПРОТО" "СЛУШАЕТСЯ"
        hr
        for i in "${!items[@]}"; do
            IFS=$'\t' read -r p t <<<"${items[$i]}"
            check="${p%%-*}"
            state="?"
            if command -v ss >/dev/null 2>&1; then
                if [[ "$t" == "TCP" ]]; then
                    ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${check}$" && state="да" || state="нет"
                else
                    ss -lnuH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${check}$" && state="да" || state="нет"
                fi
            fi
            printf '  %-6s %-14s %-8s %s\n' "$((i+1))" "$p" "$t" "$state"
        done
    fi
    hr
}

# ---------------------------------------------------------------------------
# Операции: ссылки / QR
# ---------------------------------------------------------------------------
op_show_links() { # op_show_links [user]
    local only="${1:-}" u
    [[ -n "$only" ]] && regenerate_all_links >/dev/null 2>&1 || true
    echo
    hr
    printf '%s                   КЛИЕНТСКИЕ ССЫЛКИ%s\n' "$C_BLD" "$C_RST"
    hr
    local found=0
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        [[ -n "$only" && "$u" != "$only" ]] && continue
        found=1
        printf '\n%s%s%s\n' "$C_BLD" "$u" "$C_RST"
        hr
        local out std simple
        out="$(generate_user_links "$u")" || { warn "Не удалось сгенерировать для $u"; continue; }
        std="$(printf '%s\n' "$out" | sed -n 's/^STANDARD=//p')"
        simple="$(printf '%s\n' "$out" | sed -n 's/^SIMPLE=//p')"
        write_client_files "$u" "$std" "$simple"
        [[ -n "$std" ]]    && printf 'mieru://  %s\n' "$std"
        [[ -n "$simple" ]] && printf 'mierus:// %s\n' "$simple"
        printf 'файл: %s\n' "$CLIENTS_DIR/$(sanitize_filename "$u").txt"
    done < <(state_get -r '.users[].name' 2>/dev/null)
    (( found == 0 )) && warn "Пользователи не найдены."
    hr
}

op_show_qr_interactive() {
    local names=() i name choice link
    mapfile -t names < <(state_get -r '.users[].name' 2>/dev/null)
    if (( ${#names[@]} == 0 )); then warn "Пользователей нет."; return 0; fi

    echo
    hr
    printf '%s                     QR-КОД%s\n' "$C_BLD" "$C_RST"
    hr
    for i in "${!names[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${names[$i]}"; done
    echo
    ask choice "Номер пользователя (0 — отмена): " "0"
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Неверный ввод."; return 1; }
    (( choice >= 1 && choice <= ${#names[@]} )) || { info "Отменено."; return 0; }
    name="${names[$((choice-1))]}"

    local out simple std
    out="$(generate_user_links "$name")" || { err "Не удалось получить ссылку."; return 1; }
    std="$(printf '%s\n' "$out" | sed -n 's/^STANDARD=//p')"
    simple="$(printf '%s\n' "$out" | sed -n 's/^SIMPLE=//p')"
    link="${std:-$simple}"

    [[ -z "$link" ]] && { err "Ссылка пуста."; return 1; }
    echo
    printf '%s%s%s\n\n' "$C_BLD" "$name" "$C_RST"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$link" || true
    else
        warn "qrencode не установлен — показываю только ссылку."
    fi
    echo
    printf '%s\n' "$link"
}

# ---------------------------------------------------------------------------
# Backup / restore
# ---------------------------------------------------------------------------
op_backup() {
    ensure_base_dirs
    local stamp dir
    stamp="$(date +%Y%m%d_%H%M%S)"
    dir="$BACKUP_DIR/$stamp"
    mkdir -p "$dir"
    chmod 700 "$dir"

    state_exists && cp -p "$STATE_FILE" "$dir/state.json" 2>/dev/null || true
    [[ -f "$SERVER_JSON" ]] && cp -p "$SERVER_JSON" "$dir/server_config.json" 2>/dev/null || true
    if [[ -d "$CLIENTS_DIR" ]]; then
        cp -rp "$CLIENTS_DIR" "$dir/clients" 2>/dev/null || true
    fi
    mita describe config >"$dir/mita_describe_config.json" 2>/dev/null || true
    chmod 600 "$dir"/* 2>/dev/null || true

    info "Backup создан: $dir"

    # оставляем последние 20 копий
    mapfile -t old < <(ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n +21)
    local d
    for d in "${old[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
    return 0
}

op_restore_interactive() {
    local dirs=() i dir choice
    mapfile -t dirs < <(ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null)
    if (( ${#dirs[@]} == 0 )); then warn "Резервных копий нет."; return 0; fi

    echo
    hr
    printf '%s                 ВОССТАНОВЛЕНИЕ%s\n' "$C_BLD" "$C_RST"
    hr
    for i in "${!dirs[@]}"; do printf '  %2d) %s\n' "$((i+1))" "$(basename "${dirs[$i]}")"; done
    echo
    ask choice "Номер копии (0 — отмена): " "0"
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "Неверный ввод."; return 1; }
    (( choice >= 1 && choice <= ${#dirs[@]} )) || { info "Отменено."; return 0; }
    dir="${dirs[$((choice-1))]}"

    [[ -f "$dir/state.json" ]] || { err "В копии нет state.json."; return 1; }
    op_restore_from "$dir"
}

op_restore_from() {
    local dir="$1"
    ensure_base_dirs
    op_backup >/dev/null 2>&1 || true
    cp -p "$dir/state.json" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    info "Состояние восстановлено из $(basename "$dir")"

    # убираем в mita пользователей, которых нет в восстановленном состоянии
    mita_ensure_daemon >/dev/null 2>&1 || true
    local desired current n
    desired="$(state_get -r '.users[].name')"
    current="$(mita_current_users)"
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if ! grep -qxF "$n" <<<"$desired"; then
            mita delete user "$n" >/dev/null 2>&1 || true
            warn "Удалён из mita пользователь '$n' (нет в копии)."
        fi
    done <<<"$current"

    if mita_hard_apply; then
        info "Конфигурация применена, mita перезапущен."
    else
        warn "Не удалось применить конфигурацию."
    fi
    regenerate_all_links
}

# ---------------------------------------------------------------------------
# Прочие операции
# ---------------------------------------------------------------------------
op_status() {
    echo
    hr
    printf '%s                       СТАТУС%s\n' "$C_BLD" "$C_RST"
    hr
    [[ -f "$STATE_FILE" ]] && printf '  %-18s %s\n' "Файл состояния:" "$STATE_FILE" || warn "Файл состояния отсутствует."
    printf '  %-18s %s\n' "Сервер:" "$(state_get -r '.serverAddress // "?"' 2>/dev/null)"
    printf '  %-18s %s\n' "Пользователей:" "$(state_get -r '.users | length' 2>/dev/null || echo 0)"
    printf '  %-18s %s\n' "Портов:" "$(state_get -r '.ports | length' 2>/dev/null || echo 0)"
    printf '  %-18s %s\n' "mita:" "$(systemctl is-active mita 2>/dev/null || echo unknown)"
    printf '  %-18s %s\n' "mita version:" "$(mita version 2>&1 | head -n1)"
    hr
    mita status 2>&1 | sed 's/^/  /' || true
    hr
    echo "  Трафик:"
    mita get users 2>&1 | sed 's/^/  /' || true
    hr
}

op_logs() {
    info "Последние 60 строк журнала mita (Ctrl+C для выхода):"
    hr
    journalctl -u mita -n 60 --no-pager 2>/dev/null || warn "journalctl недоступен."
    hr
}

op_update() {
    local ver
    ver="$(latest_mita_version)"
    [[ -n "$ver" ]] || die "Не удалось получить последнюю версию."
    download_and_install_mita "$ver"
    rm -f "$MIERU_BIN"   # обновим и клиент для ссылок
    if apply_server_config; then
        mita stop >/dev/null 2>&1 || true
        mita start >/dev/null 2>&1 || true
    fi
    regenerate_all_links
    info "Обновление завершено."
}

op_show_config() {
    echo
    hr
    printf '%s              КОНФИГУРАЦИЯ MITA%s\n' "$C_BLD" "$C_RST"
    hr
    mita describe config 2>&1 || true
    hr
    echo "  Наш файл: $SERVER_JSON"
    echo "  (пароли mita не хранит — открытые пароли только в state.json)"
}

op_restart() {
    mita_ensure_daemon >/dev/null 2>&1 || true
    mita stop >/dev/null 2>&1 || true
    apply_server_config || { err "Не удалось применить конфигурацию."; return 1; }
    mita start >/dev/null 2>&1
    sleep 1
    if mita_proxy_running; then info "mita перезапущен и работает."; else warn "mita не запустился, смотрите логи."; fi
}

op_self_update() {
    local tmp sha ts url ok=0 ver
    tmp="$(mktemp)"
    ts="$(date +%s)"
    # SHA последнего коммита main — raw по нему никогда не отдаёт кэш
    sha="$(curl -fsSL --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/RikCost/mieru-script/commits/main" 2>/dev/null \
            | grep -oE '"sha": *"[0-9a-f]{40}"' | head -n1 | grep -oE '[0-9a-f]{40}')"
    local urls=()
    if [[ -n "$sha" ]]; then
        info "Последний коммит main: ${sha:0:12}"
        urls+=("https://raw.githubusercontent.com/RikCost/mieru-script/${sha}/mieru-manager.sh")
    fi
    urls+=(
        "https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/mieru-manager.sh"
        "https://raw.githack.com/RikCost/mieru-script/main/mieru-manager.sh"
        "$REPO_RAW/mieru-manager.sh?t=${ts}"
    )
    for url in "${urls[@]}"; do
        if curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 -o "$tmp" "$url" && [[ -s "$tmp" ]]; then
            ok=1; break
        fi
    done
    if [[ "$ok" -eq 1 ]]; then
        install -m 0755 "$tmp" /usr/local/bin/mieru-manager 2>/dev/null \
            || cp "$tmp" /usr/local/bin/mieru-manager
        chmod 0755 /usr/local/bin/mieru-manager 2>/dev/null || true
        ver="$(grep -m1 '^APP_VERSION=' /usr/local/bin/mieru-manager | cut -d'"' -f2)"
        rm -f "$tmp"
        info "mieru-manager обновлён до версии ${ver:-?}. Перезапустите его."
    else
        rm -f "$tmp"
        err "Не удалось скачать обновление."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Мастер первого запуска
# ---------------------------------------------------------------------------
first_run_wizard() {
    hr
    printf '%s          ПЕРВИЧНАЯ НАСТРОЙКА MIERU (mita)%s\n' "$C_BLD" "$C_RST"
    hr
    echo "  Сервер: $(state_get -r '.serverAddress')"
    echo

    # --- порты ---
    local spec proto choice
    echo "  Настроим порты, которые будет слушать mita."
    echo "  Можно указать один порт (443) или диапазон (2012-2022)."
    echo "  Рекомендуется минимум один TCP и один UDP."
    while :; do
        ask spec "  Порт или диапазон (Enter — 443): " "443"
        valid_port_spec "$spec" || { warn "  Некорректный порт/диапазон."; continue; }
        ask choice "  Протокол: 1) TCP  2) UDP  3) TCP+UDP  [1]: " "1"
        case "$choice" in
            1|"") add_port_to_state "$spec" TCP && firewall_allow_port "$spec" TCP ;;
            2)     add_port_to_state "$spec" UDP && firewall_allow_port "$spec" UDP ;;
            3)     add_port_to_state "$spec" TCP && firewall_allow_port "$spec" TCP
                   add_port_to_state "$spec" UDP && firewall_allow_port "$spec" UDP ;;
            *)     warn "  Неверный выбор."; continue ;;
        esac
        info "  Порт $spec добавлен."
        confirm "  Добавить ещё порт?" || break
    done

    # --- пользователи ---
    echo
    echo "  Теперь добавим пользователей (по одному)."
    while :; do
        local name pw pw2
        while :; do
            ask name "  Имя пользователя: " ""
            [[ -z "$name" ]] && { warn "  Имя не может быть пустым."; continue; }
            valid_user_name "$name" || { warn "  Недопустимое имя."; continue; }
            break
        done
        ask_secret pw "  Пароль (Enter = сгенерировать): "
        if [[ -z "$pw" ]]; then
            pw="$(gen_password)"
            info "  Сгенерирован пароль: ${C_BLD}${pw}${C_RST}"
        else
            ask_secret pw2 "  Повторите пароль: "
            [[ "$pw" == "$pw2" ]] || { err "  Пароли не совпадают."; continue; }
        fi
        state_update --arg n "$name" --arg p "$pw" '.users += [{name:$n, password:$p}]' \
            || { err "  Не удалось сохранить."; continue; }
        info "  Пользователь '$name' добавлен."
        confirm "  Добавить ещё пользователя?" || break
    done

    state_touch
    if ! mita_hard_apply; then
        warn "Не удалось применить конфигурацию. Проверьте вывод: mita describe config"
        return 1
    fi
    info "Конфигурация применена, mita запущен."
    regenerate_all_links
}

# ---------------------------------------------------------------------------
# Установка
# ---------------------------------------------------------------------------
cmd_install() {
    require_root install
    info "${APP_NAME} v${APP_VERSION}: установка/настройка mita..."
    ensure_base_dirs
    state_init
    install_deps

    if ! command -v mita >/dev/null 2>&1; then
        download_and_install_mita
    else
        info "mita уже установлен: $(mita version 2>&1 | head -n1)"
        state_update --arg v "$(latest_mita_version)" '.mitaVersion = $v' >/dev/null 2>&1 || true
        systemctl enable mita >/dev/null 2>&1 || true
        systemctl start mita >/dev/null 2>&1 || true
    fi

    state_touch

    local users ports
    users="$(state_get -r '.users | length')"
    ports="$(state_get -r '.ports | length')"

    if (( users == 0 || ports == 0 )); then
        if [[ "$HAS_TTY" -eq 1 ]]; then
            first_run_wizard
        else
            warn "Нет пользователей/портов. Запустите 'mieru-manager' интерактивно."
        fi
    else
        info "Найдена существующая конфигурация, применяю её."
        mita_hard_apply || true
        regenerate_all_links
    fi

    echo
    hr
    printf '%s                 УСТАНОВКА ЗАВЕРШЕНА%s\n' "$C_GRN$C_BLD" "$C_RST"
    hr
    echo "  Сервер:        $(state_get -r '.serverAddress')"
    echo "  Пользователей: $(state_get -r '.users | length')"
    echo "  Портов:        $(state_get -r '.ports | length')"
    echo "  Состояние:     $STATE_FILE"
    echo "  Ссылки:        $CLIENTS_DIR/"
    echo
    echo "  Управление:    mieru-manager"
    hr
}

# ---------------------------------------------------------------------------
# Меню
# ---------------------------------------------------------------------------
print_menu_header() {
    local ip status users ports sc
    ip="$(state_get -r '.serverAddress // "?"' 2>/dev/null || echo '?')"
    users="$(state_get -r '.users | length' 2>/dev/null || echo 0)"
    ports="$(state_get -r '.ports | length' 2>/dev/null || echo 0)"
    if mita_proxy_running 2>/dev/null; then
        status="● RUNNING"; sc="$C_GRN"
    else
        status="● IDLE/STOPPED"; sc="$C_YEL"
    fi
    echo
    hr
    printf '%s             MIERU MANAGER %s%s\n' "$C_BLD" "$APP_VERSION" "$C_RST"
    hr
    printf '  Сервер:  %s\n' "$ip"
    printf '  Mita:    %s%s%s\n' "$sc" "$status" "$C_RST"
    printf '  Юзеров:  %s\n' "$users"
    printf '  Портов:  %s\n' "$ports"
    hr
}

print_menu_items() {
    cat <<'EOF'
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
EOF
}

cmd_self_check() {
    printf '\n=== %s v%s self-check ===\n' "$APP_NAME" "$APP_VERSION"
    printf 'HAS_TTY=%s  isatty: fd0=%s fd1=%s fd2=%s\n' \
        "$HAS_TTY" \
        "$([[ -t 0 ]] && echo yes || echo no)" \
        "$([[ -t 1 ]] && echo yes || echo no)" \
        "$([[ -t 2 ]] && echo yes || echo no)"
    printf 'TERM=%s  LANG=%s  LC_ALL=%s\n' "${TERM:-}" "${LANG:-}" "${LC_ALL:-}"
    printf 'fd0 -> %s\n' "$(readlink /proc/$$/fd/0 2>/dev/null)"
    printf 'fd1 -> %s\n' "$(readlink /proc/$$/fd/1 2>/dev/null)"
    printf 'fd2 -> %s\n' "$(readlink /proc/$$/fd/2 2>/dev/null)"
    ls -l /dev/tty 2>&1 | sed 's/^/  /'
    printf '%s\n' '--- тест вывода списка (stdout) ---'
    print_menu_header
    print_menu_items
    printf '%s\n' '--- конец теста ---'
    printf 'state: %s\n' "$STATE_FILE"
}

menu() {
    require_root
    # На некоторых системах (обёртки, логирование, sudo-настройки) stdout менеджера
    # может не совпадать с реальным терминалом. Тогда пишем меню напрямую в /dev/tty.
    if [[ ! -t 1 && -w /dev/tty ]]; then exec 1>/dev/tty; fi
    if [[ ! -t 2 && -w /dev/tty ]]; then exec 2>/dev/tty; fi
    while :; do
        # Очистка экрана только по явному желанию (по умолчанию список всегда виден).
        if [[ "${MIERU_CLEAR:-0}" == "1" ]] && command -v clear >/dev/null 2>&1; then
            clear 2>/dev/null || true
        fi
        print_menu_header
        print_menu_items
        echo
        local choice u
        ask choice "  Действие [0-19, ? — список, 0 — выход]: " "0"
        case "$choice" in
            "?"|h|H|help) continue ;;
            1)  op_add_user_interactive; pause ;;
            2)  op_delete_user_interactive; pause ;;
            3)  op_change_password_interactive; pause ;;
            4)  op_list_users; pause ;;
            5)  op_add_port_interactive; pause ;;
            6)  op_delete_port_interactive; pause ;;
            7)  op_list_ports; pause ;;
            8)  ask u "  Имя пользователя: " ""; [[ -n "$u" ]] && op_show_links "$u"; pause ;;
            9)  op_show_links; pause ;;
            10) op_show_qr_interactive; pause ;;
            11) op_backup; pause ;;
            12) op_restore_interactive; pause ;;
            13) op_update; pause ;;
            14) op_restart; pause ;;
            15) op_status; pause ;;
            16) op_logs; pause ;;
            17) op_show_config; pause ;;
            18) op_self_update; pause ;;
            19) op_set_user_ports_interactive; pause ;;
            0|q|Q) info "До выхода!"; exit 0 ;;
            *)  warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${APP_NAME} v${APP_VERSION} — управление прокси-сервером mita (mieru)

Использование:
  ${APP_NAME} [команда] [аргументы]

Без аргументов открывает интерактивное меню (при первом запуске — установку).

Команды:
  install                     Установить/перенастроить mita
  menu                        Интерактивное меню
  status                      Статус сервера, службы и трафика
  list-users                  Список пользователей
  add-user <имя> [пароль] [порты]     Порты: "all", номера "1,3" или "443/tcp,2012-2022/udp"
  delete-user <имя>           Удалить пользователя
  set-user-ports <имя> <порты>  Какие порты включать в ссылку (all | 1,3 | 443/tcp)
  passwd <имя> [пароль]       Сменить пароль
  list-ports                  Список портов
  add-port <порт|диапазон> <tcp|udp|both>   Добавить порт (443 или 2012-2022)
  delete-port <порт|диапазон>          Удалить порт (443 или 2012-2022)
  links [имя]                 Показать клиентские ссылки
  qr <имя>                    Показать QR-код
  config                      Показать конфигурацию mita
  restart                     Перезапустить mita
  backup                      Создать резервную копию
  restore <каталог>           Восстановить из копии
  update                      Обновить mita до последней версии
  self-update                 Обновить сам ${APP_NAME}
  self-check                  Диагностика (терминал, tty, вывод)
  logs                        Показать журнал mita
  version                     Версия ${APP_NAME}
  help                        Эта справка

Файлы:
  ${STATE_FILE}     состояние (пользователи, пароли, порты)
  ${SERVER_JSON}    сгенерированный конфиг для mita
  ${CLIENTS_DIR}/   клиентские ссылки и конфиги
  ${BACKUP_DIR}/    резервные копии
EOF
}

cmd_add_user_cli() {
    local name="${1:-}" pw="${2:-}" ports_sel="${3:-}"
    [[ -n "$name" ]] || die "Укажите имя: add-user <имя> [пароль] [порты]"
    valid_user_name "$name" || die "Недопустимое имя пользователя."
    state_get -e --arg n "$name" '.users[] | select(.name == $n)' 2>/dev/null | grep -q . \
        && die "Пользователь '$name' уже существует."
    [[ -z "$pw" ]] && pw="$(gen_password)"
    (( ${#pw} <= 64 )) || die "Пароль длиннее 64 байт."
    local ports_json; ports_json="$(select_ports_from_arg "$ports_sel")"
    if [[ "$ports_json" == "[]" ]]; then
        state_update --arg n "$name" --arg p "$pw" '.users += [{name:$n, password:$p}]' || die "Ошибка сохранения."
    else
        state_update --arg n "$name" --arg p "$pw" --argjson ports "$ports_json" \
            '.users += [{name:$n, password:$p, ports:$ports}]' || die "Ошибка сохранения."
    fi
    state_touch
    mita_soft_apply || die "Не удалось применить конфигурацию."
    info "Пользователь '$name' добавлен. Пароль: $pw"
    save_user_links "$name"
}

cmd_delete_user_cli() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Укажите имя: delete-user <имя>"
    state_get -e --arg n "$name" '.users[] | select(.name == $n)' 2>/dev/null | grep -q . \
        || die "Пользователь '$name' не найден."
    mita_ensure_daemon >/dev/null 2>&1 || true
    mita delete user "$name" >/dev/null 2>&1 || true
    state_update --arg n "$name" '.users = [ .users[] | select(.name != $n) ]' || die "Ошибка сохранения."
    state_touch
    mita_proxy_running && mita reload >/dev/null 2>&1 || true
    rm -f "$CLIENTS_DIR/$(sanitize_filename "$name").txt" "$CLIENTS_DIR/$(sanitize_filename "$name").json"
    info "Пользователь '$name' удалён."
}

cmd_set_user_ports_cli() {
    local name="${1:-}" sel="${2:-all}"
    [[ -n "$name" ]] || die "Укажите имя: set-user-ports <имя> <all|1,3|443/tcp,2012-2022/udp>"
    state_get -e --arg name "$name" '.users[] | select(.name == $name)' 2>/dev/null | grep -q . \
        || die "Пользователь '$name' не найден."
    local ports_json; ports_json="$(select_ports_from_arg "$sel")"
    if [[ "$ports_json" == "[]" ]]; then
        state_update --arg name "$name" '.users |= map(if .name == $name then del(.ports) else . end)' || die "Ошибка сохранения."
    else
        state_update --arg name "$name" --argjson ports "$ports_json" \
            '.users |= map(if .name == $name then .ports = $ports else . end)' || die "Ошибка сохранения."
    fi
    state_touch
    save_user_links "$name" >/dev/null
    info "Порты пользователя '$name' обновлены: $sel"
}

cmd_passwd_cli() {
    local name="${1:-}" pw="${2:-}"
    [[ -n "$name" ]] || die "Укажите имя: passwd <имя> [пароль]"
    state_get -e --arg n "$name" '.users[] | select(.name == $n)' 2>/dev/null | grep -q . \
        || die "Пользователь '$name' не найден."
    [[ -z "$pw" ]] && pw="$(gen_password)"
    (( ${#pw} <= 64 )) || die "Пароль длиннее 64 байт."
    state_update --arg n "$name" --arg p "$pw" '(.users[] | select(.name == $n) | .password) = $p' \
        || die "Ошибка сохранения."
    state_touch
    mita_soft_apply || die "Не удалось применить конфигурацию."
    info "Пароль '$name' изменён на: $pw"
    save_user_links "$name" >/dev/null
}

cmd_add_port_cli() {
    local spec="${1:-}" proto="${2:-tcp}"
    valid_port_spec "$spec" || die "Укажите порт или диапазон: add-port <443|2012-2022> <tcp|udp|both>"
    local list=()
    case "$(printf '%s' "$proto" | tr 'A-Z' 'a-z')" in
        tcp)  list=(TCP) ;;
        udp)  list=(UDP) ;;
        both|all) list=(TCP UDP) ;;
        *) die "Протокол: tcp, udp или both" ;;
    esac
    local p
    for p in "${list[@]}"; do
        if port_exists "$spec" "$p"; then
            warn "Порт ${spec}/${p} уже есть."
            continue
        fi
        add_port_to_state "$spec" "$p" || die "Ошибка сохранения."
        firewall_allow_port "$spec" "$p"
    done
    state_touch
    try_hard_apply || die "Не удалось перезапустить mita."
    regenerate_all_links
    info "Порт ${spec} (${proto}) добавлен."
}

cmd_delete_port_cli() {
    local spec="${1:-}"
    valid_port_spec "$spec" || die "Укажите порт или диапазон: delete-port <443|2012-2022>"
    local items; items="$(state_get -r --arg v "$spec" '.ports[] | select((.port | tostring) == $v or .portRange == $v) | .protocol')"
    [[ -z "$items" ]] && die "Порт $spec не найден."
    local t
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        remove_port_from_state "$spec" "$t" || die "Ошибка."
        firewall_deny_port "$spec" "$t"
        local affected; affected="$(users_using_port "$spec" "$t")"
        prune_user_ports "$spec" "$t"
        [[ -n "$affected" ]] && warn "Порт ${spec}/${t} убран из ссылок: $affected"
    done <<<"$items"
    state_touch
    try_hard_apply || die "Не удалось перезапустить mita."
    regenerate_all_links
    info "Порт $spec удалён."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    case "$cmd" in
        "" )
            if ! command -v mita >/dev/null 2>&1 || ! state_exists; then
                cmd_install
            fi
            if [[ "$HAS_TTY" -eq 1 ]]; then
                menu
            else
                usage
            fi
            ;;
        install)      cmd_install ;;
        menu)         menu ;;
        status)       require_root; op_status ;;
        list-users)   require_root; op_list_users ;;
        add-user)     require_root; shift; cmd_add_user_cli "$@" ;;
        delete-user)  require_root; shift; cmd_delete_user_cli "$@" ;;
        set-user-ports) require_root; shift; cmd_set_user_ports_cli "$@" ;;
        passwd)       require_root; shift; cmd_passwd_cli "$@" ;;
        list-ports)   require_root; op_list_ports ;;
        add-port)     require_root; shift; cmd_add_port_cli "$@" ;;
        delete-port)  require_root; shift; cmd_delete_port_cli "$@" ;;
        links)        require_root; shift; op_show_links "${1:-}" ;;
        qr)           require_root; shift; [[ -n "${1:-}" ]] || die "Укажите имя: qr <имя>"; op_show_qr_user "${1}" ;;
        config)       require_root; op_show_config ;;
        restart)      require_root; op_restart ;;
        backup)       require_root; op_backup ;;
        restore)      require_root; shift; [[ -n "${1:-}" ]] || die "Укажите каталог: restore <каталог>"; op_restore_from "${1}" ;;
        update)       require_root; op_update ;;
        self-update)  require_root; op_self_update ;;
        self-check)   cmd_self_check ;;
        logs)         require_root; op_logs ;;
        version)      printf '%s v%s\n' "$APP_NAME" "$APP_VERSION" ;;
        help|-h|--help) usage ;;
        *)            err "Неизвестная команда: $cmd"; echo; usage; exit 1 ;;
    esac
}

# QR для конкретного пользователя без интерактивного выбора
op_show_qr_user() {
    local name="$1" out std simple link
    state_get -e --arg n "$name" '.users[] | select(.name == $n)' 2>/dev/null | grep -q . \
        || die "Пользователь '$name' не найден."
    out="$(generate_user_links "$name")" || die "Не удалось получить ссылку."
    std="$(printf '%s\n' "$out" | sed -n 's/^STANDARD=//p')"
    simple="$(printf '%s\n' "$out" | sed -n 's/^SIMPLE=//p')"
    link="${std:-$simple}"
    [[ -z "$link" ]] && die "Ссылка пуста."
    printf '%s%s%s\n\n' "$C_BLD" "$name" "$C_RST"
    command -v qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$link" || warn "qrencode не установлен."
    echo
    printf '%s\n' "$link"
}

main "$@"
