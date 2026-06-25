#!/usr/bin/env bash
set -Eeuo pipefail

# Serve the wg_mk deploy scripts over HTTP so clients can fetch them with curl
# instead of cloning this repo. Serves every *.sh in the served directory plus a
# generated /install.sh bootstrap that downloads deploy_client.sh to a stable
# path (so launchd/systemd boot persistence keeps resolving) and runs it.
#
# Two ways to run:
#   - Local: run on the wg-easy host; serves the local repo.
#   - Remote: pass --ssh-host <alias> to SSH into that host (from ~/.ssh/config)
#     and install the server there. Pairs with sync.sh (sync repo, then serve).
#
# The two deploy scripts (deploy_server.sh, deploy_client.sh) are protected with
# HTTP Basic Auth by default; a password is generated and printed unless given.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

SERVE_PORT="${WG_SERVE_PORT:-8080}"
SERVE_BIND="${WG_SERVE_BIND:-0.0.0.0}"
SERVE_DIR="${WG_SERVE_DIR:-$SCRIPT_DIR}"

SSH_HOST="${WG_SERVE_SSH_HOST:-}"
REMOTE_DIR="${WG_SERVE_REMOTE_DIR:-wg_mk}"

AUTH_USER="${WG_SERVE_USER:-}"
AUTH_PASS="${WG_SERVE_PASSWORD:-}"
NO_AUTH=0
WG_SERVE_AUTH=0

STARTUP_LABEL="wg_mk-serve"
SERVICE_FILE="/etc/systemd/system/${STARTUP_LABEL}.service"

DO_INSTALL=0
DO_REMOVE=0
DO_STATUS=0
KILL_PORT=0
NO_ENDPOINTS=0

if [[ -d "${SCRIPT_DIR}/bin" ]]; then
  PATH="${SCRIPT_DIR}/bin:${PATH}"
  export PATH
fi

log() {
  printf '[wg-serve] %s\n' "$*" >&2
}

