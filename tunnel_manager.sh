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
    echo -e "${CYAN}    Proxmox Tunnel Manager v2.1 (Fixed)               ${NC}"
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

# --- ВАЛИДАЦИЯ КОНФИГУРАЦИИ ---
validate_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Конфигурация не создана!${NC}"
        return 1
    fi
    
    if ! grep -q "^#META" "$CONFIG_FILE"; then
        echo -e "${RED}Отсутствует META-строка в конфигурации!${NC}"
        return 1
    fi
    
    TUNNEL_COUNT=$(grep -v "^#" "$CONFIG_FILE" | grep -v "^$" | grep -c ":")
    if [ "$TUNNEL_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}Предупреждение: Туннели не настроены${NC}"
    fi
    
    return 0
}

# --- ДОБАВЛЕНИЕ ТУННЕЛЕЙ ---
add_tunnel_entry() {
    header
    echo -e "${YELLOW}--- Добавление туннеля ---${NC}"
    if [ ! -f "$CONFIG_FILE" ]; then 
        echo -e "${RED}Сначала выполните пункт 1 (настройка с нуля)${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    read -p "Удаленный порт (на VPS, например 2277): " R_PORT
    
    # Валидация порта
    if ! [[ "$R_PORT" =~ ^[0-9]+$ ]] || [ "$R_PORT" -lt 1 ] || [ "$R_PORT" -gt 65535 ]; then
        echo -e "${RED}Ошибка: Некорректный порт!${NC}"
        read -p "Нажмите Enter..."
        return
    fi
    
    DEFAULT_IP="127.0.0.1"
    read -p "Локальный IP (куда пересылать) [$DEFAULT_IP]: " L_IP
    L_IP=${L_IP:-$DEFAULT_IP}
    
    read -p "Локальный порт (Proxmox, например 22 или 8006): " L_PORT
    
    # Валидация локального порта
    if ! [[ "$L_PORT" =~ ^[0-9]+$ ]] || [ "$L_PORT" -lt 1 ] || [ "$L_PORT" -gt 65535 ]; then
        echo -e "${RED}Ошибка: Некорректный локальный порт!${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    if [[ -n "$R_PORT" && -n "$L_PORT" ]]; then
        # Проверка дубликатов
        sed -i "/^$R_PORT:/d" "$CONFIG_FILE"
        echo "$R_PORT:$L_IP:$L_PORT" >> "$CONFIG_FILE"
        echo -e "${GREEN}✓ Туннель добавлен: VPS:$R_PORT -> Local:$L_IP:$L_PORT${NC}"
        apply_changes
    else
        echo -e "${RED}Ошибка: Некорректные данные${NC}"
        read -p "Нажмите Enter..."
    fi
}

list_tunnels() {
    [ ! -f "$CONFIG_FILE" ] && return
    echo -e "${BLUE}Настроенные туннели:${NC}"
    echo "VPS Port      ->  Local Address"
    echo "--------------------------------"
    grep -v "^#" "$CONFIG_FILE" | grep -v "^$" | while IFS=':' read -r R L_IP L_P; do
        [ -n "$R" ] && echo "$R         ->  $L_IP:$L_P"








    done
}

# --- ГЕНЕРАЦИЯ WRAPPER-СКРИПТА (ИСПРАВЛЕННАЯ) ---
create_wrapper_script() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Файл конфигурации не найден!${NC}"
        return 1
    fi
    
    META_LINE=$(grep "^#META" "$CONFIG_FILE" | head -n 1)
    
    if [ -z "$META_LINE" ]; then
        echo -e "${RED}Ошибка: META-строка не найдена в конфигурации!${NC}"
        echo -e "${YELLOW}Возможно, нужно выполнить пункт 1 (настройка с нуля)${NC}"
        return 1
    fi
    
    IFS=':' read -r _ USER HOST PORT <<< "$META_LINE"
    
    if [[ -z "$USER" || -z "$HOST" || -z "$PORT" ]]; then
        echo -e "${RED}Ошибка: Некорректная META-строка!${NC}"
        echo "Содержимое: $META_LINE"
        return 1
    fi

    # Создаем wrapper-скрипт с использованием плейсхолдеров
    cat > "$SCRIPT_PATH" << 'EOL'
#!/bin/bash
REMOTE_USER="USER_PLACEHOLDER"
REMOTE_HOST="HOST_PLACEHOLDER"
SSH_PORT="PORT_PLACEHOLDER"
KEY_PATH="KEY_PLACEHOLDER"
CONFIG_FILE="/etc/proxmox_tunnel.conf"

