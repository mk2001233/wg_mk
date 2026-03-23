#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WG_EASY_TEST_URL="${WG_EASY_TEST_URL:-http://123.57.216.161:51821}"
WG_EASY_TEST_USER="${WG_EASY_TEST_USER:-admin}"
WG_EASY_TEST_PASSWORD="${WG_EASY_TEST_PASSWORD:-71082aaa348e3b03d45bf7f6a2c41ef18fe3}"
WG_EASY_TEST_MIN_CLIENTS="${WG_EASY_TEST_MIN_CLIENTS:-0}"
WG_EASY_TEST_CLIENT_ID="${WG_EASY_TEST_CLIENT_ID:-}"
WG_EASY_TEST_CLIENT_NAME="${WG_EASY_TEST_CLIENT_NAME:-}"
WG_EASY_TEST_INSECURE_TLS="${WG_EASY_TEST_INSECURE_TLS:-0}"

if [[ -d "${SCRIPT_DIR}/bin" ]]; then
  PATH="${SCRIPT_DIR}/bin:${PATH}"
  export PATH
fi

if [[ -d "${SCRIPT_DIR}/lib" ]]; then
  DYLD_LIBRARY_PATH="${SCRIPT_DIR}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
  export DYLD_LIBRARY_PATH
fi

log() {
  printf '[wg-easy-test] %s\n' "$*"
}

die() {
  printf '[wg-easy-test] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

default_interface() {
  route -n get default 2>/dev/null |
    awk '/interface:/{print $2; exit}'
}

local_intranet_ip() {
  local iface ip

  iface="$(default_interface)"
  if [[ -n "$iface" ]]; then
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s %s\n' "$iface" "$ip"
      return 0
    fi
  fi

  ifconfig |
    awk '
      /^[a-z0-9]+:/ { iface=$1; sub(/:$/, "", iface) }
      iface !~ /^(lo|utun)/ && $1 == "inet" { print iface, $2; exit }
    '
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

  [[ -n "$name" ]] || die "Could not determine the default local client name."
  printf '%s\n' "$name"
}

curl_ui() {
  local -a args
  args=(--fail --silent --show-error --location --max-time 8)

  if [[ "$WG_EASY_TEST_INSECURE_TLS" == "1" ]]; then
    args+=(-k)
  fi

  curl "${args[@]}" "$@"
}

curl_api() {
  local -a args
  args=(--fail --silent --show-error --location --max-time 8)

  if [[ "$WG_EASY_TEST_INSECURE_TLS" == "1" ]]; then
    args+=(-k)
  fi

  curl "${args[@]}" --user "${WG_EASY_TEST_USER}:${WG_EASY_TEST_PASSWORD}" "$@"
}

validate_inputs() {
  WG_EASY_TEST_URL="${WG_EASY_TEST_URL%/}"

  [[ -n "$WG_EASY_TEST_URL" ]] || die "WG_EASY_TEST_URL must not be empty."
  [[ -n "$WG_EASY_TEST_USER" ]] || die "WG_EASY_TEST_USER must not be empty."
  [[ -n "$WG_EASY_TEST_PASSWORD" ]] || die "WG_EASY_TEST_PASSWORD must not be empty."

  if ! [[ "$WG_EASY_TEST_MIN_CLIENTS" =~ ^[0-9]+$ ]]; then
    die "WG_EASY_TEST_MIN_CLIENTS must be an integer >= 0."
  fi

  if [[ -n "$WG_EASY_TEST_CLIENT_ID" && -n "$WG_EASY_TEST_CLIENT_NAME" ]]; then
    die "Set only one of WG_EASY_TEST_CLIENT_ID or WG_EASY_TEST_CLIENT_NAME."
  fi

  if [[ -n "$WG_EASY_TEST_CLIENT_ID" ]] && ! [[ "$WG_EASY_TEST_CLIENT_ID" =~ ^[0-9]+$ ]]; then
    die "WG_EASY_TEST_CLIENT_ID must be numeric."
  fi

  if [[ -z "$WG_EASY_TEST_CLIENT_ID" && -z "$WG_EASY_TEST_CLIENT_NAME" ]]; then
    WG_EASY_TEST_CLIENT_NAME="$(default_local_client_name)"
  fi
}

check_local_machine() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    log "Local macOS client checks skipped on non-Darwin host."
    return 0
  fi

  require_command wg
  require_command wg-quick
  require_command wireguard-go
  log "Local WireGuard client tools are installed."

  local intranet
  intranet="$(local_intranet_ip || true)"
  if [[ -n "$intranet" ]]; then
    log "Local intranet IP: ${intranet#* } (${intranet%% *})"
  else
    log "Local intranet IP: unavailable"
  fi

  if sudo -n true >/dev/null 2>&1; then
    local interfaces count
    interfaces="$(sudo env PATH="$PATH" wg show interfaces 2>/dev/null || true)"
    if [[ -n "$interfaces" ]]; then
      count="$(printf '%s\n' "$interfaces" | awk '{print NF}')"
    else
      count=0
    fi
    log "Local WireGuard interface count: ${count}"
  else
    log "Skipping local interface status check because passwordless sudo is unavailable."
  fi
}

