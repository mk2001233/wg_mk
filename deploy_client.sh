#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
TARGET_DIR="${WG_MACOS_CONFIG_DIR:-$HOME/.config/wireguard}"
TUNNEL_NAME=""
CONFIG_FILE=""
CONFIG_BASE64=""
WG_EASY_API_URL="${WG_EASY_API_URL:-}"
WG_EASY_API_USER="${WG_EASY_API_USER:-}"
WG_EASY_API_PASSWORD="${WG_EASY_API_PASSWORD:-}"
WG_EASY_CLIENT_ID=""
WG_EASY_CLIENT_NAME=""
WG_EASY_API_INSECURE_TLS=0
FETCHED_WG_EASY_TMP=""
FETCHED_WG_EASY_CLIENT_NAME=""
INSTALL_TOOLS=0
BRING_UP=0
BRING_DOWN=0
SHOW_STATUS=0
FORCE=0
PRINT_PATH=0

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

Write a macOS WireGuard client config from a wg-easy-generated .conf file,
optionally fetch it directly from a wg-easy server or create it there first,
optionally install CLI tools via Homebrew, and optionally bring the tunnel up.

With no arguments, the script defaults to:
  --tunnel-name MaxdeMacBook-Ai --up

Config input:
  --config-file PATH        Read client config from a .conf file
  --config-base64 STRING    Read client config from a base64-encoded string
                            If neither option is set, the script reads config from stdin
  --wg-easy-url URL         Fetch the config from this wg-easy base URL
  --wg-easy-user USER       wg-easy API username
  --wg-easy-password PASS   wg-easy API password
  --wg-easy-client-id ID    Fetch a specific wg-easy client by numeric ID
  --wg-easy-client-name NAME
                            Fetch a specific wg-easy client by exact name, or
                            create it first if it does not exist yet.
                            Defaults to the local host name when omitted.
  --wg-easy-insecure-tls    Allow self-signed or otherwise invalid TLS certs

Config target:
  --tunnel-name NAME        Tunnel name; defaults to the config file basename,
                            except raw invocation defaults to MaxdeMacBook-Ai
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
  WG_EASY_API_PASSWORD='secret' ${SCRIPT_NAME} --wg-easy-url https://vpn.example.com:51821 --wg-easy-user admin --wg-easy-client-name macbook --up
  cat ./macbook.conf | ${SCRIPT_NAME} --tunnel-name homevpn --up
  ${SCRIPT_NAME} --tunnel-name homevpn --down
  ${SCRIPT_NAME} --status
EOF
}

log() {
  printf '[macos-wg] %s\n' "$*" >&2
}

die() {
  printf '[macos-wg] ERROR: %s\n' "$*" >&2
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is intended to run on macOS."
}

default_local_client_name() {
  local name=""

  if [[ "$(uname -s)" == "Darwin" ]]; then
    name="$(scutil --get LocalHostName 2>/dev/null || true)"
  fi

  if [[ -z "$name" ]]; then
    name="$(hostname 2>/dev/null || true)"
    name="${name%.local}"
  fi

  name="$(
    printf '%s' "$name" |
      tr '[:space:]' '-' |
      tr -cd '[:alnum:]._-'
  )"

  [[ -n "$name" ]] || die "Could not determine a default local client name."
  printf '%s\n' "$name"
}

ensure_brew() {
  command -v brew >/dev/null 2>&1 || die "Homebrew is required for tool installation. Install it from https://brew.sh"
}

