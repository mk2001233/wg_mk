#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${WG_EASY_STACK_DIR:-/opt/wg-easy}"
DATA_DIR="${STACK_DIR}/data"
ENV_FILE="${STACK_DIR}/.env"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
INFO_FILE="${STACK_DIR}/deployment-info.txt"
SYSCTL_FILE="/etc/sysctl.d/99-wg-easy.conf"
DOCKER_PROXY_FILE="/etc/systemd/system/docker.service.d/http-proxy.conf"
CONTAINERD_PROXY_FILE="/etc/systemd/system/containerd.service.d/http-proxy.conf"

PROXY_URL="${WG_EASY_PROXY_URL:-http://127.0.0.1:11066}"
PROXY_MODE="${WG_EASY_PROXY_MODE:-auto}"
PULL_TIMEOUT_SECONDS="${WG_EASY_PULL_TIMEOUT_SECONDS:-900}"
SHELL_PROXY_ENABLED=0
WG_EASY_ALLOWED_IPS_EXPLICIT=0

if [[ -n "${WG_EASY_ALLOWED_IPS+x}" ]]; then
  WG_EASY_ALLOWED_IPS_EXPLICIT=1
fi

log() {
  printf '[wg-easy] %s\n' "$*"
}

die() {
  printf '[wg-easy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run this script as root."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

apt_no_proxy() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
    apt-get "$@"
}

curl_no_proxy() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
    curl "$@"
}

validate_proxy_mode() {
  case "$PROXY_MODE" in
    auto|always|never) ;;
    *)
      die "WG_EASY_PROXY_MODE must be one of: auto, always, never."
      ;;
  esac
}

validate_timeout() {
  if ! [[ "$PULL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || (( PULL_TIMEOUT_SECONDS < 30 )); then
    die "WG_EASY_PULL_TIMEOUT_SECONDS must be an integer >= 30."
  fi
}

proxy_host() {
  printf '%s' "$PROXY_URL" | sed -E 's#^[A-Za-z]+://([^:/]+).*#\1#'
}

proxy_port() {
  printf '%s' "$PROXY_URL" | sed -nE 's#^[A-Za-z]+://[^:/]+:([0-9]+).*#\1#p'
}

proxy_reachable() {
  local host port
  host="$(proxy_host)"
  port="$(proxy_port)"

  if [[ -z "$host" || -z "$port" ]]; then
    return 1
  fi

  timeout 3 bash -lc "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

enable_shell_proxy() {
  if [[ "$SHELL_PROXY_ENABLED" -eq 1 ]]; then
    return 0
  fi

  export HTTP_PROXY="$PROXY_URL"
  export HTTPS_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"
  export http_proxy="$PROXY_URL"
  export https_proxy="$PROXY_URL"
  export all_proxy="$PROXY_URL"
  export NO_PROXY="127.0.0.1,localhost,::1"
  export no_proxy="$NO_PROXY"
  SHELL_PROXY_ENABLED=1
  log "Enabled shell proxy via ${PROXY_URL}"
}

disable_shell_proxy() {
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
  unset http_proxy https_proxy all_proxy
  unset FTP_PROXY ftp_proxy
  unset NO_PROXY no_proxy
}

maybe_enable_shell_proxy() {
  case "$PROXY_MODE" in
    never)
      return 1
      ;;
    always)
      proxy_reachable || die "Proxy mode is 'always' but ${PROXY_URL} is not reachable."
      enable_shell_proxy
      return 0
      ;;
    auto)
      if proxy_reachable; then
        enable_shell_proxy
        return 0
      fi
      return 1
      ;;
  esac
}

write_proxy_dropin() {
  local target_file=$1
  mkdir -p "$(dirname "$target_file")"
  cat >"$target_file" <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="ALL_PROXY=${PROXY_URL}"
Environment="NO_PROXY=127.0.0.1,localhost,::1"
EOF
}

configure_docker_proxy() {
  case "$PROXY_MODE" in
    never)
      return 1
      ;;
    always|auto)
      proxy_reachable || die "Docker proxy requested but ${PROXY_URL} is not reachable."
      write_proxy_dropin "$DOCKER_PROXY_FILE"
      write_proxy_dropin "$CONTAINERD_PROXY_FILE"
      systemctl daemon-reload
      systemctl restart containerd docker
      log "Configured Docker and containerd to use proxy ${PROXY_URL}"
      return 0
      ;;
  esac
}

