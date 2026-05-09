#!/usr/bin/env bash
# vpn_diag.sh — диагностика каскада RU -> CH на стеке 3x-ui (XRay) + Cloudflare WARP.
# Запускать на КАЖДОМ сервере (RU и CH) под root. Скрипт собирает отчёт и кладёт его в /tmp.
#
# Использование:
#   sudo bash vpn_diag.sh                       # обычный прогон
#   sudo bash vpn_diag.sh --peer <IP_другого_сервера>   # дополнительно проверит линк до второго узла
#   sudo bash vpn_diag.sh --install             # доустановит mtr/iperf3/speedtest, если не хватает
#   sudo bash vpn_diag.sh --iperf-server        # поднимет iperf3 в режиме сервера на 5201 и выйдет
#
# Чтобы измерить линк RU<->CH:
#   1) на одном сервере: sudo bash vpn_diag.sh --iperf-server
#   2) на втором: sudo bash vpn_diag.sh --peer <IP_первого>

set -u

PEER=""
DO_INSTALL=0
IPERF_SERVER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --peer) PEER="$2"; shift 2 ;;
        --install) DO_INSTALL=1; shift ;;
        --iperf-server) IPERF_SERVER=1; shift ;;
        -h|--help)
            sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "Неизвестный флаг: $1"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "Запусти от root (sudo bash $0 ...)"
    exit 1
fi

if [ "$IPERF_SERVER" -eq 1 ]; then
    command -v iperf3 >/dev/null || { apt-get update -qq && apt-get install -y iperf3; }
    echo "Стартую iperf3 на 0.0.0.0:5201 ..."
    echo "Не забудь открыть порт: ufw allow 5201/tcp && ufw allow 5201/udp"
    exec iperf3 -s -p 5201
fi

if [ "$DO_INSTALL" -eq 1 ]; then
    apt-get update -qq
    apt-get install -y mtr-tiny iperf3 ethtool conntrack jq curl bc dnsutils traceroute
fi

HOST="$(hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/vpn-diag-${HOST}-${TS}.txt"

# ---------- helpers ----------
section() { printf '\n\n========== %s ==========\n' "$*" | tee -a "$OUT"; }
run() {
    local desc="$1"; shift
    printf '\n--- %s ---\n$ %s\n' "$desc" "$*" | tee -a "$OUT"
    "$@" 2>&1 | tee -a "$OUT" || true
}
runsh() {
    local desc="$1"; shift
    printf '\n--- %s ---\n$ %s\n' "$desc" "$*" | tee -a "$OUT"
    bash -c "$*" 2>&1 | tee -a "$OUT" || true
}

# ---------- system ----------
section "1. SYSTEM"
run "uname"        uname -a
run "uptime"       uptime
run "OS release"   cat /etc/os-release
run "CPU"          lscpu
run "RAM"          free -h
run "Диск"         df -hT
run "Load 1m"      bash -c "cut -d' ' -f1 /proc/loadavg"

# ---------- network ----------
section "2. NETWORK INTERFACES"
run "Интерфейсы"   ip -br addr
run "Маршруты"     ip route
run "Default iface (по умолчанию)"   bash -c "ip route get 1.1.1.1 | head -1"
# фикс: ip -o выдаёт всё в одну строку, sed достаёт значение после 'dev'
DEFIF="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
echo "DEFIF=${DEFIF}" | tee -a "$OUT"

if [ -n "${DEFIF:-}" ]; then
    run "ip -s link на ${DEFIF}" ip -s link show "$DEFIF"
    if command -v ethtool >/dev/null; then
        run "ethtool ${DEFIF}"            ethtool "$DEFIF"
        run "ethtool -S errors/drops"     bash -c "ethtool -S ${DEFIF} 2>&1 | egrep -i 'err|drop|discard|fail|miss|overrun|underrun|fcs|crc' || echo '(нет счётчиков ошибок или их 0)'"
        run "ethtool -S полный"           ethtool -S "$DEFIF"
        run "ethtool -g (ring buffers)"   ethtool -g "$DEFIF"
        run "ethtool -k offload (хвост)"  bash -c "ethtool -k ${DEFIF} 2>/dev/null | egrep -i 'tcp-segmentation|generic-segmentation|generic-receive|large-receive|tx-checksum|rx-checksum|scatter-gather'"
    fi
    # Текущий bandwidth: считаем дельту байт за 5 секунд
    runsh "Текущий bandwidth на ${DEFIF} (за 5 сек)" "
        rx1=\$(cat /sys/class/net/${DEFIF}/statistics/rx_bytes);
        tx1=\$(cat /sys/class/net/${DEFIF}/statistics/tx_bytes);
        sleep 5;
        rx2=\$(cat /sys/class/net/${DEFIF}/statistics/rx_bytes);
        tx2=\$(cat /sys/class/net/${DEFIF}/statistics/tx_bytes);
        echo \"RX: \$(( (rx2-rx1)*8/5/1000000 )) Mbit/s\";
        echo \"TX: \$(( (tx2-tx1)*8/5/1000000 )) Mbit/s\""