ensure_python3() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for wg-easy API client handling."
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

  if (( ${#sanitized} > 15 )); then
    log "Tunnel name ${sanitized} is longer than 15 characters; truncating it for wg-quick compatibility."
    sanitized="${sanitized:0:15}"
  fi

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

have_wg_easy_fetch() {
  [[ -n "$WG_EASY_API_URL$WG_EASY_API_USER$WG_EASY_API_PASSWORD$WG_EASY_CLIENT_ID$WG_EASY_CLIENT_NAME" ]]
}

validate_config_file() {
  local path=$1

  grep -q '^\[Interface\]' "$path" || die "Config is missing an [Interface] section."
  grep -q '^\[Peer\]' "$path" || die "Config is missing a [Peer] section."
}

stdin_to_temp() {
  local tmp=$1
  local first_byte=""

  [[ -t 0 ]] && return 1

  # Avoid treating an attached-but-empty stdin pipe as a config source.
  IFS= read -r -n 1 -t 0 first_byte || return 1
  printf '%s' "$first_byte" >"$tmp"
  cat >>"$tmp"
}

read_config_to_temp() {
  local tmp
  tmp="$(mktemp)"

  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    cat "$CONFIG_FILE" >"$tmp"
  elif [[ -n "$CONFIG_BASE64" ]]; then
    printf '%s' "$CONFIG_BASE64" | decode_base64 >"$tmp" 2>/dev/null || die "Could not decode --config-base64 input."
  elif stdin_to_temp "$tmp"; then
    :
  else
    rm -f "$tmp"
    die "Provide --config-file, --config-base64, or pipe a config on stdin."
  fi

  tr -d '\r' <"$tmp" >"${tmp}.lf"
  mv "${tmp}.lf" "$tmp"

  validate_config_file "$tmp"

  printf '%s\n' "$tmp"
}

curl_wg_easy() {
  local -a args
  args=(--fail --silent --show-error --user "${WG_EASY_API_USER}:${WG_EASY_API_PASSWORD}")

  if [[ "$WG_EASY_API_INSECURE_TLS" -eq 1 ]]; then
    args+=(-k)
  fi

  curl "${args[@]}" "$@"
}

list_wg_easy_clients_json() {
  curl_wg_easy "${WG_EASY_API_URL}/api/client" ||
    die "wg-easy client list request failed. Check the URL, credentials, and make sure 2FA is disabled for API use."
}

create_wg_easy_client_json() {
  local payload response client_id

  payload="$(
    python3 - "$WG_EASY_CLIENT_NAME" <<'PY'
import json
import sys

print(json.dumps({"name": sys.argv[1], "expiresAt": None}))
PY
  )"

  log "Creating wg-easy client ${WG_EASY_CLIENT_NAME}" >&2
  response="$(
    curl_wg_easy \
      --header 'Content-Type: application/json' \
      --data "$payload" \
      "${WG_EASY_API_URL}/api/client"
  )" || die "wg-easy client creation failed. Check the URL, credentials, and make sure the account can create clients."

  client_id="$(
    printf '%s' "$response" |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["clientId"])'
  )" || die "Could not parse the wg-easy client creation response."

  curl_wg_easy "${WG_EASY_API_URL}/api/client/${client_id}" ||
    die "wg-easy client creation succeeded but the follow-up lookup for client ${client_id} failed."
}

find_wg_easy_client_json_by_name() {
  local clients_json=$1

  WG_EASY_CLIENTS_JSON="$clients_json" python3 - "$WG_EASY_CLIENT_NAME" <<'PY'
import json
import os
import sys

target = sys.argv[1]
clients = json.loads(os.environ["WG_EASY_CLIENTS_JSON"])
matches = [client for client in clients if client.get("name") == target]

if not matches:
    print("__WG_EASY_MISSING__")
    sys.exit(0)

if len(matches) > 1:
    print("__WG_EASY_DUPLICATE__")
    sys.exit(0)

json.dump(matches[0], sys.stdout)
PY
}

resolve_wg_easy_client_json() {
  local response="" client_json=""

  WG_EASY_API_URL="${WG_EASY_API_URL%/}"

  if [[ -n "$WG_EASY_CLIENT_ID" ]]; then
    if ! response="$(curl_wg_easy "${WG_EASY_API_URL}/api/client/${WG_EASY_CLIENT_ID}")"; then
      die "wg-easy client lookup failed. Check the URL, credentials, client ID, and make sure 2FA is disabled for API use."
    fi
    printf '%s\n' "$response"
    return 0
  fi

  response="$(list_wg_easy_clients_json)"
  client_json="$(find_wg_easy_client_json_by_name "$response")" ||
    die "Could not parse the wg-easy client list."

  case "$client_json" in
    "__WG_EASY_MISSING__")
      create_wg_easy_client_json
    ;;
    "__WG_EASY_DUPLICATE__")
      die "Multiple wg-easy clients named ${WG_EASY_CLIENT_NAME} were found. Use --wg-easy-client-id instead."
    ;;
    *)
      printf '%s\n' "$client_json"
    ;;
  esac
}

