#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
MANAGED_STARTUP_LABEL="com.mk.wg_mk.client"
MANAGED_STARTUP_PLIST="/Library/LaunchDaemons/${MANAGED_STARTUP_LABEL}.plist"
MANAGED_STARTUP_CONFIG="/usr/local/etc/wireguard/wg_mk.conf"
DRY_RUN=0
SHOW_STATUS=0
KEEP_STARTUP=0

if [[ -d "${SCRIPT_DIR}/bin" ]]; then
  PATH="${SCRIPT_DIR}/bin:${PATH}"
  export PATH
fi

if [[ -d "${SCRIPT_DIR}/lib" ]]; then
  DYLD_LIBRARY_PATH="${SCRIPT_DIR}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
  export DYLD_LIBRARY_PATH
fi

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Stop all active local WireGuard interfaces on macOS.

The script:
  1. Detects active WireGuard interfaces with wg(8)
  2. Finds matching wg-quick "up" targets from running processes
  3. Runs wg-quick down for those targets
  4. Falls back to terminating wireguard-go and lingering wg-quick processes
  5. Removes the managed launchd startup job so wg_mk stays down after reboot

Options:
  --dry-run      Show what would be stopped without changing anything
  --keep-startup Keep the managed launchd startup job installed
  --status       Show active WireGuard interfaces and discovered wg-quick targets
  -h, --help     Show this help
EOF
}

log() {
  printf '[wg-stop-all] %s\n' "$*"
}

die() {
  printf '[wg-stop-all] ERROR: %s\n' "$*" >&2
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is intended to run on macOS."
}

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

run_env() {
  local -a env_args
  env_args=(env "PATH=${PATH}")

  if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    env_args+=("DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH}")
  fi

  "${env_args[@]}" "$@"
}

run_privileged() {
  if is_root; then
    "$@"
    return 0
  fi

  sudo "$@"
}

run_privileged_env() {
  if is_root; then
    run_env "$@"
    return 0
  fi

  local -a env_args
  env_args=(env "PATH=${PATH}")

  if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    env_args+=("DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH}")
  fi

  sudo "${env_args[@]}" "$@"
}

ensure_cli_tools() {
  command -v wg >/dev/null 2>&1 || die "Required command not found: wg"
  command -v wg-quick >/dev/null 2>&1 || die "Required command not found: wg-quick"
}

