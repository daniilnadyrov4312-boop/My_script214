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
    apt-get update -y
    apt-get install -y curl wget gnupg lsb-release ca-certificates \
        sqlite3 expect qrencode jq tar gzip \
        ufw fail2ban unattended-upgrades \
        netfilter-persistent iptables-persistent
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

# --- АВТООБНОВЛЕНИЯ БЕЗОПАСНОСТИ ---
enable_unattended_upgrades() {
    log "Настройка unattended-upgrades..."
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    ok "Автообновления безопасности включены."
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
install_3xui() {
    [ -f /usr/local/x-ui/x-ui ] && { warn "3X-UI уже установлен — пропускаю."; return; }
    log "Установка 3X-UI..."
    local logf=/tmp/3xui_install.log
    expect <<'EXP' | tee "$logf"
set timeout -1
spawn bash -c "curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh | bash"
expect "Confirm the installation"
sleep 1
send "y\r"
expect "customize the Panel Port settings"
sleep 1
send "n\r"
expect "Choose an option"
sleep 1
send "2\r"
expect "Port to use for ACME"
sleep 1
send "\r"
expect eof
EXP
    sleep 2
    ok "3X-UI установлен."
}

# --- БАЗОВЫЙ HARDENING (вызывать первым в setup-*.sh) ---
do_base_hardening() {
    require_root
    install_base_packages
    enable_bbr
    enable_unattended_upgrades
}
