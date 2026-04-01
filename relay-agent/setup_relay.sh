#!/bin/bash
# ═══════════════════════════════════════
# WARP Relay — полная настройка relay-сервера
# Устанавливает: ipset whitelist + iptables NAT + relay-agent
# Запуск: sudo bash setup_relay.sh
# ═══════════════════════════════════════

set -e

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'; B='\033[1m'

echo -e "${B}═══════════════════════════════════════${N}"
echo -e "${B}  WARP Relay — Full Setup${N}"
echo -e "${B}═══════════════════════════════════════${N}"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${R}Запустите от root: sudo bash $0${N}"
    exit 1
fi

# ── Параметры ──
read -p "Agent secret (общий с панелью): " AGENT_SECRET
read -p "Agent port [7580]: " AGENT_PORT
AGENT_PORT=${AGENT_PORT:-7580}

INSTALL_DIR="/opt/warp-relay-agent"
TAG="WR_RULE"

# ═══════════════════════════════════════
# 1. СИСТЕМНЫЕ ПАКЕТЫ
# ═══════════════════════════════════════

echo ""
echo -e "${Y}[1/6] Установка пакетов...${N}"
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq iptables ipset curl conntrack netfilter-persistent ipset-persistent python3 python3-pip python3-venv

# ═══════════════════════════════════════
# 2. IP FORWARD
# ═══════════════════════════════════════

echo -e "${Y}[2/6] Включаем ip_forward...${N}"
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/ipv4-forwarding.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# ═══════════════════════════════════════
# 3. IPSET
# ═══════════════════════════════════════

echo -e "${Y}[3/6] Создаём ipset warp_whitelist...${N}"
ipset destroy warp_whitelist 2>/dev/null || true
ipset create warp_whitelist hash:ip
echo -e "${G}  ipset создан${N}"

# ═══════════════════════════════════════
# 4. IPTABLES — NAT + WHITELIST FORWARD
# ═══════════════════════════════════════

echo -e "${Y}[4/6] Настраиваем iptables...${N}"

SRC_IP=$(curl -4s ifconfig.me)
DST_IP=$(getent ahostsv4 engage.cloudflareclient.com | awk '{print $1; exit}')

echo -e "  Relay IP:  ${B}${SRC_IP}${N}"
echo -e "  CF IP:     ${B}${DST_IP}${N}"

# Удаляем старые правила
iptables -t nat -S | grep "WR_RULE" | sed 's/^-A/-D/' | while read rule; do
    iptables -t nat $rule 2>/dev/null || true
done
iptables -S | grep "WR_RULE\|WR_WHITELIST" | sed 's/^-A/-D/' | while read rule; do
    iptables $rule 2>/dev/null || true
done

# NAT — мультипорт
PORTS=(500 854 859 864 878 880 890 891 894 903 908 928 934 939 942 943 945 946 955 968 987 988 1002 1010 1014 1018 1070 1074 1180 1387 1701 1843 2371 2408 2506 3138 3476 3581 3854 4177 4198 4233 4500 5279 5956 7103 7152 7156 7281 7559 8319 8742 8854 8886)

CHUNK_SIZE=15
for ((i=0; i<${#PORTS[@]}; i+=CHUNK_SIZE)); do
    CHUNK=("${PORTS[@]:i:CHUNK_SIZE}")
    PORTS_GROUP=$(IFS=,; echo "${CHUNK[*]}")

    iptables -t nat -A PREROUTING \
        -d ${SRC_IP} -p udp -m multiport --dports ${PORTS_GROUP} \
        -j DNAT --to-destination ${DST_IP} \
        -m comment --comment "${TAG}"

    iptables -t nat -A POSTROUTING \
        -p udp -d ${DST_IP} -m multiport --dports ${PORTS_GROUP} \
        -j MASQUERADE \
        -m comment --comment "${TAG}"
done

# FORWARD — только из whitelist
iptables -I FORWARD 1 \
    -p udp -d ${DST_IP} \
    -m set --match-set warp_whitelist src \
    -j ACCEPT \
    -m comment --comment "WR_WHITELIST_OUT"

iptables -I FORWARD 2 \
    -p udp -s ${DST_IP} \
    -j ACCEPT \
    -m comment --comment "WR_WHITELIST_IN"

iptables -A FORWARD \
    -p udp -d ${DST_IP} \
    -j DROP \
    -m comment --comment "WR_WHITELIST_DROP"

# Сохранение
netfilter-persistent save
ipset save > /etc/ipset.rules 2>/dev/null || true

echo -e "${G}  ${#PORTS[@]} портов настроено${N}"

# ipset автозагрузка
cat > /etc/systemd/system/ipset-restore.service << 'EOF'
[Unit]
Description=Restore ipset rules
Before=netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -f /etc/ipset.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ipset-restore.service

# ═══════════════════════════════════════
# 5. RELAY AGENT
# ═══════════════════════════════════════

echo -e "${Y}[5/6] Устанавливаем relay-agent...${N}"

mkdir -p ${INSTALL_DIR}

# Копируем agent.py если он рядом
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/agent.py" ]; then
    cp "${SCRIPT_DIR}/agent.py" ${INSTALL_DIR}/
    cp "${SCRIPT_DIR}/requirements.txt" ${INSTALL_DIR}/ 2>/dev/null || true
    echo -e "${G}  agent.py скопирован${N}"
else
    echo -e "${R}  agent.py не найден рядом со скриптом!${N}"
    echo -e "  Скопируйте agent.py в ${INSTALL_DIR}/ вручную"
fi

# Python venv
python3 -m venv ${INSTALL_DIR}/venv
${INSTALL_DIR}/venv/bin/pip install -q fastapi uvicorn python-dotenv

# .env
cat > ${INSTALL_DIR}/.env << EOF
AGENT_SECRET=${AGENT_SECRET}
AGENT_PORT=${AGENT_PORT}
IPSET_NAME=warp_whitelist
EOF

echo -e "${G}  venv и .env созданы${N}"

# ═══════════════════════════════════════
# 6. SYSTEMD SERVICE
# ═══════════════════════════════════════

echo -e "${Y}[6/6] Настраиваем systemd...${N}"

cat > /etc/systemd/system/warp-relay-agent.service << EOF
[Unit]
Description=WARP Relay Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/agent.py
Restart=always
RestartSec=5
EnvironmentFile=${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now warp-relay-agent

# Ждём запуска
sleep 2
if systemctl is-active --quiet warp-relay-agent; then
    echo -e "${G}  Agent запущен на порту ${AGENT_PORT}${N}"
else
    echo -e "${R}  Agent не запустился! Проверь: journalctl -u warp-relay-agent${N}"
fi

# ═══════════════════════════════════════
# ИТОГ
# ═══════════════════════════════════════

echo ""
echo -e "${G}═══════════════════════════════════════${N}"
echo -e "${G}  Relay настроен!${N}"
echo -e "${G}═══════════════════════════════════════${N}"
echo ""
echo -e "  ${C}Relay IP:${N}         ${B}${SRC_IP}${N}"
echo -e "  ${C}Agent:${N}            ${B}http://${SRC_IP}:${AGENT_PORT}${N}"
echo -e "  ${C}WARP ports:${N}       ${B}${#PORTS[@]} портов${N}"
echo -e "  ${C}Whitelist ipset:${N}  ${B}warp_whitelist${N}"
echo ""
echo -e "  ${Y}Проверка:${N}"
echo -e "  curl http://localhost:${AGENT_PORT}/health"
echo -e "  ipset list warp_whitelist"
echo -e "  systemctl status warp-relay-agent"
echo ""
echo -e "  ${Y}Добавить в панель:${N}"
echo -e "  POST /api/relays {\"name\": \"$(hostname)\", \"host\": \"${SRC_IP}\", \"agent_port\": ${AGENT_PORT}, \"agent_secret\": \"...\"}"
echo ""
