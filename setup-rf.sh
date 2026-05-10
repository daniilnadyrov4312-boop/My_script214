#!/bin/bash
# setup-rf.sh — установка российского (домашнего) сервера.
# Ставит: базу + 3X-UI (без WARP) + nginx для раздачи файла подписки + iptables DNAT
#         для каскада MTProto на швейцарский сервер.
#
# ENV-переменные:
#   SWISS_IP            — IP швейцарского сервера (обязательно)
#   SWISS_TELEMT_PORT   — порт telemt на швейцарском (default: 443)
#   RF_MTPROTO_PORT     — порт, на котором клиенты подключаются к РФ (default: 444)
#   SUBSCRIBE_DOMAIN    — домен для раздачи sub-файла, без https:// (например sub.example.com)
#   SUBSCRIBE_PATH      — URL-путь файла подписки (default: /sub.txt)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

mkdir -p /etc/myscript
CONFIG_FILE=/etc/myscript/rf.env
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

SWISS_IP="${SWISS_IP:-}"
SWISS_TELEMT_PORT="${SWISS_TELEMT_PORT:-443}"
RF_MTPROTO_PORT="${RF_MTPROTO_PORT:-444}"
SUBSCRIBE_DOMAIN="${SUBSCRIBE_DOMAIN:-}"
SUBSCRIBE_PATH="${SUBSCRIBE_PATH:-/sub.txt}"

[ -z "$SWISS_IP" ] && die "Не задан SWISS_IP. Запусти: SWISS_IP=1.2.3.4 ./setup-rf.sh"
[ -z "$SUBSCRIBE_DOMAIN" ] && die "Не задан SUBSCRIBE_DOMAIN. Запусти с SUBSCRIBE_DOMAIN=sub.example.com ..."

if [ -f /usr/local/x-ui/x-ui ]; then
    die "3X-UI уже установлен — скрипт только для чистой установки."
fi

do_base_hardening
enable_ip_forward

# --- 3X-UI (БЕЗ WARP) ---
install_3xui
read -r XUI_USER XUI_PASS XUI_PORT XUI_PATH <<<"$(extract_3xui_creds)"

# --- NGINX + ФАЙЛ ПОДПИСКИ ---
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
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $SUBSCRIBE_DOMAIN;

    root /var/www/subscribe;
    index index.html;

    # Cloudflare-only access: блокируем прямые подключения к origin
    # (раскомментируй если хочешь жёстко закрыть, понадобятся real-IP CF ranges)
    # set_real_ip_from 173.245.48.0/20;  # ... остальные CF ranges
    # real_ip_header CF-Connecting-IP;

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
nginx -t && systemctl reload nginx
ok "nginx раздаёт http://$SUBSCRIBE_DOMAIN$SUBSCRIBE_PATH (origin порт 80)"

# --- IPTABLES DNAT КАСКАД ДЛЯ MTPROTO ---
log "Настройка каскада MTProto: tcp/${RF_MTPROTO_PORT} → ${SWISS_IP}:${SWISS_TELEMT_PORT}..."
IFACE=$(detect_egress_iface)
[ -z "$IFACE" ] && die "Не определён egress-интерфейс."

# Чистим старые правила
iptables -t nat -D PREROUTING -p tcp --dport "$RF_MTPROTO_PORT" -j DNAT --to-destination "$SWISS_IP:$SWISS_TELEMT_PORT" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$SWISS_IP" --dport "$SWISS_TELEMT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -p tcp -s "$SWISS_IP" --sport "$SWISS_TELEMT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# Накатываем
iptables -t nat -A PREROUTING -p tcp --dport "$RF_MTPROTO_PORT" -j DNAT --to-destination "$SWISS_IP:$SWISS_TELEMT_PORT"
iptables -A FORWARD -p tcp -d "$SWISS_IP" --dport "$SWISS_TELEMT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -p tcp -s "$SWISS_IP" --sport "$SWISS_TELEMT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT
if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
fi

# UFW forward policy
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

netfilter-persistent save >/dev/null
ok "Каскад настроен: клиенты → ${RF_MTPROTO_PORT} → Swiss:${SWISS_TELEMT_PORT}"

# --- SSH + FAIL2BAN ---
NEW_SSH_PORT=$(randomize_ssh_port)
setup_fail2ban_ssh "$NEW_SSH_PORT"

# --- UFW ---
ufw_reset_base
ufw_allow "$NEW_SSH_PORT" tcp
[ -n "$XUI_PORT" ] && ufw_allow "$XUI_PORT" tcp
ufw_allow 443 tcp           # 3x-ui inbounds
ufw_allow 8443 tcp          # 3x-ui inbounds
ufw_allow 80 tcp            # nginx (sub-файл) для Cloudflare
ufw_allow "$RF_MTPROTO_PORT" tcp   # каскад MTProto
ufw_enable

# --- СОХРАНИТЬ КОНФИГ ---
PUB_IP=$(detect_public_ip)
cat >"$CONFIG_FILE" <<EOF
SWISS_IP="$SWISS_IP"
SWISS_TELEMT_PORT="$SWISS_TELEMT_PORT"
RF_MTPROTO_PORT="$RF_MTPROTO_PORT"
SUBSCRIBE_DOMAIN="$SUBSCRIBE_DOMAIN"
SUBSCRIBE_PATH="$SUBSCRIBE_PATH"
SSH_PORT="$NEW_SSH_PORT"
PUB_IP="$PUB_IP"
EOF
chmod 600 "$CONFIG_FILE"

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

[ Файл подписки ]
  URL:        http://${SUBSCRIBE_DOMAIN}${SUBSCRIBE_PATH}
              (через Cloudflare proxy: https://${SUBSCRIBE_DOMAIN}${SUBSCRIBE_PATH})
  Файл:       /var/www/subscribe${SUBSCRIBE_PATH}
              ← положи сюда свои vless://... вручную

  CLOUDFLARE: проверь что в DNS A-запись ${SUBSCRIBE_DOMAIN} → ${PUB_IP}
              и SSL/TLS Mode выставлен в "Flexible" (или "Full" с self-signed).

[ MTProto каскад ]
  Клиентский endpoint:  ${PUB_IP}:${RF_MTPROTO_PORT}
  Перенаправление на:   ${SWISS_IP}:${SWISS_TELEMT_PORT}
  Секрет:               возьми с швейцарского сервера (cat /etc/telemt/telemt.toml)
  Готовая ссылка:       tg://proxy?server=${PUB_IP}&port=${RF_MTPROTO_PORT}&secret=<SWISS_SECRET>

[ Безопасность ]
  SSH port:   ${NEW_SSH_PORT}    (ssh root@${PUB_IP} -p ${NEW_SSH_PORT})
  fail2ban:   3 попытки → бан 1 год
  UFW:        включён, порты: ${NEW_SSH_PORT}, ${XUI_PORT}, 443, 8443, 80, ${RF_MTPROTO_PORT}

═══════════════════════════════════════════════════════════
  СОХРАНИ ЭТО! Конфиг записан в ${CONFIG_FILE}
═══════════════════════════════════════════════════════════
EOF
