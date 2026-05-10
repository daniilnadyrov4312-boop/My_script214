# My_script214 — каскад VPN: RF + Swiss

Скрипты для настройки двухсерверного каскада: 3X-UI на обоих, WARP + telemt MTProto
на швейцарском, nginx (раздача файла подписки) + iptables-каскад на российском, плюс
сборщик логов в Telegram.

## Файлы

| Файл               | Где запускать       | Что делает |
|--------------------|---------------------|-----------|
| `lib/common.sh`    | —                   | Общие функции (подключается через `source`) |
| `setup-swiss.sh`   | На швейцарском VPS  | База + 3X-UI + WARP + telemt (MTProto FakeTLS) |
| `setup-rf.sh`      | На российском VPS   | База + 3X-UI + nginx + iptables DNAT для каскада |
| `diag-collect.sh`  | На обоих            | Сбор логов → Telegram (для скармливания нейронке) |

## Порядок развёртывания

### 1. Швейцарский сервер (первым)

```bash
git clone https://github.com/daniilnadyrov4312-boop/My_script214.git
cd My_script214
chmod +x setup-swiss.sh diag-collect.sh

# Дефолты подходят, но можно переопределить:
TLS_DOMAIN=cloudflare.com TELEMT_PORT=443 ./setup-swiss.sh
```

В конце скрипт напечатает:
- Кредсы 3X-UI (URL, логин, пароль)
- WARP-прокси (127.0.0.1:40000)
- Секрет telemt и tg://-ссылку для теста
- Новый SSH-порт (запиши!)

Конфиг сохранится в `/etc/myscript/swiss.env`.

### 2. RF-сервер

```bash
git clone https://github.com/daniilnadyrov4312-boop/My_script214.git
cd My_script214
chmod +x setup-rf.sh diag-collect.sh

SWISS_IP=<IP_швейцарского> \
SWISS_TELEMT_PORT=443 \
RF_MTPROTO_PORT=444 \
SUBSCRIBE_DOMAIN=sub.example.com \
SUBSCRIBE_PATH=/sub.txt \
  ./setup-rf.sh
```

Что произойдёт:
- 3X-UI без WARP
- nginx на :80 раздаёт `/var/www/subscribe/sub.txt` (положи туда `vless://...` руками)
- iptables: входящий tcp/444 → пробрасывается на `<SWISS_IP>:443` (телеметра)
- В UFW открыты: новый SSH, порт панели, 443, 8443, 80, 444

### 3. Cloudflare

В DNS-зоне домена `sub.example.com`:
- Тип: **A**, Name: `sub`, Content: **<IP RF-сервера>**
- Proxy status: **оранжевое облако** (включить)
- В SSL/TLS → Overview: **Flexible** (либо Full с self-signed на origin)

Файл подписки будет доступен по `https://sub.example.com/sub.txt`.

### 4. MTProto-ссылка для клиентов

С швейцарского возьми секрет:

```bash
grep secret /etc/telemt/telemt.toml
```

Сформируй ссылку (IP и порт — от RF-сервера, секрет — от швейцарского):

```
tg://proxy?server=<RF_IP>&port=<RF_MTPROTO_PORT>&secret=<SWISS_SECRET>
```

Открой её на телефоне → Telegram добавит прокси автоматически.

### 5. Сборщик логов (на обоих серверах)

Однократная настройка:

```bash
./diag-collect.sh --setup
# токен и chat_id Telegram-бота
```

Запуск вручную:

```bash
./diag-collect.sh                # за последние 2 часа
./diag-collect.sh --hours 12     # за 12 часов
```

Автозапуск раз в час:

```bash
./diag-collect.sh --install-cron
```

Результат — `.tar.gz` с системным состоянием, статусами сервисов, journalctl,
docker-логами, dmesg — приходит в Telegram-чат. Скачиваешь, скармливаешь
нейронке для разбора.

## Что собирает diag

- `uname -a`, `uptime`, `free`, `df`, `top`, `ss -tlnp`
- `ufw status`, `iptables -t nat -S`, `iptables -S FORWARD`
- `systemctl status` для: x-ui, warp-svc, nginx, telemt, fail2ban, ssh, docker
- `journalctl --since "<N> hours ago"` (общий и по каждому сервису)
- `docker ps -a` + логи всех контейнеров за окно
- `dmesg -T | tail -300`
- `/etc/myscript/*.env` (без секретов)

## Безопасность

- SSH перевешивается на случайный порт 10000-65000 (печатается в конце установки).
- fail2ban: 3 попытки → бан на год.
- UFW по умолчанию: deny incoming, allow outgoing.
- Cloudflare WARP только на швейцарском (на RF не нужен и вреден).
- 3X-UI веб-панель доступна только по своему рандомному порту с обфусцированным URL-путём.

## Troubleshooting

### v2rayN 7.21.2 крашится при включении TUN на Windows
- Выключи в настройках **legacy TUN protection** (старый singbox-TUN конфликтует с новым Xray-TUN).
- Обнови **xray core до 26.4.17+** через меню обновления ядра.
- Перед апгрейдом 7.21.2 сделай бэкап папки `guiConfigs`.
- Метаисью с обходными путями: https://github.com/2dust/v2rayN/issues/8977

### Каскад MTProto не работает
1. На RF: `iptables -t nat -L PREROUTING -n -v` — счётчики растут?
2. На RF: `cat /proc/sys/net/ipv4/ip_forward` должно быть `1`.
3. На Swiss: `ss -tlnp | grep 443` — telemt слушает?
4. На Swiss UFW: входящие с RF_IP разрешены? (`ufw status`)

### Файл подписки не отдаётся
1. `curl -v http://<SUBSCRIBE_DOMAIN>/sub.txt` напрямую с другого хоста — отвечает?
2. Cloudflare DNS: A-запись точно на правильный IP?
3. SSL/TLS Mode = Flexible (не Strict — у нас на origin нет валидного цертификата).

### Через 6-7 дней панель 3x-ui перестала открываться по HTTPS на RF
Установщик 3x-ui получает Let's Encrypt **IP-сертификат**, у него срок жизни 6 дней
с авто-ротацией каждые ~3-4 дня через `acme.sh` standalone-режим (порт 80).
На RF-сервере порт 80 после установки занят nginx → ротация падает → сертификат истекает.

Костыль: на ротации останавливать nginx. Ставим хук одной командой:
```bash
~/.acme.sh/acme.sh --info -d <SERVER_IP> >/dev/null && \
  ~/.acme.sh/acme.sh --renew -d <SERVER_IP> --force \
    --pre-hook "systemctl stop nginx" \
    --post-hook "systemctl start nginx"
```
Или принять, что панель будет открываться с предупреждением (cert expired) и нажимать
«Дополнительно → Перейти». Для производства — заменить на nginx-проксированный
сертификат, но это уже отдельная задача.

## Переустановка

Скрипты `setup-*` отказываются работать поверх существующего 3X-UI (защита от перезатирания).
Чтобы переставить:

```bash
# опасно, удалит панель
/usr/local/x-ui/x-ui uninstall
rm -rf /etc/x-ui /usr/local/x-ui
# затем заново ./setup-*.sh
```
