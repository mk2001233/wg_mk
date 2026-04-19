#!/usr/bin/env bash
set -Eeuo pipefail

OS_KERNEL="$(uname -s)"
case "$OS_KERNEL" in
  Darwin) PLATFORM=darwin ;;
  Linux)  PLATFORM=linux ;;
  *)      printf '[wg-client] ERROR: Unsupported platform: %s. This script supports macOS and Linux.\n' "$OS_KERNEL" >&2; exit 1 ;;
esac

if [[ "$PLATFORM" == "darwin" && -d /opt/homebrew/bin ]]; then
  export PATH="/opt/homebrew/bin:$PATH"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
USER_HOME="${HOME:-}"
if [[ -z "$USER_HOME" ]]; then
  if [[ "$PLATFORM" == "darwin" ]]; then
    USER_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  else
    USER_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
  fi
fi
if [[ -z "$USER_HOME" ]]; then
  if [[ "$PLATFORM" == "darwin" ]]; then
    USER_HOME="/var/root"
  else
    USER_HOME="/root"
  fi
fi
TARGET_DIR="${WG_CLIENT_CONFIG_DIR:-${WG_MACOS_CONFIG_DIR:-$USER_HOME/.config/wireguard}}"
MANAGED_TUNNEL_NAME="wg_mk"
MANAGED_IPV4_PREFIX="10.8.0."
MANAGED_IPV4_CIDR="10.8.0.0/24"
MANAGED_ALLOWED_IPS="${MANAGED_IPV4_CIDR}"
MANAGED_IPV6_PREFIX="fd00:dead:beef:"
MANAGED_PERSISTENT_KEEPALIVE=25
DEFAULT_WG_EASY_URL="http://123.57.216.161:51821"
DEFAULT_WG_EASY_USER="admin"
DEFAULT_WG_EASY_PASSWORD="71082aaa348e3b03d45bf7f6a2c41ef18fe3"
STARTUP_LABEL="com.mk.wg_mk.client"
STARTUP_LOG_DIR="/var/log/wg_mk"
STARTUP_STDOUT_LOG="${STARTUP_LOG_DIR}/client-startup.log"
STARTUP_STDERR_LOG="${STARTUP_LOG_DIR}/client-startup.err"

if [[ "$PLATFORM" == "darwin" ]]; then
  STARTUP_PLIST="/Library/LaunchDaemons/${STARTUP_LABEL}.plist"
  STARTUP_SYSTEM_CONFIG_DIR="/usr/local/etc/wireguard"
  LIB_PATH_VAR="DYLD_LIBRARY_PATH"
else
  STARTUP_SERVICE_FILE="/etc/systemd/system/${STARTUP_LABEL}.service"
  STARTUP_SYSTEM_CONFIG_DIR="/etc/wireguard"
  LIB_PATH_VAR="LD_LIBRARY_PATH"
fi

TUNNEL_NAME=""
TUNNEL_NAME_EXPLICIT=0
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
STARTUP_INSTALL=0
NO_STARTUP=0
STARTUP_REMOVE=0
STARTUP_STATUS=0
STARTUP_RUN=0

if [[ -d "${SCRIPT_DIR}/bin" ]]; then
  PATH="${SCRIPT_DIR}/bin:${PATH}"
  export PATH
fi

if [[ -d "${SCRIPT_DIR}/lib" ]]; then
  eval "${LIB_PATH_VAR}=\"${SCRIPT_DIR}/lib\${${LIB_PATH_VAR}:+:\${${LIB_PATH_VAR}}}\""
  export "${LIB_PATH_VAR}"
fi

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Write a WireGuard client config from a wg-easy-generated .conf file,
optionally fetch it directly from a wg-easy server or create it there first,
optionally install CLI tools, and optionally bring the tunnel up.

Supports macOS and Linux (Ubuntu). On macOS uses launchd for persistence;
on Linux uses systemd.

With no arguments, the script defaults to:
  --wg-easy-url ${DEFAULT_WG_EASY_URL}
  --wg-easy-user ${DEFAULT_WG_EASY_USER}
  --wg-easy-client-name <local-host-name>
  --tunnel-name ${MANAGED_TUNNEL_NAME} --force --startup-install

