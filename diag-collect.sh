#!/bin/bash
# diag-collect.sh — собрать логи и отправить в Telegram (на нейронку).
# Конфиг: /etc/myscript/diag.env
#   TG_BOT_TOKEN="..."
#   TG_CHAT_ID="..."
#   HOURS_BACK=2          (default 2)
#   EXTRA_FILES="..."     (через пробел, опционально)
#
# Использование:
#   ./diag-collect.sh                       # собрать и отправить
#   ./diag-collect.sh --setup               # интерактивно записать /etc/myscript/diag.env
#   ./diag-collect.sh --install-cron        # повесить hourly cron
#   ./diag-collect.sh --uninstall-cron
#   ./diag-collect.sh --hours 6             # переопределить окно

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=/etc/myscript/diag.env
CRON_FILE=/etc/cron.d/myscript-diag

setup_config() {
    require_root
    mkdir -p /etc/myscript
    read -rp "Telegram BOT TOKEN: " tok
    read -rp "Telegram CHAT ID:   " chat
    read -rp "Сколько часов логов собирать [2]: " hours
    hours="${hours:-2}"
    cat >"$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$tok"
TG_CHAT_ID="$chat"
HOURS_BACK="$hours"
EXTRA_FILES=""
EOF
    chmod 600 "$CONFIG_FILE"
    ok "Конфиг сохранён в $CONFIG_FILE"
}

install_cron() {
    require_root
    cat >"$CRON_FILE" <<EOF
# myscript diag — отправка логов в Telegram раз в час
0 * * * * root $SCRIPT_DIR/diag-collect.sh --silent >>/var/log/myscript-diag.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    ok "Cron установлен: $CRON_FILE (раз в час)"
}

uninstall_cron() {
    require_root
    rm -f "$CRON_FILE"
    ok "Cron снят."
}

# --- ПАРСИНГ АРГУМЕНТОВ ---
SILENT=0
HOURS_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --setup)            setup_config; exit 0 ;;
        --install-cron)     install_cron; exit 0 ;;
        --uninstall-cron)   uninstall_cron; exit 0 ;;
        --silent)           SILENT=1; shift ;;
        --hours)            HOURS_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            grep -E '^#' "$0" | sed -E 's/^# ?//' | head -20
            exit 0 ;;
        *)  die "Неизвестный флаг: $1 (см. --help)" ;;
    esac
done

require_root

[ -f "$CONFIG_FILE" ] || die "Нет конфига. Запусти: $0 --setup"
# shellcheck disable=SC1090
source "$CONFIG_FILE"
HOURS_BACK="${HOURS_OVERRIDE:-${HOURS_BACK:-2}}"

[ -z "${TG_BOT_TOKEN:-}" ] && die "TG_BOT_TOKEN пуст в $CONFIG_FILE"
[ -z "${TG_CHAT_ID:-}" ]   && die "TG_CHAT_ID пуст в $CONFIG_FILE"

HOST=$(hostname)
TS=$(date +%Y%m%d-%H%M%S)
WORK=$(mktemp -d -t diag-XXXXXX)
OUTDIR="$WORK/diag-$HOST-$TS"
mkdir -p "$OUTDIR"

log "Сбор логов в $OUTDIR ..."

# --- СИСТЕМНОЕ СОСТОЯНИЕ ---
{
    echo "=== uname -a ==="; uname -a
    echo; echo "=== uptime ==="; uptime
    echo; echo "=== free -h ==="; free -h
    echo; echo "=== df -h ==="; df -h
    echo; echo "=== top -bn1 (head) ==="; top -bn1 | head -25
    echo; echo "=== ss -tlnp ==="; ss -tlnp 2>/dev/null
    echo; echo "=== ufw status ==="; ufw status verbose 2>/dev/null || echo "ufw not installed"
    echo; echo "=== iptables -t nat -S ==="; iptables -t nat -S 2>/dev/null
    echo; echo "=== iptables -S FORWARD ==="; iptables -S FORWARD 2>/dev/null
    echo; echo "=== last -10 ==="; last -10 2>/dev/null
} >"$OUTDIR/system-state.txt" 2>&1

