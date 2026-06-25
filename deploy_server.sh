#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="${WG_EASY_STACK_DIR:-/opt/wg-easy}"
DATA_DIR="${STACK_DIR}/data"
DB_FILE="${DATA_DIR}/wg-easy.db"
ENV_FILE="${STACK_DIR}/.env"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
INFO_FILE="${STACK_DIR}/deployment-info.txt"
SYSCTL_FILE="/etc/sysctl.d/99-wg-easy.conf"
DOCKER_PROXY_FILE="/etc/systemd/system/docker.service.d/http-proxy.conf"
CONTAINERD_PROXY_FILE="/etc/systemd/system/containerd.service.d/http-proxy.conf"
APT_PROXY_FILE="/etc/apt/apt.conf.d/99-wg-easy-proxy"
APT_SOURCES_FILE="/etc/apt/sources.list"
APT_DEB822_FILE="/etc/apt/sources.list.d/ubuntu.sources"
WG_INTERFACE_NAME="wg0"

PROXY_URL="${WG_EASY_PROXY_URL:-http://127.0.0.1:11066}"
PROXY_MODE="${WG_EASY_PROXY_MODE:-auto}"
PULL_TIMEOUT_SECONDS="${WG_EASY_PULL_TIMEOUT_SECONDS:-900}"
SHELL_PROXY_ENABLED=0
PROXY_ACTIVE=0
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

# Authority (host[:port]) after stripping the scheme and any user:pass@ userinfo.
# Strip up to the LAST '@' and the path so credentials that contain '@', ':' or
# '/' cannot bleed into the host/port.
proxy_authority() {
  printf '%s' "$PROXY_URL" | sed -E 's#^[A-Za-z]+://##; s#^.*@##; s#/.*$##'
}

proxy_host() {
  proxy_authority | sed -E 's#:[0-9]+$##'
}

proxy_port() {
  proxy_authority | sed -nE 's#^.*:([0-9]+)$#\1#p'
}

proxy_reachable() {
  local host port
  host="$(proxy_host)"
  port="$(proxy_port)"

  if [[ -z "$host" || -z "$port" ]]; then
    return 1
  fi

  # Never re-evaluate these as shell: require a plain host/IP and numeric port,
  # then pass them as positional args so the probe cannot run embedded code.
  if ! [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
    log "Ignoring proxy with a malformed host/port parsed from PROXY_URL."
    return 1
  fi

  timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1
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
  local proxy_escaped
  # systemd expands $VAR / ${VAR} in Environment=; a literal '$' must be '$$'.
  proxy_escaped="$(printf '%s' "$PROXY_URL" | sed 's/\$/$$/g')"
  mkdir -p "$(dirname "$target_file")"
  cat >"$target_file" <<EOF
[Service]
Environment="HTTP_PROXY=${proxy_escaped}"
Environment="HTTPS_PROXY=${proxy_escaped}"
Environment="ALL_PROXY=${proxy_escaped}"
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

write_apt_proxy() {
  mkdir -p "$(dirname "$APT_PROXY_FILE")"
  cat >"$APT_PROXY_FILE" <<EOF
Acquire::http::Proxy "${PROXY_URL}";
Acquire::https::Proxy "${PROXY_URL}";
EOF
  chmod 644 "$APT_PROXY_FILE"
  log "Configured apt to use proxy ${PROXY_URL}"
}

# Replace the distro mirror with the official Ubuntu mirrors. Cloud images often
# ship a provider-internal mirror (e.g. mirrors.cloud.aliyuncs.com) that is only
# reachable over the intranet; when we route apt through an external proxy we
# need mirrors the proxy can actually reach.
use_official_ubuntu_sources() {
  local codename backup

  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || die "Could not determine Ubuntu codename for official apt sources."

  # Move aside a deb822 ubuntu.sources so it cannot reintroduce the old mirror.
  if [[ -f "$APT_DEB822_FILE" ]]; then
    mv -f "$APT_DEB822_FILE" "${APT_DEB822_FILE}.wg-easy.bak"
  fi

  if [[ -f "$APT_SOURCES_FILE" ]] && ! grep -q 'wg-easy: official Ubuntu mirrors' "$APT_SOURCES_FILE"; then
    backup="${APT_SOURCES_FILE}.wg-easy.bak"
    [[ -f "$backup" ]] || cp -a "$APT_SOURCES_FILE" "$backup"
  fi

  cat >"$APT_SOURCES_FILE" <<EOF
# wg-easy: official Ubuntu mirrors (reachable via proxy)
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
EOF
  log "Switched apt sources to official Ubuntu mirrors (${codename}); original saved to ${APT_SOURCES_FILE}.wg-easy.bak"
}

# Decide once how dependencies are fetched. In 'always' mode we commit to the
# proxy for everything: official Ubuntu mirrors + apt proxy + shell proxy (curl)
# + (later) the Docker daemon proxy. 'auto' enables the proxy only when it is
# reachable and otherwise stays direct; 'never' never touches it.
setup_proxy() {
  case "$PROXY_MODE" in
    never)
      disable_shell_proxy
      return 0
      ;;
    always)
      proxy_reachable || die "Proxy mode is 'always' but ${PROXY_URL} is not reachable."
      enable_shell_proxy
      use_official_ubuntu_sources
      write_apt_proxy
      PROXY_ACTIVE=1
      log "Proxy active: apt, Docker repo, and image pulls will all use ${PROXY_URL}."
      ;;
    auto)
      # Stay direct by default; the apt/curl/docker fallbacks enable the proxy
      # on demand if a direct fetch fails (see maybe_enable_shell_proxy).
      disable_shell_proxy
      ;;
  esac
}

