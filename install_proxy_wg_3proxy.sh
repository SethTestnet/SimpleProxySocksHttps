#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# SimpleProxySocksHttps
# WireGuard + 3proxy private proxy installer
#
# Ubuntu 22.04 / 24.04
#
# Result:
#   WireGuard server: 10.66.66.1/24
#   WireGuard client: 10.66.66.2/32
#   SOCKS5 proxy:     10.66.66.1:1080
#   HTTP proxy:       10.66.66.1:3128
#
# Public internet:
#   OPEN:   22/tcp, 51820/udp
#   CLOSED: 1080/tcp, 3128/tcp
#
# Client WireGuard AllowedIPs:
#   10.66.66.1/32
#
# This means WireGuard does NOT route all client traffic.
# It only gives access to the private proxy address.
# ============================================================

WG_IFACE="wg0"
WG_PORT="51820"
WG_SERVER_IP="10.66.66.1"
WG_SERVER_CIDR="10.66.66.1/24"
WG_CLIENT_IP="10.66.66.2"
WG_CLIENT_CIDR="10.66.66.2/32"

SOCKS_PORT="1080"
HTTP_PORT="3128"

THREEPROXY_VERSION="0.9.5"
THREEPROXY_DIR="/usr/local/3proxy"
THREEPROXY_CFG_DIR="${THREEPROXY_DIR}/conf"
THREEPROXY_CFG="${THREEPROXY_CFG_DIR}/3proxy.cfg"
THREEPROXY_BIN="${THREEPROXY_DIR}/bin/3proxy"
THREEPROXY_LOG_DIR="/var/log/3proxy"

WG_DIR="/etc/wireguard"
CLIENT_CONF_PATH="/root/wg-client-private-proxy.conf"
INFO_PATH="/root/proxy-info.txt"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

die() {
  echo "${RED}ERROR:${NC} $*" >&2
  exit 1
}

info() {
  echo "${GREEN}==>${NC} $*"
}

warn() {
  echo "${YELLOW}WARN:${NC} $*"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root. Example: curl -fsSL URL | sudo bash"
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot find /etc/os-release"
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is tested on Ubuntu. Current OS: ${ID:-unknown}. Continuing anyway."
  fi
}

ask_default() {
  local prompt="$1"
  local default="$2"
  local value=""

  read -r -p "${prompt} [${default}]: " value || true
  echo "${value:-$default}"
}