# --- СЕРВИСЫ ---
SERVICES="x-ui warp-svc nginx telemt fail2ban ssh sshd docker"
{
    for s in $SERVICES; do
        echo "=== systemctl status $s ==="
        systemctl status "$s" --no-pager -n 20 2>/dev/null || echo "(no service: $s)"
        echo
    done
} >"$OUTDIR/services-status.txt" 2>&1

# --- ЖУРНАЛЫ (последние HOURS_BACK часов) ---
journalctl --since "${HOURS_BACK} hours ago" --no-pager 2>/dev/null \
    >"$OUTDIR/journalctl-${HOURS_BACK}h.log" || true

for s in $SERVICES; do
    journalctl -u "$s" --since "${HOURS_BACK} hours ago" --no-pager 2>/dev/null \
        >"$OUTDIR/svc-${s}.log" || true
done

# --- DOCKER ---
if command -v docker >/dev/null 2>&1; then
    {
        echo "=== docker ps -a ==="; docker ps -a 2>&1
        echo; echo "=== docker stats (snapshot) ==="
        docker stats --no-stream 2>&1 || true
    } >"$OUTDIR/docker.txt"
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
        docker logs --since "${HOURS_BACK}h" "$c" >"$OUTDIR/docker-${c}.log" 2>&1 || true
    done
fi

# --- DMESG ---
dmesg -T 2>/dev/null | tail -300 >"$OUTDIR/dmesg-tail.log" || true

# --- КОНФИГИ MYSCRIPT (без секретов) ---
for f in /etc/myscript/swiss.env /etc/myscript/rf.env; do
    [ -f "$f" ] && grep -vE 'TOKEN|SECRET|PASS' "$f" >"$OUTDIR/$(basename "$f")" || true
done

# --- ДОП. ФАЙЛЫ ---
for f in $EXTRA_FILES; do
    [ -e "$f" ] && cp -r "$f" "$OUTDIR/" 2>/dev/null || true
done

# --- УПАКОВКА ---
ARCHIVE="/tmp/diag-${HOST}-${TS}.tar.gz"
tar -C "$WORK" -czf "$ARCHIVE" "diag-$HOST-$TS"
SIZE=$(du -h "$ARCHIVE" | cut -f1)

log "Архив: $ARCHIVE ($SIZE)"

# --- ОТПРАВКА В TELEGRAM ---
TG_API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
CAPTION="diag: ${HOST} @ $(date -Iseconds) (${HOURS_BACK}h, ${SIZE})"

# Telegram лимит: 50MB на документ через bot API
MAX_BYTES=$((48 * 1024 * 1024))
ACT_BYTES=$(stat -c%s "$ARCHIVE")
if [ "$ACT_BYTES" -gt "$MAX_BYTES" ]; then
    warn "Архив > 48MB — отправляю только сводку (system-state + services-status)."
    SMALL="/tmp/diag-${HOST}-${TS}-summary.tar.gz"
    tar -C "$WORK" -czf "$SMALL" \
        "diag-$HOST-$TS/system-state.txt" \
        "diag-$HOST-$TS/services-status.txt" \
        "diag-$HOST-$TS/dmesg-tail.log"
    ARCHIVE="$SMALL"
fi

HTTP_CODE=$(curl -s -o /tmp/tg-resp.json -w '%{http_code}' \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "caption=${CAPTION}" \
    -F "document=@${ARCHIVE}" \
    "${TG_API}/sendDocument") || true

if [ "$HTTP_CODE" = "200" ]; then
    ok "Отправлено в Telegram (chat $TG_CHAT_ID)."
else
    warn "Ошибка отправки (HTTP $HTTP_CODE):"
    cat /tmp/tg-resp.json 2>/dev/null
fi

# --- УБОРКА ---
rm -rf "$WORK"
[ "$SILENT" -eq 0 ] && ok "Готово." || true
