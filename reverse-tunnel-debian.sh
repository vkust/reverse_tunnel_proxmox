#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Проверка прав root (Proxmox требует root)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root${NC}"
  exit 1
fi

# Функция для цветного вывода
print_msg() {
    local color="$1"
    local msg="$2"
    printf "${color}${msg}${NC}\n"
}

# Функция проверки IP адреса (Исправленная версия)
validate_ip() {
    local ip="$1"
    
    # Убираем возможные лишние пробелы
    ip=$(echo "$ip" | xargs)

    # Проверка формата X.X.X.X через стандартный grep (самый надежный способ)
    if echo "$ip" | grep -E -q '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        # Разбиваем на массив по разделителю точки
        IFS='.' read -r -a octets <<< "$ip"
        
        # Проверяем каждый октет
        for octet in "${octets[@]}"; do
            # Проверка, чтобы числа не превышали 255 и убираем ведущие нули (чтобы не считалось восьмеричным)
            if [[ "$octet" =~ ^0[0-9]+$ ]]; then 
                octet=${octet#0} # Убираем ведущий ноль
            fi
            
            if [ -z "$octet" ] || [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Функция проверки порта
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# Функция установки зависимостей
check_dependencies() {
    print_msg "$BLUE" "Проверка зависимостей..."
    
    if ! command -v ssh >/dev/null 2>&1; then
        print_msg "$YELLOW" "Установка OpenSSH Client..."
        apt-get update && apt-get install -y openssh-client
    else
        print_msg "$GREEN" "OpenSSH Client уже установлен."
    fi
}

# Функция генерации SSH ключей
generate_ssh_keys() {
    mkdir -p /root/.ssh
    if [ ! -f /root/.ssh/id_rsa ]; then
        print_msg "$BLUE" "Генерация ключа SSH..."
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
        print_msg "$GREEN" "Ключи сгенерированы."
    else
        print_msg "$BLUE" "Используется существующий ключ."
    fi
}

# Функция настройки SSH config (для надежности соединения)
setup_ssh_config() {
    mkdir -p /root/.ssh
    local config_file="/root/.ssh/config"
    
    # Добавляем настройки, если их нет
    if ! grep -q "ServerAliveInterval" "$config_file" 2>/dev/null; then
        cat >> "$config_file" << EOF

Host *
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        chmod 600 "$config_file"
        print_msg "$GREEN" "Конфигурация SSH клиента обновлена."
    fi
}

# Функция копирования SSH ключа
copy_ssh_key() {
    print_msg "$BLUE" "\nКопирование публичного ключа на VPS..."
    print_msg "$YELLOW" "Внимание: Сейчас потребуется ввести пароль от VPS."
    
    # Пытаемся использовать ssh-copy-id если есть, иначе ручной метод
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -p "$ssh_port" -i /root/.ssh/id_rsa.pub "${vps_user}@${vps_ip}"
    else
        cat /root/.ssh/id_rsa.pub | ssh -p "$ssh_port" "${vps_user}@${vps_ip}" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    fi

    if [ $? -eq 0 ]; then
        # Проверяем подключение
        if ssh -p "$ssh_port" -o BatchMode=yes -o ConnectTimeout=5 "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null; then
            print_msg "$GREEN" "✓ Ключ успешно скопирован и подключение работает"
        else
            print_msg "$RED" "Ошибка: Ключ скопирован, но автоматический вход не работает."
            exit 1
        fi
    else
        print_msg "$RED" "Ошибка: не удалось скопировать ключ"
        exit 1
    fi
}

# Функция создания Systemd сервиса
create_systemd_service() {
    local service_file="/etc/systemd/system/reverse-tunnel.service"
    
    # Формируем строку аргументов для SSH
    local ssh_args="-N -T -o \"ExitOnForwardFailure=yes\" -i /root/.ssh/id_rsa"
    
    # Добавляем туннели
    for remote_port in $tunnel_ports; do
        # Находим соответствующие локальные параметры (используем массивы bash для удобства, но сохраним логику скрипта)
        # В данном случае просто перебираем списки, так как индексы совпадают
        
        # Получаем индекс текущего порта
        local idx=1
        for rp in $tunnel_ports; do
            if [ "$rp" == "$remote_port" ]; then
                break
            fi
            ((idx++))
        done
        
        local_host=$(echo $local_hosts | awk -v i=$idx '{print $i}')
        local_port=$(echo $local_ports | awk -v i=$idx '{print $i}')
        
        ssh_args="$ssh_args -R ${remote_port}:${local_host}:${local_port}"
    done
    
    # Добавляем хост назначения
    ssh_args="$ssh_args -p ${ssh_port} ${vps_user}@${vps_ip}"

    print_msg "$BLUE" "Создание Systemd сервиса..."

    cat > "$service_file" << EOF
[Unit]
Description=Reverse SSH Tunnel Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
# Автоматический перезапуск при падении
Restart=always
RestartSec=10
# Параметры SSH:
# -N: Не выполнять удаленную команду (только проброс)
# -T: Не выделять псевдотерминал
# ExitOnForwardFailure: Завершить процесс, если не удалось создать туннель (чтобы systemd перезапустил)
ExecStart=/usr/bin/ssh $ssh_args

[Install]
WantedBy=multi-user.target
EOF

    # Перечитываем конфигурацию systemd
    systemctl daemon-reload
}

# UI Функции
show_header() {
    clear
    printf "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║            Настройка обратного SSH-туннеля                 ║${NC}\n"
    printf "${BLUE}║                   для Proxmox (Debian)                     ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n\n"
}

get_input() {
    local prompt="$1"
    local default="$2"
    local hint="$3"
    
    if [ -n "$hint" ]; then
        printf "${YELLOW}ℹ ${hint}${NC}\n"
    fi
    
    if [ -n "$default" ]; then
        read -p "$(echo -e "${prompt} [${GREEN}${default}${NC}]: ")" input
        echo "${input:-$default}"
    else
        read -p "${prompt}: " input
        echo "$input"
    fi
}

main() {
    show_header
    check_dependencies
    
    # Если сервис уже есть, предложим удалить или пересоздать
    if [ -f "/etc/systemd/system/reverse-tunnel.service" ]; then
        print_msg "$YELLOW" "Обнаружен существующий сервис reverse-tunnel."
        read -p "Перенастроить заново? (y/n): " reconfig
        if [[ "$reconfig" != "y" ]]; then
            print_msg "$GREEN" "Отмена."
            exit 0
        fi
        systemctl stop reverse-tunnel
    fi

    generate_ssh_keys
    setup_ssh_config

    # Сбор данных
    printf "\n${YELLOW}═══ Настройка подключения к VPS ═══${NC}\n"
    
    while true; do
        vps_ip=$(get_input "Введите IP-адрес VPS сервера" "" "Пример: 1.2.3.4")
        if validate_ip "$vps_ip"; then break; else print_msg "$RED" "Некорректный IP"; fi
    done

    while true; do
        ssh_port=$(get_input "Введите порт SSH на VPS" "22" "")
        if validate_port "$ssh_port"; then break; else print_msg "$RED" "Некорректный порт"; fi
    done

    vps_user=$(get_input "Введите имя пользователя на VPS" "root" "")

    # Сбор данных о туннелях
    printf "\n${YELLOW}═══ Настройка туннелей ═══${NC}\n"
    tunnel_count=$(get_input "Сколько туннелей настроить?" "1" "")
    
    tunnel_ports=""
    local_ports=""
    local_hosts=""

    for (( i=1; i<=tunnel_count; i++ )); do
        printf "\n${BLUE}╔═══ Туннель %d ═══╗${NC}\n" "$i"
        
        while true; do
            rp=$(get_input "Удаленный порт (на VPS)" "" "Порт, к которому будете подключаться извне")
            if validate_port "$rp"; then break; fi
        done

        while true; do
            lp=$(get_input "Локальный порт (на Proxmox)" "8006" "Стандартный порт Proxmox: 8006")
            if validate_port "$lp"; then break; fi
        done

        lh=$(get_input "Локальный хост" "localhost" "Обычно localhost или IP виртуалки")

        tunnel_ports="$tunnel_ports $rp"
        local_ports="$local_ports $lp"
        local_hosts="$local_hosts $lh"
    done

    # Копирование ключа
    copy_ssh_key

    # Создание сервиса
    create_systemd_service

    # Запуск
    print_msg "$BLUE" "Запуск службы..."
    systemctl enable reverse-tunnel
    systemctl start reverse-tunnel

    sleep 2

    if systemctl is-active --quiet reverse-tunnel; then
        print_msg "$GREEN" "\n✓ Туннель успешно запущен и добавлен в автозагрузку!"
        print_msg "$YELLOW" "\nУправление службой:"
        echo "Статус:     systemctl status reverse-tunnel"
        echo "Логи:       journalctl -u reverse-tunnel -f"
        echo "Рестарт:    systemctl restart reverse-tunnel"
        echo "Остановка:  systemctl stop reverse-tunnel"
    else
        print_msg "$RED" "\n✗ Ошибка запуска службы."
        print_msg "$YELLOW" "Проверьте логи командой: journalctl -u reverse-tunnel -n 20"
    fi
}

main "$@"
