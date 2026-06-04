#!/bin/bash
# setup-rf.sh — установка российского (домашнего) сервера.
# Архитектура (актуальная):
#   - 3X-UI с VLESS+Reality inbound'ами (основной VPN-трафик ВЫХОДИТ С САМОГО RF)
#   - nginx раздаёт файл подписки (HTTP origin, наружу HTTPS делает Cloudflare proxy)
#   - сетевой тюнинг (UDP-буферы + conntrack) — лечит игровые лаги и забивание NAT
#   - мониторинг (vnstat + sysstat) — для последующей диагностики
#   - hardening: SSH-порт случайный, fail2ban, UFW, BBR, автообновления
#
# ENV-переменные:
#   SUBSCRIBE_DOMAIN    — домен для раздачи sub-файла, без https:// (обязательно)
#   SUBSCRIBE_PATH      — URL-путь файла подписки (default: /sub.txt)
#
# Запуск:
#   SUBSCRIBE_DOMAIN=sub.example.com ./setup-rf.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

mkdir -p /etc/myscript
CONFIG_FILE=/etc/myscript/rf.env
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

SUBSCRIBE_DOMAIN="${SUBSCRIBE_DOMAIN:-}"
SUBSCRIBE_PATH="${SUBSCRIBE_PATH:-/sub.txt}"

[ -z "$SUBSCRIBE_DOMAIN" ] && die "Не задан SUBSCRIBE_DOMAIN. Запусти: SUBSCRIBE_DOMAIN=sub.example.com ./setup-rf.sh"

if [ -f /usr/local/x-ui/x-ui ]; then
    die "3X-UI уже установлен — скрипт только для чистой установки."
fi

# === БАЗА ===
do_base_hardening
enable_ip_forward
tune_network_sysctl

# === 3X-UI ===
install_3xui
read -r XUI_USER XUI_PASS XUI_PORT XUI_PATH <<<"$(extract_3xui_creds)"

# === NGINX + ФАЙЛ ПОДПИСКИ ===
log "Установка nginx и раздачи файла подписки на $SUBSCRIBE_DOMAIN$SUBSCRIBE_PATH..."
apt-get install -y nginx

mkdir -p /var/www/subscribe
if [ ! -f "/var/www/subscribe$SUBSCRIBE_PATH" ]; then
    cat >"/var/www/subscribe$SUBSCRIBE_PATH" <<EOF
# Файл подписки. Положи сюда vless://... ссылки, по одной на строку.
# Этот placeholder отдаётся как есть, пока ты не заменишь его.
EOF
fi
chown -R www-data:www-data /var/www/subscribe
chmod 644 "/var/www/subscribe$SUBSCRIBE_PATH"

cat >/etc/nginx/sites-available/subscribe <<EOF
server {
    listen 80;
    server_name $SUBSCRIBE_DOMAIN;

    root /var/www/subscribe;

    location $SUBSCRIBE_PATH {
        default_type text/plain;
        add_header Cache-Control "no-store";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/subscribe /etc/nginx/sites-enabled/subscribe
rm -f /etc/nginx/sites-enabled/default
nginx -t || die "nginx config invalid"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx
ok "nginx раздаёт http://$SUBSCRIBE_DOMAIN$SUBSCRIBE_PATH (origin порт 80)"

# === SSH + FAIL2BAN ===
NEW_SSH_PORT=$(randomize_ssh_port)
setup_fail2ban_ssh "$NEW_SSH_PORT"

# === UFW ===
# FORWARD policy ACCEPT — на случай если потом будешь ставить kaskad-pro для MTProxy.
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw_reset_base
ufw_allow "$NEW_SSH_PORT" tcp
[ -n "$XUI_PORT" ] && ufw_allow "$XUI_PORT" tcp   # 3X-UI panel
ufw_allow 443 tcp           # 3X-UI VLESS inbound (Reality/xhttp)
ufw_allow 8443 tcp          # 3X-UI второй inbound (опционально)
ufw_allow 80 tcp            # nginx (sub-файл) для Cloudflare
ufw_allow 2096 tcp          # 3X-UI subscription server (внутренний)
ufw_enable

# === МОНИТОРИНГ ===
install_monitoring

# === СОХРАНИТЬ КОНФИГ ===
PUB_IP=$(detect_public_ip)
cat >"$CONFIG_FILE" <<EOF
SUBSCRIBE_DOMAIN="$SUBSCRIBE_DOMAIN"
SUBSCRIBE_PATH="$SUBSCRIBE_PATH"
SSH_PORT="$NEW_SSH_PORT"
PUB_IP="$PUB_IP"
EOF
chmod 600 "$CONFIG_FILE"

# === ПРОВЕРКА БЛОКА RKN ДЛЯ НОВОГО IP ===
check_ip_blacklist "$PUB_IP"

PANEL_URL="https://${PUB_IP}:${XUI_PORT}/$(echo "$XUI_PATH" | tr -d '"/')/"

clear
cat <<EOF

═══════════════════════════════════════════════════════════
  RF-СЕРВЕР — УСТАНОВКА ЗАВЕРШЕНА
═══════════════════════════════════════════════════════════

[ 3X-UI ]
  URL:        ${PANEL_URL}
  Username:   ${XUI_USER}
  Password:   ${XUI_PASS}
  Port:       ${XUI_PORT}

  В панели создай VLESS+Reality inbound на порту 443
  (dest: www.cloudflare.com:443, fingerprint: chrome).

[ Файл подписки ]
  URL:        http://${SUBSCRIBE_DOMAIN}${SUBSCRIBE_PATH}
              (через Cloudflare proxy: https://${SUBSCRIBE_DOMAIN}${SUBSCRIBE_PATH})
  Файл:       /var/www/subscribe${SUBSCRIBE_PATH}
              ← положи сюда свои vless://... вручную

  CLOUDFLARE: проверь что в DNS A-запись ${SUBSCRIBE_DOMAIN} → ${PUB_IP}
              proxy mode = ON (orange cloud)
              SSL/TLS Mode = Flexible (или Full с self-signed)

[ Безопасность ]
  SSH port:   ${NEW_SSH_PORT}    (ssh root@${PUB_IP} -p ${NEW_SSH_PORT})
  fail2ban:   3 попытки → бан 1 год
  UFW:        включён, порты: ${NEW_SSH_PORT}, ${XUI_PORT}, 443, 8443, 80, 2096

[ Мониторинг ]
  vnstat -h            ← bandwidth по часам
  sar -n DEV 1 10      ← live network metrics
  Через 24ч появятся полные данные.

═══════════════════════════════════════════════════════════
  СОХРАНИ ЭТО! Конфиг записан в ${CONFIG_FILE}
═══════════════════════════════════════════════════════════
EOF
