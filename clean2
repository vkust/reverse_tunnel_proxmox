#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка root
if [ "$EUID" -ne 0 ]; then
   echo -e "${RED}Запустите скрипт от имени root${NC}"
   exit 1
fi

echo -e "${YELLOW}--- Начало очистки Script 2 (Lite Reverse Tunnel) ---${NC}"

# 1. Остановка и удаление сервиса
SERVICE_NAME="reverse-tunnel.service"
if systemctl list-units --full -all | grep -Fq "$SERVICE_NAME"; then
    echo "Остановка сервиса $SERVICE_NAME..."
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    rm "/etc/systemd/system/$SERVICE_NAME"
    echo -e "${GREEN}Сервис удален.${NC}"
else
    echo "Сервис $SERVICE_NAME не найден, пропускаем."
fi

# 2. Перезагрузка systemd
systemctl daemon-reload

# 3. Очистка SSH Config (Сложный момент)
# Скрипт 2 добавлял настройки в /root/.ssh/config.
# Автоматическое удаление строк через скрипт опасно, так как можно задеть другие конфиги.
CONFIG_FILE="/root/.ssh/config"
if [ -f "$CONFIG_FILE" ]; then
    if grep -q "ServerAliveInterval" "$CONFIG_FILE"; then
        echo -e "${YELLOW}В файле $CONFIG_FILE найдены изменения.${NC}"
        echo "Исходный скрипт добавил блок 'Host *'. Рекомендуется проверить и удалить его вручную."
        echo "Хотите открыть файл в nano сейчас? (y/N)"
        read -r EDIT_CONF
        if [[ "$EDIT_CONF" =~ ^[Yy]$ ]]; then
            nano "$CONFIG_FILE"
        fi
    fi
fi

# 4. Удаление SSH ключей (Опционально)
echo -e "${YELLOW}ВНИМАНИЕ: Удаление SSH ключей удалит доступ ко ВСЕМ серверам.${NC}"
read -p "Удалить SSH ключи root (/root/.ssh/id_rsa*)? (y/N): " REMOVE_KEYS
if [[ "$REMOVE_KEYS" =~ ^[Yy]$ ]]; then
    rm -f /root/.ssh/id_rsa /root/.ssh/id_rsa.pub
    echo -e "${GREEN}SSH ключи удалены.${NC}"
fi

echo -e "${GREEN}--- Очистка завершена! ---${NC}"
echo "Примечание: Пакет 'openssh-client' (ssh) не был удален, так как он нужен системе."
echo "Не забудьте вручную удалить строку из authorized_keys на VPS сервере."
