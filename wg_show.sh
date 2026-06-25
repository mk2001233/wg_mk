#!/usr/bin/env bash
set -Eeuo pipefail

OS_KERNEL="$(uname -s)"
case "$OS_KERNEL" in
  Darwin) PLATFORM=darwin ;;
  Linux)  PLATFORM=linux ;;
  *)      printf '[wg-show] ERROR: Unsupported platform: %s. This script supports macOS and Linux.\n' "$OS_KERNEL" >&2; exit 1 ;;
esac

# Resolve robustly even when piped via `curl ... | bash` (BASH_SOURCE unset).
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || true)"
[[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR="$(pwd)"
SCRIPT_NAME="$(basename "${SCRIPT_SOURCE}")"

if [[ -d "${SCRIPT_DIR}/bin" ]]; then
  PATH="${SCRIPT_DIR}/bin:${PATH}"
  export PATH
fi

if [[ -d "${SCRIPT_DIR}/lib" ]]; then
  if [[ "$PLATFORM" == "darwin" ]]; then
    DYLD_LIBRARY_PATH="${SCRIPT_DIR}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
    export DYLD_LIBRARY_PATH
  else
    LD_LIBRARY_PATH="${SCRIPT_DIR}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export LD_LIBRARY_PATH
  fi
fi

MANAGED_TUNNEL_NAME="wg_mk"
TARGET_DIR="${WG_CLIENT_CONFIG_DIR:-${WG_MACOS_CONFIG_DIR:-${HOME:-}/.config/wireguard}}"
MANAGED_CONFIG="${TARGET_DIR}/${MANAGED_TUNNEL_NAME}.conf"
STARTUP_LABEL="com.mk.wg_mk.client"
if [[ "$PLATFORM" == "darwin" ]]; then
  STARTUP_PLIST="/Library/LaunchDaemons/${STARTUP_LABEL}.plist"
  STARTUP_SYS_CONFIG="/usr/local/etc/wireguard/${MANAGED_TUNNEL_NAME}.conf"
else
  STARTUP_SERVICE="/etc/systemd/system/${STARTUP_LABEL}.service"
  STARTUP_SYS_CONFIG="/etc/wireguard/${MANAGED_TUNNEL_NAME}.conf"
fi

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Show WireGuard status on macOS and Linux. Shows whichever applies to this host:

  Server (if a wg-easy container is present):
    - container status, public host / ports / UI URL (from ${WG_EASY_STACK_DIR}/.env)
    - the server-side wg output from inside the container (peers / clients)

  Client (if the managed ${MANAGED_TUNNEL_NAME} tunnel is configured here):
    - tunnel up/down state and live wg output (handshake, transfer, endpoint)
    - the saved config's non-secret fields (Address, Endpoint, AllowedIPs, …)
    - boot-persistence state (launchd on macOS, systemd on Linux)

  Plus the generic local view: active interfaces, their addresses, wg-quick
  targets, and the raw wg show output.

Run as your normal user; the script uses sudo only where needed.

Options:
  -h, --help  Show this help
EOF
}

log() {
  printf '[wg-show] %s\n' "$*"
}

die() {
  printf '[wg-show] ERROR: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

HAS_WG=0
WG_EASY_STACK_DIR="${WG_EASY_STACK_DIR:-/opt/wg-easy}"
WG_EASY_CONTAINER="wg-easy"

detect_tools() {
  if command_exists wg; then HAS_WG=1; else HAS_WG=0; fi
}

run_docker() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

is_wg_easy_server() {
  command_exists docker || return 1
  run_docker inspect "$WG_EASY_CONTAINER" >/dev/null 2>&1
}

server_env_val() {
  sudo sed -nE "s/^$1=(.*)\$/\1/p" "${WG_EASY_STACK_DIR}/.env" 2>/dev/null || true
}

show_server() {
  local status host vpn ui user wgout

  log "wg-easy server:"
  status="$(run_docker inspect --format '{{.State.Status}}{{if .State.Health}} (health: {{.State.Health.Status}}){{end}}' "$WG_EASY_CONTAINER" 2>/dev/null || true)"
  log "  Container: ${status:-unknown}"

  host="$(server_env_val WG_EASY_PUBLIC_HOST)"
  vpn="$(server_env_val WG_EASY_VPN_PORT)"
  ui="$(server_env_val WG_EASY_UI_PORT)"
  user="$(server_env_val WG_EASY_ADMIN_USER)"
  if [[ -n "$host" ]]; then
    log "  Public host: ${host}"
    [[ -n "$vpn" ]] && log "  WireGuard endpoint: ${host}:${vpn}/udp"
    [[ -n "$ui" ]] && log "  Web UI: http://${host}:${ui}"
  fi
  [[ -n "$user" ]] && log "  Admin user: ${user}"

  log "  Server WireGuard (inside container):"
  wgout="$(run_docker exec "$WG_EASY_CONTAINER" wg show 2>/dev/null || true)"
  if [[ -n "$wgout" ]]; then
    printf '%s\n' "$wgout" | sed 's/^/    /'
  else
    log "    (could not query wg inside the container)"
  fi
}

# Print only non-secret config fields (never PrivateKey/PublicKey/PresharedKey).
show_config_summary() {
  local cfg=$1 line
  local -a reader=(cat)
  [[ -r "$cfg" ]] || reader=(sudo cat)
  while IFS= read -r line; do
    case "$line" in
      Address*|DNS*|Endpoint*|AllowedIPs*|PersistentKeepalive*|ListenPort*|MTU*)
        log "    ${line}"
        ;;
    esac
  done < <("${reader[@]}" "$cfg" 2>/dev/null || true)
}

show_startup_status() {
  log "  Boot persistence:"
  if [[ "$PLATFORM" == "darwin" ]]; then
    if [[ -f "$STARTUP_PLIST" ]]; then
      log "    Installed: yes (${STARTUP_PLIST})"
      if sudo launchctl print "system/${STARTUP_LABEL}" >/dev/null 2>&1; then
        log "    launchd job: loaded"
      else
        log "    launchd job: not loaded"
      fi
    else
      log "    Installed: no"
    fi
  else
    if [[ -f "$STARTUP_SERVICE" ]]; then
      log "    Installed: yes (${STARTUP_SERVICE})"
      if sudo systemctl is-enabled "${STARTUP_LABEL}.service" >/dev/null 2>&1; then
        log "    systemd: enabled"
      else
        log "    systemd: not enabled"
      fi
      if sudo systemctl is-active "${STARTUP_LABEL}.service" >/dev/null 2>&1; then
        log "    systemd: active"
      else
        log "    systemd: inactive"
      fi
    else
      log "    Installed: no"
    fi
  fi
}

managed_tunnel_up() {
  (( HAS_WG == 1 )) && sudo env PATH="$PATH" wg show "$MANAGED_TUNNEL_NAME" >/dev/null 2>&1
}

has_client() {
  [[ -f "$MANAGED_CONFIG" ]] && return 0
  managed_tunnel_up
}

show_client() {
  log "Managed client tunnel (${MANAGED_TUNNEL_NAME}):"
  if managed_tunnel_up; then
    log "  State: UP"
    sudo env PATH="$PATH" wg show "$MANAGED_TUNNEL_NAME" 2>/dev/null | sed 's/^/    /'
  else
    log "  State: down"
  fi
  if [[ -f "$MANAGED_CONFIG" ]]; then
    log "  Config: ${MANAGED_CONFIG}"
    show_config_summary "$MANAGED_CONFIG"
  else
    log "  Config: not found (${MANAGED_CONFIG})"
  fi
  show_startup_status
}

active_interfaces() {
  sudo env PATH="$PATH" wg show interfaces 2>/dev/null || true
}

print_interfaces() {
  local interfaces=$1
  local iface

  for iface in $interfaces; do
    printf '%s\n' "$iface"
  done
}

discover_wg_quick_targets() {
  ps -axo command= |
    awk '
      {
        for (i = 1; i <= NF - 2; i++) {
          n = split($i, parts, "/")
          if (parts[n] == "wg-quick" && $(i + 1) == "up") {
            print $(i + 2)
          }
        }
      }
    ' |
    awk 'NF && !seen[$0]++'
}

show_interface_addresses() {
  local iface=$1

  if [[ "$PLATFORM" == "darwin" ]]; then
    ifconfig "$iface" 2>/dev/null |
      awk '
        $1 == "inet" { print "wireguard-ipv4 " $2; next }
        $1 == "inet6" && $2 !~ /^fe80:/ { print "wireguard-ipv6 " $2; next }
        $1 == "inet6" && $2 ~ /^fe80:/ { print "link-local-ipv6 " $2 }
      '
  else
    ip addr show "$iface" 2>/dev/null |
      awk '
        $1 == "inet"  { split($2, a, "/"); print "wireguard-ipv4 " a[1]; next }
        $1 == "inet6" && $2 !~ /^fe80:/ { split($2, a, "/"); print "wireguard-ipv6 " a[1]; next }
        $1 == "inet6" && $2 ~ /^fe80:/ { split($2, a, "/"); print "link-local-ipv6 " a[1] }
      '
  fi
}

show_generic() {
  local interfaces
  local targets
  local iface

  interfaces="$(active_interfaces)"
  if [[ -z "$interfaces" ]]; then
    log "No active WireGuard interfaces found."
  else
    log "Active WireGuard interfaces:"
    while IFS= read -r iface; do
      [[ -n "$iface" ]] || continue
      log "  ${iface}"
      while IFS= read -r addr; do
        [[ -n "$addr" ]] || continue
        case "$addr" in
          wireguard-ipv4\ *)
            log "    WireGuard interface IP: ${addr#wireguard-ipv4 }"
            ;;
          wireguard-ipv6\ *)
            log "    WireGuard interface IPv6: ${addr#wireguard-ipv6 }"
            ;;
          link-local-ipv6\ *)
            log "    Link-local IPv6: ${addr#link-local-ipv6 }"
            ;;
          *)
            log "    ${addr}"
            ;;
        esac
      done < <(show_interface_addresses "$iface")
    done < <(print_interfaces "$interfaces")
  fi

  targets="$(discover_wg_quick_targets || true)"
  if [[ -z "$targets" ]]; then
    log "No running wg-quick up targets were discovered."
  else
    log "Discovered wg-quick up targets:"
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      log "  ${target}"
    done <<<"$targets"
  fi

  log "Raw wg show output:"
  sudo env PATH="$PATH" wg show || true
}

show_status() {
  local shown=0

  if is_wg_easy_server; then
    show_server
    shown=1
    log ""
  fi

  if has_client; then
    show_client
    shown=1
    log ""
  fi

  if (( HAS_WG == 1 )); then
    show_generic
    shown=1
  fi

  if (( shown == 0 )); then
    log "No wg-easy server and no managed ${MANAGED_TUNNEL_NAME} client found on this host."
    (( HAS_WG == 0 )) && log "WireGuard tools (wg) are not installed here."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  detect_tools
  show_status
}

main "$@"