apt_install_base() {
  apt_no_proxy update
  apt_no_proxy install -y ca-certificates curl iproute2 python3
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

# Remove a CONFLICTING pre-existing host WireGuard interface before starting
# wg-easy. The wg-easy tunnel lives inside the container, so its wg0 is in a
# separate netns and is never listed here. To avoid disturbing an unrelated host
# tunnel the admin may run, we only tear down an interface that actually
# conflicts: one bound to the wg-easy VPN port (when wg(8) is available to read
# it) or, as a fallback, one using the wg-easy interface name.
teardown_conflicting_interfaces() {
  command_exists ip || return 0

  local link port
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue

    if command_exists wg; then
      port="$(wg show "$link" listen-port 2>/dev/null || true)"
      if [[ -n "$port" ]]; then
        [[ "$port" == "$WG_EASY_VPN_PORT" ]] || continue
      else
        [[ "$link" == "$WG_INTERFACE_NAME" ]] || continue
      fi
    else
      [[ "$link" == "$WG_INTERFACE_NAME" ]] || continue
    fi

    log "Removing conflicting host WireGuard interface: ${link} (listen-port ${port:-unknown})"
    wg-quick down "$link" >/dev/null 2>&1 || ip link delete "$link" >/dev/null 2>&1 || true
  done < <(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1)
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
  apply_cli_overrides
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

ensure_peer_forward_hooks() {
  local hook_state

  [[ -f "$DB_FILE" ]] || die "Expected wg-easy database at ${DB_FILE}."
  command_exists python3 || die "python3 is required to update ${DB_FILE}."

  hook_state="$(
    WG_EASY_DB_FILE="$DB_FILE" WG_EASY_WG_INTERFACE="$WG_INTERFACE_NAME" python3 - <<'PY'
import os
import sqlite3
import sys

db_file = os.environ["WG_EASY_DB_FILE"]
wg_interface = os.environ["WG_EASY_WG_INTERFACE"]

post_up_rules = [
    f"iptables -I FORWARD -i {wg_interface} -o {wg_interface} -j ACCEPT;",
    f"ip6tables -I FORWARD -i {wg_interface} -o {wg_interface} -j ACCEPT;",
]
post_down_rules = [
    f"iptables -D FORWARD -i {wg_interface} -o {wg_interface} -j ACCEPT;",
    f"ip6tables -D FORWARD -i {wg_interface} -o {wg_interface} -j ACCEPT;",
]

conn = sqlite3.connect(db_file)
cur = conn.cursor()
cur.execute("SELECT post_up, post_down FROM hooks_table WHERE id = ?", (wg_interface,))
row = cur.fetchone()

if row is None:
    print("missing")
    sys.exit(0)

post_up, post_down = row
original = (post_up, post_down)

for rule in reversed(post_up_rules):
    if rule not in post_up:
        post_up = f"{rule} {post_up}".strip()

for rule in reversed(post_down_rules):
    if rule not in post_down:
        post_down = f"{rule} {post_down}".strip()

if (post_up, post_down) != original:
    cur.execute(
        "UPDATE hooks_table SET post_up = ?, post_down = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        (post_up, post_down, wg_interface),
    )
    conn.commit()
    print("updated")
else:
    print("unchanged")
PY
  )"

  case "$hook_state" in
    updated)
      log "Updated wg-easy hooks to allow peer-to-peer forwarding on ${WG_INTERFACE_NAME}."
      ;;
    unchanged)
      ;;
    missing)
      die "wg-easy hooks table did not contain interface ${WG_INTERFACE_NAME}."
      ;;
    *)
      die "Unexpected wg-easy hook update state: ${hook_state}"
      ;;
  esac

  docker exec wg-easy sh -lc "
    iptables -C FORWARD -i ${WG_INTERFACE_NAME} -o ${WG_INTERFACE_NAME} -j ACCEPT 2>/dev/null ||
      iptables -I FORWARD -i ${WG_INTERFACE_NAME} -o ${WG_INTERFACE_NAME} -j ACCEPT
    ip6tables -C FORWARD -i ${WG_INTERFACE_NAME} -o ${WG_INTERFACE_NAME} -j ACCEPT 2>/dev/null ||
      ip6tables -I FORWARD -i ${WG_INTERFACE_NAME} -o ${WG_INTERFACE_NAME} -j ACCEPT
  " >/dev/null
}