ask_yes_no_default_yes() {
  local prompt="$1"
  local value=""

  read -r -p "${prompt} [Y/n]: " value || true
  value="${value:-Y}"

  [[ "$value" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]
}

generate_password() {
  openssl rand -base64 32 | tr -d '=+/' | cut -c1-28
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

detect_public_ip() {
  local ip=""

  ip="$(curl -4fsSL --max-time 7 https://ifconfig.co 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsSL --max-time 7 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsSL --max-time 7 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi

  [[ -n "$ip" ]] || die "Cannot detect public IPv4 address"
  echo "$ip"
}

install_packages() {
  local do_upgrade="$1"

  info "Updating apt cache"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y

  if [[ "$do_upgrade" == "yes" ]]; then
    info "Upgrading installed packages"
    apt-get upgrade -y
  fi

  info "Installing dependencies"

  apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    make \
    gcc \
    libc6-dev \
    wireguard \
    wireguard-tools \
    iproute2 \
    iptables \
    ufw \
    openssl \
    ca-certificates \
    net-tools
}

create_swap_if_needed() {
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"

  if (( mem_kb < 900000 )); then
    if [[ ! -f /swapfile ]]; then
      info "Low RAM detected. Creating 1G swap"
      fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile

      if ! grep -q '^/swapfile ' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
      fi
    else
      warn "Swap file already exists. Skipping swap creation"
    fi
  fi
}

stop_old_services() {
  info "Stopping old services if they exist"

  systemctl stop 3proxy 2>/dev/null || true
  systemctl stop "wg-quick@${WG_IFACE}" 2>/dev/null || true

  pkill -f "${THREEPROXY_BIN}" 2>/dev/null || true
}

install_3proxy() {
  info "Installing 3proxy ${THREEPROXY_VERSION}"

  local workdir="/tmp/3proxy-build"

  rm -rf "$workdir"
  mkdir -p "$workdir"
  cd "$workdir"

  wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/${THREEPROXY_VERSION}.tar.gz" -O 3proxy.tar.gz
  tar -xzf 3proxy.tar.gz
  cd "3proxy-${THREEPROXY_VERSION}"

  make -f Makefile.Linux

  mkdir -p "${THREEPROXY_DIR}/bin" "${THREEPROXY_CFG_DIR}" "${THREEPROXY_LOG_DIR}"
  cp ./bin/3proxy "${THREEPROXY_BIN}"
  chmod +x "${THREEPROXY_BIN}"

  if ! id -u 3proxy >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin 3proxy
  fi

  chown -R 3proxy:3proxy "${THREEPROXY_DIR}" "${THREEPROXY_LOG_DIR}"
  chmod 755 "${THREEPROXY_LOG_DIR}"
}

configure_sysctl() {
  info "Configuring sysctl"

  cat >/etc/sysctl.d/99-simple-proxy.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=0
EOF

  sysctl --system >/dev/null
}

backup_old_configs() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -f "${WG_DIR}/${WG_IFACE}.conf" ]]; then
    cp "${WG_DIR}/${WG_IFACE}.conf" "${WG_DIR}/${WG_IFACE}.conf.backup-${ts}"
  fi

  if [[ -f "${THREEPROXY_CFG}" ]]; then
    cp "${THREEPROXY_CFG}" "${THREEPROXY_CFG}.backup-${ts}"
  fi

  if [[ -f "${CLIENT_CONF_PATH}" ]]; then
    cp "${CLIENT_CONF_PATH}" "${CLIENT_CONF_PATH}.backup-${ts}"
  fi
}

configure_wireguard() {
  local public_ip="$1"

  info "Configuring WireGuard"

  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"

  local server_private server_public client_private client_public

  server_private="$(wg genkey)"
  server_public="$(echo "$server_private" | wg pubkey)"
  client_private="$(wg genkey)"
  client_public="$(echo "$client_private" | wg pubkey)"

  cat >"${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = ${server_private}
SaveConfig = false

[Peer]
PublicKey = ${client_public}
AllowedIPs = ${WG_CLIENT_CIDR}
EOF

  chmod 600 "${WG_DIR}/${WG_IFACE}.conf"

  cat >"${CLIENT_CONF_PATH}" <<EOF
[Interface]
PrivateKey = ${client_private}
Address = ${WG_CLIENT_CIDR}

[Peer]
PublicKey = ${server_public}
Endpoint = ${public_ip}:${WG_PORT}
AllowedIPs = ${WG_SERVER_IP}/32
PersistentKeepalive = 25
EOF

  chmod 600 "${CLIENT_CONF_PATH}"
}

