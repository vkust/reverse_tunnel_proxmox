#!/bin/bash

# Настройки по умолчанию
STORAGE="local"
V_ID_DEFAULT="105"
BRIDGE_DEFAULT="vmbr0"

echo "=== OpenWrt LXC Installer for Proxmox ==="

# 1. Выбор версии
echo "Выберите версию OpenWrt:"
echo "1) 24.10.0 (Latest Release)"
echo "2) 23.05.5 (Stable)"
echo "3) Ввести свою версию вручную"
read -p "Ваш выбор: " VERSION_CHOICE

case $VERSION_CHOICE in
    1) OW_VER="24.10.0" ;;
    2) OW_VER="23.05.5" ;;
    3) read -p "Введите версию (например, 24.10.0): " OW_VER ;;
    *) echo "Ошибка выбора"; exit 1 ;;
esac

# 2. Проверка доступности образа
URL="https://downloads.openwrt.org/releases/${OW_VER}/targets/x86/64/openwrt-${OW_VER}-x86-64-rootfs.tar.gz"
echo "Проверка доступности: $URL"

if wget --spider -q "$URL"; then
    echo "[OK] Образ найден."
else
    echo "[Error] Образ не найден по этой ссылке! Проверьте номер версии."
    exit 1
fi

# 3. Запрос параметров контейнера
read -p "Введите ID контейнера (по умолчанию $V_ID_DEFAULT): " CTID
CTID=${CTID:-$V_ID_DEFAULT}

read -p "Введите имя контейнера (например, OpenWrt-LXC): " CTNAME
CTNAME=${CTNAME:-OpenWrt-LXC}

# 4. Скачивание образа в хранилище Proxmox
TEMPLATE_PATH="/var/lib/vz/template/cache/openwrt-${OW_VER}-rootfs.tar.gz"
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "Скачивание rootfs..."
    wget -O "$TEMPLATE_PATH" "$URL"
fi

# 5. Создание контейнера
# Используем --features nesting=1 и privileged=1, так как роутеру нужны права на работу с сетью
echo "Создание контейнера $CTID..."
pct create $CTID "$TEMPLATE_PATH" \
    --hostname "$CTNAME" \
    --memory 256 \
    --swap 0 \
    --net0 name=eth0,bridge=$BRIDGE_DEFAULT,ip=dhcp \
    --storage $STORAGE \
    --ostype unmanaged \
    --unprivileged 0 \
    --features nesting=1

# 6. Тюнинг конфигурации для полноценной работы сети
CONF_FILE="/etc/pve/lxc/${CTID}.conf"
echo "Добавление разрешений для TUN/TAP и ядерных модулей..."
cat >> $CONF_FILE <<EOF
lxc.cap.drop:
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

echo "=== Готово! ==="
echo "Контейнер $CTID создан. Запустите его командой: pct start $CTID"
echo "Затем войдите в консоль: pct console $CTID"
