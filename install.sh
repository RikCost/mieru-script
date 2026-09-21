#!/usr/bin/env bash
# =============================================================================
#  mieru-script — bootstrap-установщик
#  Скачивает mieru-manager в /usr/local/bin и запускает его.
#
#  Запуск:
#     curl -fsSL https://raw.githubusercontent.com/RikCost/mieru-script/main/install.sh | bash
#
#  С аргументами:
#     curl -fsSL .../install.sh | bash -s -- status
# =============================================================================
set -Eeuo pipefail

REPO_RAW="${MIERU_REPO_RAW:-https://raw.githubusercontent.com/RikCost/mieru-script/main}"
TARGET="/usr/local/bin/mieru-manager"
TMP=""

cleanup() { [[ -n "$TMP" && -f "$TMP" ]] && rm -f "$TMP" || true; }
trap cleanup EXIT

printf '[+] mieru-script installer\n'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf '[-] Запустите от root: sudo bash\n' >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    printf '[!] curl не найден, устанавливаю...\n'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        apt-get install -y -qq curl || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q curl || true
    fi
    command -v curl >/dev/null 2>&1 || { printf '[-] Не удалось установить curl.\n' >&2; exit 1; }
fi

printf '[+] Скачиваю mieru-manager...\n'
TMP="$(mktemp)"

# Несколько зеркал на случай, если raw.githubusercontent.com недоступен с VPS.
MIRRORS=(
    "$REPO_RAW/mieru-manager.sh"
    "https://cdn.jsdelivr.net/gh/RikCost/mieru-script@main/mieru-manager.sh"
    "https://raw.githack.com/RikCost/mieru-script/main/mieru-manager.sh"
    "https://github.com/RikCost/mieru-script/raw/main/mieru-manager.sh"
)
OK=0
for url in "${MIRRORS[@]}"; do
    printf '    пробую: %s\n' "$url"
    if curl -fsSL --retry 2 --connect-timeout 15 --max-time 180 -o "$TMP" "$url" && [[ -s "$TMP" ]]; then
        OK=1
        break
    fi
done
if [[ "$OK" -ne 1 ]]; then
    printf '[-] Не удалось скачать mieru-manager ни с одного зеркала.\n' >&2
    printf '    Проверьте доступ к GitHub с сервера.\n' >&2
    exit 1
fi

install -m 0755 "$TMP" "$TARGET" 2>/dev/null || { cp "$TMP" "$TARGET" && chmod 0755 "$TARGET"; }
rm -f "$TMP"; TMP=""

printf '[+] Установлено: %s\n' "$TARGET"
printf '[+] Запускаю mieru-manager...\n\n'

# ВАЖНО: нельзя делать `exec </dev/tty` — при `curl | bash` bash читает сам
# скрипт из fd 0, и после переключения fd 0 на терминал он зависает, ожидая
# продолжения сценария из tty. Просто подключаем терминал к запускаемой
# программе (это не меняет fd 0 текущего shell).
if [[ -e /dev/tty ]]; then
    "$TARGET" "$@" </dev/tty
else
    "$TARGET" "$@"
fi
