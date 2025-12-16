#!/bin/bash

# --- НАСТРОЙКИ ---
CONFIG_FILE="/etc/reverse_tunnel.conf"
SERVICE_FILE="/etc/systemd/system/reverse-tunnel.service"
WRAPPER_SCRIPT="/usr/local/bin/reverse_tunnel_runner.sh"

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт от имени root"
    exit 1
fi

# Функция для цветного вывода
print_msg() {
    local color="$1"
    local msg="$2"
    printf "${color}${msg}${NC}\n"
}

# Валидация IP
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Валидация порта
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# Установка зависимостей (вместо setup_ssh)
install_deps() {
    print_msg "$BLUE" "Проверка зависимостей..."
    if ! command -v autossh >/dev/null 2>&1; then
        print_msg "$BLUE" "Установка autossh и openssh-client..."
        apt-get update -qq && apt-get install -y autossh openssh-client -qq
    else
        print_msg "$GREEN" "Autossh и SSH клиент уже установлены."
    fi
}

# Генерация ключей
generate_ssh_keys() {
    mkdir -p /root/.ssh
    if [ ! -f /root/.ssh/id_rsa ]; then
        print_msg "$BLUE" "Генерация ключа OpenSSH..."
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
    else
        print_msg "$BLUE" "Используется существующий ключ."
    fi
}

# Копирование ключа
copy_ssh_key() {
    print_msg "$BLUE" "\nКопирование публичного ключа на VPS..."
    printf "Введите пароль для пользователя %s@%s когда появится запрос\n" "$vps_user" "$vps_ip"
    
    # Используем ssh-copy-id, это надежнее на Debian
    ssh-copy-id -p "$ssh_port" -o StrictHostKeyChecking=no "${vps_user}@${vps_ip}"
    
    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "✓ Ключ успешно скопирован."
        # Проверка подключения
        if ssh -p "$ssh_port" -o BatchMode=yes -o ConnectTimeout=5 "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null; then
             print_msg "$GREEN" "✓ Тестовое подключение прошло успешно."
        else
             print_msg "$RED" "⚠ Ключ скопирован, но автоматический вход не работает. Проверьте настройки VPS."
        fi
    else
        print_msg "$RED" "Ошибка: не удалось скопировать ключ."
        print_msg "$YELLOW" "Попробуйте скопировать вручную или проверьте пароль."
        exit 1
    fi
}

# Создание конфигурационного файла (вместо UCI)
create_config() {
    # Сохраняем настройки в простой текстовый файл
    # Формат: REMOTE_PORT:LOCAL_IP:LOCAL_PORT
    cat > "$CONFIG_FILE" << EOF
# Конфигурация туннелей
# Формат: REMOTE_PORT:LOCAL_IP:LOCAL_PORT
EOF
    
    # Метаданные для подключения
    echo "META_USER=$vps_user" >> "$CONFIG_FILE"
    echo "META_HOST=$vps_ip" >> "$CONFIG_FILE"
    echo "META_PORT=$ssh_port" >> "$CONFIG_FILE"

    # Запись туннелей
    local i=0
    for remote_port in $tunnel_ports; do
        # Извлекаем соответствующие локальные данные из списков (bash arrays были бы лучше, но сохраняем стиль sh)
        local_h=$(echo $local_hosts | cut -d' ' -f$((i+1)))
        local_p=$(echo $local_ports | cut -d' ' -f$((i+1)))
        
        echo "TUNNEL=$remote_port:$local_h:$local_p" >> "$CONFIG_FILE"
        i=$((i+1))
    done
}

# Создание скрипта-обертки (Wrapper)
create_wrapper() {
    cat > "$WRAPPER_SCRIPT" << 'EOF'
#!/bin/bash
CONF="/etc/reverse_tunnel.conf"

# Чтение настроек
USER=$(grep "^META_USER=" $CONF | cut -d= -f2)
HOST=$(grep "^META_HOST=" $CONF | cut -d= -f2)
PORT=$(grep "^META_PORT=" $CONF | cut -d= -f2)

# Сбор аргументов
TUNNEL_ARGS=""
while read -r line; do
    if [[ "$line" == TUNNEL=* ]]; then
        val=${line#*=}
        REMOTE=$(echo $val | cut -d: -f1)
        LOCAL_IP=$(echo $val | cut -d: -f2)
        LOCAL_PORT=$(echo $val | cut -d: -f3)
        # ВАЖНО: Добавляем 0.0.0.0 для внешнего доступа
        TUNNEL_ARGS="$TUNNEL_ARGS -R 0.0.0.0:$REMOTE:$LOCAL_IP:$LOCAL_PORT"
    fi
done < "$CONF"

echo "Запуск туннелей к $HOST..."
exec autossh -M 0 -N \
    -o "ServerAliveInterval 15" \
    -o "ServerAliveCountMax 3" \
    -o "ExitOnForwardFailure=yes" \
    -o "StrictHostKeyChecking=no" \
    -p "$PORT" \
    $TUNNEL_ARGS \
    "${USER}@${HOST}"
EOF
    chmod +x "$WRAPPER_SCRIPT"
}

# Создание systemd сервиса (вместо init.d)
create_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Reverse SSH Tunnel Service
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$WRAPPER_SCRIPT
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable reverse-tunnel.service
    systemctl restart reverse-tunnel.service
}