usage() {
  cat <<EOF
Usage:
  ${0##*/} [options]

Deploy wg-easy on this host. Every setting can be provided as a flag below or as
the matching WG_EASY_* environment variable. Precedence, highest first: a flag,
then values already saved in ${ENV_FILE} (reused on redeploy), then a matching
WG_EASY_* environment variable, then the built-in default. Run as root.

Server settings:
  --public-host VALUE      Public IP/hostname clients connect to (WG_EASY_PUBLIC_HOST)
  --vpn-port VALUE         WireGuard UDP port (WG_EASY_VPN_PORT)
  --ui-port VALUE          Web UI TCP port (WG_EASY_UI_PORT)
  --admin-user VALUE       Admin username (WG_EASY_ADMIN_USER)
  --admin-password VALUE   Admin password (WG_EASY_ADMIN_PASSWORD)
  --dns VALUE              DNS servers, comma-separated (WG_EASY_DNS)
  --ipv4-cidr VALUE        VPN IPv4 CIDR (WG_EASY_IPV4_CIDR)
  --ipv6-cidr VALUE        VPN IPv6 CIDR (WG_EASY_IPV6_CIDR)
  --allowed-ips VALUE      AllowedIPs pushed to clients (WG_EASY_ALLOWED_IPS)

Image pull / proxy:
  --proxy-url VALUE        Fallback proxy URL (WG_EASY_PROXY_URL)
  --proxy-mode VALUE       auto|always|never (WG_EASY_PROXY_MODE)
  --pull-timeout VALUE     Image pull timeout in seconds, >= 30 (WG_EASY_PULL_TIMEOUT_SECONDS)

  -h, --help               Show this help

Examples:
  sudo bash ${0##*/} --public-host 203.0.113.10
  sudo bash ${0##*/} --public-host vpn.example.com --vpn-port 51820 --ui-port 51821
  sudo bash ${0##*/} --public-host 203.0.113.10 --admin-password 's3cret' --dns 1.1.1.1
  sudo bash ${0##*/} --public-host 203.0.113.10 --proxy-mode always --proxy-url http://127.0.0.1:11066
EOF
}

require_value() {
  [[ -n "${2:-}" ]] || die "Option $1 requires a value."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public-host|--host|--server-ip)
        require_value "$1" "${2:-}"; CLI_WG_EASY_PUBLIC_HOST="$2"; shift 2 ;;
      --vpn-port)
        require_value "$1" "${2:-}"; CLI_WG_EASY_VPN_PORT="$2"; shift 2 ;;
      --ui-port)
        require_value "$1" "${2:-}"; CLI_WG_EASY_UI_PORT="$2"; shift 2 ;;
      --admin-user)
        require_value "$1" "${2:-}"; CLI_WG_EASY_ADMIN_USER="$2"; shift 2 ;;
      --admin-password)
        require_value "$1" "${2:-}"; CLI_WG_EASY_ADMIN_PASSWORD="$2"; shift 2 ;;
      --dns)
        require_value "$1" "${2:-}"; CLI_WG_EASY_DNS="$2"; shift 2 ;;
      --ipv4-cidr)
        require_value "$1" "${2:-}"; CLI_WG_EASY_IPV4_CIDR="$2"; shift 2 ;;
      --ipv6-cidr)
        require_value "$1" "${2:-}"; CLI_WG_EASY_IPV6_CIDR="$2"; shift 2 ;;
      --allowed-ips)
        require_value "$1" "${2:-}"; CLI_WG_EASY_ALLOWED_IPS="$2"; shift 2 ;;
      --proxy-url)
        require_value "$1" "${2:-}"; PROXY_URL="$2"; shift 2 ;;
      --proxy-mode)
        require_value "$1" "${2:-}"; PROXY_MODE="$2"; shift 2 ;;
      --pull-timeout)
        require_value "$1" "${2:-}"; PULL_TIMEOUT_SECONDS="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown argument: $1 (see --help)." ;;
    esac
  done
}

