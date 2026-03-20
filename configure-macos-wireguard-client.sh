#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
TARGET_DIR="${WG_MACOS_CONFIG_DIR:-$HOME/.config/wireguard}"
TUNNEL_NAME=""
CONFIG_FILE=""
CONFIG_BASE64=""
INSTALL_TOOLS=0
BRING_UP=0
BRING_DOWN=0
SHOW_STATUS=0
FORCE=0
PRINT_PATH=0

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Write a macOS WireGuard client config from a wg-easy-generated .conf file,
optionally install CLI tools via Homebrew, and optionally bring the tunnel up.

Config input:
  --config-file PATH        Read client config from a .conf file
  --config-base64 STRING    Read client config from a base64-encoded string
                            If neither option is set, the script reads config from stdin

Config target:
  --tunnel-name NAME        Tunnel name; defaults to the config file basename
  --target-dir DIR          Directory for saved configs
  --force                   Overwrite an existing target config
  --print-config-path       Print the final config path after writing/resolving it

Actions:
  --install-tools           Install wireguard-tools with Homebrew if needed
  --up                      Bring the tunnel up after writing or from an existing config
  --down                    Bring an existing tunnel down
  --status                  Show current WireGuard status
  -h, --help                Show this help

Examples:
  ${SCRIPT_NAME} --config-file ./macbook.conf --install-tools --up
  ${SCRIPT_NAME} --config-file ./macbook.conf --tunnel-name homevpn
  ${SCRIPT_NAME} --config-base64 "\$(base64 < ./macbook.conf | tr -d '\n')" --tunnel-name homevpn
  cat ./macbook.conf | ${SCRIPT_NAME} --tunnel-name homevpn --up
  ${SCRIPT_NAME} --tunnel-name homevpn --down
  ${SCRIPT_NAME} --status
EOF
}

log() {
  printf '[macos-wg] %s\n' "$*"
}

die() {
  printf '[macos-wg] ERROR: %s\n' "$*" >&2
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is intended to run on macOS."
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew is required for tool installation. Install it from https://brew.sh"
}

decode_base64() {
  local payload
  payload="$(cat)"

  if printf '%s' "$payload" | base64 -D 2>/dev/null; then
    return 0
  fi

  if printf '%s' "$payload" | base64 --decode 2>/dev/null; then
    return 0
  fi

  die "Could not decode base64 input with the local base64 utility."
}

ensure_cli_tools() {
  if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 && command -v wireguard-go >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$INSTALL_TOOLS" -ne 1 ]]; then
    die "wireguard-tools are not available. Re-run with --install-tools or install them manually with Homebrew."
  fi

  ensure_brew
  log "Installing wireguard-tools with Homebrew"
  brew install wireguard-tools
  command -v wg >/dev/null 2>&1 || die "wg was not found after Homebrew installation."
  command -v wg-quick >/dev/null 2>&1 || die "wg-quick was not found after Homebrew installation."
  command -v wireguard-go >/dev/null 2>&1 || die "wireguard-go was not found after Homebrew installation."
}

sanitize_tunnel_name() {
  local raw=$1
  local sanitized

  sanitized="$(printf '%s' "$raw" | tr '[:space:]' '-' | tr -cd '[:alnum:]._-' )"
  [[ -n "$sanitized" ]] || die "Tunnel name resolved to an empty value."
  printf '%s\n' "$sanitized"
}

resolve_tunnel_name() {
  if [[ -n "$TUNNEL_NAME" ]]; then
    TUNNEL_NAME="$(sanitize_tunnel_name "$TUNNEL_NAME")"
    return 0
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    TUNNEL_NAME="$(sanitize_tunnel_name "$(basename "${CONFIG_FILE%.conf}")")"
    return 0
  fi

  die "--tunnel-name is required when config is not being read from a file path."
}

target_config_path() {
  printf '%s/%s.conf\n' "$TARGET_DIR" "$TUNNEL_NAME"
}

read_config_to_temp() {
  local tmp
  tmp="$(mktemp)"

  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    cat "$CONFIG_FILE" >"$tmp"
  elif [[ -n "$CONFIG_BASE64" ]]; then
    printf '%s' "$CONFIG_BASE64" | decode_base64 >"$tmp" 2>/dev/null || die "Could not decode --config-base64 input."
  elif [[ ! -t 0 ]]; then
    cat >"$tmp"
  else
    rm -f "$tmp"
    die "Provide --config-file, --config-base64, or pipe a config on stdin."
  fi

  tr -d '\r' <"$tmp" >"${tmp}.lf"
  mv "${tmp}.lf" "$tmp"

  grep -q '^\[Interface\]' "$tmp" || die "Config is missing an [Interface] section."
  grep -q '^\[Peer\]' "$tmp" || die "Config is missing a [Peer] section."

  printf '%s\n' "$tmp"
}

