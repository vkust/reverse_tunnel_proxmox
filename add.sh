#!/usr/bin/env bash

set -euo pipefail

# ================== Настройки ==================
CONF_FILE="/etc/reverse-tunnel.conf"
SERVICE_FILE="/etc/systemd/system/reverse-tunnel.service"
SERVICE_NAME="reverse-tunnel.service"

# ================== Цвета и оформление ==================
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_msg() {
    local color="$1"; shift
    printf "${color}%b${NC}\n" "$*"
}

draw_box() {
    local title="$1"
    local width=${2:-60}
    local pad_left=$(( (width - ${#title} - 2) / 2 ))
    local pad_right=$(( width - ${#title} - 2 - pad_left ))
    printf "${BLUE}╔"; printf '═%.0s' $(seq 1 $width); printf "╗\n"
    printf "║"; printf ' %.0s' $(seq 1 $pad_left); printf "${BOLD}%s${NC}${BLUE}" "$title"
    printf ' %.0s' $(seq 1 $pad_right); printf "║\n"
    printf "╚"; printf '═%.0s' $(seq 1 $width); printf "╝${NC}\n"
}

show_header() {
    clear
    draw_box "Менеджер обратных SSH-туннелей (Debian)" 70
    echo
}

pause() {
    read -rp "Нажмите Enter для продолжения..." _
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

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_msg "$RED" "Этот скрипт нужно запускать от root."
        exit 1
    fi
}

check_dependencies() {
    local deps=(ssh sshpass)
    local missing=()
    for d in "${deps[@]}"; do
        if ! command -v "$d" >/dev/null 2>&1; then
            missing+=("$d")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        print_msg "$YELLOW" "Будут установлены пакеты: ${missing[*]}"
        apt-get update -y
        apt-get install -y "${missing[@]}"
    fi
}

# ================== Конфиг ==================
create_default_conf() {
    if [ -f "$CONF_FILE" ]; then
        return
    fi
    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" << 'EOF'
# ==== Общие параметры VPS ====
VPS_HOST=1.2.3.4
VPS_PORT=22
VPS_USER=root
SSH_KEY=/root/.ssh/id_rsa

# ==== Туннели ====
# Формат строки:
#   TUNNEL_N=remote_port:local_host:local_port
#
# Примеры:
# TUNNEL_1=2222:localhost:22
# TUNNEL_2=8443:192.168.1.10:443
EOF
    chmod 600 "$CONF_FILE"
}

edit_conf() {
    create_default_conf
    ${EDITOR:-nano} "$CONF_FILE"
}

print_tunnels() {
    create_default_conf
    print_msg "$CYAN" "Текущие туннели:"
    if ! grep -qE '^TUNNEL_[0-9]+=' "$CONF_FILE"; then
        print_msg "$YELLOW" "Туннели пока не настроены."
        return
    fi
    grep -E '^TUNNEL_[0-9]+=' "$CONF_FILE" | while IFS='=' read -r name value; do
        value=${value//\"/}
        IFS=':' read -r rport lhost lport <<<"$value"
        printf "  ${GREEN}%s${NC}: VPS:%s → %s:%s\n" "$name" "$rport" "$lhost" "$lport"
    done
}

add_tunnel() {
    create_default_conf
    draw_box "Добавление туннеля" 50
    local rport lport lhost

    while true; do
        read -rp "Удалённый порт на VPS: " rport
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
        print_msg "$YELLOW" "Предупреждение: IP не прошёл строгую проверку, но будет записан как есть."
    fi

    local idx=1
    while grep -q "^TUNNEL_${idx}=" "$CONF_FILE" 2>/dev/null; do
        idx=$((idx+1))
    done

    echo "TUNNEL_${idx}=${rport}:${lhost}:${lport}" >> "$CONF_FILE"
    print_msg "$GREEN" "Добавлен туннель ${BOLD}TUNNEL_${idx}${NC}${GREEN}."
}

delete_tunnel() {
    create_default_conf
    print_tunnels
    echo
    read -rp "Введите имя туннеля для удаления (например, TUNNEL_1): " tname
    if ! grep -q "^${tname}=" "$CONF_FILE" 2>/dev/null; then
        print_msg "$RED" "Туннель ${tname} не найден."
        return
    fi
    sed -i "/^${tname}=/d" "$CONF_FILE"
    print_msg "$GREEN" "Туннель ${tname} удалён."
}

# ================== SSH ключ и VPS ==================
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

    print_msg "$CYAN" "Настройка доступа по ключу к ${VPS_USER}@${VPS_HOST}:${VPS_PORT}"

    read -rp "Копировать ключ на VPS с помощью ssh-copy-id? [Y/n]: " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        ssh-copy-id -i "${SSH_KEY}.pub" -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" || {
            print_msg "$RED" "Не удалось скопировать ключ. Проверьте доступ."
            return 1
        }
    fi

    if ssh -i "$SSH_KEY" -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "echo OK" >/dev/null 2>&1; then
        print_msg "$GREEN" "Подключение по ключу успешно."
    else
        print_msg "$RED" "Не удалось проверить подключение по ключу."
    fi
}

# ================== systemd‑юнит ==================
create_service() {
    create_default_conf
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Persistent reverse SSH tunnels
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=-/etc/reverse-tunnel.conf
ExecStart=/usr/bin/ssh \
    -NTg \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -i ${SSH_KEY} \
$(/usr/local/sbin/reverse-tunnel-installer.sh --print-ports) \
    ${VPS_USER}@${VPS_HOST} -p ${VPS_PORT}

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_msg "$GREEN" "Создан systemd‑юнит: $SERVICE_FILE"
}

restart_service() {
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    print_msg "$GREEN" "Сервис перезапущен и включён в автозагрузку."
}

show_status() {
    systemctl status "$SERVICE_NAME" --no-pager
}

view_logs() {
    journalctl -u "$SERVICE_NAME" -xe --no-pager
}

uninstall_all() {
    draw_box "Удаление" 40
    print_msg "$RED" "Будут удалены:"
    print_msg "$RED" " - $SERVICE_FILE"
    print_msg "$RED" " - $CONF_FILE"
    print_msg "$RED" " - отключён сервис $SERVICE_NAME"
    echo
    read -rp "Точно удалить всё? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { print_msg "$YELLOW" "Отмена."; return; }

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$CONF_FILE"
    systemctl daemon-reload
    print_msg "$GREEN" "Всё, что создал скрипт, удалено."
}

# ===== Режим для systemd: печать параметров -R =====
if [ "${1:-}" = "--print-ports" ]; then
    create_default_conf
    # shellcheck disable=SC1090
    source "$CONF_FILE"

    grep -E '^TUNNEL_[0-9]+=' "$CONF_FILE" 2>/dev/null | while IFS='=' read -r _ value; do
        value=${value//\"/}
        IFS=':' read -r rport lhost lport <<<"$value"
        printf " -R %s:%s:%s" "$rport" "$lhost" "$lport"
    done
    exit 0
fi

# ================== Главное меню ==================
main_menu() {
    require_root
    check_dependencies
    create_default_conf

    while true; do
        show_header
        print_msg "$CYAN" "Конфиг: ${BOLD}$CONF_FILE${NC}"
        print_msg "$CYAN" "Юнит:  ${BOLD}$SERVICE_FILE${NC}"
        echo
        print_msg "$GREEN" "1) Первичная установка / обновление сервиса"
        print_msg "$GREEN" "2) Настроить/отредактировать конфиг"
        print_msg "$GREEN" "3) Посмотреть туннели"
        print_msg "$GREEN" "4) Добавить туннель"
        print_msg "$GREEN" "5) Удалить туннель"
        print_msg "$GREEN" "6) Настроить SSH‑ключ и доступ к VPS"
        print_msg "$GREEN" "7) Статус сервиса"
        print_msg "$GREEN" "8) Перезапустить сервис"
        print_msg "$GREEN" "9) Просмотр логов"
        print_msg "$RED"   "10) Полное удаление (сервис + конфиг)"
        echo
        print_msg "$YELLOW" "0) Выход"
        echo
        read -rp "Выберите пункт: " choice

        case "$choice" in
            1) create_service; restart_service; pause ;;
            2) edit_conf; restart_service; pause ;;
            3) print_tunnels; pause ;;
            4) add_tunnel; restart_service; pause ;;
            5) delete_tunnel; restart_service; pause ;;
            6) copy_key_to_vps; pause ;;
            7) show_status; pause ;;
            8) restart_service; pause ;;
            9) view_logs; pause ;;
            10) uninstall_all; pause ;;
            0) exit 0 ;;
            *) print_msg "$RED" "Неверный выбор."; sleep 1 ;;
        esac
    done
}

main_menu "$@"