apply_cli_overrides() {
  [[ -n "${CLI_WG_EASY_PUBLIC_HOST+x}" ]] && WG_EASY_PUBLIC_HOST="$CLI_WG_EASY_PUBLIC_HOST"
  [[ -n "${CLI_WG_EASY_VPN_PORT+x}" ]] && WG_EASY_VPN_PORT="$CLI_WG_EASY_VPN_PORT"
  [[ -n "${CLI_WG_EASY_UI_PORT+x}" ]] && WG_EASY_UI_PORT="$CLI_WG_EASY_UI_PORT"
  [[ -n "${CLI_WG_EASY_ADMIN_USER+x}" ]] && WG_EASY_ADMIN_USER="$CLI_WG_EASY_ADMIN_USER"
  [[ -n "${CLI_WG_EASY_ADMIN_PASSWORD+x}" ]] && WG_EASY_ADMIN_PASSWORD="$CLI_WG_EASY_ADMIN_PASSWORD"
  [[ -n "${CLI_WG_EASY_DNS+x}" ]] && WG_EASY_DNS="$CLI_WG_EASY_DNS"
  [[ -n "${CLI_WG_EASY_IPV4_CIDR+x}" ]] && WG_EASY_IPV4_CIDR="$CLI_WG_EASY_IPV4_CIDR"
  [[ -n "${CLI_WG_EASY_IPV6_CIDR+x}" ]] && WG_EASY_IPV6_CIDR="$CLI_WG_EASY_IPV6_CIDR"
  if [[ -n "${CLI_WG_EASY_ALLOWED_IPS+x}" ]]; then
    WG_EASY_ALLOWED_IPS="$CLI_WG_EASY_ALLOWED_IPS"
    WG_EASY_ALLOWED_IPS_EXPLICIT=1
  fi
  return 0
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
  parse_args "$@"
  require_root
  validate_proxy_mode
  validate_timeout
  setup_proxy
  ensure_wireguard_module
  install_base_packages
  install_docker
  configure_host_sysctl
  teardown_conflicting_interfaces
  prepare_stack
  if [[ "$PROXY_MODE" == "always" ]]; then
    configure_docker_proxy || true
  fi
  start_stack
  wait_for_http "http://127.0.0.1:${WG_EASY_UI_PORT}" 60 2 || die "wg-easy did not become ready on port ${WG_EASY_UI_PORT}."
  ensure_peer_forward_hooks
  write_info_file

  log "Deployment complete."
  log "UI: http://${WG_EASY_PUBLIC_HOST}:${WG_EASY_UI_PORT}"
  log "User: ${WG_EASY_ADMIN_USER}"
  log "Password: ${WG_EASY_ADMIN_PASSWORD}"
  log "Stack directory: ${STACK_DIR}"
}

main "$@"