active_interfaces() {
  run_privileged_env wg show interfaces 2>/dev/null || true
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

discover_config_targets() {
  local dir conf

  for dir in \
    "$HOME/.config/wireguard" \
    /etc/wireguard \
    /usr/local/etc/wireguard \
    /opt/homebrew/etc/wireguard
  do
    [[ -d "$dir" ]] || continue
    for conf in "$dir"/*.conf; do
      [[ -e "$conf" ]] || continue
      printf '%s\n' "$conf"
    done
  done |
    awk 'NF && !seen[$0]++'
}

startup_installed() {
  [[ -f "$MANAGED_STARTUP_PLIST" ]]
}

startup_config_present() {
  [[ -f "$MANAGED_STARTUP_CONFIG" ]]
}

startup_loaded() {
  run_privileged launchctl print "system/${MANAGED_STARTUP_LABEL}" >/dev/null 2>&1
}

show_status() {
  local interfaces
  local targets

  interfaces="$(active_interfaces)"
  if [[ -z "$interfaces" ]]; then
    log "No active WireGuard interfaces found."
  else
    log "Active WireGuard interfaces:"
    while IFS= read -r iface; do
      [[ -n "$iface" ]] || continue
      log "  ${iface}"
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

  if startup_installed || startup_config_present; then
    log "Managed startup support:"
    if startup_installed; then
      log "  launchd plist: ${MANAGED_STARTUP_PLIST}"
    else
      log "  launchd plist: missing"
    fi

    if startup_config_present; then
      log "  startup config: ${MANAGED_STARTUP_CONFIG}"
    else
      log "  startup config: missing"
    fi

    if startup_loaded; then
      log "  launchd job loaded: yes"
    else
      log "  launchd job loaded: no"
    fi
  else
    log "Managed startup support is not installed."
  fi
}

run_wg_quick_down() {
  local target=$1

  if (( DRY_RUN == 1 )); then
    log "Would run: sudo wg-quick down ${target}"
    return 0
  fi

  if run_privileged_env wg-quick down "$target"; then
    log "Stopped: ${target}"
    return 0
  fi

  log "wg-quick down failed for ${target}"
  return 1
}

run_targets_from_file() {
  local file=$1
  local target

  [[ -s "$file" ]] || return 0

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    run_wg_quick_down "$target" || true
  done <"$file"
}

fallback_stop_processes() {
  if (( DRY_RUN == 1 )); then
    log "Would run fallback: sudo pkill -x wireguard-go"
    log "Would run fallback: sudo pkill -f 'wg-quick up '"
    return 0
  fi

  run_privileged pkill -x wireguard-go >/dev/null 2>&1 || true
  run_privileged pkill -f 'wg-quick up ' >/dev/null 2>&1 || true
  sleep 1
  log "Applied fallback process stop for wireguard-go and wg-quick."
}

disable_managed_startup() {
  if (( KEEP_STARTUP == 1 )); then
    return 0
  fi

  if ! startup_installed && ! startup_config_present; then
    log "No managed startup support is installed."
    return 0
  fi

  if (( DRY_RUN == 1 )); then
    if startup_installed; then
      log "Would remove startup plist: ${MANAGED_STARTUP_PLIST}"
    fi
    if startup_config_present; then
      log "Would remove startup config: ${MANAGED_STARTUP_CONFIG}"
    fi
    log "Would boot out launchd job: system/${MANAGED_STARTUP_LABEL}"
    return 0
  fi

  run_privileged launchctl bootout system "$MANAGED_STARTUP_PLIST" >/dev/null 2>&1 || true
  run_privileged rm -f "$MANAGED_STARTUP_PLIST"
  run_privileged rm -f "$MANAGED_STARTUP_CONFIG"
  log "Removed managed startup support."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --keep-startup)
        KEEP_STARTUP=1
        shift
        ;;
      --status)
        SHOW_STATUS=1
        shift
        ;;
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
  local before
  local after
  local proc_targets
  local config_targets
  local startup_present=0

  require_macos
  parse_args "$@"
  ensure_cli_tools

  if (( SHOW_STATUS == 1 )); then
    show_status
    exit 0
  fi

  if startup_installed || startup_config_present; then
    startup_present=1
  fi

  if (( DRY_RUN == 0 )); then
    run_privileged true
  fi

  before="$(active_interfaces)"
  if [[ -n "$before" ]]; then
    log "Active WireGuard interfaces before stop: ${before}"
  else
    log "No active WireGuard interfaces found."
  fi

  if [[ -z "$before" ]] && (( KEEP_STARTUP == 1 || startup_present == 0 )); then
    if (( KEEP_STARTUP == 1 )); then
      log "Managed startup support was left installed by request."
    fi
    exit 0
  fi

  proc_targets="$(mktemp)"
  config_targets="$(mktemp)"
  trap 'rm -f "${proc_targets:-}" "${config_targets:-}"' EXIT

  discover_wg_quick_targets >"$proc_targets"
  if [[ -s "$proc_targets" ]]; then
    log "Stopping discovered wg-quick targets."
    run_targets_from_file "$proc_targets"
  else
    log "No wg-quick process targets were discovered."
  fi

  after="$(active_interfaces)"
  if [[ -n "$after" ]]; then
    log "WireGuard interfaces still active after the first pass: ${after}"
    discover_config_targets >"$config_targets"
    if [[ -s "$config_targets" ]]; then
      log "Trying standard WireGuard config paths."
      run_targets_from_file "$config_targets"
    fi
  fi

  after="$(active_interfaces)"
  if [[ -n "$after" ]]; then
    log "WireGuard interfaces still active after wg-quick down attempts: ${after}"
    fallback_stop_processes
  fi

  disable_managed_startup

  if (( DRY_RUN == 1 )); then
    log "Dry run complete."
    exit 0
  fi

  after="$(active_interfaces)"
  if [[ -n "$after" ]]; then
    die "Some WireGuard interfaces are still active: ${after}"
  fi

  if (( KEEP_STARTUP == 1 )); then
    log "All WireGuard interfaces are down. Managed startup support was kept."
  else
    log "All WireGuard interfaces are down and managed startup support was removed."
  fi
}

main "$@"
