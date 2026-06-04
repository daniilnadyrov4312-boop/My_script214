#!/bin/bash
# lib/common.sh — общие функции для setup-swiss.sh / setup-rf.sh / diag-collect.sh
# Подключается через: source "$(dirname "$0")/lib/common.sh"

# --- ЦВЕТА ---
C_RED='\033[0;31m'
C_GRN='\033[0;32m'
C_YLW='\033[1;33m'
C_CYN='\033[0;36m'
C_BLD='\033[1m'
C_NC='\033[0m'

# ВСЕ диагностические сообщения идут в stderr — чтобы видеть их на терминале
# даже когда функция вызывается через $(...), и при этом не загаживать
# captured stdout (важно для функций типа randomize_ssh_port).
log()    { echo -e "${C_CYN}[*]${C_NC} $*" >&2; }
ok()     { echo -e "${C_GRN}[OK]${C_NC} $*" >&2; }
warn()   { echo -e "${C_YLW}[!]${C_NC} $*" >&2; }
die()    { echo -e "${C_RED}[ERR]${C_NC} $*" >&2; exit 1; }

# --- ПРОВЕРКА ROOT ---
require_root() {
    [ "$EUID" -eq 0 ] || die "Запустите от root (sudo)."
}

# --- ОПРЕДЕЛЕНИЕ IP / ИНТЕРФЕЙСА ---
detect_public_ip() {
    curl -s --max-time 5 -4 https://api.ipify.org \
      || curl -s --max-time 5 -4 https://icanhazip.com \
      || curl -s --max-time 5 -4 https://ifconfig.me
}

detect_egress_iface() {
    ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}

# --- БАЗОВЫЕ ПАКЕТЫ ---
install_base_packages() {
    log "Обновление apt и установка базовых пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    # Ubuntu 22+: needrestart показывает TUI-меню при установке пакетов — глушим
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1
    apt-get update -y
    # NB: iptables-persistent / netfilter-persistent на Ubuntu 24.04 (Noble) КОНФЛИКТУЮТ с ufw
    # (ufw 0.36.2-6 объявляет Breaks: iptables-persistent). Раньше нужны были для kaskad-каскада,
    # сейчас kaskad ставится отдельно через gokaskad и сам управляет своими правилами.
    apt-get install -y curl wget gnupg lsb-release ca-certificates \
        sqlite3 expect qrencode jq tar gzip \
        ufw fail2ban unattended-upgrades
}

# --- TCP BBR ---
enable_bbr() {
    log "Включение TCP BBR..."
    cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null
    ok "BBR включён."
}

# --- IP FORWARD (для каскада) ---
enable_ip_forward() {
    log "Включение ip_forward..."
    cat >/etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF
    sysctl -p /etc/sysctl.d/99-forward.conf >/dev/null
    ok "ip_forward включён."
}

# --- СЕТЕВОЙ ТЮНИНГ ДЛЯ VPN/ПРОКСИ ---
# Лечит:
#   - UDP-дропы при всплесках (UdpRcvbufErrors) → "100% loss в моменте" в играх
#   - забивание conntrack-таблицы при NAT-каскаде
#   - переполнения очередей на сетевом интерфейсе
# Применяется мгновенно через sysctl --system, без перезапуска сервисов.
tune_network_sysctl() {
    log "Применение сетевого тюнинга (UDP-буферы + conntrack)..."
    cat >/etc/sysctl.d/99-vpn-tuning.conf <<'EOF'
# VPN/proxy network tuning
# Откат: rm этот файл + sysctl --system

# --- сетевые буферы (против UDP-дропов и TCP retransmits) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 5000

# --- UDP-память глобально (xray открывает сотни UDP-сокетов) ---
net.ipv4.udp_mem = 65536 131072 262144

# --- conntrack (для NAT/forward, актуально на RF) ---
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
    sysctl --system >/dev/null 2>&1 || true
    ok "Сетевой тюнинг применён (rmem/wmem 16MB, conntrack 262k)."
}

# --- АВТООБНОВЛЕНИЯ БЕЗОПАСНОСТИ ---
enable_unattended_upgrades() {
    log "Настройка unattended-upgrades..."
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    ok "Автообновления безопасности включены."
}

# --- МОНИТОРИНГ ТРАФИКА И СИСТЕМЫ ---
# vnstat: графики bandwidth по часам/дням
# sysstat (sar): системные метрики каждую минуту (CPU/RAM/network errors)
# Через 24ч появятся полноценные данные для анализа аномалий.
install_monitoring() {
    log "Установка мониторинга (vnstat + sysstat)..."
    apt-get install -y vnstat sysstat >/dev/null
    sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
    # default cron — раз в 10 мин; меняем на каждую минуту для большей детализации
    sed -i 's|^5-55/10|*/1|' /etc/cron.d/sysstat 2>/dev/null || true
    systemctl enable --now vnstat sysstat >/dev/null 2>&1 || true
    ok "vnstat + sysstat подняты (через 24ч будут полные графики)."
}