fi

# ---------- TCP / sysctl ----------
section "3. TCP / SYSCTL"
run "BBR / qdisc"  bash -c "sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc"
run "Доступные CC" bash -c "sysctl net.ipv4.tcp_available_congestion_control"
run "tcp_mem/rmem/wmem" bash -c "sysctl net.ipv4.tcp_mem net.ipv4.tcp_rmem net.ipv4.tcp_wmem"
run "ip_forward"   bash -c "sysctl net.ipv4.ip_forward"
run "qdisc на интерфейсах" tc -s qdisc show
run "ss -s (общая статистика)" ss -s
runsh "Retrans / drops (nstat)"  "nstat -az 2>/dev/null | egrep -i 'retrans|drop|loss|reorder|listenoverflow|listendrops|tcpsynretrans' || true"
runsh "Retrans-rate за 30 сек (актуальный)" "
    nstat -rs >/dev/null 2>&1;
    sleep 30;
    out=\$(nstat -an 2>/dev/null);
    sent=\$(echo \"\$out\"  | awk '/^TcpOutSegs / {print \$2}');
    retr=\$(echo \"\$out\"  | awk '/^TcpRetransSegs / {print \$2}');
    echo \"Sent: \$sent  Retrans: \$retr\";
    if [ -n \"\$sent\" ] && [ \"\$sent\" -gt 0 ]; then
        echo \"Retrans rate: \$(awk -v r=\$retr -v s=\$sent 'BEGIN{printf \"%.3f%%\\n\", r*100/s}')\";
    fi"
runsh "TCP сегменты (netstat)"   "netstat -s 2>/dev/null | egrep -i 'segments retrans|packets received|bad segments|listen' || true"

# ---------- conntrack ----------
section "4. CONNTRACK"
runsh "conntrack count" "cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null"
runsh "conntrack max"   "cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null"
runsh "Топ-10 src по соединениям" \
    "ss -tan state established 2>/dev/null | awk 'NR>1{print \$4}' | awk -F: '{print \$1}' | sort | uniq -c | sort -rn | head -10"

# ---------- firewall ----------
section "5. FIREWALL"
run "ufw status"   ufw status verbose
runsh "iptables -L -v -n"  "iptables -L -v -n | head -100"
runsh "fail2ban status"    "fail2ban-client status 2>/dev/null && fail2ban-client status sshd 2>/dev/null"

# ---------- 3x-ui / xray ----------
section "6. 3X-UI / XRAY"
run "x-ui systemd"    systemctl status x-ui --no-pager -l
runsh "xray процессы / cpu" \
    "ps -eo pid,pcpu,pmem,rss,nlwp,comm,args --sort=-pcpu | egrep -i 'xray|x-ui' | head -20"
runsh "xray слушает порты" \
    "ss -tlnp 2>/dev/null | egrep -i 'xray|x-ui' || true"
runsh "Логи x-ui (хвост 80 строк)" \
    "journalctl -u x-ui -n 80 --no-pager 2>/dev/null"
runsh "Конфиг outbound'ов (поиск forward на CH)" \
    "find /etc/x-ui /usr/local/x-ui -name '*.json' 2>/dev/null | xargs -I{} sh -c 'echo \"### {}\"; cat \"{}\"' 2>/dev/null | head -300"

# ---------- WARP ----------
section "7. CLOUDFLARE WARP"
runsh "warp-cli status"   "warp-cli status 2>/dev/null || echo 'warp-cli не установлен/не запущен'"
runsh "warp-cli settings" "warp-cli settings 2>/dev/null || true"
runsh "WARP listen?"      "ss -tlnp 2>/dev/null | grep ':40000' || echo 'порт 40000 не слушается'"
runsh "Тест WARP-прокси (curl через 127.0.0.1:40000) — trace" \
    "curl -m 8 -x socks5h://127.0.0.1:40000 -s https://www.cloudflare.com/cdn-cgi/trace 2>&1 | head -20"
runsh "Скорость через WARP (cachefly 100MB через socks5)" \
    "curl -o /dev/null -x socks5h://127.0.0.1:40000 -m 40 -w 'speed=%{speed_download} bytes/s   size=%{size_download}   time=%{time_total}\n' https://cachefly.cachefly.net/100mb.test 2>&1"

# ---------- DNS ----------
section "8. DNS"
run  "resolv.conf"  cat /etc/resolv.conf
runsh "Скорость DNS (cloudflare)" "for i in 1 2 3; do dig +tries=1 +time=2 @1.1.1.1 google.com 2>/dev/null | grep 'Query time' ; done"
runsh "Скорость DNS (google)"     "for i in 1 2 3; do dig +tries=1 +time=2 @8.8.8.8 google.com 2>/dev/null | grep 'Query time' ; done"

# ---------- latency / loss to internet ----------
section "9. LATENCY / LOSS (внешние таргеты)"
for tgt in 1.1.1.1 8.8.8.8 9.9.9.9; do
    runsh "ping ${tgt}" "ping -c 20 -i 0.2 -W 2 ${tgt} | tail -3"
done
if command -v mtr >/dev/null; then
    for tgt in 1.1.1.1 8.8.8.8; do
        runsh "mtr ${tgt}" "mtr -rwzbc 50 ${tgt}"
    done
else
    echo "mtr не установлен — поставь: apt install mtr-tiny  (или запусти скрипт с --install)" | tee -a "$OUT"
fi

# ---------- peer link ----------
if [ -n "$PEER" ]; then
    section "10. ЛИНК ДО PEER (${PEER})"
    runsh "ping peer"        "ping -c 30 -i 0.2 -W 2 ${PEER} | tail -3"
    if command -v mtr >/dev/null; then
        runsh "mtr до peer"  "mtr -rwzbc 50 ${PEER}"
    fi
    if command -v iperf3 >/dev/null; then
        runsh "iperf3 TCP к peer (30s)"  "iperf3 -c ${PEER} -p 5201 -t 30 -i 5"
        runsh "iperf3 TCP reverse (30s)" "iperf3 -c ${PEER} -p 5201 -t 30 -i 5 -R"
        runsh "iperf3 TCP параллель 4 потока (20s)" "iperf3 -c ${PEER} -p 5201 -t 20 -P 4"
        runsh "iperf3 UDP 200M (10s)"    "iperf3 -c ${PEER} -p 5201 -u -b 200M -t 10"
    else
        echo "iperf3 не установлен — apt install iperf3" | tee -a "$OUT"
    fi
fi

# ---------- speed (наружу) ----------
section "11. PUBLIC SPEED TEST (curl, голая скорость БЕЗ xray и WARP)"
# тянем большие файлы через дефолтный маршрут — это «голая» скорость хоста
runsh "curl 100MB cachefly (US/Anycast)" \
    "curl -o /dev/null -m 40 -w 'speed=%{speed_download} bytes/s   size=%{size_download}   time=%{time_total}\n' https://cachefly.cachefly.net/100mb.test"
runsh "curl 100MB OVH eu" \
    "curl -o /dev/null -m 40 -w 'speed=%{speed_download} bytes/s   size=%{size_download}   time=%{time_total}\n' https://proof.ovh.net/files/100Mb.dat"
runsh "curl 100MB leaseweb DE" \
    "curl -o /dev/null -m 40 -w 'speed=%{speed_download} bytes/s   size=%{size_download}   time=%{time_total}\n' https://mirror.leaseweb.com/speedtest/100mb.bin"
runsh "curl 100MB Cloudflare speed (raw, без WARP)" \
    "curl -o /dev/null -m 40 -w 'speed=%{speed_download} bytes/s   size=%{size_download}   time=%{time_total}\n' 'https://speed.cloudflare.com/__down?bytes=104857600'"

# ---------- dmesg / errors ----------
section "12. DMESG (последние ошибки за 24ч)"
runsh "dmesg errors" "dmesg -T --level=err,crit,alert,emerg 2>/dev/null | tail -50"
runsh "OOM?" "dmesg -T 2>/dev/null | grep -i -E 'out of memory|oom-killer' | tail -20"

# ---------- summary hints ----------
section "13. БЫСТРЫЕ ПОДСКАЗКИ"
{
echo "Что смотреть в первую очередь:"
echo "  • CPU xray в секции 6 — если pcpu >= 90 на ядро = упёрлось в шифрование (single-thread)."
echo "  • retrans-rate в секции 3 (за 30 сек) — норма < 0.5%, > 1% = плохой аплинк."
echo "  • ethtool -S errors/dropped в секции 2 — железо/драйвер/MTU."
echo "  • mtr loss% в секциях 9-10 — где теряется трафик: первый хоп (хостер), на пути или на peer."
echo "  • WARP в секции 7 — если каскад завязан на WARP, и он лагает = вся цепочка лагает."
echo "  • iperf3 в секции 10 — это РЕАЛЬНАЯ скорость линка между RU и CH без шифрования."
echo "    Если iperf3 даёт 1Gbps, а пользователь видит 20Mbps — упёрлось НЕ в линк, а в xray/CPU/WARP."
echo "  • Секция 11: голая скорость хостера. Если она и так слабая — проблема у хостера, не у тебя."
echo
echo "Сравни /tmp/vpn-diag-*.txt с RU и CH сервера: diff -y или просто рядом в редакторе."
} | tee -a "$OUT"

echo
echo "Готово. Отчёт: $OUT"
echo "Скачать на свою машину:  scp -P <порт> root@<server>:$OUT ."