die() {
  printf '[wg-serve] ERROR: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

run_privileged() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

# POSIX-safe single-quote for values interpolated into a remote shell command.
shq() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

port_listening() {
  local port=$1
  if command_exists ss; then
    ss -H -ltn 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") {f=1} END {exit f ? 0 : 1}'
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") {f=1} END {exit f ? 0 : 1}'
  else
    return 1
  fi
}

port_pids() {
  local port=$1
  run_privileged ss -H -ltnp 2>/dev/null \
    | awk -v port="$port" '$4 ~ (":" port "$")' \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

port_proc_desc() {
  local port=$1 p out="" n
  for p in $(port_pids "$port"); do
    n="$(ps -o comm= -p "$p" 2>/dev/null | tr -d '[:space:]')"
    out+="${p}(${n:-?}) "
  done
  printf '%s' "${out% }"
}

kill_port() {
  local port=$1 pids i
  pids="$(port_pids "$port")"
  [[ -n "$pids" ]] || return 0

  log "Stopping process(es) on port ${port}: $(printf '%s ' $pids)"
  # shellcheck disable=SC2086
  run_privileged kill $pids 2>/dev/null || true
  for ((i = 0; i < 10; i++)); do
    port_listening "$port" || return 0
    sleep 0.5
  done

  pids="$(port_pids "$port")"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    run_privileged kill -9 $pids 2>/dev/null || true
    sleep 1
  fi
  port_listening "$port" && die "Could not free port ${port}."
  return 0
}

# Stop our own service (if any) so a reinstall can rebind. If a foreign process
# still holds the port, offer to kill it (systemd's Type=simple cannot detect a
# failed bind, so an occupied port would otherwise crash-loop silently).
ensure_port_available() {
  run_privileged systemctl stop "${STARTUP_LABEL}.service" >/dev/null 2>&1 || true
  port_listening "$SERVE_PORT" || return 0

  local desc
  desc="$(port_proc_desc "$SERVE_PORT")"
  [[ -n "$desc" ]] || desc="another process"

  if (( KILL_PORT == 1 )); then
    log "Port ${SERVE_PORT} in use by ${desc}; --kill-port set, freeing it."
    kill_port "$SERVE_PORT"
    return 0
  fi

  if [[ -t 0 ]]; then
    log "Port ${SERVE_PORT} is in use by ${desc}."
    printf '[wg-serve] Kill it and continue? [y/N] ' >&2
    local ans=""
    read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES|Yes)
        kill_port "$SERVE_PORT"
        return 0
        ;;
    esac
    die "Aborted; left port ${SERVE_PORT} untouched. Re-run with --kill-port to force, or use a different --port."
  fi

  die "Port ${SERVE_PORT} is in use by ${desc}. Re-run with --kill-port to free it, or choose a different --port."
}

# Type=simple reports "started" as soon as the process forks, before python
# binds. Confirm the service actually came up and is listening, or surface the
# real error from the journal instead of a false success.
verify_service_started() {
  local i
  for ((i = 0; i < 20; i++)); do
    if run_privileged systemctl is-active "${STARTUP_LABEL}.service" >/dev/null 2>&1 && port_listening "$SERVE_PORT"; then
      return 0
    fi
    sleep 0.5
  done
  log "Service did not come up. Recent logs:"
  run_privileged journalctl -u "${STARTUP_LABEL}.service" --no-pager -n 20 >&2 2>/dev/null || true
  die "wg_mk-serve failed to start / bind port ${SERVE_PORT}."
}

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [options]

Serve the wg_mk deploy scripts over HTTP so clients can fetch them with curl
instead of cloning this repo. Runs locally by default, or remotely over SSH with
--ssh-host. Requires python3 (already installed by deploy_server.sh).

Endpoints:
  GET /                     Index page listing scripts and example commands
  GET /<name>.sh            Any *.sh file in the served directory
  GET /deploy_server.sh     wg-easy server installer        [auth required]
  GET /deploy_client.sh     wg-easy client installer         [auth required]
  GET /install.sh           Bootstrap that downloads deploy_client.sh to a stable
                            path and runs it against this server  [auth required]

Serving:
  --port PORT               TCP port to listen on (WG_SERVE_PORT, default 8080)
  --bind ADDR              Address to bind (WG_SERVE_BIND, default 0.0.0.0)
  --dir DIR                Directory of scripts to serve (default this repo)
  --install                Install + start a systemd service for boot persistence
  --remove                 Remove the systemd service
  --status                 Show the systemd service state
  --kill-port              If the serve port is already in use, kill the occupying
                            process without prompting (otherwise you are asked to
                            confirm when running interactively)
  --no-endpoints           Do not print the curl one-liners (used internally by
                            remote launch so only the public host is shown)

Remote launch (run from your laptop):
  --ssh-host ALIAS          SSH host alias (~/.ssh/config) to install the server on
  --remote-dir DIR          Repo dir on the remote host (default ${REMOTE_DIR};
                            must match where sync.sh placed the repo)

Auth (HTTP Basic on the deploy scripts):
  --auth-user USER          Basic-auth username (WG_SERVE_USER, default wg)
  --auth-pass PASS          Basic-auth password (WG_SERVE_PASSWORD; generated if unset)
  --no-auth                 Serve everything without authentication

  -h, --help                Show this help

Examples:
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} --port 51822 --auth-pass 's3cret'
  sudo bash ${SCRIPT_NAME} --install --port 8080
  bash ${SCRIPT_NAME} --ssh-host ex002 --port 51822 --remote-dir /home/xr/kaima/tools/wg_mk
EOF
}

require_value() {
  [[ -n "${2:-}" ]] || die "Option $1 requires a value."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        require_value "$1" "${2:-}"; SERVE_PORT="$2"; shift 2 ;;
      --bind)
        require_value "$1" "${2:-}"; SERVE_BIND="$2"; shift 2 ;;
      --dir)
        require_value "$1" "${2:-}"; SERVE_DIR="$2"; shift 2 ;;
      --ssh-host)
        require_value "$1" "${2:-}"; SSH_HOST="$2"; shift 2 ;;
      --remote-dir)
        require_value "$1" "${2:-}"; REMOTE_DIR="$2"; shift 2 ;;
      --auth-user)
        require_value "$1" "${2:-}"; AUTH_USER="$2"; shift 2 ;;
      --auth-pass)
        require_value "$1" "${2:-}"; AUTH_PASS="$2"; shift 2 ;;
      --no-auth)
        NO_AUTH=1; shift ;;
      --install)
        DO_INSTALL=1; shift ;;
      --remove)
        DO_REMOVE=1; shift ;;
      --status)
        DO_STATUS=1; shift ;;
      --kill-port)
        KILL_PORT=1; shift ;;
      --no-endpoints)
        NO_ENDPOINTS=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown argument: $1 (see --help)." ;;
    esac
  done
}