This script manages one local WireGuard tunnel only:
  ${MANAGED_TUNNEL_NAME}

It accepts only client configs in:
  ${MANAGED_IPV4_CIDR}

It rewrites peer AllowedIPs to:
  ${MANAGED_ALLOWED_IPS}
and ensures PersistentKeepalive = ${MANAGED_PERSISTENT_KEEPALIVE} to prevent tunnel sleep.

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
  --tunnel-name NAME        Must be ${MANAGED_TUNNEL_NAME} when provided
  --target-dir DIR          Directory for saved configs
  --force                   Overwrite an existing target config
  --print-config-path       Print the final config path after writing/resolving it

Actions:
  --install-tools           Install wireguard-tools if needed (Homebrew on macOS, apt on Linux)
  --up                      Bring the tunnel up after writing or from an existing config
  --down                    Bring an existing tunnel down
  --status                  Show current WireGuard status
  --startup-install         Install startup support (launchd on macOS, systemd on Linux) [default]
  --no-startup              Skip automatic startup install
  --startup-remove          Remove startup support
  --startup-status          Show startup support state
  -h, --help                Show this help

Examples:
  ${SCRIPT_NAME} --config-file ./macbook.conf --install-tools --up
  ${SCRIPT_NAME} --config-file ./macbook.conf --tunnel-name ${MANAGED_TUNNEL_NAME}
  ${SCRIPT_NAME} --config-base64 "\$(base64 < ./macbook.conf | tr -d '\n')" --tunnel-name ${MANAGED_TUNNEL_NAME}
  WG_EASY_API_PASSWORD='secret' ${SCRIPT_NAME} --wg-easy-url https://vpn.example.com:51821 --wg-easy-user admin --wg-easy-client-name macbook --up
  cat ./macbook.conf | ${SCRIPT_NAME} --tunnel-name ${MANAGED_TUNNEL_NAME} --up
  ${SCRIPT_NAME} --tunnel-name ${MANAGED_TUNNEL_NAME} --down
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --config-file ./macbook.conf --no-startup --up
  ${SCRIPT_NAME} --startup-status
  ${SCRIPT_NAME} --status
EOF
}

log() {
  printf '[wg-client] %s\n' "$*" >&2
}

die() {
  printf '[wg-client] ERROR: %s\n' "$*" >&2
  exit 1
}

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

get_lib_path_value() {
  eval "printf '%s' \"\${${LIB_PATH_VAR}:-}\""
}

run_env() {
  local -a env_args
  local lib_val
  env_args=(env "PATH=${PATH}")

  lib_val="$(get_lib_path_value)"
  if [[ -n "$lib_val" ]]; then
    env_args+=("${LIB_PATH_VAR}=${lib_val}")
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
  local lib_val
  env_args=(env "PATH=${PATH}")

  lib_val="$(get_lib_path_value)"
  if [[ -n "$lib_val" ]]; then
    env_args+=("${LIB_PATH_VAR}=${lib_val}")
  fi

  sudo "${env_args[@]}" "$@"
}

