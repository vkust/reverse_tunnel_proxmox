#!/usr/bin/env bash
set -euo pipefail

# ==== НАСТРОЙКИ ПО УМОЛЧАНИЮ ====
TUN_USER="sshtunnel"
TUN_HOME="/home/${TUN_USER}"
CONF_DIR="/etc/sshtunnels"
KEY_NAME="id_tunnel"

# ==== ПРОВЕРКИ ====
if [[ $EUID -ne 0 ]]; then
  echo "Запустите скрипт от root"
  exit 1
fi

echo "[1/6] Установка пакетов autossh, openssh-client..."
apt update -y
apt install -y autossh openssh-client

# ==== ПОЛЬЗОВАТЕЛЬ ДЛЯ ТУННЕЛЕЙ ====
echo "[2/6] Создание пользователя ${TUN_USER} (если нет)..."
if ! id "${TUN_USER}" &>/dev/null; then
  useradd -m -s /usr/sbin/nologin "${TUN_USER}"
fi

mkdir -p "${TUN_HOME}/.ssh"
chown "${TUN_USER}:${TUN_USER}" "${TUN_HOME}/.ssh"
chmod 700 "${TUN_HOME}/.ssh"

# ==== КЛЮЧ ДЛЯ ТУННЕЛЕЙ ====
echo "[3/6] Генерация SSH-ключа (если нет)..."
KEY_PATH="${TUN_HOME}/.ssh/${KEY_NAME}"
if [[ ! -f "${KEY_PATH}" ]]; then
  sudo -u "${TUN_USER}" ssh-keygen -t ed25519 -N "" -f "${KEY_PATH}"
fi
PUB_KEY="${KEY_PATH}.pub"

echo
echo "ПУБЛИЧНЫЙ КЛЮЧ (добавьте его в authorized_keys на удалённом сервере):"
echo "-------------------------------------------------------------------"
cat "${PUB_KEY}"
echo "-------------------------------------------------------------------"
echo

# ==== ДИРЕКТОРИЯ КОНФИГОВ ====
echo "[4/6] Создание директории конфигов ${CONF_DIR}..."
mkdir -p "${CONF_DIR}"
chmod 700 "${CONF_DIR}"

# ==== SYSTEMD ШАБЛОН ====
UNIT_FILE="/etc/systemd/system/sshtunnel@.service"
echo "[5/6] Создание systemd unit-шаблона ${UNIT_FILE}..."
cat > "${UNIT_FILE}" <<'EOF'
[Unit]
Description=Reverse SSH tunnel %i
After=network-online.target
Wants=network-online.target

[Service]
User=sshtunnel
EnvironmentFile=/etc/sshtunnels/%i.conf
Environment="AUTOSSH_GATETIME=0"

ExecStart=/usr/bin/autossh -M 0 -N \
  -o "PubkeyAuthentication=yes" \
  -o "PasswordAuthentication=no" \
  $EXTRA_OPTS \
  -i ${SSH_KEY} \
  -R ${REVERSE_PORT}:${LOCAL_HOST}:${LOCAL_PORT} \
  -p ${REMOTE_PORT} \
  ${REMOTE_USER}@${REMOTE_HOST}

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "${UNIT_FILE}"

# ==== УПРАВЛЯЮЩИЙ СКРИПТ ====
MANAGER="/usr/local/sbin/sshtunnel"
echo "[6/6] Создание управляющего скрипта ${MANAGER}..."
cat > "${MANAGER}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONF_DIR=/etc/sshtunnels

usage() {
  cat <<USAGE
Usage: $0 {add|edit|start|stop|restart|status|logs|remove|list} NAME

  add NAME      - создать шаблон конфига и включить туннель
  edit NAME     - открыть конфиг в \$EDITOR и перезапустить туннель
  start NAME    - запустить туннель
  stop NAME     - остановить туннель
  restart NAME  - перезапустить туннель
  status NAME   - показать статус туннеля
  logs NAME     - показать журнал (journalctl -u)
  remove NAME   - отключить и удалить конфиг
  list          - перечислить имеющиеся конфиги
USAGE
}

cmd=${1:-}
name=${2:-}

mkdir -p "$CONF_DIR"

if [[ "${cmd:-}" == "list" ]]; then
  ls -1 "$CONF_DIR"/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##' || true
  exit 0
fi

[[ -z "${cmd:-}" || -z "${name:-}" ]] && { usage; exit 1; }

conf="$CONF_DIR/$name.conf"
unit="sshtunnel@${name}.service"

case "$cmd" in
  add)
    if [[ -e "$conf" ]]; then
      echo "Config $conf already exists"
      exit 1
    fi
    cat >"$conf" <<EOC
# Пользователь и хост, к которому стучимся
REMOTE_USER=remoteuser
REMOTE_HOST=example.com
REMOTE_PORT=22

# Обратный порт на REMOTE_HOST и локальный адрес/порт
REVERSE_PORT=20022
LOCAL_HOST=127.0.0.1
LOCAL_PORT=22

# Ключ (по умолчанию /home/sshtunnel/.ssh/id_tunnel)
SSH_KEY=/home/sshtunnel/.ssh/id_tunnel

# Дополнительные опции SSH
EXTRA_OPTS="-o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
EOC
    chmod 600 "$conf"
    systemctl daemon-reload
    systemctl enable --now "$unit"
    systemctl status "$unit" --no-pager
    ;;

  edit)
    ${EDITOR:-nano} "$conf"
    systemctl daemon-reload
    systemctl restart "$unit" || true
    ;;

  start)
    systemctl start "$unit"
    ;;

  stop)
    systemctl stop "$unit"
    ;;

  restart)
    systemctl daemon-reload
    systemctl restart "$unit"
    ;;

  status)
    systemctl status "$unit"
    ;;

  logs)
    journalctl -u "$unit" -e
    ;;

  remove)
    systemctl disable --now "$unit" || true
    rm -f "$conf"
    ;;

  *)
    usage
    exit 1
    ;;
esac
EOF

chmod +x "${MANAGER}"

systemctl daemon-reload

echo
echo "Готово."
echo "1) Добавьте показанный выше публичный ключ в ~/.ssh/authorized_keys нужного пользователя на удалённом сервере."
echo "2) Создайте первый туннель, отредактировав конфиг:"
echo "   sshtunnel add myvm"
echo "   sshtunnel edit myvm   # изменить REMOTE_HOST, REVERSE_PORT и т.д."
echo "3) Проверить состояние и логи:"
echo "   sshtunnel status myvm"
echo "   sshtunnel logs myvm"