# UI Функции
show_header() {
    clear
    printf "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║          Настройка обратного SSH-туннеля                   ║${NC}\n"
    printf "${BLUE}║                 (Debian / Proxmox)                         ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n\n"
}

show_progress() {
    local step="$1"
    local total="$2"
    local description="$3"
    printf "${BLUE}[%d/%d]${NC} %s\n" "$step" "$total" "$description"
}

get_input() {
    local prompt="$1"
    local default="$2"
    local hint="$3"
    
    if [ -n "$hint" ]; then printf "${YELLOW}ℹ ${hint}${NC}\n"; fi
    if [ -n "$default" ]; then
        printf "${prompt} [${GREEN}%s${NC}]: " "$default"
    else
        printf "${prompt}: "
    fi
}

# --- ОСНОВНАЯ ЛОГИКА ---
main() {
    show_header

    # Проверка наличия конфига
    if [ -f "$CONFIG_FILE" ]; then
        print_msg "$YELLOW" "Обнаружена существующая конфигурация в $CONFIG_FILE"
        echo "Содержимое:"
        grep "TUNNEL=" "$CONFIG_FILE"
        echo
    fi

    install_deps

    # Сбор данных
    printf "\n${YELLOW}═══ Настройка подключения к VPS ═══${NC}\n"
    
    while true; do
        get_input "Введите IP-адрес VPS сервера" "" "Пример: 109.x.x.x"
        read vps_ip
        if validate_ip "$vps_ip"; then break; else print_msg "$RED" "✗ Некорректный IP"; fi
    done

    get_input "Введите порт SSH на VPS" "22" ""
    read ssh_port
    ssh_port=${ssh_port:-22}

    get_input "Введите пользователя на VPS" "root" ""
    read vps_user
    vps_user=${vps_user:-root}

    # Туннели
    printf "\n${YELLOW}═══ Настройка туннелей ═══${NC}\n"
    get_input "Сколько туннелей вы хотите настроить" "1" ""
    read tunnel_count
    tunnel_count=${tunnel_count:-1}

    # Автоопределение локального IP для решения проблем с localhost
    DEFAULT_LOCAL_IP=$(ip route get 1 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')

    tunnel_ports=""
    local_ports=""
    local_hosts=""

    i=1
    while [ $i -le $tunnel_count ]; do
        printf "\n${BLUE}╔═══ Туннель %d ═══╗${NC}\n" "$i"
        
        while true; do
            get_input "Удаленный порт (на VPS)" "" "Например: 2277"
            read remote_port
            if validate_port "$remote_port"; then break; else print_msg "$RED" "✗ Некорректный порт"; fi
        done

        while true; do
            get_input "Локальный порт (Proxmox)" "8006" "22 (SSH) или 8006 (Web)"
            read local_port
            if validate_port "$local_port"; then break; else print_msg "$RED" "✗ Некорректный порт"; fi
        done

        get_input "Локальный IP устройства" "$DEFAULT_LOCAL_IP" "Рекомендуется реальный IP вместо localhost"
        read local_host
        local_host=${local_host:-$DEFAULT_LOCAL_IP}

        # Накапливаем списки
        tunnel_ports="$tunnel_ports $remote_port"
        local_ports="$local_ports $local_port"
        local_hosts="$local_hosts $local_host"
        i=$((i + 1))
    done

    # Выполнение этапов
    show_progress 1 5 "Генерация ключей"
    generate_ssh_keys

    show_progress 2 5 "Копирование ключа на VPS"
    copy_ssh_key

    show_progress 3 5 "Создание конфигурации"
    create_config

    show_progress 4 5 "Создание скрипта запуска"
    create_wrapper

    show_progress 5 5 "Запуск Systemd сервиса"
    create_service

    # Финал
    print_msg "$GREEN" "\nНастройка завершена!"
    print_msg "$YELLOW" "\nУправление службой:"
    printf "Статус:      \033[32msystemctl status reverse-tunnel\033[0m\n"
    printf "Перезапуск:  \033[32msystemctl restart reverse-tunnel\033[0m\n"
    printf "Логи:        \033[32mjournalctl -u reverse-tunnel -f\033[0m\n"
    
    echo
    if systemctl is-active --quiet reverse-tunnel; then
        print_msg "$GREEN" "✓ Служба активна и работает!"
    else
        print_msg "$RED" "✗ Служба не запустилась. Проверьте логи."
    fi
}

main "$@"
