#!/usr/bin/env bash

# ================== Цвета ==================
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONF_FILE="/etc/reverse-tunnel.conf"
SERVICE_NAME="reverse-tunnel.service"

print_msg() {
    local color="$1"; shift
    printf "${color}%b${NC}\n" "$*"
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

show_header() {
    clear
    printf "${BLUE}╔══════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║      Менеджер обратных SSH-туннелей (Debian)        ║${NC}\n"
    printf "${BLUE}╚══════════════════════════════════════════════════════╝${NC}\n\n"
}

pause() {
    read -rp "Нажмите Enter для продолжения..." _
}

create_default_conf() {
    if [ -f "$CONF_FILE" ]; then
        return
    fi

    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" << 'EOF'
# Общие параметры
VPS_HOST=1.2.3.4
VPS_PORT=22
VPS_USER=root
SSH_KEY=/root/.ssh/id_rsa

# Примеры туннелей
# Формат: remote_port:local_host:local_port
# TUNNEL_1=2222:localhost:22
EOF
    chmod 600 "$CONF_FILE"
}

edit_conf() {
    create_default_conf
    ${EDITOR:-nano} "$CONF_FILE"
}

generate_ssh_key() {
    local key="${1:-/root/.ssh/id_rsa}"
    mkdir -p /root/.ssh
    if [ ! -f "$key" ]; then
        print_msg "$BLUE" "Генерация SSH ключа: $key"
        ssh-keygen -t rsa -b 4096 -f "$key" -N ""
    else
        print_msg "$YELLOW" "Ключ уже существует: $key"
    fi
}

copy_key_to_vps() {
    create_default_conf
    # shellcheck disable=SC1090
    source "$CONF_FILE"

    generate_ssh_key "$SSH_KEY"

    print_msg "$BLUE" "Копирование ключа на ${VPS_USER}@${VPS_HOST}:${VPS_PORT}"
    ssh-copy-id -i "${SSH_KEY}.pub" -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" || {
        print_msg "$RED" "Не удалось скопировать ключ."
        return 1
    }

    ssh -i "$SSH_KEY" -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "echo OK" >/dev/null 2>&1 && \
        print_msg "$GREEN" "Подключение по ключу работает."
}

print_tunnels() {
    create_default_conf
    # shellcheck disable=SC1090
    source "$CONF_FILE"

    print_msg "$YELLOW" "Текущая конфигурация туннелей:"
    grep -E '^TUNNEL_[0-9]+=' "$CONF_FILE" | while IFS='=' read -r name value; do
        value=${value//\"/}
        IFS=':' read -r rport lhost lport <<<"$value"
        printf "  %s: VPS:%s -> %s:%s\n" "$name" "$rport" "$lhost" "$lport"
    done
}

add_tunnel() {
    create_default_conf
    local rport lport lhost

    while true; do
        read -rp "Удалённый порт (на VPS): " rport
        validate_port "$rport" && break
        print_msg "$RED" "Некорректный порт."
    done

    while true; do
        read -rp "Локальный порт: " lport
        validate_port "$lport" && break
        print_msg "$RED" "Некорректный порт."
    done

    read -rp "Локальный хост [localhost]: " lhost
    lhost=${lhost:-localhost}
    if [ "$lhost" != "localhost" ] && ! validate_ip "$lhost"; then
        print_msg "$YELLOW" "Предупреждение: IP не прошёл валидацию, но будет записан как есть."
    fi

    # найти свободный номер
    local idx=1
    while grep -q "^TUNNEL_${idx}=" "$CONF_FILE" 2>/dev/null; do
        idx=$((idx+1))
    done

    echo "TUNNEL_${idx}=${rport}:${lhost}:${lport}" >> "$CONF_FILE"
    print_msg "$GREEN" "Добавлен туннель TUNNEL_${idx}."
}

delete_tunnel() {
    create_default_conf
    print_tunnels
    echo
    read -rp "Введите имя туннеля для удаления (например, TUNNEL_1): " tname
    if ! grep -q "^${tname}=" "$CONF_FILE"; then
        print_msg "$RED" "Туннель ${tname} не найден."
        return
    fi
    sed -i "/^${tname}=/d" "$CONF_FILE"
    print_msg "$GREEN" "Туннель ${tname} удалён."
}

show_status() {
    systemctl status "$SERVICE_NAME" --no-pager
}

restart_service() {
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    print_msg "$GREEN" "Сервис перезапущен и включён в автозагрузку."
}

view_logs() {
    journalctl -u "$SERVICE_NAME" -xe --no-pager
}

uninstall_all() {
    read -rp "Удалить сервис, конфиг и остановить туннели? [y/N]: " ans
    case "$ans" in
        y|Y)
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${SERVICE_NAME}"
            rm -f "$CONF_FILE"
            systemctl daemon-reload
            print_msg "$GREEN" "Сервис и конфигурация удалены."
            ;;
        *)
            print_msg "$YELLOW" "Отмена удаления."
            ;;
    esac
}

# ----- Вспомогательный режим: печать параметров -R для systemd -----
if [ "$1" == "--print-ports" ]; then
    create_default_conf
    # shellcheck disable=SC1090
    source "$CONF_FILE"

    grep -E '^TUNNEL_[0-9]+=' "$CONF_FILE" | while IFS='=' read -r _ value; do
        value=${value//\"/}
        IFS=':' read -r rport lhost lport <<<"$value"
        printf " -R %s:%s:%s" "$rport" "$lhost" "$lport"
    done
    exit 0
fi

# ================== Главное меню ==================
while true; do
    show_header
    print_msg "$GREEN" "1) Настроить/отредактировать конфиг"
    print_msg "$GREEN" "2) Добавить туннель"
    print_msg "$GREEN" "3) Удалить туннель"
    print_msg "$GREEN" "4) Скопировать SSH-ключ на VPS"
    print_msg "$GREEN" "5) Статус сервиса"
    print_msg "$GREEN" "6) Перезапустить сервис"
    print_msg "$GREEN" "7) Просмотр логов"
    print_msg "$RED"   "8) Полное удаление (сервис + конфиг)"
    echo
    print_msg "$YELLOW" "0) Выход"
    echo
    read -rp "Выберите пункт: " choice

    case "$choice" in
        1) edit_conf; restart_service; pause ;;
        2) add_tunnel; restart_service; pause ;;
        3) delete_tunnel; restart_service; pause ;;
        4) copy_key_to_vps; pause ;;
        5) show_status; pause ;;
        6) restart_service; pause ;;
        7) view_logs; pause ;;
        8) uninstall_all; pause ;;
        0) exit 0 ;;
        *) print_msg "$RED" "Неверный выбор."; sleep 1 ;;
    esac
done
