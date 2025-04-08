#!/bin/bash

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени root"
   exit 1
fi

# Установка autossh, если не установлен
if ! command -v autossh &> /dev/null; then
    echo "Установка autossh..."
    apt-get update && apt-get install -y autossh
fi

# Запрос данных у пользователя
echo "Настройка SSH-туннеля для Proxmox"
read -p "Введите IP внешнего сервера: " EXTERNAL_IP
read -p "Введите порт SSH внешнего сервера (по умолчанию 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}  # Установка 22 по умолчанию

# Генерация SSH-ключа, если его нет
SSH_KEY="/root/.ssh/id_rsa"
if [ ! -f "$SSH_KEY" ]; then
    echo "Генерация SSH-ключа..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N ""
fi

# Отправка ключа на внешний сервер
echo "Отправка SSH-ключа на внешний сервер ($EXTERNAL_IP)..."
ssh-copy-id -i "$SSH_KEY.pub" -p "$SSH_PORT" "root@$EXTERNAL_IP"
if [ $? -eq 0 ]; then
    echo "Ключ успешно отправлен."
else
    echo "Ошибка при отправке ключа. Проверьте доступность сервера и повторите попытку."
    exit 1
fi

# Проверка подключения
echo "Проверка SSH-подключения..."
ssh -p "$SSH_PORT" "root@$EXTERNAL_IP" -o BatchMode=yes -o ConnectTimeout=5 "echo 'Подключение успешно'"
if [ $? -ne 0 ]; then
    echo "Не удалось подключиться к серверу. Проверьте настройки и повторите."
    exit 1
fi

# Запрос портов для перенаправления
echo "Укажите перенаправления портов."
echo "Формат: <удаленный_порт>:<локальный_IP>:<локальный_порт> (например, 2222:192.168.1.10:22)"
echo "Для локальной машины используйте 'localhost' как IP."
declare -A PORTS
while true; do
    read -p "Введите перенаправление (или оставьте пустым для завершения): " INPUT
    if [[ -z "$INPUT" ]]; then
        break
    fi
    # Разбор строки формата <удаленный_порт>:<локальный_IP>:<локальный_порт>
    REMOTE_PORT=$(echo "$INPUT" | cut -d':' -f1)
    LOCAL_IP=$(echo "$INPUT" | cut -d':' -f2)
    LOCAL_PORT=$(echo "$INPUT" | cut -d':' -f3)
    if [[ -z "$REMOTE_PORT" || -z "$LOCAL_IP" || -z "$LOCAL_PORT" ]]; then
        echo "Неверный формат. Используйте <удаленный_порт>:<локальный_IP>:<локальный_порт>"
        continue
    fi
    PORTS["$LOCAL_IP:$LOCAL_PORT"]=$REMOTE_PORT
done

# Создание файла туннеля
TUNNEL_SCRIPT="/usr/local/bin/proxmox_tunnel.sh"
cat > $TUNNEL_SCRIPT << EOL
#!/bin/bash

# Параметры подключения
EXTERNAL_SERVER="root@$EXTERNAL_IP"
SSH_PORT=$SSH_PORT
CONFIG_FILE="/etc/proxmox_tunnel.conf"

# Чтение портов из конфигурационного файла
if [ -f "\$CONFIG_FILE" ]; then
    while IFS=':' read -r REMOTE_PORT LOCAL_IP LOCAL_PORT; do
        # Пропускаем пустые строки и комментарии
        if [[ -z "\$REMOTE_PORT" || "\$REMOTE_PORT" =~ ^# ]]; then
            continue
        fi
        if [[ -n "\$REMOTE_PORT" && -n "\$LOCAL_IP" && -n "\$LOCAL_PORT" ]]; then
            PORT_ARGS="\$PORT_ARGS -R \$REMOTE_PORT:\$LOCAL_IP:\$LOCAL_PORT"
        fi
    done < "\$CONFIG_FILE"
fi

# Запуск autossh с параметрами для надежности
eval "autossh -M 0 -f -N \\
  -o \"ServerAliveInterval=60\" \\
  -o \"ServerAliveCountMax=3\" \\
  -o \"ExitOnForwardFailure=yes\" \\
  \$PORT_ARGS \\
  -p \$SSH_PORT \$EXTERNAL_SERVER"
EOL

# Делаем скрипт исполняемым
chmod +x $TUNNEL_SCRIPT

# Создание конфигурационного файла
CONFIG_FILE="/etc/proxmox_tunnel.conf"
cat > $CONFIG_FILE << EOL
# Формат: <удаленный_порт>:<локальный_IP>:<локальный_порт>
# Пример: 2222:192.168.1.10:22
# Для локальной машины используйте localhost
EOL
for KEY in "${!PORTS[@]}"; do
    REMOTE=${PORTS[$KEY]}
    LOCAL_IP=$(echo "$KEY" | cut -d':' -f1)
    LOCAL_PORT=$(echo "$KEY" | cut -d':' -f2)
    echo "$REMOTE:$LOCAL_IP:$LOCAL_PORT" >> $CONFIG_FILE
done

# Создание systemd сервиса
SERVICE_FILE="/etc/systemd/system/proxmox-tunnel.service"
cat > $SERVICE_FILE << EOL
[Unit]
Description=Proxmox SSH Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/proxmox_tunnel.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOL

# Активация сервиса
systemctl daemon-reload
systemctl enable proxmox-tunnel.service
systemctl start proxmox-tunnel.service

# Проверка статуса
sleep 2
if systemctl is-active proxmox-tunnel.service > /dev/null; then
    echo "Настройка завершена! Туннель запущен."
    echo "Проверьте подключение:"
    for KEY in "${!PORTS[@]}"; do
        REMOTE=${PORTS[$KEY]}
        LOCAL_IP=$(echo "$KEY" | cut -d':' -f1)
        LOCAL_PORT=$(echo "$KEY" | cut -d':' -f2)
        if [ "$LOCAL_PORT" = "22" ]; then
            echo " - SSH ($LOCAL_IP): ssh -p $REMOTE root@$EXTERNAL_IP"
        elif [ "$LOCAL_PORT" = "8006" ]; then
            echo " - Веб-интерфейс ($LOCAL_IP): http://$EXTERNAL_IP:$REMOTE"
        else
            echo " - Порт $LOCAL_PORT ($LOCAL_IP): подключитесь через $EXTERNAL_IP:$REMOTE"
        fi
    done
    echo "Для добавления новых перенаправлений отредактируйте $CONFIG_FILE и перезапустите сервис:"
    echo "  systemctl restart proxmox-tunnel.service"
else
    echo "Ошибка при запуске сервиса. Проверьте логи: journalctl -u proxmox-tunnel.service"
fi