fetch_wg_easy_config_to_temp() {
  local tmp client_json client_id client_name
  tmp="$(mktemp)"
  ensure_python3

  if ! client_json="$(resolve_wg_easy_client_json)"; then
    rm -f "$tmp"
    die "Could not resolve the requested wg-easy client."
  fi

  client_id="$(printf '%s' "$client_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
  client_name="$(printf '%s' "$client_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])')"

  if ! curl_wg_easy "${WG_EASY_API_URL}/api/client/${client_id}/configuration" >"$tmp"; then
    rm -f "$tmp"
    die "wg-easy client configuration download failed. Check the URL, credentials, client permissions, and make sure 2FA is disabled for API use."
  fi

  tr -d '\r' <"$tmp" >"${tmp}.lf"
  mv "${tmp}.lf" "$tmp"
  validate_config_file "$tmp"

  FETCHED_WG_EASY_TMP="$tmp"
  FETCHED_WG_EASY_CLIENT_NAME="$client_name"
  if [[ -z "$TUNNEL_NAME" ]]; then
    TUNNEL_NAME="$(sanitize_tunnel_name "$client_name")"
  fi

  log "Fetched wg-easy config for client ${client_name} (${client_id})" >&2
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
    if [[ "$(uname -s)" == "Darwin" ]] && ! sudo -n true >/dev/null 2>&1; then
      log "Skipping wg-quick validation because passwordless sudo is unavailable in this shell."
    else
      WG_QUICK_USERSPACE_IMPLEMENTATION="${WG_QUICK_USERSPACE_IMPLEMENTATION:-$(command -v wireguard-go || true)}" \
        wg-quick strip "$dst" >/dev/null || die "Saved config failed wg-quick validation."
    fi
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
      --wg-easy-url)
        WG_EASY_API_URL=${2:-}
        shift 2
        ;;
      --wg-easy-user)
        WG_EASY_API_USER=${2:-}
        shift 2
        ;;
      --wg-easy-password)
        WG_EASY_API_PASSWORD=${2:-}
        shift 2
        ;;
      --wg-easy-client-id)
        WG_EASY_CLIENT_ID=${2:-}
        shift 2
        ;;
      --wg-easy-client-name)
        WG_EASY_CLIENT_NAME=${2:-}
        shift 2
        ;;
      --wg-easy-insecure-tls)
        WG_EASY_API_INSECURE_TLS=1
        shift
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
  local fetch_count=0

  count=$((count + BRING_UP))
  count=$((count + BRING_DOWN))
  count=$((count + SHOW_STATUS))

  if (( count > 1 )); then
    die "Use at most one of --up, --down, or --status."
  fi

  if [[ -n "$CONFIG_FILE" && -n "$CONFIG_BASE64" ]]; then
    die "Use only one of --config-file or --config-base64."
  fi

  if (( SHOW_STATUS == 1 )) && [[ -n "$CONFIG_FILE$CONFIG_BASE64$TUNNEL_NAME" ]]; then
    die "--status does not take config input or tunnel name."
  fi

  if have_wg_easy_fetch; then
    [[ -n "$WG_EASY_API_URL" ]] || die "--wg-easy-url is required for automatic fetch."
    [[ -n "$WG_EASY_API_USER" ]] || die "--wg-easy-user is required for automatic fetch."
    [[ -n "$WG_EASY_API_PASSWORD" ]] || die "Set --wg-easy-password or WG_EASY_API_PASSWORD for automatic fetch."

    if [[ -z "$WG_EASY_CLIENT_ID" && -z "$WG_EASY_CLIENT_NAME" ]]; then
      WG_EASY_CLIENT_NAME="$(default_local_client_name)"
    fi

    if [[ -n "$WG_EASY_CLIENT_ID" ]]; then
      fetch_count=$((fetch_count + 1))
      [[ "$WG_EASY_CLIENT_ID" =~ ^[0-9]+$ ]] || die "--wg-easy-client-id must be numeric."
    fi

    if [[ -n "$WG_EASY_CLIENT_NAME" ]]; then
      fetch_count=$((fetch_count + 1))
    fi

    if (( fetch_count != 1 )); then
      die "Use exactly one of --wg-easy-client-id or --wg-easy-client-name."
    fi

    if [[ -n "$CONFIG_FILE$CONFIG_BASE64" ]]; then
      die "Use either local config input or wg-easy fetch options, not both."
    fi

    if (( SHOW_STATUS == 1 || BRING_DOWN == 1 )); then
      die "wg-easy fetch options can only be used for saving a config or bringing it up."
    fi
  fi
}

main() {
  local tmp_config=""
  local cfg_path=""
  local raw_defaults=0

  require_macos
  if (( $# == 0 )); then
    raw_defaults=1
  fi
  parse_args "$@"
  if (( raw_defaults == 1 )); then
    TUNNEL_NAME="MaxdeMacBook-Ai"
    BRING_UP=1
    log "No arguments supplied; defaulting to --tunnel-name ${TUNNEL_NAME} --up"
  fi
  validate_actions

  if (( SHOW_STATUS == 1 )); then
    show_status
    exit 0
  fi

  if have_wg_easy_fetch; then
    fetch_wg_easy_config_to_temp
    tmp_config="$FETCHED_WG_EASY_TMP"
    trap 'rm -f "${tmp_config:-}"' EXIT
    if (( INSTALL_TOOLS == 1 || BRING_UP == 1 )); then
      ensure_cli_tools
    fi
    write_config "$tmp_config"
    cfg_path="$(existing_config_or_die)"
  elif [[ -n "$CONFIG_FILE" || -n "$CONFIG_BASE64" ]]; then
    tmp_config="$(read_config_to_temp)"
    trap 'rm -f "${tmp_config:-}"' EXIT
    if (( INSTALL_TOOLS == 1 || BRING_UP == 1 )); then
      ensure_cli_tools
    fi
    write_config "$tmp_config"
    cfg_path="$(existing_config_or_die)"
  else
    if tmp_config="$(read_config_to_temp 2>/dev/null)"; then
      trap 'rm -f "${tmp_config:-}"' EXIT
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