validate() {
  if ! [[ "$SERVE_PORT" =~ ^[0-9]+$ ]] || (( SERVE_PORT < 1 || SERVE_PORT > 65535 )); then
    die "--port must be a valid TCP port (1-65535)."
  fi

  SERVE_DIR="$(cd "$SERVE_DIR" 2>/dev/null && pwd)" || die "Serve directory not found: ${SERVE_DIR}"
  [[ -f "${SERVE_DIR}/deploy_client.sh" ]] || die "deploy_client.sh not found in ${SERVE_DIR}."

  command_exists python3 || die "python3 is required. Install it with: apt-get install -y python3"
}

gen_secret() {
  if command_exists python3; then
    python3 -c 'import secrets; print(secrets.token_hex(16))'
  elif command_exists openssl; then
    openssl rand -hex 16
  else
    die "Cannot generate an auth password (need python3 or openssl); pass --auth-pass."
  fi
}

resolve_auth() {
  if (( NO_AUTH == 1 )); then
    WG_SERVE_AUTH=0
    AUTH_USER=""
    AUTH_PASS=""
    return 0
  fi

  WG_SERVE_AUTH=1
  AUTH_USER="${AUTH_USER:-wg}"
  if [[ -z "$AUTH_PASS" ]]; then
    AUTH_PASS="$(gen_secret)"
  fi
}

hint_host() {
  local h="$SERVE_BIND"
  if [[ "$h" == "0.0.0.0" || "$h" == "::" ]]; then
    h="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$h" ]] || h="<server-ip>"
  fi
  printf '%s' "$h"
}

print_endpoints() {
  local host=$1
  local cred=""

  if (( NO_AUTH == 0 )); then
    log "Auth (HTTP Basic): user=${AUTH_USER} password=${AUTH_PASS}"
    cred="-u ${AUTH_USER}:${AUTH_PASS} "
  else
    log "NOTE: auth disabled (--no-auth); the deploy scripts embed the default wg-easy admin password."
  fi

  log "Server:  curl -fsSL ${cred}http://${host}:${SERVE_PORT}/deploy_server.sh | sudo bash -s -- --public-host ${host}"
  log "Client:  curl -fsSL ${cred}http://${host}:${SERVE_PORT}/install.sh | bash"
}

install_service() {
  validate
  resolve_auth
  ensure_port_available

  local exec_line="/bin/bash ${SCRIPT_DIR}/${SCRIPT_NAME} --port ${SERVE_PORT} --bind ${SERVE_BIND} --dir ${SERVE_DIR}"
  (( NO_AUTH == 1 )) && exec_line+=" --no-auth"

  local tmp
  tmp="$(mktemp)"
  {
    cat <<EOF
[Unit]
Description=wg_mk deploy script server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EOF
    if (( NO_AUTH == 0 )); then
      printf 'Environment=WG_SERVE_USER=%s\n' "$AUTH_USER"
      printf 'Environment=WG_SERVE_PASSWORD=%s\n' "$AUTH_PASS"
    fi
    cat <<EOF
ExecStart=${exec_line}
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal
WorkingDirectory=${SERVE_DIR}

[Install]
WantedBy=multi-user.target
EOF
  } >"$tmp"

  # 0600: the unit may carry the basic-auth password.
  run_privileged install -m 600 "$tmp" "$SERVICE_FILE"
  rm -f "$tmp"

  run_privileged systemctl daemon-reload
  run_privileged systemctl enable "${STARTUP_LABEL}.service" >/dev/null 2>&1 || true
  run_privileged systemctl restart "${STARTUP_LABEL}.service"
  verify_service_started

  log "Installed and started ${SERVICE_FILE}"
  log "Serving ${SERVE_DIR} on http://${SERVE_BIND}:${SERVE_PORT}"
}

remove_service() {
  run_privileged systemctl disable --now "${STARTUP_LABEL}.service" >/dev/null 2>&1 || true
  run_privileged rm -f "$SERVICE_FILE"
  run_privileged systemctl daemon-reload
  log "Removed ${SERVICE_FILE}"
}

status_service() {
  log "Service unit: ${SERVICE_FILE}"
  if [[ -f "$SERVICE_FILE" ]]; then
    log "Service installed: yes"
  else
    log "Service installed: no"
  fi

  if run_privileged systemctl is-enabled "${STARTUP_LABEL}.service" >/dev/null 2>&1; then
    log "Service enabled: yes"
  else
    log "Service enabled: no"
  fi

  if run_privileged systemctl is-active "${STARTUP_LABEL}.service" >/dev/null 2>&1; then
    log "Service active: yes"
  else
    log "Service active: no"
  fi
}

