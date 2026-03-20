# wg-easy Deployment

This repository contains a single deployment script for bringing up a `wg-easy` server on Ubuntu with Docker.

The script installs Docker if needed, writes a compose stack under `/opt/wg-easy`, enables IP forwarding, and starts `wg-easy` with persistent data stored outside the repo.

## Files

- `deploy_server.sh`: unattended installer and updater for the `wg-easy` stack
- `deploy_client.sh`: macOS client helper for saving a `wg-easy` client config and optionally bringing it up with `wg-quick`
- `test_client.sh`: verification helper for checking local client tooling and remote `wg-easy` UI/API health

## What the Script Does

- Installs base packages needed for deployment
- Installs Docker Engine and the Docker Compose plugin
- Clears inherited shell proxy variables by default so normal apt traffic stays direct
- Falls back to `http://127.0.0.1:11066` when Docker download or image pull paths fail or hang
- Writes:
  - `/opt/wg-easy/.env`
  - `/opt/wg-easy/docker-compose.yml`
  - `/opt/wg-easy/deployment-info.txt`
- Creates persistent state in `/opt/wg-easy/data`
- Starts `ghcr.io/wg-easy/wg-easy:15`

## Requirements

- Ubuntu host with `systemd`
- Root access
- WireGuard kernel module available on the host
- Inbound cloud/firewall rules for:
  - `51820/udp` for WireGuard
  - `51821/tcp` only if you want the web UI reachable directly

## Quick Start

Run with defaults:

```bash
sudo ./deploy_server.sh
```

Run with an explicit public IP:

```bash
sudo WG_EASY_PUBLIC_HOST=39.96.200.42 ./deploy_server.sh
```

Force the local proxy from the start:

```bash
sudo WG_EASY_PROXY_MODE=always ./deploy_server.sh
```

Shorten the image-pull timeout before proxy fallback:

```bash
sudo WG_EASY_PULL_TIMEOUT_SECONDS=300 ./deploy_server.sh
```

## Configuration

Supported environment variables:

- `WG_EASY_PUBLIC_HOST`: public IP or DNS name advertised to clients
- `WG_EASY_VPN_PORT`: WireGuard UDP port, default `51820`
- `WG_EASY_UI_PORT`: web UI TCP port, default `51821`
- `WG_EASY_ADMIN_USER`: bootstrap admin username, default `admin`
- `WG_EASY_ADMIN_PASSWORD`: bootstrap admin password, default `71082aaa348e3b03d45bf7f6a2c41ef18fe3`
- `WG_EASY_DNS`: client DNS list, default `1.1.1.1,8.8.8.8`
- `WG_EASY_IPV4_CIDR`: VPN IPv4 subnet, default `10.8.0.0/24`
- `WG_EASY_IPV6_CIDR`: VPN IPv6 subnet, default `fd00:dead:beef::/64`
- `WG_EASY_ALLOWED_IPS`: client allowed IPs, default `0.0.0.0/0,::/0`
- `WG_EASY_STACK_DIR`: stack root, default `/opt/wg-easy`
- `WG_EASY_PROXY_URL`: proxy URL, default `http://127.0.0.1:11066`
- `WG_EASY_PROXY_MODE`: `auto`, `always`, or `never`, default `auto`
- `WG_EASY_PULL_TIMEOUT_SECONDS`: timeout for `docker compose up -d` before proxy retry, default `900`

## Output and State

After deployment, check:

- `/opt/wg-easy/deployment-info.txt` for the UI URL and bootstrap credentials
- `/opt/wg-easy/.env` for the current stack configuration
- `/opt/wg-easy/data/` for persistent `wg-easy` state

The repo itself does not store runtime secrets unless you copy them here manually.

## Operations

Restart the stack:

```bash
docker compose -f /opt/wg-easy/docker-compose.yml --env-file /opt/wg-easy/.env up -d
```

Check container status:

```bash
docker ps
docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' wg-easy
```

Check logs:

```bash
docker logs --tail 100 wg-easy
```

## Verification

Run the deployment verifier from a machine that can reach the `wg-easy` UI:

```bash
./test_client.sh
```

Override the target or credentials when needed:

```bash
WG_EASY_TEST_URL=http://39.96.200.42:51821 \
WG_EASY_TEST_USER=admin \
WG_EASY_TEST_PASSWORD='your-password' \
./test_client.sh
```

Optionally require a minimum client count or verify that a specific client config can be downloaded:

