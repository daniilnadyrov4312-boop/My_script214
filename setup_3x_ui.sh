#!/bin/bash

# Функция для ожидания нажатия
wait_for_enter() {
    echo -e "\nНажмите [Enter], чтобы продолжить..."
    read -r
}

# 1. Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: Запустите скрипт от имени root (или через sudo)!"
  exit 1
fi

# 2. Проверка на уже установленную панель
if [ -f "/usr/local/x-ui/x-ui" ]; then
    echo "⚠️ Панель 3x-ui уже установлена. Этот скрипт предназначен для чистой установки."
    exit 1
fi

# Генерация нового случайного порта SSH
NEW_SSH_PORT=$(shuf -i 10000-65000 -n 1)

echo "--- Подготовка системы ---"
apt-get update && apt-get install -y expect qrencode curl sqlite3 ufw gnupg lsb-release systemd fail2ban unattended-upgrades
sleep 1

# Настройка автообновлений (Улучшение 3)
echo "--- Включение автоматических обновлений безопасности ---"
cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Включение TCP BBR (Улучшение 1)
echo "--- Включение алгоритма TCP BBR ---"
cat <<EOF > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p /etc/sysctl.d/99-bbr.conf

# Установка Cloudflare WARP
echo "--- Установка Cloudflare WARP ---"
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt-get update && apt-get install cloudflare-warp -y

# Настройка Cloudflare WARP
echo "--- Настройка Cloudflare WARP (Режим прокси: 40000) ---"
warp-cli registration new
warp-cli mode proxy
warp-cli proxy port 40000
warp-cli connect
sleep 2

echo "--- Запуск установки 3x-ui ---"
LOG_FILE="/tmp/3x_ui_install.log"
> "$LOG_FILE"

# Установка 3x-ui через Expect
expect <<EOF | tee $LOG_FILE
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
EOF

echo -e "\n--- Обработка данных (пауза 2 сек) ---"
sleep 2

# --- ИЗВЛЕЧЕНИЕ ДАННЫХ ПАНЕЛИ ---
DB_PATH="/etc/x-ui/x-ui.db"

if [ -f "$DB_PATH" ]; then
    USER_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='username';" 2>/dev/null)
    PASS_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='password';" 2>/dev/null)
    PORT_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='port';" 2>/dev/null)
    PATH_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null)
fi

if [[ -z "$USER_EXT" ]] || [[ -z "$PASS_EXT" ]]; then
    USER_EXT=$(grep "Username:" $LOG_FILE | tail -1 | awk '{print $NF}' | tr -d '\r')
    PASS_EXT=$(grep "Password:" $LOG_FILE | tail -1 | awk '{print $NF}' | tr -d '\r')
fi

if [[ ! "$PORT_EXT" =~ ^[0-9]+$ ]]; then
    PORT_EXT=$(grep -E "Port:[[:space:]]+[0-9]+" $LOG_FILE | tail -1 | awk '{print $NF}' | tr -d '\r')
fi

if [[ -z "$PATH_EXT" ]]; then
    PATH_EXT=$(grep "WebBasePath:" $LOG_FILE | tail -1 | awk '{print $NF}' | tr -d '\r')
fi

IP_EXT=$(curl -s ifconfig.me)
PATH_CLEAN=$(echo "$PATH_EXT" | tr -d '"/' )
URL_EXT="https://${IP_EXT}:${PORT_EXT}/${PATH_CLEAN}/"

rm -f $LOG_FILE

# Смена порта SSH
echo "--- Настройка нового порта SSH: $NEW_SSH_PORT ---"
# Добавляем новый файл конфигурации для порта, чтобы не конфликтовало с базовым файлом sshd_config
echo "Port $NEW_SSH_PORT" > /etc/ssh/sshd_config.d/custom_port.conf
# На всякий случай зачищаем старый порт из основного файла конфигурации
sed -i 's/^#*Port 22/#Port 22/g' /etc/ssh/sshd_config
sed -i 's/^Port [0-9]*/#Port \0/g' /etc/ssh/sshd_config
# Перезагружаем SSH (текущая сессия при этом не прервется)
systemctl restart ssh || systemctl restart sshd