remote_launch() {
  command_exists ssh || die "ssh is required for --ssh-host."

  local actions=$((DO_INSTALL + DO_REMOVE + DO_STATUS))
  (( actions <= 1 )) || die "Use only one of --install, --remove, or --status."

  local host
  host="$(ssh -G "$SSH_HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  [[ -n "$host" ]] || host="$SSH_HOST"

  local remote_action="--install"
  (( DO_REMOVE == 1 )) && remote_action="--remove"
  (( DO_STATUS == 1 )) && remote_action="--status"

  local auth_env=""
  if [[ "$remote_action" == "--install" ]]; then
    resolve_auth
    if (( NO_AUTH == 1 )); then
      remote_action+=" --no-auth"
    else
      auth_env="WG_SERVE_USER=$(shq "$AUTH_USER") WG_SERVE_PASSWORD=$(shq "$AUTH_PASS") "
    fi
    (( KILL_PORT == 1 )) && remote_action+=" --kill-port"
    # The box can only detect its private IP; let this laptop print the public
    # one-liners (resolved from ssh -G) instead of the box printing them too.
    remote_action+=" --no-endpoints"
  fi

  local remote_cmd
  remote_cmd="cd $(shq "$REMOTE_DIR") && ${auth_env}bash serve_scripts.sh ${remote_action} --port $(shq "$SERVE_PORT") --bind $(shq "$SERVE_BIND")"

  log "Launching distribution server on ${SSH_HOST} (${host}:${SERVE_PORT}) via SSH"
  log "Remote dir: ${REMOTE_DIR} (must contain the synced repo; see sync.sh)"

  if [[ "$remote_action" == --install* ]]; then
    # -t allocates a remote TTY so the "kill it?" prompt can read from your
    # terminal; if your side is not a terminal, ssh skips the PTY and the remote
    # falls back to a non-interactive abort (unless --kill-port was passed).
    ssh -t "$SSH_HOST" "$remote_cmd"
    print_endpoints "$host"
  else
    ssh "$SSH_HOST" "$remote_cmd"
  fi
}