apt_install_base() {
  apt_no_proxy update
  apt_no_proxy install -y ca-certificates curl iproute2
}

install_base_packages() {
  if ! apt_install_base; then
    log "Base package install failed directly."
    maybe_enable_shell_proxy || return 1
    apt_install_base
  fi
}

install_docker_once() {
  local arch codename key_url repo_url

  if command_exists docker && docker compose version >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi

  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")"
  key_url="https://download.docker.com/linux/ubuntu/gpg"
  repo_url="https://download.docker.com/linux/ubuntu"

  apt_no_proxy update
  apt_no_proxy install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings

  if ! curl_no_proxy -fsSL "$key_url" -o /etc/apt/keyrings/docker.asc; then
    log "Docker GPG key download failed directly."
    maybe_enable_shell_proxy || return 1
    curl -fsSL "$key_url" -o /etc/apt/keyrings/docker.asc
  fi

  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' \
    "$arch" \
    "$repo_url" \
    "$codename" \
    >/etc/apt/sources.list.d/docker.list

  apt_no_proxy update
  apt_no_proxy install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker compose version >/dev/null 2>&1
}

install_docker() {
  if install_docker_once; then
    return 0
  fi

  log "Docker installation failed directly."
  maybe_enable_shell_proxy || return 1
  install_docker_once
}

port_in_use() {
  local port=$1
  local proto=$2

  case "$proto" in
    tcp)
      ss -H -ltn | awk -v port=":${port}" '$4 ~ port {found=1} END {exit found ? 0 : 1}'
      ;;
    udp)
      ss -H -lun | awk -v port=":${port}" '$4 ~ port {found=1} END {exit found ? 0 : 1}'
      ;;
    *)
      die "Unsupported protocol check: ${proto}"
      ;;
  esac
}

detect_public_host() {
  local host

  host="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$host" ]] && [[ "$PROXY_MODE" != "never" ]] && proxy_reachable; then
    host="$(HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$host" ]]; then
    host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$host" ]] || die "Could not determine the public host IP. Set WG_EASY_PUBLIC_HOST and retry."
  printf '%s\n' "$host"
}

validate_port() {
  local name=$1
  local value=$2

  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    die "${name} must be a valid TCP/UDP port."
  fi
}

load_existing_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    log "Reusing existing ${ENV_FILE}"
  fi
}

set_defaults() {
  : "${WG_EASY_VPN_PORT:=51820}"
  : "${WG_EASY_UI_PORT:=51821}"
  : "${WG_EASY_ADMIN_USER:=admin}"
  : "${WG_EASY_ADMIN_PASSWORD:=71082aaa348e3b03d45bf7f6a2c41ef18fe3}"
  : "${WG_EASY_DNS:=1.1.1.1,8.8.8.8}"
  : "${WG_EASY_IPV4_CIDR:=10.8.0.0/24}"
  : "${WG_EASY_IPV6_CIDR:=fd00:dead:beef::/64}"

  if [[ -z "${WG_EASY_ALLOWED_IPS+x}" ]]; then
    WG_EASY_ALLOWED_IPS="${WG_EASY_IPV4_CIDR}"
  elif [[ "$WG_EASY_ALLOWED_IPS_EXPLICIT" -eq 0 && "$WG_EASY_ALLOWED_IPS" == "0.0.0.0/0,::/0" ]]; then
    WG_EASY_ALLOWED_IPS="${WG_EASY_IPV4_CIDR}"
  fi

  : "${WG_EASY_PUBLIC_HOST:=123.57.216.161}"
}

validate_settings() {
  validate_port "WG_EASY_VPN_PORT" "$WG_EASY_VPN_PORT"
  validate_port "WG_EASY_UI_PORT" "$WG_EASY_UI_PORT"

  if [[ "$WG_EASY_VPN_PORT" == "$WG_EASY_UI_PORT" ]]; then
    die "WG_EASY_VPN_PORT and WG_EASY_UI_PORT must be different."
  fi
}

ensure_ports_free() {
  if port_in_use "$WG_EASY_VPN_PORT" udp; then
    die "UDP port ${WG_EASY_VPN_PORT} is already in use."
  fi

  if port_in_use "$WG_EASY_UI_PORT" tcp; then
    die "TCP port ${WG_EASY_UI_PORT} is already in use."
  fi
}

ensure_wireguard_module() {
  modprobe -n -v wireguard >/dev/null 2>&1 || die "WireGuard kernel module is not available on this host."
}