xml_escape() {
  printf '%s' "$1" |
    sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

default_local_client_name() {
  local name=""

  if [[ "$PLATFORM" == "darwin" ]]; then
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
  if [[ "$PLATFORM" == "darwin" ]]; then
    ensure_cli_tools_darwin
  else
    ensure_cli_tools_linux
  fi
}

ensure_cli_tools_darwin() {
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

ensure_cli_tools_linux() {
  if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
    return 0
  fi

  log "wireguard-tools not found; installing automatically via apt"
  run_privileged apt-get update
  run_privileged apt-get install -y wireguard-tools
  command -v wg >/dev/null 2>&1 || die "wg was not found after apt installation."
  command -v wg-quick >/dev/null 2>&1 || die "wg-quick was not found after apt installation."
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
    [[ "$TUNNEL_NAME" == "$MANAGED_TUNNEL_NAME" ]] ||
      die "This script manages a single local WireGuard tunnel: ${MANAGED_TUNNEL_NAME}."
    return 0
  fi

  TUNNEL_NAME="$MANAGED_TUNNEL_NAME"
}

target_config_path() {
  printf '%s/%s.conf\n' "$TARGET_DIR" "$TUNNEL_NAME"
}

startup_config_path() {
  printf '%s/%s.conf\n' "$STARTUP_SYSTEM_CONFIG_DIR" "$MANAGED_TUNNEL_NAME"
}

have_wg_easy_fetch() {
  [[ -n "$WG_EASY_API_URL$WG_EASY_API_USER$WG_EASY_API_PASSWORD$WG_EASY_CLIENT_ID$WG_EASY_CLIENT_NAME" ]]
}

validate_config_file() {
  local path=$1
  local addresses entry value
  local saw_address=0

  grep -q '^\[Interface\]' "$path" || die "Config is missing an [Interface] section."
  grep -q '^\[Peer\]' "$path" || die "Config is missing a [Peer] section."

  while IFS= read -r entry; do
    saw_address=1
    value="${entry#*=}"
    while IFS= read -r value; do
      value="${value## }"
      value="${value%% }"
      value="${value%%/*}"
      [[ -n "$value" ]] || continue

      if [[ "$value" == *:* ]]; then
        [[ "$value" == "${MANAGED_IPV6_PREFIX}"* ]] ||
          die "Config IPv6 address ${value} is outside the managed prefix ${MANAGED_IPV6_PREFIX}."
      else
        [[ "$value" == "${MANAGED_IPV4_PREFIX}"* ]] ||
          die "Config IPv4 address ${value} is outside the managed prefix ${MANAGED_IPV4_CIDR}."
      fi
    done < <(
      printf '%s\n' "$value" |
        tr ',' '\n'
    )
  done < <(
    grep -E '^[[:space:]]*Address[[:space:]]*=' "$path"
  )

  (( saw_address == 1 )) || die "Config is missing an Address entry."
}

normalize_config_allowed_ips() {
  local path=$1
  local tmp
  local current

  current="$(
    grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$path" || true
  )"

  [[ -n "$current" ]] || die "Config is missing an AllowedIPs entry."

  tmp="$(mktemp)"
  awk -v allowed_ips="$MANAGED_ALLOWED_IPS" '
    /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
      print "AllowedIPs = " allowed_ips
      updated = 1
      next
    }
    { print }
    END {
      if (updated != 1) {
        exit 10
      }
    }
  ' "$path" >"$tmp" || {
    rm -f "$tmp"
    die "Could not normalize AllowedIPs in $path."
  }

  mv "$tmp" "$path"

  if ! printf '%s\n' "$current" | grep -Eq "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*${MANAGED_ALLOWED_IPS}[[:space:]]*$"; then
    log "Normalized AllowedIPs to ${MANAGED_ALLOWED_IPS}"
  fi
}

normalize_config_keepalive() {
  local path=$1
  local tmp

  if grep -Eq '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$path"; then
    tmp="$(mktemp)"
    awk -v ka="$MANAGED_PERSISTENT_KEEPALIVE" '
      /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ {
        print "PersistentKeepalive = " ka
        next
      }
      { print }
    ' "$path" >"$tmp"
    mv "$tmp" "$path"
  else
    tmp="$(mktemp)"
    awk -v ka="$MANAGED_PERSISTENT_KEEPALIVE" '
      /^[[:space:]]*\[Peer\]/ { in_peer = 1 }
      in_peer && /^[[:space:]]*$/ {
        print "PersistentKeepalive = " ka
        in_peer = 0
      }
      { print }
      END {
        if (in_peer) print "PersistentKeepalive = " ka
      }
    ' "$path" >"$tmp"
    mv "$tmp" "$path"
  fi

  log "Ensured PersistentKeepalive = ${MANAGED_PERSISTENT_KEEPALIVE}"
}

startup_installed() {
  if [[ "$PLATFORM" == "darwin" ]]; then
    [[ -f "$STARTUP_PLIST" ]]
  else
    [[ -f "$STARTUP_SERVICE_FILE" ]]
  fi
}

