#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
CONFIG_FILE="/etc/proxmox_tunnel.conf"
SCRIPT_PATH="/usr/local/bin/proxmox_tunnel_wrapper.sh"
SERVICE_NAME="proxmox-tunnel.service"
SSH_KEY_PATH="/root/.ssh/id_rsa_tunnel" # Отдельный ключ, чтобы не трогать системный

# --- ЦВЕТА И ОФОРМЛЕНИЕ ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

header() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}       Proxmox Secure Tunnel Manager (Autossh)        ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: Скрипт должен быть запущен от имени root!${NC}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${BLUE}[INFO] Проверка зависимостей...${NC}"
    if ! command -v autossh >/dev/null 2>&1; then
        echo -e "${YELLOW}Autossh не найден. Установка...${NC}"
        apt-get update -qq && apt-get install -y autossh -qq
    else
        echo -e "${GREEN}Autossh уже установлен.${NC}"
    fi
}

# --- ЛОГИКА SSH КЛЮЧЕЙ ---

setup_ssh_connection() {
    header
    echo -e "${YELLOW}--- Настройка подключения к внешнему серверу (VPS) ---${NC}"
    
    # Запрос данных
    read -p "Введите IP внешнего сервера (VPS): " REMOTE_HOST
    read -p "Введите порт SSH внешнего сервера [22]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-22}
    read -p "Введите пользователя на VPS [root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    # Генерация отдельного ключа для туннеля (безопаснее)
    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo -e "${BLUE}[INFO] Генерация выделенного SSH-ключа ($SSH_KEY_PATH)...${NC}"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    else
        echo -e "${GREEN}[OK] Ключ уже существует.${NC}"
    fi

    # Копирование ключа
    echo -e "${BLUE}[INFO] Копирование ключа на VPS...${NC}"
    echo -e "${YELLOW}Сейчас потребуется ввести пароль от VPS пользователя $REMOTE_USER${NC}"
    
    ssh-copy-id -i "${SSH_KEY_PATH}.pub" -p "$REMOTE_PORT" -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK] Ключ успешно скопирован!${NC}"
        # Сохраняем параметры подключения в конфиг (первая строка - комментарий с метаданными)
        # Формат метаданных: #META:USER:HOST:PORT
        echo "#META:$REMOTE_USER:$REMOTE_HOST:$REMOTE_PORT" > "$CONFIG_FILE"
    else
        echo -e "${RED}[ERROR] Не удалось скопировать ключ. Проверьте данные и попробуйте снова.${NC}"
        read -p "Нажмите Enter для возврата в меню..."
        return 1
    fi
}

# --- УПРАВЛЕНИЕ ТУННЕЛЯМИ ---

add_tunnel_entry() {
    header
    echo -e "${YELLOW}--- Добавление нового туннеля ---${NC}"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Сначала выполните первоначальную настройку (Пункт 1).${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo "Формат: Удаленный порт -> Локальный IP:Локальный Порт"
    echo "Пример для Proxmox Web: Удаленный 8006 -> 127.0.0.1:8006"
    echo ""
    
    read -p "Удаленный порт (на VPS): " R_PORT
    read -p "Локальный IP (обычно 127.0.0.1): " L_IP
    L_IP=${L_IP:-127.0.0.1}
    read -p "Локальный порт (Proxmox): " L_PORT

    if [[ -z "$R_PORT" || -z "$L_PORT" ]]; then
        echo -e "${RED}Ошибка: Порты не могут быть пустыми.${NC}"
    else
        echo "$R_PORT:$L_IP:$L_PORT" >> "$CONFIG_FILE"
        echo -e "${GREEN}Туннель добавлен в конфигурацию.${NC}"
        apply_changes
    fi
}

list_tunnels() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Нет активных конфигураций."
        return
    fi
    echo -e "${BLUE}Текущие туннели:${NC}"
    printf "%-15s %-15s %-15s\n" "Remote Port" "Local IP" "Local Port"
    echo "-----------------------------------------------"
    grep -v "^#" "$CONFIG_FILE" | while IFS=':' read -r R L_IP L_P; do
        if [ -n "$R" ]; then
            printf "%-15s %-15s %-15s\n" "$R" "$L_IP" "$L_P"
        fi
    done
}

# --- ГЕНЕРАЦИЯ СЕРВИСА ---