write_config() {
  local src=$1
  local dst

  resolve_tunnel_name
  dst="$(target_config_path)"

  install -d -m 700 "$TARGET_DIR"

  if [[ -e "$dst" && "$FORCE" -ne 1 ]]; then
    die "Target config already exists: $dst. Re-run with --force to overwrite it."
  fi

  cp "$src" "$dst"
  chmod 600 "$dst"

  if command -v wg-quick >/dev/null 2>&1; then
    WG_QUICK_USERSPACE_IMPLEMENTATION="${WG_QUICK_USERSPACE_IMPLEMENTATION:-$(command -v wireguard-go || true)}" \
      wg-quick strip "$dst" >/dev/null || die "Saved config failed wg-quick validation."
  fi

  log "Saved config to $dst"
  if [[ "$PRINT_PATH" -eq 1 ]]; then
    printf '%s\n' "$dst"
  fi
}

existing_config_or_die() {
  local dst
  resolve_tunnel_name
  dst="$(target_config_path)"
  [[ -f "$dst" ]] || die "Config does not exist: $dst"
  printf '%s\n' "$dst"
}

run_wg_quick() {
  local action=$1
  local cfg=$2
  local wg_go

  ensure_cli_tools
  wg_go="${WG_QUICK_USERSPACE_IMPLEMENTATION:-$(command -v wireguard-go || true)}"
  [[ -n "$wg_go" ]] || die "wireguard-go is required on macOS but was not found."

  sudo env PATH="$PATH" WG_QUICK_USERSPACE_IMPLEMENTATION="$wg_go" wg-quick "$action" "$cfg"
}

show_status() {
  ensure_cli_tools
  sudo env PATH="$PATH" wg show
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-file)
        CONFIG_FILE=${2:-}
        shift 2
        ;;
      --config-base64)
        CONFIG_BASE64=${2:-}
        shift 2
        ;;
      --tunnel-name)
        TUNNEL_NAME=${2:-}
        shift 2
        ;;
      --target-dir)
        TARGET_DIR=${2:-}
        shift 2
        ;;
      --install-tools)
        INSTALL_TOOLS=1
        shift
        ;;
      --up)
        BRING_UP=1
        shift
        ;;
      --down)
        BRING_DOWN=1
        shift
        ;;
      --status)
        SHOW_STATUS=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --print-config-path)
        PRINT_PATH=1
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

validate_actions() {
  local count=0

  (( count += BRING_UP ))
  (( count += BRING_DOWN ))
  (( count += SHOW_STATUS ))

  if (( count > 1 )); then
    die "Use at most one of --up, --down, or --status."
  fi

  if [[ -n "$CONFIG_FILE" && -n "$CONFIG_BASE64" ]]; then
    die "Use only one of --config-file or --config-base64."
  fi

  if (( SHOW_STATUS == 1 )) && [[ -n "$CONFIG_FILE$CONFIG_BASE64$TUNNEL_NAME" ]]; then
    die "--status does not take config input or tunnel name."
  fi
}

main() {
  local tmp_config=""
  local cfg_path=""

  require_macos
  parse_args "$@"
  validate_actions

  if (( SHOW_STATUS == 1 )); then
    show_status
    exit 0
  fi

  if [[ -n "$CONFIG_FILE" || -n "$CONFIG_BASE64" || ! -t 0 ]]; then
    tmp_config="$(read_config_to_temp)"
    trap 'rm -f "$tmp_config"' EXIT
    if (( INSTALL_TOOLS == 1 || BRING_UP == 1 )); then
      ensure_cli_tools
    fi
    write_config "$tmp_config"
    cfg_path="$(existing_config_or_die)"
  else
    cfg_path="$(existing_config_or_die)"
    if (( INSTALL_TOOLS == 1 || BRING_UP == 1 || BRING_DOWN == 1 )); then
      ensure_cli_tools
    fi
    if (( PRINT_PATH == 1 )); then
      printf '%s\n' "$cfg_path"
    fi
  fi

  if (( BRING_UP == 1 )); then
    run_wg_quick up "$cfg_path"
    log "Tunnel is up: $cfg_path"
    exit 0
  fi

  if (( BRING_DOWN == 1 )); then
    run_wg_quick down "$cfg_path"
    log "Tunnel is down: $cfg_path"
    exit 0
  fi

  log "Next step: import $cfg_path into the official WireGuard macOS app, or re-run with --up to use wg-quick."
}

main "$@"