apply_default_fetch_settings() {
  WG_EASY_API_URL="${WG_EASY_API_URL:-$DEFAULT_WG_EASY_URL}"
  WG_EASY_API_USER="${WG_EASY_API_USER:-$DEFAULT_WG_EASY_USER}"
  WG_EASY_API_PASSWORD="${WG_EASY_API_PASSWORD:-$DEFAULT_WG_EASY_PASSWORD}"
  WG_EASY_CLIENT_NAME="${WG_EASY_CLIENT_NAME:-$(default_local_client_name)}"
  TUNNEL_NAME="$MANAGED_TUNNEL_NAME"
}

stdin_to_temp() {
  local tmp=$1
  local first_byte=""

  [[ -t 0 ]] && return 1

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

  normalize_config_allowed_ips "$tmp"
  normalize_config_keepalive "$tmp"
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
  normalize_config_allowed_ips "$tmp"
  normalize_config_keepalive "$tmp"
  validate_config_file "$tmp"

  FETCHED_WG_EASY_TMP="$tmp"
  FETCHED_WG_EASY_CLIENT_NAME="$client_name"
  if [[ -z "$TUNNEL_NAME" ]]; then
    TUNNEL_NAME="$MANAGED_TUNNEL_NAME"
  fi

  log "Fetched wg-easy config for client ${client_name} (${client_id})" >&2
}

sync_startup_config() {
  local src=$1
  local tmp dst

  if (( STARTUP_INSTALL != 1 )) && ! startup_installed; then
    return 0
  fi

  dst="$(startup_config_path)"
  tmp="$(mktemp)"
  cp "$src" "$tmp"

  run_privileged install -d -m 755 "$STARTUP_SYSTEM_CONFIG_DIR"
  run_privileged install -m 600 "$tmp" "$dst"
  rm -f "$tmp"

  log "Synced startup config to $dst"
}