serve() {
  validate
  resolve_auth

  if port_listening "$SERVE_PORT"; then
    die "Port ${SERVE_PORT} is already in use (the wg_mk-serve service may already be running; check --status or pick another --port)."
  fi

  log "Serving ${SERVE_DIR} on http://${SERVE_BIND}:${SERVE_PORT}"
  print_endpoints "$(hint_host)"

  export WG_SERVE_DIR="$SERVE_DIR" WG_SERVE_BIND="$SERVE_BIND" WG_SERVE_PORT="$SERVE_PORT"
  export WG_SERVE_AUTH="$WG_SERVE_AUTH" WG_SERVE_USER="$AUTH_USER" WG_SERVE_PASSWORD="$AUTH_PASS"
  exec python3 - <<'PY'
import base64
import hmac
import os
import posixpath
import socket
import socketserver
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler

DIR = os.environ["WG_SERVE_DIR"]
BIND = os.environ.get("WG_SERVE_BIND", "0.0.0.0")
PORT = int(os.environ["WG_SERVE_PORT"])

AUTH = os.environ.get("WG_SERVE_AUTH", "0") == "1"
AUTH_USER = os.environ.get("WG_SERVE_USER", "")
AUTH_PASS = os.environ.get("WG_SERVE_PASSWORD", "")

# Files (and the install bootstrap) that require HTTP Basic Auth.
GATED_FILES = {"deploy_server.sh", "deploy_client.sh"}

SHELL_CTYPE = "text/x-shellscript; charset=utf-8"

BOOTSTRAP_TEMPLATE = r'''#!/usr/bin/env bash
set -Eeuo pipefail
# Generated by serve_scripts.sh. Downloads deploy_client.sh to a stable path so
# the launchd/systemd boot job keeps resolving, then runs it against this server.
# Pass extra deploy_client.sh flags after a '--', e.g.:
#   curl -fsSL -u USER:PASS @@BASE@@/install.sh | bash -s -- --no-startup
BASE_URL="@@BASE@@"
SERVER_HOST="@@HOST@@"
WG_USER='@@USER@@'
WG_PASS='@@PASS@@'
DEST_DIR="${WG_MK_DIR:-/opt/wg_mk}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

$SUDO mkdir -p "$DEST_DIR"
if [ -n "$WG_PASS" ]; then
  $SUDO curl -fsSL -u "$WG_USER:$WG_PASS" "$BASE_URL/deploy_client.sh" -o "$DEST_DIR/deploy_client.sh"
else
  $SUDO curl -fsSL "$BASE_URL/deploy_client.sh" -o "$DEST_DIR/deploy_client.sh"
fi
$SUDO chmod 0755 "$DEST_DIR/deploy_client.sh"

have_target=0
for arg in "$@"; do
  case "$arg" in
    --server-ip|--server-host|--wg-easy-url) have_target=1 ;;
  esac
done

if [ "$have_target" -eq 1 ]; then
  exec bash "$DEST_DIR/deploy_client.sh" "$@"
fi
exec bash "$DEST_DIR/deploy_client.sh" --server-ip "$SERVER_HOST" "$@"
'''


def list_scripts():
    out = []
    for name in sorted(os.listdir(DIR)):
        if name.endswith(".sh") and os.path.isfile(os.path.join(DIR, name)):
            out.append(name)
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "wg-serve/1.0"
    protocol_version = "HTTP/1.1"

    def host_pair(self):
        host = self.headers.get("Host") or BIND
        if host.startswith("["):
            end = host.find("]")
            hostonly = host[1:end] if end != -1 else host
        else:
            hostonly = host.split(":")[0]
        return host, hostonly

    def authorized(self):
        if not AUTH:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8", "replace")
        except Exception:
            return False
        user, _, password = decoded.partition(":")
        return hmac.compare_digest(user, AUTH_USER) and hmac.compare_digest(password, AUTH_PASS)

    def send_body(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_401(self):
        body = b"Unauthorized\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="wg_mk"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.route()

    def do_GET(self):
        self.route()

    def route(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("", "/", "/index.html"):
            self.send_body(200, self.index())
            return
        if path in ("/install.sh", "/client", "/client.sh"):
            if not self.authorized():
                self.send_401()
                return
            self.send_body(200, self.bootstrap(), SHELL_CTYPE)
            return
        name = posixpath.basename(path)
        if path == "/" + name and name.endswith(".sh") and name in list_scripts():
            if name in GATED_FILES and not self.authorized():
                self.send_401()
                return
            with open(os.path.join(DIR, name), "rb") as handle:
                self.send_body(200, handle.read(), SHELL_CTYPE)
            return
        self.send_body(404, "Not found\n")

    def index(self):
        host, _ = self.host_pair()
        base = "http://%s" % host
        cred = "-u <user>:<password> " if AUTH else ""
        lines = ["wg_mk deploy script server", "==========================", ""]
        if AUTH:
            lines += ["The deploy scripts require HTTP Basic Auth (-u user:password).", ""]
        lines += ["Scripts:"]
        for name in list_scripts():
            tag = "  [auth]" if name in GATED_FILES else ""
            lines.append("  %s/%s%s" % (base, name, tag))
        lines += [
            "",
            "Server (Ubuntu) - boot persistence via Docker restart policy:",
            "  curl -fsSL %s%s/deploy_server.sh | sudo bash -s -- --public-host <public-ip>" % (cred, base),
            "",
            "Client (macOS/Linux) - boot persistence via launchd/systemd:",
            "  curl -fsSL %s%s/install.sh | bash" % (cred, base),
            "",
            "Status (server or client, no auth):",
            "  curl -fsSL %s/wg_show.sh | bash" % base,
            "",
        ]
        return "\n".join(lines)

    def bootstrap(self):
        host, hostonly = self.host_pair()
        base = "http://%s" % host
        user = AUTH_USER if AUTH else ""
        password = AUTH_PASS if AUTH else ""
        return (
            BOOTSTRAP_TEMPLATE
            .replace("@@BASE@@", base)
            .replace("@@HOST@@", hostonly)
            .replace("@@USER@@", user)
            .replace("@@PASS@@", password)
        )

    def log_message(self, fmt, *args):
        sys.stderr.write("[wg-serve] %s %s\n" % (self.address_string(), fmt % args))


class ThreadingServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    address_family = socket.AF_INET6 if ":" in BIND else socket.AF_INET


def main():
    httpd = ThreadingServer((BIND, PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


main()
PY
}

main() {
  parse_args "$@"

  if [[ -n "$SSH_HOST" ]]; then
    remote_launch
    exit 0
  fi

  local actions=$((DO_INSTALL + DO_REMOVE + DO_STATUS))
  (( actions <= 1 )) || die "Use only one of --install, --remove, or --status."

  if (( DO_REMOVE == 1 )); then
    remove_service
    exit 0
  fi

  if (( DO_STATUS == 1 )); then
    status_service
    exit 0
  fi

  if (( DO_INSTALL == 1 )); then
    install_service
    (( NO_ENDPOINTS == 1 )) || print_endpoints "$(hint_host)"
    exit 0
  fi

  serve
}

main "$@"
