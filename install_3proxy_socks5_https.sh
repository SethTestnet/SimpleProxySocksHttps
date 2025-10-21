#!/usr/bin/env bash
set -Eeuo pipefail

# === Configurable defaults ===
DEFAULT_VERSION="0.9.5"
DEFAULT_SOCKS_PORT="1080"
DEFAULT_HTTP_PORT="3128"
DEFAULT_USER="proxyuser"

# === Utils ===
log(){ echo -e "\033[1;32m[OK]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
die(){ echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

require_root(){
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Запусти скрипт от root (sudo bash $0)"
  fi
}

ask(){
  local prompt="$1" default="${2:-}"
  local ans
  read -r -p "$prompt ${default:+[$default]}: " ans || true
  echo "${ans:-$default}"
}

# === Main ===
require_root
echo "=== 3proxy SOCKS5 + HTTPS installer ==="

VERSION="$(ask 'Версия 3proxy' "$DEFAULT_VERSION")"
SOCKS_PORT="$(ask 'Порт для SOCKS5' "$DEFAULT_SOCKS_PORT")"
HTTP_PORT="$(ask 'Порт для HTTPS-прокси (HTTP CONNECT)' "$DEFAULT_HTTP_PORT")"
USER_NAME="$(ask 'Логин прокси' "$DEFAULT_USER")"
read -r -s -p "Пароль прокси (без двоеточий ':'): " PASSWD; echo
ALLOW_IP="$(ask 'Разрешить только одному IP (например 1.2.3.4) или оставить пустым' "")"

[[ -z "$USER_NAME" || -z "$PASSWD" ]] && die "Логин и пароль не могут быть пустыми."
[[ "$PASSWD" == *:* ]] && die "Пароль не должен содержать двоеточие ':'"

log "Устанавливаем зависимости..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential wget tar libssl-dev ufw curl ca-certificates

WORKDIR="/usr/local/src/3proxy-build"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

ARCHIVE_URL="https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz"
log "Скачиваем 3proxy $VERSION..."
wget -O 3proxy.tar.gz "$ARCHIVE_URL"
tar xzf 3proxy.tar.gz
cd "3proxy-${VERSION}"

log "Собираем..."
make -f Makefile.Linux -j"$(nproc)"
make -f Makefile.Linux install

BIN_PATH="$(command -v 3proxy || true)"
[[ -z "$BIN_PATH" ]] && BIN_PATH="/usr/bin/3proxy"
[[ ! -x "$BIN_PATH" ]] && die "Не найден бинарь 3proxy"

log "Бинарь найден: $BIN_PATH"
install -d /usr/local/3proxy
echo "I ACCEPT" > /usr/local/3proxy/3proxy.accept

CONF_DIR="/usr/local/3proxy/conf"
LOG_DIR="/var/log/3proxy"
install -d "$CONF_DIR" "$LOG_DIR"
touch "$LOG_DIR/3proxy.log"

CONF_FILE="$CONF_DIR/3proxy.cfg"
log "Создаём конфиг..."
cat > "$CONF_FILE" <<EOF
nscache 65536
log $LOG_DIR/3proxy.log D
logformat "L%d-%m-%Y %H:%M:%S %N %p %c %C %r %u %U %T %B"
rotate 7
counter $LOG_DIR/3proxy.3cf

auth strong
users $USER_NAME:CL:$PASSWD
allow $USER_NAME

socks -p$SOCKS_PORT -a
proxy -p$HTTP_PORT -a
EOF

# systemd unit
UNIT_FILE="/etc/systemd/system/3proxy.service"
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=3proxy SOCKS5 + HTTPS proxy server
After=network.target

[Service]
Type=simple
WorkingDirectory=$CONF_DIR
ExecStart=$BIN_PATH $CONF_FILE
Restart=always
RestartSec=5s
LimitNOFILE=65535
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now 3proxy
sleep 0.8
systemctl status 3proxy --no-pager || true

# firewall
if command -v ufw >/dev/null 2>&1; then
  ufw --force enable || true
  if [[ -n "$ALLOW_IP" ]]; then
    ufw allow from "$ALLOW_IP"/32 to any port "$SOCKS_PORT"
    ufw allow from "$ALLOW_IP"/32 to any port "$HTTP_PORT"
    log "Разрешил доступ только для $ALLOW_IP"
  else
    ufw allow "$SOCKS_PORT"/tcp
    ufw allow "$HTTP_PORT"/tcp
    log "Открыл порты $SOCKS_PORT и $HTTP_PORT для всех"
  fi
else
  warn "UFW не найден, порты не открывались"
fi

# autodetect server IPv4
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
[[ -z "$SERVER_IP" ]] && SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$SERVER_IP" ]] && SERVER_IP="$(curl -4 -fsS ifconfig.co 2>/dev/null || true)"

cat <<MSG

==========================================
✅ Установка завершена

SOCKS5-прокси:
  Порт: $SOCKS_PORT

HTTPS (HTTP CONNECT)-прокси:
  Порт: $HTTP_PORT

Логин:    $USER_NAME
Пароль:   $PASSWD
IP:       ${SERVER_IP:-<не определён>}

Доступ (строки для быстрого копирования):
  SOCKS5  →  socks5://$USER_NAME:$PASSWD@$SERVER_IP:$SOCKS_PORT
  HTTPS   →  http://$USER_NAME:$PASSWD@$SERVER_IP:$HTTP_PORT

Проверка:
  curl -v --socks5-hostname '$USER_NAME:$PASSWD'@${SERVER_IP:-<IP>}:$SOCKS_PORT https://ifconfig.co
  curl -v -x http://$USER_NAME:$PASSWD@${SERVER_IP:-<IP>}:$HTTP_PORT https://ifconfig.co

Файлы:
  Конфиг: $CONF_FILE
  Логи:   $LOG_DIR/3proxy.log
  Systemd: $UNIT_FILE

Команды:
  sudo systemctl status 3proxy --no-pager
  sudo systemctl restart 3proxy
  sudo tail -f $LOG_DIR/3proxy/3proxy.log
==========================================
MSG
