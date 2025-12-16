#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
   echo -e "${RED}Этот скрипт должен быть запущен от имени root${NC}"
   exit 1
fi

echo -e "${YELLOW}--- Начало очистки Script 1 (Proxmox Autossh) ---${NC}"

# 1. Остановка и отключение сервиса
SERVICE_NAME="proxmox-tunnel.service"
if systemctl list-units --full -all | grep -Fq "$SERVICE_NAME"; then
    echo "Остановка сервиса $SERVICE_NAME..."
    systemctl stop "$SERVICE_NAME"
    systemctl disable "$SERVICE_NAME"
    rm "/etc/systemd/system/$SERVICE_NAME"
    echo -e "${GREEN}Сервис удален.${NC}"
else
    echo "Сервис $SERVICE_NAME не найден."
fi

# 2. Удаление файлов скрипта и конфигурации
FILES_TO_REMOVE=(
    "/usr/local/bin/proxmox_tunnel.sh"
    "/etc/proxmox_tunnel.conf"
)

for FILE in "${FILES_TO_REMOVE[@]}"; do
    if [ -f "$FILE" ]; then
        rm "$FILE"
        echo -e "${GREEN}Удален файл: $FILE${NC}"
    fi
done

# 3. Перезагрузка демона systemd
systemctl daemon-reload

# 4. Удаление autossh (Опционально)
read -p "Хотите удалить пакет autossh? (y/N): " REMOVE_AUTOSSH
if [[ "$REMOVE_AUTOSSH" =~ ^[Yy]$ ]]; then
    apt-get remove -y autossh
    echo -e "${GREEN}Autossh удален.${NC}"
fi

# 5. Удаление SSH ключей (Опционально, ОПАСНО)
echo -e "${YELLOW}ВНИМАНИЕ: Удаление SSH ключей разорвет доступ ко всем серверам, использующим этот ключ.${NC}"
read -p "Удалить SSH ключи root (/root/.ssh/id_rsa*)? (y/N): " REMOVE_KEYS
if [[ "$REMOVE_KEYS" =~ ^[Yy]$ ]]; then
    rm -f /root/.ssh/id_rsa /root/.ssh/id_rsa.pub
    echo -e "${GREEN}SSH ключи удалены.${NC}"
fi

echo -e "${GREEN}--- Очистка завершена! ---${NC}"
echo "Не забудьте вручную удалить ключ из authorized_keys на внешнем сервере."
