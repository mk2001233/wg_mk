#!/usr/bin/env bash
set -Eeuo pipefail

OS_KERNEL="$(uname -s)"
case "$OS_KERNEL" in
  Darwin) PLATFORM=darwin ;;
  Linux)  PLATFORM=linux ;;
  *)      printf '[wg-show] ERROR: Unsupported platform: %s. This script supports macOS and Linux.\n' "$OS_KERNEL" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

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

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Show local WireGuard status on macOS and Linux.

The script prints:
  - active WireGuard interfaces from wg(8)
  - the WireGuard IPv4 and IPv6 addresses currently bound to those interfaces
  - discovered wg-quick "up" targets from running processes
  - the raw wg show output

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

ensure_cli_tools() {
  command -v wg >/dev/null 2>&1 || die "Required command not found: wg"
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

show_status() {
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
  ensure_cli_tools
  show_status
}

main "$@"