check_ui() {
  local status
  status="$(
    curl_ui --head --write-out '%{http_code}' --output /dev/null \
      "${WG_EASY_TEST_URL}/login"
  )" || die "wg-easy UI check failed at ${WG_EASY_TEST_URL}/login"

  [[ "$status" == "200" ]] || die "wg-easy login page returned HTTP ${status}, expected 200."
  log "wg-easy login page reachable at ${WG_EASY_TEST_URL}/login"
}

fetch_clients_json() {
  curl_api "${WG_EASY_TEST_URL}/api/client" ||
    die "wg-easy API auth failed for ${WG_EASY_TEST_URL}/api/client"
}

count_clients() {
  WG_EASY_TEST_CLIENTS_JSON="$1" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["WG_EASY_TEST_CLIENTS_JSON"])
if not isinstance(data, list):
    raise SystemExit("Client response is not a JSON array")
print(len(data))
PY
}

resolve_client_id() {
  local clients_json=$1

  if [[ -n "$WG_EASY_TEST_CLIENT_ID" ]]; then
    printf '%s\n' "$WG_EASY_TEST_CLIENT_ID"
    return 0
  fi

  if [[ -z "$WG_EASY_TEST_CLIENT_NAME" ]]; then
    return 0
  fi

  WG_EASY_TEST_CLIENTS_JSON="$clients_json" python3 - "$WG_EASY_TEST_CLIENT_NAME" <<'PY'
import json
import os
import sys

target = sys.argv[1]
clients = json.loads(os.environ["WG_EASY_TEST_CLIENTS_JSON"])
matches = [client for client in clients if client.get("name") == target]

if not matches:
    print("__WG_EASY_MISSING__")
    sys.exit(0)

if len(matches) > 1:
    print("__WG_EASY_DUPLICATE__")
    sys.exit(0)

print(matches[0]["id"])
PY
}

check_optional_client_config() {
  local clients_json=$1
  local client_id tmp

  client_id="$(resolve_client_id "$clients_json")" || die "Could not resolve the requested test client."
  case "$client_id" in
    "__WG_EASY_MISSING__")
      die "No wg-easy client named ${WG_EASY_TEST_CLIENT_NAME} exists for this machine. Run ./deploy_client.sh with --wg-easy-url ${WG_EASY_TEST_URL} and --wg-easy-user ${WG_EASY_TEST_USER} to register it."
      ;;
    "__WG_EASY_DUPLICATE__")
      die "Multiple wg-easy clients named ${WG_EASY_TEST_CLIENT_NAME} exist. Set WG_EASY_TEST_CLIENT_ID to the intended client."
      ;;
    "")
      return 0
      ;;
  esac

  tmp="$(mktemp)"
  trap 'rm -f "${tmp:-}"' RETURN

  curl_api "${WG_EASY_TEST_URL}/api/client/${client_id}/configuration" >"$tmp" ||
    die "Client configuration download failed for client ${client_id}."

  grep -q '^\[Interface\]' "$tmp" || die "Downloaded config for client ${client_id} is missing [Interface]."
  grep -q '^\[Peer\]' "$tmp" || die "Downloaded config for client ${client_id} is missing [Peer]."
  log "Client configuration download ok for client ${client_id}"
}

main() {
  local clients_json client_count

  require_command curl
  require_command python3
  validate_inputs
  check_local_machine
  check_ui

  clients_json="$(fetch_clients_json)"
  client_count="$(count_clients "$clients_json")" ||
    die "Could not parse wg-easy client list."

  if (( client_count < WG_EASY_TEST_MIN_CLIENTS )); then
    die "wg-easy client count ${client_count} is below required minimum ${WG_EASY_TEST_MIN_CLIENTS}."
  fi

  log "wg-easy API auth ok; client count: ${client_count}"
  if [[ -n "$WG_EASY_TEST_CLIENT_NAME" ]]; then
    log "Expected client name: ${WG_EASY_TEST_CLIENT_NAME}"
  elif [[ -n "$WG_EASY_TEST_CLIENT_ID" ]]; then
    log "Expected client id: ${WG_EASY_TEST_CLIENT_ID}"
  fi
  check_optional_client_config "$clients_json"
  log "Deployment checks passed."
}

main "$@"
