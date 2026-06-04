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

log()    { echo -e "${C_CYN}[*]${C_NC} $*"; }
ok()     { echo -e "${C_GRN}[OK]${C_NC} $*"; }
warn()   { echo -e "${C_YLW}[!]${C_NC} $*"; }
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

# --- СЛУЧАЙНЫЙ SSH-ПОРТ ---
randomize_ssh_port() {
    local new_port
    new_port=$(shuf -i 10000-65000 -n 1)
    log "Смена SSH-порта на $new_port..."
    mkdir -p /etc/ssh/sshd_config.d
    echo "Port $new_port" >/etc/ssh/sshd_config.d/custom_port.conf
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

# --- УСТАНОВКА 3X-UI ЧЕРЕЗ EXPECT ---
# Поток актуального install.sh (mhsanaei/3x-ui, конец 2025):
#   1. Авто-детект публичного IP. Если не вышло — спросит вручную.
#   2. "Would you like to customize the Panel Port settings? [y/n]" → n (рандомный)
#   3. SSL Setup (MANDATORY): "Choose an option (default 2 for IP)" → \r (= 2, LE для IP)
#   4. "Port to use for ACME HTTP-01 listener (default 80)" → \r
# ACME требует свободный 80/tcp снаружи; на свежей машине он свободный.
install_3xui() {
    [ -f /usr/local/x-ui/x-ui ] && { warn "3X-UI уже установлен — пропускаю."; return; }
    log "Установка 3X-UI..."
    local pub_ip
    pub_ip=$(detect_public_ip || true)
    log "Public IP для fallback в установщик: ${pub_ip:-<not detected>}"
    local logf=/tmp/3xui_install.log
    PUB_IP_FOR_EXPECT="$pub_ip" expect <<'EXP' | tee "$logf"
set timeout 600
set pub_ip $env(PUB_IP_FOR_EXPECT)

spawn bash -c "curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh | bash"

# Глобальные обработчики (могут сработать в любой момент):
expect_before {
    "Please enter your server's public IPv4 address:" {
        send "$pub_ip\r"; exp_continue
    }
    -re "Enter another port for acme.sh standalone listener.*:" {
        send "\r"; exp_continue
    }
}

expect "customize the Panel Port settings"
sleep 1
send "n\r"

# SSL setup — выбираем дефолт (опция 2 = LE для IP)
expect "Choose an option"
sleep 1
send "\r"

# ACME HTTP-01 порт — дефолт 80
expect "Port to use for ACME HTTP-01 listener"
sleep 1
send "\r"

# Дальше после ACME могут быть пост-промпты (если LE-cert получен):
#   - "Would you like to modify --reloadcmd for ACME?" → n (оставить дефолт)
#   - "Would you like to set this certificate for the panel?" → y (применить сертификат)
# Если LE упал — этих промптов не будет, идём прямо в eof.
expect {
    -re "modify --reloadcmd for ACME.*y/n" {
        send "n\r"; exp_continue
    }
    -re "set this certificate for the panel.*y/n" {
        send "y\r"; exp_continue
    }
    eof
}
EXP
    sleep 2
    if [ ! -f /usr/local/x-ui/x-ui ]; then
        die "3X-UI install не отработал — смотри $logf"
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