# Настройка защиты от брутфорса Fail2Ban (Улучшение 4)
echo "--- Настройка защиты Fail2Ban ---"
cat <<EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
backend = systemd
# Баним после 3 попыток на 1 год (31536000 секунд)
maxretry = 3
bantime = 31536000
findtime = 3600
EOF
systemctl restart fail2ban

# Настройка UFW
echo "--- Настройка Firewall (UFW) ---"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# Открываем порты панели и стандартные порты, запрошенные пользователем
ufw allow ${PORT_EXT}/tcp
ufw allow 443/tcp
ufw allow 8443/tcp
# Открываем порт для Cloudflare WARP
ufw allow 40000/tcp
ufw allow 40000/udp
# Открываем новый сгенерированный SSH порт
ufw allow ${NEW_SSH_PORT}/tcp
# Включаем UFW жестко
ufw --force enable

# --- ВЫВОД ФИНАЛЬНЫХ ДАННЫХ ---
clear
echo "═══════════════════════════════════════════════════════════"
echo "         УСТАНОВКА ЗАВЕРШЕНА! ТЕХНИЧЕСКИЕ ДАННЫЕ:          "
echo "═══════════════════════════════════════════════════════════"
echo -e "\e[1;36m[ ДАННЫЕ ПАНЕЛИ 3X-UI ]\e[0m"
echo -e "👤 Имя пользователя: \e[1m${USER_EXT}\e[0m"
echo -e "🔑 Пароль:           \e[1m${PASS_EXT}\e[0m"
echo -e "🔌 Порт панели:      \e[33m${PORT_EXT}\e[0m"
echo -e "📁 Путь панели:      /${PATH_CLEAN}/"
echo -e "🌐 Ссылка для входа: \e[32m\e[4m${URL_EXT}\e[0m"
echo ""
echo -e "\e[1;36m[ СИСТЕМНЫЕ ДАННЫЕ И БЕЗОПАСНОСТЬ ]\e[0m"
echo -e "🛡️  UFW (Firewall):   \e[32mВКЛЮЧЕН\e[0m (Открыты порты: $PORT_EXT, 443, 8443, 40000, $NEW_SSH_PORT)"
echo -e "👮 Fail2Ban:        \e[32mВКЛЮЧЕН\e[0m (Бан SSH сканеров на 1 год после 3 попыток)"
echo -e "🔄 Автообновления:  \e[32mВКЛЮЧЕНЫ\e[0m (Unattended-upgrades)"
echo -e "🚀 Режим BBR:       \e[32mАКТИВЕН\e[0m (Ускорение сети)"
echo -e "🔒 Узел SSH изменен: Новое подключение будет по порту \e[1;31m$NEW_SSH_PORT\e[0m"
echo -e "💻 Команда для SSH:  ssh root@${IP_EXT} -p $NEW_SSH_PORT"
echo ""
echo -e "\e[1;36m[ СТАТУС CLOUDFLARE WARP ]\e[0m"
warp-cli status | head -n 3
echo -e "📡 Прокси WARP:      127.0.0.1:40000"
echo "═══════════════════════════════════════════════════════════"
echo -e "\e[1;33m⚠️  ВНИМАНИЕ! СОХРАНИТЕ НОВЫЙ ПОРТ SSH И ДАННЫЕ ВХОДА!\e[0m"
echo -e "С текущей консоли вы не вылетите, но при следующем входе"
echo -e "в терминал используйте команду с новым портом $NEW_SSH_PORT."
echo "═══════════════════════════════════════════════════════════"
echo -e "\e[1;32m✅ Система готова к работе!\e[0m"
