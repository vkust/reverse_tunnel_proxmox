#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
CONFIG_FILE="/etc/proxmox_tunnel.conf"
SCRIPT_PATH="/usr/local/bin/proxmox_tunnel_wrapper.sh"
SERVICE_NAME="proxmox-tunnel.service"
SSH_KEY_PATH="/root/.ssh/id_rsa_tunnel"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

header() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}    Proxmox Tunnel Manager v2.0 (Stable Fix)          ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: Запуск только от root!${NC}"
        exit 1
    fi
}

install_dependencies() {
    if ! command -v autossh >/dev/null 2>&1; then
        echo -e "${YELLOW}Установка autossh...${NC}"
        apt-get update -qq && apt-get install -y autossh -qq
    fi
}

# --- ПОДКЛЮЧЕНИЕ ---
setup_ssh_connection() {
    header
    echo -e "${YELLOW}--- Настройка подключения (VPS) ---${NC}"
    read -p "IP внешнего сервера (VPS): " REMOTE_HOST
    read -p "Порт SSH на VPS [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "Пользователь VPS [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo -e "${BLUE}Генерация ключа...${NC}"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    fi

    echo -e "${BLUE}Копирование ключа... Введите пароль VPS:${NC}"
    ssh-copy-id -i "${SSH_KEY_PATH}.pub" -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}"

    if [ $? -eq 0 ]; then
        echo "#META:$REMOTE_USER:$REMOTE_HOST:$REMOTE_PORT" > "$CONFIG_FILE"
        echo -e "${GREEN}Ключ скопирован.${NC}"
    else
        echo -e "${RED}Ошибка копирования ключа.${NC}"
        return 1
    fi
}

# --- ДОБАВЛЕНИЕ ТУННЕЛЕЙ ---
add_tunnel_entry() {
    header
    echo -e "${YELLOW}--- Добавление туннеля ---${NC}"
    if [ ! -f "$CONFIG_FILE" ]; then echo "Сначала выполните пункт 1."; read -p "..."; return; fi

    read -p "Удаленный порт (на VPS, например 2277): " R_PORT
    
    # Автоматическое определение локального IP
    DEFAULT_IP="127.0.0.1"
    read -p "Локальный IP (куда пересылать) [$DEFAULT_IP]: " L_IP
    L_IP=${L_IP:-$DEFAULT_IP}
    
    read -p "Локальный порт (Proxmox, например 22 или 8006): " L_PORT

    if [[ -n "$R_PORT" && -n "$L_PORT" ]]; then
        # Проверка дубликатов
        sed -i "/^$R_PORT:/d" "$CONFIG_FILE"
        echo "$R_PORT:$L_IP:$L_PORT" >> "$CONFIG_FILE"
        echo -e "${GREEN}Туннель добавлен.${NC}"
        apply_changes
    else
        echo "Ошибка данных."
    fi
}

list_tunnels() {
    [ ! -f "$CONFIG_FILE" ] && return
    echo -e "${BLUE}Активные туннели:${NC}"
    echo "VPS Port      ->  Local Address"
    echo "--------------------------------"
    grep -v "^#" "$CONFIG_FILE" | while IFS=':' read -r R L_IP L_P; do
        [ -n "$R" ] && echo "$R         ->  $L_IP:$L_P"
    done
}

# --- ГЕНЕРАЦИЯ (ИСПРАВЛЕННАЯ ЛОГИКА) ---
create_wrapper_script() {
    META_LINE=$(grep "^#META" "$CONFIG_FILE" | head -n 1)
    IFS=':' read -r _ USER HOST PORT <<< "$META_LINE"

    cat > "$SCRIPT_PATH" << EOL
#!/bin/bash
REMOTE_USER="$USER"
REMOTE_HOST="$HOST"
SSH_PORT="$PORT"
KEY_PATH="$SSH_KEY_PATH"

TUNNEL_ARGS=""
while IFS=':' read -r R_PORT L_IP L_PORT; do
    [[ "\$R_PORT" =~ ^#.*$ ]] && continue
    [[ -z "\$R_PORT" ]] && continue
    
    # ВАЖНОЕ ИЗМЕНЕНИЕ: Добавлено 0.0.0.0: перед портом
    # Это заставляет VPS слушать на всех интерфейсах, а не только localhost
    TUNNEL_ARGS="\$TUNNEL_ARGS -R 0.0.0.0:\$R_PORT:\$L_IP:\$L_PORT"
done < "$CONFIG_FILE"

if [ -z "\$TUNNEL_ARGS" ]; then exit 0; fi

# -4: Использовать только IPv4 (для стабильности)
exec autossh -M 0 -N \\
    -4 \\
    -o "ServerAliveInterval 15" \\
    -o "ServerAliveCountMax 3" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "StrictHostKeyChecking=no" \\
    -o "UserKnownHostsFile=/dev/null" \\
    -i "\$KEY_PATH" \\
    -p "\$SSH_PORT" \\
    \$TUNNEL_ARGS \\
    "\$REMOTE_USER@\$REMOTE_HOST"
EOL
    chmod +x "$SCRIPT_PATH"
}

create_systemd_service() {
    cat > "/etc/systemd/system/$SERVICE_NAME" << EOL
[Unit]
Description=Proxmox Stable Tunnel
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

apply_changes() {
    create_wrapper_script
    create_systemd_service
    systemctl restart "$SERVICE_NAME"
    echo -e "${GREEN}Сервис перезапущен.${NC}"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Статус: ACTIVE${NC}"
    else
        echo -e "${RED}Статус: FAILED. Смотрите логи.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ---
full_uninstall() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH" "$CONFIG_FILE" "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
    systemctl daemon-reload
    echo "Удалено."
}

# --- МЕНЮ ---
main_menu() {
    while true; do
        header
        list_tunnels
        echo ""
        echo "1) Настройка с нуля (ключи + установка)"
        echo "2) Добавить туннель / Применить исправления"
        echo "3) Показать логи"
        echo "4) Удалить все"
        echo "0) Выход"
        read -p "> " C
        case $C in
            1) install_dependencies; setup_ssh_connection && add_tunnel_entry ;;
            2) add_tunnel_entry ;;
            3) journalctl -u "$SERVICE_NAME" -n 20 --no-pager; read -p "..." ;;
            4) full_uninstall; exit ;;
            0) exit ;;
        esac
    done
}

check_root
main_menu