create_wrapper_script() {
    # Получаем метаданные из конфига
    META_LINE=$(grep "^#META" "$CONFIG_FILE" | head -n 1)
    IFS=':' read -r _ USER HOST PORT <<< "$META_LINE"

    cat > "$SCRIPT_PATH" << EOL
#!/bin/bash
# Автоматически сгенерированный скрипт для Proxmox Tunnel

REMOTE_USER="$USER"
REMOTE_HOST="$HOST"
SSH_PORT="$PORT"
KEY_PATH="$SSH_KEY_PATH"
CONFIG="$CONFIG_FILE"

# Сбор аргументов для форвардинга
TUNNEL_ARGS=""
while IFS=':' read -r R_PORT L_IP L_PORT; do
    # Пропуск комментариев и пустых строк
    [[ "\$R_PORT" =~ ^#.*$ ]] && continue
    [[ -z "\$R_PORT" ]] && continue
    
    TUNNEL_ARGS="\$TUNNEL_ARGS -R \$R_PORT:\$L_IP:\$L_PORT"
done < "\$CONFIG"

if [ -z "\$TUNNEL_ARGS" ]; then
    echo "Нет туннелей для запуска"
    exit 0
fi

echo "Запуск autossh с аргументами: \$TUNNEL_ARGS"

# Запуск Autossh
# -M 0 : отключить собственный мониторинг autossh (используем SSH keepalive)
# -o "ServerAliveInterval 30" : слать пинг каждые 30 сек
# -o "ServerAliveCountMax 3" : разрыв после 3 неудач (90 сек таймаут)
# -N : не выполнять команду удаленно (только форвардинг)
exec autossh -M 0 -N \\
    -o "ServerAliveInterval 30" \\
    -o "ServerAliveCountMax 3" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "StrictHostKeyChecking=no" \\
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
Description=Proxmox Persistent Autossh Tunnel
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=10s
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOL
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

apply_changes() {
    echo -e "${BLUE}[INFO] Применение изменений...${NC}"
    create_wrapper_script
    create_systemd_service
    systemctl restart "$SERVICE_NAME"
    
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}Сервис успешно перезапущен и активен!${NC}"
    else
        echo -e "${RED}Ошибка запуска сервиса. Проверьте: systemctl status $SERVICE_NAME${NC}"
    fi
    read -p "Нажмите Enter для продолжения..."
}

# --- УДАЛЕНИЕ ---

full_uninstall() {
    header
    echo -e "${RED}ВНИМАНИЕ: Это удалит сервис туннелирования и конфиги.${NC}"
    read -p "Вы уверены? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/$SERVICE_NAME"
        rm -f "$SCRIPT_PATH"
        rm -f "$CONFIG_FILE"
        systemctl daemon-reload
        
        read -p "Удалить созданный SSH-ключ ($SSH_KEY_PATH)? (y/N): " RM_KEY
        if [[ "$RM_KEY" =~ ^[Yy]$ ]]; then
            rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
            echo "Ключи удалены."
        fi
        
        echo -e "${GREEN}Удаление завершено.${NC}"
    else
        echo "Отмена."
    fi
    read -p "Нажмите Enter..."
}

# --- ГЛАВНОЕ МЕНЮ ---

main_menu() {
    while true; do
        header
        echo "Статус сервиса: $(systemctl is-active $SERVICE_NAME 2>/dev/null || echo 'inactive')"
        echo ""
        list_tunnels
        echo ""
        echo "1) Настройка подключения и установка (Первый запуск)"
        echo "2) Добавить новый туннель"
        echo "3) Очистить список туннелей (удалить все)"
        echo "4) Показать логи сервиса"
        echo "5) Полное удаление скрипта и сервиса"
        echo "0) Выход"
        echo ""
        read -p "Выберите действие: " CHOICE
        
        case $CHOICE in
            1)
                install_dependencies
                setup_ssh_connection && add_tunnel_entry
                ;;
            2)
                add_tunnel_entry
                ;;
            3)
                # Оставляем только метаданные
                sed -i '/^[^#]/d' "$CONFIG_FILE"
                apply_changes
                ;;
            4)
                journalctl -u "$SERVICE_NAME" -n 20 --no-pager
                read -p "Нажмите Enter..."
                ;;
            5)
                full_uninstall
                ;;
            0)
                exit 0
                ;;
            *)
                echo "Неверный выбор."
                sleep 1
                ;;
        esac
    done
}

# Запуск
check_root
main_menu
