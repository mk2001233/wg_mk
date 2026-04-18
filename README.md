# wg-easy Deployment

## Server

```bash
bash deploy_server.sh
```

```bash
WG_EASY_PUBLIC_HOST=123.57.216.161 WG_EASY_PROXY_URL=http://127.0.0.1:11096 bash deploy_server.sh
```

```bash
sudo WG_EASY_PROXY_MODE=always bash deploy_server.sh
```

```bash
sudo WG_EASY_PULL_TIMEOUT_SECONDS=300 bash deploy_server.sh
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

## Client (macOS / Linux)

```bash
bash deploy_client.sh
```

## Status & Teardown

```bash
bash wg_show.sh
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

```bash
bash sync.sh ex001 /home/xr/kaima/tools/wg_mk data logs
```

## Change Public Host After First Boot

```bash
# update /opt/wg-easy/.env
# update /opt/wg-easy/data/wg-easy.db: user_configs_table.host, clients_table.server_endpoint
docker compose -f /opt/wg-easy/docker-compose.yml --env-file /opt/wg-easy/.env up -d
```
