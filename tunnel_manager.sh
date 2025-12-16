#!/bin/bash

# --- НАСТРОЙКИ ---
CONFIG_FILE="/etc/reverse_tunnel.conf"
SERVICE_FILE="/etc/systemd/system/proxmox-tunnel.service"
WRAPPER_SCRIPT="/usr/local/bin/proxmox_tunnel_wrapper.sh"

# Цвета
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo "Нужен root!"; exit 1; fi

print_msg() { printf "${2}${1}${NC}\n"; }

# 1. Установка зависимостей
install_deps() {
    print_msg "Проверка зависимостей..." "$BLUE"
    if ! command -v autossh >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y autossh openssh-client -qq
    fi
}

# 2. Генерация ключей
setup_keys() {
    mkdir -p /root/.ssh
    if [ ! -f /root/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
        print_msg "Ключи сгенерированы." "$GREEN"
    fi
}

# 3. Копирование ключа (с проверкой)
copy_key() {
    print_msg "\nКопирование ключа на VPS ($vps_ip)..." "$YELLOW"
    ssh-copy-id -p "$ssh_port" -o StrictHostKeyChecking=no "${vps_user}@${vps_ip}"
    if [ $? -eq 0 ]; then
        print_msg "Ключ успешно скопирован." "$GREEN"
    else
        print_msg "Ошибка копирования ключа. Проверьте пароль." "$RED"
        exit 1
    fi
}

# 4. Создание конфига
create_config() {
    cat > "$CONFIG_FILE" << EOF
META_USER=$vps_user
META_HOST=$vps_ip
META_PORT=$ssh_port
# Format: REMOTE_PORT:LOCAL_IP:LOCAL_PORT
EOF
    
    local i=1
    for remote in $tunnel_ports; do
        l_host=$(echo $local_hosts | cut -d' ' -f$i)
        l_port=$(echo $local_ports | cut -d' ' -f$i)
        echo "TUNNEL=$remote:$l_host:$l_port" >> "$CONFIG_FILE"
        i=$((i+1))
    done
}

# 5. Создание Wrapper-скрипта (ИСПРАВЛЕННАЯ ЛОГИКА)
create_wrapper() {
    cat > "$WRAPPER_SCRIPT" << 'EOF'
#!/bin/bash
CONF="/etc/reverse_tunnel.conf"

USER=$(grep "^META_USER=" $CONF | cut -d= -f2)
HOST=$(grep "^META_HOST=" $CONF | cut -d= -f2)
PORT=$(grep "^META_PORT=" $CONF | cut -d= -f2)

TUNNEL_ARGS=""
while read -r line; do
    if [[ "$line" == TUNNEL=* ]]; then
        val=${line#*=}
        REMOTE=$(echo $val | cut -d: -f1)
        L_IP=$(echo $val | cut -d: -f2)
        L_PORT=$(echo $val | cut -d: -f3)
        
        # FIX: Убрали 0.0.0.0, полагаемся на GatewayPorts yes на VPS
        # Это решает проблемы с IPv6 и конфликтами биндинга
        TUNNEL_ARGS="$TUNNEL_ARGS -R $REMOTE:$L_IP:$L_PORT"
    fi
done < "$CONF"

echo "Запуск туннеля к $HOST..."
# FIX: Убрали ExitOnForwardFailure=yes, чтобы сервис не падал циклично,
# если порт временно занят. Он будет пытаться держать соединение.
exec autossh -M 0 -N \
    -o "ServerAliveInterval 10" \
    -o "ServerAliveCountMax 3" \
    -o "StrictHostKeyChecking=no" \
    -p "$PORT" \
    $TUNNEL_ARGS \
    "${USER}@${HOST}"
EOF
    chmod +x "$WRAPPER_SCRIPT"
}

# 6. Создание Systemd сервиса
create_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Proxmox Stable Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=$WRAPPER_SCRIPT
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable proxmox-tunnel.service
    systemctl restart proxmox-tunnel.service
}

# --- ГЛАВНОЕ МЕНЮ ---
main() {
    clear
    print_msg "=== Proxmox Tunnel Installer (Fix Edition) ===" "$BLUE"
    
    # Сбор данных
    read -p "IP VPS сервера: " vps_ip
    read -p "SSH порт VPS [22]: " ssh_port
    ssh_port=${ssh_port:-22}
    read -p "Пользователь VPS [root]: " vps_user
    vps_user=${vps_user:-root}

    # Туннели
    tunnel_ports=""
    local_ports=""
    local_hosts=""
    
    # Автоопределение локального IP
    MY_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')
    
    echo ""
    print_msg "Добавление туннеля (например, для SSH)" "$YELLOW"
    read -p "Удаленный порт на VPS (например 2273): " r_port
    read -p "Локальный IP [$MY_IP]: " l_ip
    l_ip=${l_ip:-$MY_IP}
    read -p "Локальный порт [22]: " l_port
    l_port=${l_port:-22}
    
    tunnel_ports="$r_port"
    local_hosts="$l_ip"
    local_ports="$l_port"
    
    # Установка
    install_deps
    setup_keys
    copy_key
    create_config
    create_wrapper
    create_service
    
    sleep 3
    if systemctl is-active --quiet proxmox-tunnel.service; then
        print_msg "\nГотово! Служба запущена." "$GREEN"
        print_msg "Проверьте логи командой: journalctl -u proxmox-tunnel.service -f" "$YELLOW"
    else
        print_msg "\nСлужба не запустилась." "$RED"
        journalctl -u proxmox-tunnel.service -n 10 --no-pager
    fi
}

main