write_startup_plist() {
  local tmp=$1
  local script_path
  local path_value
  local dyld_value

  script_path="${SCRIPT_DIR}/deploy_client.sh"
  path_value="$(xml_escape "${PATH}")"
  dyld_value="$(xml_escape "${DYLD_LIBRARY_PATH:-}")"

  cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${STARTUP_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script_path}</string>
    <string>--startup-run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>AbandonProcessGroup</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${path_value}</string>
EOF

  if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    cat >>"$tmp" <<EOF
    <key>DYLD_LIBRARY_PATH</key>
    <string>${dyld_value}</string>
EOF
  fi

  cat >>"$tmp" <<EOF
  </dict>
  <key>WorkingDirectory</key>
  <string>${SCRIPT_DIR}</string>
  <key>StandardOutPath</key>
  <string>${STARTUP_STDOUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${STARTUP_STDERR_LOG}</string>
</dict>
</plist>
EOF
}

write_startup_unit() {
  local tmp=$1
  local script_path
  local lib_val

  script_path="${SCRIPT_DIR}/deploy_client.sh"
  lib_val="$(get_lib_path_value)"

  cat >"$tmp" <<EOF
[Unit]
Description=WireGuard client tunnel (${MANAGED_TUNNEL_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=${PATH}
EOF

  if [[ -n "$lib_val" ]]; then
    printf 'Environment=%s=%s\n' "$LIB_PATH_VAR" "$lib_val" >>"$tmp"
  fi

  cat >>"$tmp" <<EOF
ExecStart=/bin/bash ${script_path} --startup-run
ExecStop=$(command -v wg-quick) down $(startup_config_path)
WorkingDirectory=${SCRIPT_DIR}
StandardOutput=append:${STARTUP_STDOUT_LOG}
StandardError=append:${STARTUP_STDERR_LOG}

[Install]
WantedBy=multi-user.target
EOF
}

install_startup_support() {
  if [[ "$PLATFORM" == "darwin" ]]; then
    install_startup_support_darwin "$@"
  else
    install_startup_support_linux "$@"
  fi
}

install_startup_support_darwin() {
  local cfg_path=$1
  local tmp

  sync_startup_config "$cfg_path"

  tmp="$(mktemp)"
  write_startup_plist "$tmp"

  run_privileged install -d -m 755 /Library/LaunchDaemons
  run_privileged install -d -m 755 "$STARTUP_LOG_DIR"
  run_privileged install -m 644 "$tmp" "$STARTUP_PLIST"
  run_privileged chown root:wheel "$STARTUP_PLIST"
  rm -f "$tmp"

  run_privileged launchctl bootout system "$STARTUP_PLIST" >/dev/null 2>&1 || true
  run_privileged launchctl bootstrap system "$STARTUP_PLIST"
  run_privileged launchctl enable "system/${STARTUP_LABEL}" >/dev/null 2>&1 || true
  run_privileged launchctl kickstart -k "system/${STARTUP_LABEL}" >/dev/null 2>&1 || true

  log "Installed startup support: ${STARTUP_PLIST}"
  log "Startup config path: $(startup_config_path)"
}

install_startup_support_linux() {
  local cfg_path=$1
  local tmp

  sync_startup_config "$cfg_path"

  tmp="$(mktemp)"
  write_startup_unit "$tmp"

  run_privileged install -d -m 755 "$STARTUP_LOG_DIR"
  run_privileged install -m 644 "$tmp" "$STARTUP_SERVICE_FILE"
  rm -f "$tmp"

  run_privileged systemctl daemon-reload
  run_privileged systemctl enable --now "${STARTUP_LABEL}.service"

  log "Installed startup support: ${STARTUP_SERVICE_FILE}"
  log "Startup config path: $(startup_config_path)"
}

remove_startup_support() {
  if [[ "$PLATFORM" == "darwin" ]]; then
    remove_startup_support_darwin
  else
    remove_startup_support_linux
  fi
}

remove_startup_support_darwin() {
  run_privileged launchctl bootout system "$STARTUP_PLIST" >/dev/null 2>&1 || true
  run_privileged rm -f "$STARTUP_PLIST"
  run_privileged rm -f "$(startup_config_path)"
  log "Removed startup support."
}

remove_startup_support_linux() {
  run_privileged systemctl disable --now "${STARTUP_LABEL}.service" >/dev/null 2>&1 || true
  run_privileged rm -f "$STARTUP_SERVICE_FILE"
  run_privileged rm -f "$(startup_config_path)"
  run_privileged systemctl daemon-reload
  log "Removed startup support."
}

show_startup_support_status() {
  if [[ "$PLATFORM" == "darwin" ]]; then
    show_startup_support_status_darwin
  else
    show_startup_support_status_linux
  fi
}

show_startup_support_status_darwin() {
  local cfg_path

  cfg_path="$(startup_config_path)"
  log "Startup plist: ${STARTUP_PLIST}"
  if startup_installed; then
    log "Startup installed: yes"
  else
    log "Startup installed: no"
  fi

  log "Startup config path: ${cfg_path}"
  if [[ -f "$cfg_path" ]]; then
    log "Startup config present: yes"
  else
    log "Startup config present: no"
  fi

  if run_privileged launchctl print "system/${STARTUP_LABEL}" >/dev/null 2>&1; then
    log "launchd job loaded: yes"
  else
    log "launchd job loaded: no"
  fi
}

show_startup_support_status_linux() {
  local cfg_path

  cfg_path="$(startup_config_path)"
  log "Startup unit: ${STARTUP_SERVICE_FILE}"
  if startup_installed; then
    log "Startup installed: yes"
  else
    log "Startup installed: no"
  fi

  log "Startup config path: ${cfg_path}"
  if [[ -f "$cfg_path" ]]; then
    log "Startup config present: yes"
  else
    log "Startup config present: no"
  fi

  if run_privileged systemctl is-enabled "${STARTUP_LABEL}.service" >/dev/null 2>&1; then
    log "systemd unit enabled: yes"
  else
    log "systemd unit enabled: no"
  fi

  if run_privileged systemctl is-active "${STARTUP_LABEL}.service" >/dev/null 2>&1; then
    log "systemd unit active: yes"
  else
    log "systemd unit active: no"
  fi
}

run_startup_support() {
  local cfg_path

  is_root || die "--startup-run must be executed as root by the init system."
  cfg_path="$(startup_config_path)"
  [[ -f "$cfg_path" ]] || die "Startup config does not exist: $cfg_path"

  TUNNEL_NAME="$MANAGED_TUNNEL_NAME"
  run_wg_quick up "$cfg_path"
  log "Startup tunnel is up: $cfg_path"
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
  normalize_config_allowed_ips "$dst"
  normalize_config_keepalive "$dst"
  sync_startup_config "$dst"

  if command -v wg-quick >/dev/null 2>&1; then
    if ! is_root && ! sudo -n true >/dev/null 2>&1; then
      log "Skipping wg-quick validation because passwordless sudo is unavailable in this shell."
    elif [[ "$PLATFORM" == "darwin" ]]; then
      WG_QUICK_USERSPACE_IMPLEMENTATION="${WG_QUICK_USERSPACE_IMPLEMENTATION:-$(command -v wireguard-go || true)}" \
        wg-quick strip "$dst" >/dev/null || die "Saved config failed wg-quick validation."
    else
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

  ensure_cli_tools

  if [[ "$PLATFORM" == "darwin" ]]; then
    local wg_go
    wg_go="${WG_QUICK_USERSPACE_IMPLEMENTATION:-$(command -v wireguard-go || true)}"
    [[ -n "$wg_go" ]] || die "wireguard-go is required on macOS but was not found."

    if [[ "$action" == "up" ]]; then
      run_privileged_env WG_QUICK_USERSPACE_IMPLEMENTATION="$wg_go" wg-quick down "$cfg" >/dev/null 2>&1 || true
    fi

    run_privileged_env WG_QUICK_USERSPACE_IMPLEMENTATION="$wg_go" wg-quick "$action" "$cfg"
  else
    if [[ "$action" == "up" ]]; then
      run_privileged_env wg-quick down "$cfg" >/dev/null 2>&1 || true
    fi

    run_privileged_env wg-quick "$action" "$cfg"
  fi
}

show_status() {
  ensure_cli_tools
  run_privileged_env wg show
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
        TUNNEL_NAME_EXPLICIT=1
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
      --startup-install)
        STARTUP_INSTALL=1
        shift
        ;;
      --no-startup)
        NO_STARTUP=1
        shift
        ;;
      --startup-remove)
        STARTUP_REMOVE=1
        shift
        ;;
      --startup-status)
        STARTUP_STATUS=1
        shift
        ;;
      --startup-run)
        STARTUP_RUN=1
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
  count=$((count + STARTUP_INSTALL))
  count=$((count + STARTUP_REMOVE))
  count=$((count + STARTUP_STATUS))
  count=$((count + STARTUP_RUN))

  if (( BRING_UP == 1 && STARTUP_INSTALL == 1 )); then
    count=$((count - 1))
  fi

  if (( count > 1 )); then
    die "Use exactly one primary action."
  fi

  if [[ -n "$CONFIG_FILE" && -n "$CONFIG_BASE64" ]]; then
    die "Use only one of --config-file or --config-base64."
  fi

  if (( SHOW_STATUS == 1 || STARTUP_STATUS == 1 )) && [[ -n "$CONFIG_FILE$CONFIG_BASE64" || "$TUNNEL_NAME_EXPLICIT" -eq 1 ]]; then
    die "Status actions do not take config input or tunnel name."
  fi

  if (( STARTUP_REMOVE == 1 )) && [[ -n "$CONFIG_FILE$CONFIG_BASE64$WG_EASY_API_URL$WG_EASY_API_USER$WG_EASY_API_PASSWORD$WG_EASY_CLIENT_ID$WG_EASY_CLIENT_NAME" || "$TUNNEL_NAME_EXPLICIT" -eq 1 ]]; then
    die "--startup-remove does not take config input, fetch options, or tunnel name."
  fi

  if (( STARTUP_RUN == 1 )) && [[ -n "$CONFIG_FILE$CONFIG_BASE64$WG_EASY_API_URL$WG_EASY_API_USER$WG_EASY_API_PASSWORD$WG_EASY_CLIENT_ID$WG_EASY_CLIENT_NAME" || "$TUNNEL_NAME_EXPLICIT" -eq 1 ]]; then
    die "--startup-run does not take config input, fetch options, or tunnel name."
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

    if (( SHOW_STATUS == 1 || BRING_DOWN == 1 || STARTUP_REMOVE == 1 || STARTUP_STATUS == 1 || STARTUP_RUN == 1 )); then
      die "wg-easy fetch options can only be used for saving a config or bringing it up."
    fi
  fi
}