# --- СЛУЧАЙНЫЙ SSH-ПОРТ (идемпотентно) ---
# Если порт уже установлен через наш custom_port.conf — переиспользуем,
# чтобы повторный запуск скрипта не менял порт каждый раз.
randomize_ssh_port() {
    local new_port
    local cfg=/etc/ssh/sshd_config.d/custom_port.conf
    if [ -f "$cfg" ]; then
        new_port=$(grep -oP '^Port \K[0-9]+' "$cfg" | head -1)
        if [ -n "$new_port" ]; then
            warn "SSH-порт уже установлен на $new_port — переиспользую."
            echo "$new_port"
            return 0
        fi
    fi
    new_port=$(shuf -i 10000-65000 -n 1)
    log "Смена SSH-порта на $new_port..."
    mkdir -p /etc/ssh/sshd_config.d
    echo "Port $new_port" >"$cfg"
    sed -i 's/^Port [0-9]*/#&/g' /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    ok "SSH теперь на порту $new_port (текущая сессия не разорвётся)."
    echo "$new_port"
}

# --- FAIL2BAN ДЛЯ SSH ---
setup_fail2ban_ssh() {
    local ssh_port="$1"
    log "Настройка fail2ban для SSH (порт $ssh_port)..."
    cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $ssh_port
filter = sshd
backend = systemd
maxretry = 3
bantime = 31536000
findtime = 3600
EOF
    systemctl restart fail2ban
    ok "fail2ban: 3 попытки → бан на 1 год."
}

# --- UFW БАЗА ---
ufw_reset_base() {
    log "Сброс UFW и базовая политика..."
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
}

ufw_allow() {
    # ufw_allow PORT [tcp|udp]
    local port="$1" proto="${2:-tcp}"
    ufw allow "${port}/${proto}" >/dev/null
}

ufw_enable() {
    log "Включение UFW..."
    ufw --force enable >/dev/null
    ok "UFW активен."
}

# --- ИЗВЛЕЧЕНИЕ КРЕДОВ 3X-UI ИЗ БД ---
extract_3xui_creds() {
    # echo'ит "USER PASS PORT WEBPATH" через пробел
    local db="/etc/x-ui/x-ui.db"
    [ -f "$db" ] || { echo "" ""  "" ""; return; }
    local u p port path
    u=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='username';" 2>/dev/null)
    p=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='password';" 2>/dev/null)
    port=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='port';" 2>/dev/null)
    path=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null)
    echo "$u $p $port $path"
}

# --- УСТАНОВКА 3X-UI ---
# Установщик 3X-UI v3.2.x — полностью неинтерактивный:
#   - SQLite по умолчанию
#   - Авто-генерация порта/логина/пароля/web-пути
#   - SSL: пробует LE для IP (если порт 80 закрыт — fallback на self-signed)
# Никакого expect не нужно, просто пайпим установщик в bash с закрытым stdin.
install_3xui() {
    if [ -f /usr/local/x-ui/x-ui ]; then
        warn "3X-UI уже установлен — пропускаю установку, кредами берём из существующей БД."
        return 0
    fi
    log "Установка 3X-UI (v3.2.x, auto-default)..."
    if ! curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh | bash </dev/null; then
        warn "Установщик 3X-UI вернул ненулевой exit-code — проверь вывод выше."
    fi
    sleep 2
    if [ ! -f /usr/local/x-ui/x-ui ]; then
        die "3X-UI install не отработал — бинарь /usr/local/x-ui/x-ui не появился."
    fi
    ok "3X-UI установлен."
}

# --- ПРОВЕРКА IP В РЕЕСТРАХ БЛОКИРОВОК РКН ---
# Не 100% (TSPU блочит вне реестра), но если IP уже в zapret-info / antifilter —
# это поздно для VPN. Тогда лучше сразу просить смену IP у хостера.
check_ip_blacklist() {
    local ip="$1"
    [ -z "$ip" ] && return 0
    log "Проверка IP $ip в реестрах блокировок РКН..."
    local found=0

    # zapret-info (зеркало основного реестра)
    if curl -s --max-time 15 "https://raw.githubusercontent.com/zapret-info/z-i/master/dump.csv" \
        | grep -qE "(^|;|,|\")${ip//./\\.}([,;\"]|$)" 2>/dev/null
    then
        warn "  ⚠ IP найден в zapret-info реестре"
        found=1
    fi

    # antifilter.network (полный список)
    if curl -s --max-time 15 "https://api.antifilter.network/list/ip.lst" \
        | grep -qE "^${ip//./\\.}$" 2>/dev/null
    then
        warn "  ⚠ IP найден в antifilter.network"
        found=1
    fi

    if [ "$found" -eq 0 ]; then
        ok "IP $ip НЕ в реестрах. TSPU может всё равно блочить отдельно — мониторь по факту."
    else
        warn "IP $ip уже в чёрных списках — VPN-клиенты из РФ не смогут подключиться."
        warn "Запроси у хостера СМЕНУ IP ПЕРЕД использованием."
    fi
}

# --- БАЗОВЫЙ HARDENING (вызывать первым в setup-*.sh) ---
do_base_hardening() {
    require_root
    install_base_packages
    enable_bbr
    enable_unattended_upgrades
}