configure_host_sysctl() {
  cat >"$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null
}

write_env_file() {
  cat >"$ENV_FILE" <<EOF
WG_EASY_PUBLIC_HOST=${WG_EASY_PUBLIC_HOST}
WG_EASY_VPN_PORT=${WG_EASY_VPN_PORT}
WG_EASY_UI_PORT=${WG_EASY_UI_PORT}
WG_EASY_ADMIN_USER=${WG_EASY_ADMIN_USER}
WG_EASY_ADMIN_PASSWORD=${WG_EASY_ADMIN_PASSWORD}
WG_EASY_DNS=${WG_EASY_DNS}
WG_EASY_IPV4_CIDR=${WG_EASY_IPV4_CIDR}
WG_EASY_IPV6_CIDR=${WG_EASY_IPV6_CIDR}
WG_EASY_ALLOWED_IPS=${WG_EASY_ALLOWED_IPS}
EOF
  chmod 600 "$ENV_FILE"
}

write_compose_file() {
  cat >"$COMPOSE_FILE" <<'EOF'
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    environment:
      PORT: "${WG_EASY_UI_PORT}"
      INSECURE: "true"
      INIT_ENABLED: "true"
      INIT_USERNAME: "${WG_EASY_ADMIN_USER}"
      INIT_PASSWORD: "${WG_EASY_ADMIN_PASSWORD}"
      INIT_HOST: "${WG_EASY_PUBLIC_HOST}"
      INIT_PORT: "${WG_EASY_VPN_PORT}"
      INIT_DNS: "${WG_EASY_DNS}"
      INIT_IPV4_CIDR: "${WG_EASY_IPV4_CIDR}"
      INIT_IPV6_CIDR: "${WG_EASY_IPV6_CIDR}"
      INIT_ALLOWED_IPS: "${WG_EASY_ALLOWED_IPS}"
    volumes:
      - ./data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_EASY_VPN_PORT}:${WG_EASY_VPN_PORT}/udp"
      - "${WG_EASY_UI_PORT}:${WG_EASY_UI_PORT}/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.src_valid_mark: "1"
      net.ipv6.conf.all.disable_ipv6: "0"
      net.ipv6.conf.all.forwarding: "1"
      net.ipv6.conf.default.forwarding: "1"
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF
}

prepare_stack() {
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  load_existing_env
  set_defaults
  validate_settings
  if [[ ! -f "$ENV_FILE" ]]; then
    ensure_ports_free
  fi
  write_env_file
  write_compose_file
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >/dev/null
}

start_stack_once() {
  timeout "${PULL_TIMEOUT_SECONDS}" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
}

start_stack() {
  if start_stack_once; then
    return 0
  fi

  log "Container start failed or timed out after ${PULL_TIMEOUT_SECONDS}s."
  configure_docker_proxy || return 1
  start_stack_once
}

wait_for_http() {
  local url=$1
  local attempts=${2:-30}
  local delay=${3:-2}
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

write_info_file() {
  cat >"$INFO_FILE" <<EOF
wg-easy deployment
==================
UI URL: http://${WG_EASY_PUBLIC_HOST}:${WG_EASY_UI_PORT}
Admin user: ${WG_EASY_ADMIN_USER}
Admin password: ${WG_EASY_ADMIN_PASSWORD}
WireGuard endpoint: ${WG_EASY_PUBLIC_HOST}:${WG_EASY_VPN_PORT}/udp
Compose file: ${COMPOSE_FILE}
Environment file: ${ENV_FILE}
Data directory: ${DATA_DIR}
EOF
  chmod 600 "$INFO_FILE"
}

main() {
  require_root
  validate_proxy_mode
  validate_timeout
  if [[ "$PROXY_MODE" != "always" ]]; then
    disable_shell_proxy
  fi
  ensure_wireguard_module
  install_base_packages
  install_docker
  configure_host_sysctl
  prepare_stack
  start_stack
  wait_for_http "http://127.0.0.1:${WG_EASY_UI_PORT}" 60 2 || die "wg-easy did not become ready on port ${WG_EASY_UI_PORT}."
  write_info_file

  log "Deployment complete."
  log "UI: http://${WG_EASY_PUBLIC_HOST}:${WG_EASY_UI_PORT}"
  log "User: ${WG_EASY_ADMIN_USER}"
  log "Password: ${WG_EASY_ADMIN_PASSWORD}"
  log "Stack directory: ${STACK_DIR}"
}

main "$@"
