#!/bin/bash
# setup-swiss.sh — установка швейцарского (зарубежного) сервера.
# Ставит: базу + 3X-UI + Cloudflare WARP (proxy mode) + telemt MTProto (FakeTLS).
#
# ENV-переменные (можно не задавать — будут запрошены/использованы дефолты):
#   TLS_DOMAIN          — домен для FakeTLS у telemt (default: cloudflare.com)
#   TELEMT_PORT         — порт MTProto на этом сервере (default: 443)
#   WARP_PROXY_PORT     — порт WARP в proxy-режиме (default: 40000)
#   RF_SERVER_IP        — если задан, в UFW откроется telemt-порт только для RF_SERVER_IP

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TLS_DOMAIN="${TLS_DOMAIN:-cloudflare.com}"
TELEMT_PORT="${TELEMT_PORT:-443}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
RF_SERVER_IP="${RF_SERVER_IP:-}"

mkdir -p /etc/myscript
CONFIG_FILE=/etc/myscript/swiss.env
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

if [ -f /usr/local/x-ui/x-ui ]; then
    die "3X-UI уже установлен — этот скрипт только для чистой установки. Если нужен только telemt — запусти отдельно (см. README)."
fi

do_base_hardening

# --- WARP ---
log "Установка Cloudflare WARP..."
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    >/etc/apt/sources.list.d/cloudflare-client.list
apt-get update -y
apt-get install -y cloudflare-warp

# Демон warp-svc может ещё не успеть стартануть после postinst
systemctl enable warp-svc 2>/dev/null || true
systemctl start warp-svc 2>/dev/null || true
sleep 3

log "Регистрация и запуск WARP в proxy-режиме на $WARP_PROXY_PORT..."
# warp-cli 2024+ : registration new ; старее : register ; пробуем оба, игнорим если уже зарегано
warp-cli registration new 2>/dev/null \
  || warp-cli register 2>/dev/null \
  || true
warp-cli mode proxy
warp-cli proxy port "$WARP_PROXY_PORT"
warp-cli connect
sleep 3
ok "WARP запущен."

# --- 3X-UI ---
install_3xui
read -r XUI_USER XUI_PASS XUI_PORT XUI_PATH <<<"$(extract_3xui_creds)"

# --- TELEMT ---
log "Установка telemt MTProto (FakeTLS, домен=$TLS_DOMAIN, порт=$TELEMT_PORT)..."
curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | \
    sh -s -- -l ru -d "$TLS_DOMAIN" -p "$TELEMT_PORT"

# Извлекаем готовую ссылку и секрет из конфига telemt
TELEMT_LINK=""
TELEMT_SECRET=""
if [ -f /etc/telemt/telemt.toml ]; then
    TELEMT_SECRET=$(grep -E '^\s*secret\s*=' /etc/telemt/telemt.toml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
PUB_IP=$(detect_public_ip)
if [ -n "$TELEMT_SECRET" ]; then
    TELEMT_LINK="tg://proxy?server=${PUB_IP}&port=${TELEMT_PORT}&secret=${TELEMT_SECRET}"
fi

# --- SSH + FAIL2BAN ---
NEW_SSH_PORT=$(randomize_ssh_port)
setup_fail2ban_ssh "$NEW_SSH_PORT"

# --- UFW ---
ufw_reset_base
ufw_allow "$NEW_SSH_PORT" tcp
[ -n "$XUI_PORT" ] && ufw_allow "$XUI_PORT" tcp
ufw_allow 443 tcp
ufw_allow 8443 tcp
ufw_allow "$WARP_PROXY_PORT" tcp
ufw_allow "$WARP_PROXY_PORT" udp
# telemt порт — открываем для всех, либо только для RF если задан
if [ -n "$RF_SERVER_IP" ] && [ "$TELEMT_PORT" != "443" ]; then
    ufw allow from "$RF_SERVER_IP" to any port "$TELEMT_PORT" proto tcp >/dev/null
    log "telemt порт $TELEMT_PORT открыт ТОЛЬКО для RF_SERVER_IP=$RF_SERVER_IP"
elif [ "$TELEMT_PORT" != "443" ] && [ "$TELEMT_PORT" != "8443" ]; then
    ufw_allow "$TELEMT_PORT" tcp
fi
ufw_enable

# --- СОХРАНИТЬ КОНФИГ ---
cat >"$CONFIG_FILE" <<EOF
TLS_DOMAIN="$TLS_DOMAIN"
TELEMT_PORT="$TELEMT_PORT"
TELEMT_SECRET="$TELEMT_SECRET"
WARP_PROXY_PORT="$WARP_PROXY_PORT"
SSH_PORT="$NEW_SSH_PORT"
PUB_IP="$PUB_IP"
RF_SERVER_IP="$RF_SERVER_IP"
EOF
chmod 600 "$CONFIG_FILE"

PANEL_URL="https://${PUB_IP}:${XUI_PORT}/$(echo "$XUI_PATH" | tr -d '"/')/"

clear
cat <<EOF

═══════════════════════════════════════════════════════════
  ШВЕЙЦАРСКИЙ СЕРВЕР — УСТАНОВКА ЗАВЕРШЕНА
═══════════════════════════════════════════════════════════

[ 3X-UI ]
  URL:        ${PANEL_URL}
  Username:   ${XUI_USER}
  Password:   ${XUI_PASS}
  Port:       ${XUI_PORT}

[ Cloudflare WARP ]
  Proxy:      127.0.0.1:${WARP_PROXY_PORT}
  Status:     $(warp-cli status 2>/dev/null | head -1)

[ telemt MTProto (FakeTLS) ]
  Domain:     ${TLS_DOMAIN}
  Port:       ${TELEMT_PORT}
  Secret:     ${TELEMT_SECRET:-<см. /etc/telemt/telemt.toml>}
  Direct link (для теста с этого IP):
              ${TELEMT_LINK:-<см. systemctl status telemt>}

[ Безопасность ]
  SSH port:   ${NEW_SSH_PORT}    (ssh root@${PUB_IP} -p ${NEW_SSH_PORT})
  fail2ban:   3 попытки → бан 1 год
  UFW:        включён

═══════════════════════════════════════════════════════════
  СОХРАНИ ЭТО! Конфиг записан в ${CONFIG_FILE}
═══════════════════════════════════════════════════════════

ДАЛЬШЕ:
  1. На RF-сервере запусти setup-rf.sh, передав SWISS_IP=${PUB_IP}
     и SWISS_TELEMT_PORT=${TELEMT_PORT}
  2. После этого настрой клиентскую ссылку MTProto: возьми секрет
     отсюда (${TELEMT_SECRET:-...}), но IP замени на RF-сервер.

EOF