configure_3proxy() {
  local proxy_user="$1"
  local proxy_pass="$2"

  info "Configuring 3proxy"

  mkdir -p "${THREEPROXY_CFG_DIR}" "${THREEPROXY_LOG_DIR}"

  cat >"${THREEPROXY_CFG}" <<EOF
# ============================================================
# 3proxy config
#
# Proxy listens only on WireGuard IP: ${WG_SERVER_IP}
#
# SOCKS5:
#   ${WG_SERVER_IP}:${SOCKS_PORT}
#
# HTTP / HTTPS CONNECT:
#   ${WG_SERVER_IP}:${HTTP_PORT}
#
# Important:
#   No "external" directive is used.
#   The OS chooses the correct outbound interface automatically.
# ============================================================

daemon

nscache 65536
timeouts 1 5 30 60 180 1800 15 60

log ${THREEPROXY_LOG_DIR}/3proxy.log D
logformat "L%Y-%m-%d %H:%M:%S %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

auth strong
users ${proxy_user}:CL:${proxy_pass}

allow ${proxy_user}

internal ${WG_SERVER_IP}

socks -p${SOCKS_PORT}
proxy -p${HTTP_PORT}
EOF

  chown -R 3proxy:3proxy "${THREEPROXY_DIR}" "${THREEPROXY_LOG_DIR}"
  chmod 600 "${THREEPROXY_CFG}"

  cat >/etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy Proxy Server
After=network-online.target wg-quick@${WG_IFACE}.service
Wants=network-online.target

[Service]
Type=forking
ExecStart=${THREEPROXY_BIN} ${THREEPROXY_CFG}
ExecReload=/bin/kill -SIGUSR1 \$MAINPID
Restart=always
RestartSec=3
User=3proxy
Group=3proxy
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

configure_firewall() {
  info "Configuring UFW firewall"

  ufw --force reset

  ufw default deny incoming
  ufw default allow outgoing

  # SSH. On AWS, it is better to restrict this in Security Group.
  ufw allow 22/tcp comment 'SSH'

  # Public WireGuard port.
  ufw allow "${WG_PORT}/udp" comment 'WireGuard'

  # Allow proxy ports only through WireGuard interface.
  # This is the key fix: without these rules, UFW can block proxy access even when WireGuard works.
  ufw allow in on "${WG_IFACE}" to any port "${SOCKS_PORT}" proto tcp comment 'Allow SOCKS5 via WireGuard'
  ufw allow in on "${WG_IFACE}" to any port "${HTTP_PORT}" proto tcp comment 'Allow HTTP proxy via WireGuard'

  # Block public proxy access from the internet.
  ufw deny "${SOCKS_PORT}/tcp" comment 'Block public SOCKS5'
  ufw deny "${HTTP_PORT}/tcp" comment 'Block public HTTP proxy'

  ufw --force enable
  ufw reload
}

start_services() {
  info "Starting services"

  systemctl daemon-reload

  systemctl enable "wg-quick@${WG_IFACE}"
  systemctl restart "wg-quick@${WG_IFACE}"

  sleep 1

  systemctl enable 3proxy
  systemctl restart 3proxy
}

write_info_file() {
  local public_ip="$1"
  local proxy_user="$2"
  local proxy_pass="$3"

  cat >"${INFO_PATH}" <<EOF
============================================================
Private WireGuard + 3proxy installed
============================================================

Public VPS IP:
  ${public_ip}

WireGuard:
  Server UDP port:
    ${WG_PORT}

WireGuard client config:
  ${CLIENT_CONF_PATH}

Proxy inside WireGuard only:

  SOCKS5:
    socks5://${proxy_user}:${proxy_pass}@${WG_SERVER_IP}:${SOCKS_PORT}

  HTTP / HTTPS CONNECT:
    http://${proxy_user}:${proxy_pass}@${WG_SERVER_IP}:${HTTP_PORT}

AWS / cloud firewall:
  Open:
    22/tcp
    ${WG_PORT}/udp

  Do NOT open:
    ${SOCKS_PORT}/tcp
    ${HTTP_PORT}/tcp

Client WireGuard AllowedIPs:
  ${WG_SERVER_IP}/32

This means WireGuard does NOT route all client traffic.
Only traffic to ${WG_SERVER_IP} goes through WireGuard.

Useful server commands:

  Show WireGuard status:
    wg show

  Show services:
    systemctl status wg-quick@${WG_IFACE} --no-pager
    systemctl status 3proxy --no-pager

  Show listening ports:
    ss -lntup | grep -E '${SOCKS_PORT}|${HTTP_PORT}|${WG_PORT}'

  Show UFW rules:
    ufw status numbered

  Show 3proxy logs:
    ls -la ${THREEPROXY_LOG_DIR}
    tail -f ${THREEPROXY_LOG_DIR}/3proxy.log.*

Client config:
------------------------------------------------------------
$(cat "${CLIENT_CONF_PATH}")
------------------------------------------------------------
EOF

  chmod 600 "${INFO_PATH}"
}

print_result() {
  local public_ip="$1"
  local proxy_user="$2"
  local proxy_pass="$3"

  echo
  echo "${GREEN}============================================================${NC}"
  echo "${GREEN}Done. Private proxy installed.${NC}"
  echo "${GREEN}============================================================${NC}"
  echo
  echo "Public VPS IP:"
  echo "  ${public_ip}"
  echo
  echo "WireGuard client config:"
  echo "  ${CLIENT_CONF_PATH}"
  echo
  echo "Info file:"
  echo "  ${INFO_PATH}"
  echo
  echo "Proxy is available ONLY through WireGuard:"
  echo
  echo "  SOCKS5:"
  echo "    socks5://${proxy_user}:${proxy_pass}@${WG_SERVER_IP}:${SOCKS_PORT}"
  echo
  echo "  HTTP / HTTPS:"
  echo "    http://${proxy_user}:${proxy_pass}@${WG_SERVER_IP}:${HTTP_PORT}"
  echo
  echo "${YELLOW}AWS / cloud firewall:${NC}"
  echo "  Open: ${WG_PORT}/udp"
  echo "  Do NOT open publicly: ${SOCKS_PORT}/tcp and ${HTTP_PORT}/tcp"
  echo
  echo "Show client config:"
  echo "  sudo cat ${CLIENT_CONF_PATH}"
  echo
  echo "Check services:"
  echo "  sudo systemctl status wg-quick@${WG_IFACE} --no-pager"
  echo "  sudo systemctl status 3proxy --no-pager"
  echo
  echo "Check ports:"
  echo "  sudo ss -lntup | grep -E '${SOCKS_PORT}|${HTTP_PORT}|${WG_PORT}'"
  echo
}

main() {
  need_root
  detect_os

  echo
  echo "============================================================"
  echo " WireGuard + 3proxy private proxy installer"
  echo "============================================================"
  echo

  local do_upgrade="yes"
  if ask_yes_no_default_yes "Upgrade system packages before installation?"; then
    do_upgrade="yes"
  else
    do_upgrade="no"
  fi

  SOCKS_PORT="$(ask_default "SOCKS5 port" "${SOCKS_PORT}")"
  HTTP_PORT="$(ask_default "HTTP proxy port" "${HTTP_PORT}")"
  WG_PORT="$(ask_default "WireGuard UDP port" "${WG_PORT}")"

  valid_port "${SOCKS_PORT}" || die "Invalid SOCKS5 port: ${SOCKS_PORT}"
  valid_port "${HTTP_PORT}" || die "Invalid HTTP proxy port: ${HTTP_PORT}"
  valid_port "${WG_PORT}" || die "Invalid WireGuard port: ${WG_PORT}"

  local default_user default_pass proxy_user proxy_pass
  default_user="proxyuser"
  default_pass="$(generate_password)"

  proxy_user="$(ask_default "Proxy username" "${default_user}")"
  proxy_pass="$(ask_default "Proxy password" "${default_pass}")"

  [[ -n "${proxy_user}" ]] || die "Proxy username is empty"
  [[ -n "${proxy_pass}" ]] || die "Proxy password is empty"

  if [[ "${proxy_user}" == *":"* ]]; then
    die "Proxy username must not contain ':'"
  fi

  if [[ "${proxy_pass}" == *":"* ]]; then
    die "Proxy password must not contain ':'"
  fi

  install_packages "${do_upgrade}"
  create_swap_if_needed
  stop_old_services
  backup_old_configs

  local public_ip
  public_ip="$(detect_public_ip)"

  info "Public IP: ${public_ip}"

  configure_sysctl
  install_3proxy
  configure_wireguard "${public_ip}"
  configure_3proxy "${proxy_user}" "${proxy_pass}"
  configure_firewall
  start_services
  write_info_file "${public_ip}" "${proxy_user}" "${proxy_pass}"
  print_result "${public_ip}" "${proxy_user}" "${proxy_pass}"
}

main "$@"
