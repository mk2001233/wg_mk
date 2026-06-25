# wg-easy Deployment

## Server

Settings can be passed as flags (preferred) or the matching `WG_EASY_*`
environment variables. Run `bash deploy_server.sh --help` for the full list.
Precedence, highest first: flag → existing `/opt/wg-easy/.env` → environment →
built-in default. Boot persistence is automatic (Docker `restart: unless-stopped`
plus an enabled `docker` service).

```bash
sudo bash deploy_server.sh --public-host 123.57.216.161
```

```bash
sudo bash deploy_server.sh \
  --public-host 123.57.216.161 \
  --vpn-port 51820 \
  --ui-port 51821 \
  --admin-password 's3cret' \
  --dns 1.1.1.1,8.8.8.8
```

```bash
sudo bash deploy_server.sh --public-host 123.57.216.161 --pull-timeout 300
```

### Proxy-only hosts (no direct internet)

`--proxy-mode always` commits to the proxy for **everything**: it switches
`/etc/apt/sources.list` to the official Ubuntu mirrors (backing up the original
to `*.wg-easy.bak`), points apt at the proxy, and proxies the Docker repo and
image pulls. Use this on cloud boxes whose default mirror is a provider-internal
host the proxy can't reach (e.g. Aliyun's `mirrors.cloud.aliyuncs.com`).
Authenticated proxy URLs (`user:pass@host:port`) are supported.

```bash
sudo bash deploy_server.sh \
  --public-host 47.95.167.72 \
  --vpn-port 51820 --ui-port 51821 \
  --admin-user admin --admin-password 's3cret' \
  --proxy-mode always \
  --proxy-url 'http://USER:PASS@127.0.0.1:10086'
```

`--proxy-mode auto` (default) stays direct and only falls back to the proxy if a
direct fetch fails; `--proxy-mode never` disables it entirely.

The equivalent `WG_EASY_*` environment variables still work:

```bash
WG_EASY_PUBLIC_HOST=123.57.216.161 WG_EASY_PROXY_URL=http://127.0.0.1:11096 sudo -E bash deploy_server.sh
```

```bash
docker compose -f /opt/wg-easy/docker-compose.yml --env-file /opt/wg-easy/.env up -d
```

```bash
docker ps
docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' wg-easy
```

```bash
docker logs --tail 100 wg-easy
```

## Verification

```bash
bash test_client.sh
```

```bash
WG_EASY_TEST_URL=http://123.57.216.161:51821 \
WG_EASY_TEST_USER=admin \
WG_EASY_TEST_PASSWORD='your-password' \
bash test_client.sh
```

```bash
WG_EASY_TEST_MIN_CLIENTS=1 \
WG_EASY_TEST_CLIENT_NAME=macbook \
bash test_client.sh
```

## Serve scripts (no git clone)

Run a small HTTP server on the wg-easy host so clients fetch the scripts with
`curl` instead of cloning this repo. Serves every `*.sh` in the repo plus an
`/install.sh` bootstrap that downloads `deploy_client.sh` to a stable path (so
launchd/systemd boot persistence keeps resolving) and runs it against this server.

The two deploy scripts (`deploy_server.sh`, `deploy_client.sh`) and the
`/install.sh` bootstrap are protected with **HTTP Basic Auth**. A password is
generated and printed on startup unless you pass `--auth-pass` (or set
`WG_SERVE_PASSWORD`); the index page and utility scripts stay open.

### Run on the host

```bash
# foreground on the default port (8080); prints the generated credentials
bash serve_scripts.sh
```

```bash
# choose a port + password, and install a systemd service so it survives reboots
sudo bash serve_scripts.sh --install --port 51822 --auth-pass 's3cret'
```

### Or launch it remotely over SSH

`sync.sh` the repo to the host first, then point `serve_scripts.sh` at the SSH
host alias — it installs the systemd service on that host and prints the
ready-to-use one-liners (with credentials and the alias's resolved hostname):

```bash
bash sync.sh ex002 /home/xr/kaima/tools/wg_mk
bash serve_scripts.sh --ssh-host ex002 --port 51822 --remote-dir /home/xr/kaima/tools/wg_mk
```

If the serve port is already taken, the launch aborts and tells you which process
holds it; re-run interactively to be prompted to kill it, or pass `--kill-port`
to free it automatically:

```bash
bash serve_scripts.sh --ssh-host ex002 --port 51822 --remote-dir /home/xr/kaima/tools/wg_mk --kill-port
```

### Fetch from a client / server

Replace `<user>:<pass>` and `<host>:<port>` with the values printed above:

```bash
# wg-easy server
curl -fsSL -u <user>:<pass> http://<host>:<port>/deploy_server.sh | sudo bash -s -- --public-host <public-ip>
```

```bash
# macOS / Linux client (defaults --server-ip to <host>; pass extra flags after --)
curl -fsSL -u <user>:<pass> http://<host>:<port>/install.sh | bash
curl -fsSL -u <user>:<pass> http://<host>:<port>/install.sh | bash -s -- --no-startup
```

> Use `--no-auth` to serve without authentication (not recommended — the deploy
> scripts embed the default wg-easy admin password). Either way, open the chosen
> port only to networks you trust.

## Client (macOS / Linux)

Pass the server's public IP with `--server-ip` (shorthand for
`--wg-easy-url http://IP:51821`, also applying the default API credentials). With
no flags it falls back to the built-in default server. Either way it fetches the
managed `wg_mk` config, installs boot persistence (launchd on macOS, systemd on
Linux), and brings the tunnel up. Run `bash deploy_client.sh --help` for all options.

```bash
bash deploy_client.sh --server-ip 123.57.216.161
```

```bash
bash deploy_client.sh --server-ip 123.57.216.161 --server-ui-port 51821 --wg-easy-client-name macbook
```

```bash
bash deploy_client.sh
```

## Status & Teardown

`wg_show.sh` shows whichever applies to the host: a **server** section (wg-easy
container status, public host/ports/UI, and the in-container `wg show` peers) and
a **client** section (the `wg_mk` tunnel state, config, and boot-persistence). It
is served (no auth), so you can run it anywhere without cloning:

```bash
bash wg_show.sh
```

```bash
curl -fsSL http://47.95.167.72:51822/wg_show.sh | bash
```

```bash
bash cancel_all_wireguard.sh
```

```bash
bash cancel_all_wireguard.sh --dry-run
```

```bash
bash cancel_all_wireguard.sh --keep-startup
```

## Sync

Sync this repo to a remote host via rsync, with scp+tar fallback.

- `<remote_host>`: SSH destination
- `<remote_dir>`: target directory on the remote host
- `[extra_excludes...]`: additional paths to exclude beyond the defaults

```bash
REMOTE_HOST=ex002 REMOTE_DIR=/home/xr/kaima/tools/wg_mk

bash sync.sh $REMOTE_HOST $REMOTE_DIR
```

## Change Public Host After First Boot

```bash
# update /opt/wg-easy/.env
# update /opt/wg-easy/data/wg-easy.db: user_configs_table.host, clients_table.server_endpoint
docker compose -f /opt/wg-easy/docker-compose.yml --env-file /opt/wg-easy/.env up -d
```