TUNNEL_ARGS=""
while IFS=':' read -r R_PORT L_IP L_PORT; do
    # Пропускаем комментарии и пустые строки
    [[ "$R_PORT" =~ ^#.*$ ]] && continue
    [[ -z "$R_PORT" ]] && continue
    
    # Добавляем туннель с явным указанием интерфейса
    TUNNEL_ARGS="$TUNNEL_ARGS -R 0.0.0.0:$R_PORT:$L_IP:$L_PORT"
done < "$CONFIG_FILE"

if [ -z "$TUNNEL_ARGS" ]; then 
    echo "No tunnels configured" >&2
    exit 1
fi

# Запуск autossh с параметрами для стабильности
















exec autossh -M 0 -N \
    -4 \
    -o "ServerAliveInterval=15" \
    -o "ServerAliveCountMax=3" \
    -o "ExitOnForwardFailure=yes" \
    -o "StrictHostKeyChecking=no" \
    -o "UserKnownHostsFile=/dev/null" \
    -i "$KEY_PATH" \
    -p "$SSH_PORT" \
    $TUNNEL_ARGS \
    "$REMOTE_USER@$REMOTE_HOST"
EOL

    # Замена плейсхолдеров на реальные значения
    sed -i "s|USER_PLACEHOLDER|$USER|g" "$SCRIPT_PATH"
    sed -i "s|HOST_PLACEHOLDER|$HOST|g" "$SCRIPT_PATH"
    sed -i "s|PORT_PLACEHOLDER|$PORT|g" "$SCRIPT_PATH"
    sed -i "s|KEY_PLACEHOLDER|$SSH_KEY_PATH|g" "$SCRIPT_PATH"
    
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✓ Wrapper-скрипт создан${NC}"
    return 0
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
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    echo -e "${GREEN}✓ Systemd-сервис создан${NC}"
}

apply_changes() {
    echo ""
    echo -e "${BLUE}Применение изменений...${NC}"
    
    if ! validate_config; then
        echo -e "${RED}Ошибка валидации конфигурации!${NC}"
        read -p "Нажмите Enter..."
        return 1
    fi
    
    if ! create_wrapper_script; then
        echo -e "${RED}Ошибка создания wrapper-скрипта!${NC}"
        read -p "Нажмите Enter..."
        return 1
    fi
    
    create_systemd_service
    
    echo -e "${BLUE}Перезапуск сервиса...${NC}"
    systemctl restart "$SERVICE_NAME"
    
    sleep 3

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}✓ Статус: ACTIVE${NC}"
        echo ""
        echo -e "${CYAN}Туннели должны быть доступны на VPS!${NC}"
        echo -e "${YELLOW}Для проверки выполните на VPS:${NC}"
        echo "  ss -tlnp | grep <порт>"
        echo "  или"
        echo "  netstat -tlnp | grep <порт>"
    else
        echo -e "${RED}✗ Статус: FAILED${NC}"
        echo ""
        echo -e "${YELLOW}Последние строки лога:${NC}"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
        echo ""
        echo -e "${YELLOW}Для детальной диагностики:${NC}"
        echo "  1. journalctl -u $SERVICE_NAME -f"
        echo "  2. bash -x $SCRIPT_PATH"
    fi
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ---
delete_tunnel() {
    header
    list_tunnels
    echo ""
    read -p "Введите VPS порт для удаления: " DEL_PORT
    if [ -n "$DEL_PORT" ]; then
        sed -i "/^$DEL_PORT:/d" "$CONFIG_FILE"
        echo -e "${GREEN}Туннель удален${NC}"
        apply_changes
    fi
}

full_uninstall() {
    echo -e "${YELLOW}Удаление всех компонентов...${NC}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH" "$CONFIG_FILE" "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
    systemctl daemon-reload
    echo -e "${GREEN}Удалено.${NC}"
    read -p "Нажмите Enter..."
}

# --- ДИАГНОСТИКА ---
show_diagnostics() {
    header
    echo -e "${CYAN}=== ДИАГНОСТИКА ===${NC}"
    echo ""



    echo -e "${BLUE}1. Конфигурация ($CONFIG_FILE):${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo -e "${RED}  Файл не существует!${NC}"
    fi
    echo ""



















    echo -e "${BLUE}2. Wrapper-скрипт ($SCRIPT_PATH):${NC}"
    if [ -f "$SCRIPT_PATH" ]; then
        head -n 15 "$SCRIPT_PATH"
        echo "  ..."
    else
        echo -e "${RED}  Файл не существует!${NC}"

    fi
    echo ""
    
    echo -e "${BLUE}3. Статус службы:${NC}"
    systemctl status "$SERVICE_NAME" --no-pager -l
    echo ""
    
    echo -e "${BLUE}4. Последние логи:${NC}"
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager
    echo ""
    
    read -p "Нажмите Enter..."
}

# --- МЕНЮ ---
main_menu() {
    while true; do
        header
        list_tunnels
        echo ""
        echo "1) Настройка с нуля (ключи + VPS)"
        echo "2) Добавить туннель"
        echo "3) Удалить туннель"
        echo "4) Применить изменения (рестарт)"
        echo "5) Диагностика (логи + конфиг)"
        echo "6) Удалить все"
        echo "0) Выход"
        echo ""
        read -p "Выберите действие > " C
        case $C in
            1) install_dependencies; setup_ssh_connection && add_tunnel_entry ;;
            2) add_tunnel_entry ;;
            3) delete_tunnel ;;
            4) apply_changes ;;
            5) show_diagnostics ;;
            6) full_uninstall; exit ;;
            0) exit ;;
            *) echo "Неверный выбор" ;;
        esac
    done
}

check_root
main_menu