```bash
WG_EASY_TEST_MIN_CLIENTS=1 \
WG_EASY_TEST_CLIENT_NAME=macbook \
./test_client.sh
```

By default, `./test_client.sh` expects `wg-easy` to contain a client matching this Mac's local host name and fails if the machine is not registered there yet.

## macOS Client

Use `wg-easy` to create a client and either download its `.conf` file manually or let the macOS helper fetch it directly from the `wg-easy` API. If you specify `--wg-easy-client-name` and that client does not exist yet, the helper creates it automatically before downloading the config. If you omit both `--wg-easy-client-name` and `--wg-easy-client-id`, the helper defaults to this Mac's local host name.

A bare `bash ./deploy_client.sh` now defaults to `--tunnel-name MaxdeMacBook-Ai --up`.

Save the config only:

```bash
./deploy_client.sh --config-file ./macbook.conf
```

Save the config and bring the tunnel up with Homebrew-installed CLI tools:

```bash
./deploy_client.sh --config-file ./macbook.conf --install-tools --up
```

Bring an existing saved tunnel down later:

```bash
./deploy_client.sh --tunnel-name macbook --down
```

Fetch a client config directly from `wg-easy` by exact client name and bring it up. If `macbook` does not exist yet, it will be created first:

```bash
WG_EASY_API_PASSWORD='your-password' \
./deploy_client.sh \
  --wg-easy-url https://vpn.example.com:51821 \
  --wg-easy-user admin \
  --wg-easy-client-name macbook \
  --up
```

Fetch or create the client that matches this Mac automatically:

```bash
WG_EASY_API_PASSWORD='your-password' \
./deploy_client.sh \
  --wg-easy-url http://39.96.200.42:51821 \
  --wg-easy-user admin \
  --print-config-path
```

Fetch by numeric client ID instead:

```bash
WG_EASY_API_PASSWORD='your-password' \
./deploy_client.sh \
  --wg-easy-url https://vpn.example.com:51821 \
  --wg-easy-user admin \
  --wg-easy-client-id 7 \
  --print-config-path
```

If your `wg-easy` UI is behind self-signed HTTPS, add `--wg-easy-insecure-tls`.

The macOS helper stores configs in `~/.config/wireguard` by default. It can also read a config from stdin or a base64 string.

Notes for API fetch mode:

- Upstream `wg-easy` currently uses Basic Authentication for the API.
- Accounts with 2FA enabled cannot use the API; disable 2FA for the account you use here.
- Prefer `WG_EASY_API_PASSWORD` in the environment over `--wg-easy-password` to avoid shell history leakage.
- If the fetched client name is too long for `wg-quick`, the helper truncates the local tunnel name automatically. Use `--tunnel-name` to override it explicitly.
- If a `bin/` directory exists next to the scripts, both `deploy_client.sh` and `test_client.sh` add it to `PATH` automatically. This is useful on Macs where you want to carry `wg`, `wg-quick`, and `wireguard-go` inside `/Users/mk/code/wg_mk/bin`.
- If a `lib/` directory exists next to the scripts, both client-side scripts export it through `DYLD_LIBRARY_PATH`. This is useful when you carry a repo-local `bash` and its shared libraries for `wg-quick` on a stock macOS install.
- Both client-side scripts are compatible with the stock `/bin/bash` shipped by macOS.
- On macOS shells without passwordless `sudo`, the helper still saves and validates the config structure, but it skips the extra `wg-quick strip` validation. Bringing the tunnel up or down still requires interactive `sudo` or the official WireGuard app.

## Changing the Public Host After First Boot

`wg-easy` stores the advertised host in its SQLite database after initialization. Updating only `/opt/wg-easy/.env` is not enough.

If you change the public IP or DNS name later, update both:

- `/opt/wg-easy/.env`
- `/opt/wg-easy/data/wg-easy.db`, table `user_configs_table`, column `host`

Then recreate the container:

```bash
docker compose -f /opt/wg-easy/docker-compose.yml --env-file /opt/wg-easy/.env up -d
```

If clients already exist, update their stored endpoints too:

- table `clients_table`, column `server_endpoint`

## Notes

- The script configures the `wg-easy` UI over plain HTTP on the chosen UI port.
- If the UI should be public, put it behind TLS or restrict access by source IP.
- The script is safe to rerun for the same stack, but it does not automatically rewrite persisted `wg-easy` database values after first initialization.