main() {
  local tmp_config=""
  local cfg_path=""
  local raw_defaults=0
  local existing_cfg=""

  if (( $# == 0 )); then
    raw_defaults=1
  fi
  parse_args "$@"
  if (( raw_defaults == 1 )); then
    apply_default_fetch_settings
    BRING_UP=1
    FORCE=1
    INSTALL_TOOLS=1
    log "No arguments supplied; defaulting to ${DEFAULT_WG_EASY_URL}, tunnel ${TUNNEL_NAME}, --up"
  fi

  if (( NO_STARTUP == 0 && STARTUP_INSTALL == 0 && STARTUP_REMOVE == 0 && STARTUP_STATUS == 0 && STARTUP_RUN == 0 && BRING_DOWN == 0 && SHOW_STATUS == 0 )); then
    STARTUP_INSTALL=1
    log "Defaulting to --startup-install (boot persistence)."
  fi

  existing_cfg="${TARGET_DIR}/${MANAGED_TUNNEL_NAME}.conf"
  if (( STARTUP_INSTALL == 1 )) && [[ -z "$CONFIG_FILE$CONFIG_BASE64$WG_EASY_API_URL$WG_EASY_API_USER$WG_EASY_API_PASSWORD$WG_EASY_CLIENT_ID$WG_EASY_CLIENT_NAME" ]] && [[ ! -f "$existing_cfg" ]]; then
    apply_default_fetch_settings
    FORCE=1
    log "No existing managed config found; defaulting startup install to fetch the managed client config."
  fi

  validate_actions

  if (( STARTUP_RUN == 1 )); then
    run_startup_support
    exit 0
  fi

  if (( SHOW_STATUS == 1 )); then
    show_status
    exit 0
  fi

  if (( STARTUP_STATUS == 1 )); then
    show_startup_support_status
    exit 0
  fi

  if (( STARTUP_REMOVE == 1 )); then
    remove_startup_support
    exit 0
  fi

  if have_wg_easy_fetch; then
    fetch_wg_easy_config_to_temp
    tmp_config="$FETCHED_WG_EASY_TMP"
    trap 'rm -f "${tmp_config:-}"' EXIT
    if (( INSTALL_TOOLS == 1 || BRING_UP == 1 || STARTUP_INSTALL == 1 )); then
      ensure_cli_tools
    fi
    write_config "$tmp_config"
    cfg_path="$(existing_config_or_die)"
  elif [[ -n "$CONFIG_FILE" || -n "$CONFIG_BASE64" ]]; then
    tmp_config="$(read_config_to_temp)"
    trap 'rm -f "${tmp_config:-}"' EXIT
    if (( INSTALL_TOOLS == 1 || BRING_UP == 1 || STARTUP_INSTALL == 1 )); then
      ensure_cli_tools
    fi
    write_config "$tmp_config"
    cfg_path="$(existing_config_or_die)"
  else
    if tmp_config="$(read_config_to_temp 2>/dev/null)"; then
      trap 'rm -f "${tmp_config:-}"' EXIT
      if (( INSTALL_TOOLS == 1 || BRING_UP == 1 || STARTUP_INSTALL == 1 )); then
        ensure_cli_tools
      fi
      write_config "$tmp_config"
      cfg_path="$(existing_config_or_die)"
    else
      cfg_path="$(existing_config_or_die)"
      if (( INSTALL_TOOLS == 1 || BRING_UP == 1 || BRING_DOWN == 1 || STARTUP_INSTALL == 1 )); then
        ensure_cli_tools
      fi
      if (( PRINT_PATH == 1 )); then
        printf '%s\n' "$cfg_path"
      fi
    fi
  fi

  normalize_config_allowed_ips "$cfg_path"
  normalize_config_keepalive "$cfg_path"

  if (( STARTUP_INSTALL == 1 )); then
    install_startup_support "$cfg_path"
    if (( BRING_UP != 1 )); then
      exit 0
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

  if [[ "$PLATFORM" == "darwin" ]]; then
    log "Next step: import $cfg_path into the official WireGuard macOS app, or re-run with --up to use wg-quick."
  else
    log "Next step: re-run with --up to use wg-quick. Boot persistence is already installed by default."
  fi
}

main "$@"
