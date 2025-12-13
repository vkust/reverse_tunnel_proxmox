#!/bin/bash

# Цвета
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# Проверка root (это обязательно для systemd)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запустите скрипт от имени root${NC}"
  exit 1
fi

print_msg() {
    printf "${BLUE}%s${NC}\n" "$1"
}

# 1. Тихая установка зависимостей
install_deps() {
    if ! command -v ssh >/dev/null 2>&1; then
        print_msg "Установка OpenSSH Client..."
        apt-get update -qq && apt-get install -y openssh-client -qq
    fi
}

# 2. Генерация ключей
setup_keys() {
    mkdir -p /root/.ssh
    if [ ! -f /root/.ssh/id_rsa ]; then
        print_msg "Генерация ключей..."
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" -q
    fi
    
    # Настройка config для стабильности
    if ! grep -q "ServerAliveInterval" /root/.ssh/config 2>/dev/null; then
        cat >> /root/.ssh/config << EOF
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        chmod 600 /root/.ssh/config
    fi
}

# 3. Копирование ключа
copy_key() {
    print_msg "Копирование ключа на VPS..."
    echo -e "${YELLOW}Введите пароль от VPS пользователя ${vps_user}, если потребуется:${NC}"
    
    # Пробуем ssh-copy-id, если нет - ручной метод
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -p "$ssh_port" -i /root/.ssh/id_rsa.pub "${vps_user}@${vps_ip}"
    else
        cat /root/.ssh/id_rsa.pub | ssh -p "$ssh_port" "${vps_user}@${vps_ip}" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    fi
}

# 4. Создание службы Systemd
create_service() {
    print_msg "Создание службы systemd..."
    cat > /etc/systemd/system/reverse-tunnel.service << EOF
[Unit]
Description=Reverse SSH Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10
ExecStart=/usr/bin/ssh -N -T -o "ExitOnForwardFailure=yes" -i /root/.ssh/id_rsa -p ${ssh_port} ${tunnel_args} ${vps_user}@${vps_ip}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable reverse-tunnel
    systemctl restart reverse-tunnel
}

main() {
    clear
    print_msg "--- Настройка обратного туннеля (Lite) ---"
    
    install_deps
    setup_keys

    # Сбор данных БЕЗ ПРОВЕРОК
    echo
    read -p "Введите IP VPS сервера: " vps_ip
    
    read -p "Порт SSH на VPS [22]: " ssh_port
    ssh_port=${ssh_port:-22}
    
    read -p "Пользователь на VPS [root]: " vps_user
    vps_user=${vps_user:-root}

    # Сбор туннелей
    tunnel_args=""
    echo
    read -p "Сколько туннелей создать? [1]: " count
    count=${count:-1}

    for (( i=1; i<=count; i++ )); do
        echo -e "${YELLOW}Туннель №$i${NC}"
        
        read -p "Удаленный порт (на VPS): " remote
        
        read -p "Локальный порт (Proxmox) [8006]: " local_p
        local_p=${local_p:-8006}
        
        read -p "Локальный хост [localhost]: " local_h
        local_h=${local_h:-localhost}
        
        # Формируем строку аргументов сразу
        tunnel_args="$tunnel_args -R ${remote}:${local_h}:${local_p}"
    done

    # Выполнение
    copy_key
    create_service

    # Финал
    sleep 2
    if systemctl is-active --quiet reverse-tunnel; then
        echo -e "${GREEN}Готово! Служба работает.${NC}"
        echo "Статус: systemctl status reverse-tunnel"
    else
        echo -e "${RED}Служба не запустилась.${NC}"
        echo "Проверьте введенные данные и логи: journalctl -u reverse-tunnel -n 20"
    fi
}

main "$@"
