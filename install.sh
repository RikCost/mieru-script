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

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf '[-] Запустите от root: sudo bash\n' >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    printf '[!] curl не найден, устанавливаю...\n'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl >/dev/null 2>&1 || true
    fi
    command -v curl >/dev/null 2>&1 || { printf '[-] Не удалось установить curl.\n' >&2; exit 1; }
fi

printf '[+] Скачиваю mieru-manager из %s\n' "$REPO_RAW"
TMP="$(mktemp)"
curl -fsSL --retry 3 --connect-timeout 15 "$REPO_RAW/mieru-manager.sh" -o "$TMP"

install -m 0755 "$TMP" "$TARGET" 2>/dev/null || { cp "$TMP" "$TARGET" && chmod 0755 "$TARGET"; }
rm -f "$TMP"; TMP=""

printf '[+] Установлено: %s\n' "$TARGET"

# При `curl | bash` стандартный ввод занят каналом. Возвращаем терминал,
# иначе интерактивное меню не сможет читать ответы пользователя.
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
    exec </dev/tty
fi

exec "$TARGET" "$@"
