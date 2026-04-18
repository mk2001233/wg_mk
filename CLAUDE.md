# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A WireGuard VPN deployment suite built around [wg-easy](https://github.com/wg-easy/wg-easy). Server-side targets Ubuntu+Docker; client-side targets macOS and Linux (Ubuntu) with `wg-quick` and platform-native persistence (launchd on macOS, systemd on Linux).

## Validate Changes

All scripts use `set -Eeuo pipefail`. After editing any script, run:

```bash
bash -n deploy_server.sh
bash -n deploy_client.sh
bash -n test_client.sh
bash -n wg_show.sh
bash -n cancel_all_wireguard.sh
```

There are no automated tests beyond `test_client.sh`, which is a live integration check against a running wg-easy instance.

## Architecture

**Server (`deploy_server.sh`):** Installs Docker, generates a Compose stack at `/opt/wg-easy`, starts wg-easy, and persists peer-to-peer forwarding hooks (iptables rules) in wg-easy's SQLite database via Python. Live iptables rules are applied through `docker exec` to avoid container restarts that would lose peer endpoint state.

**Client (`deploy_client.sh`):** Fetches or reads a WireGuard config, normalizes it (rewrites `AllowedIPs` to `10.8.0.0/24`, enforces `PersistentKeepalive = 25`), writes it to `~/.config/wireguard/wg_mk.conf`, and optionally installs a startup job (launchd on macOS, systemd on Linux) and brings the tunnel up. Config can come from file, base64, stdin, or the wg-easy API. On macOS uses Homebrew + wireguard-go; on Linux uses apt + kernel WireGuard.

**Utilities:** `wg_show.sh` (read-only status), `cancel_all_wireguard.sh` (teardown all interfaces), `test_client.sh` (health checks against wg-easy API).

## Key Conventions

- Single managed tunnel name: `wg_mk`. The client script refuses to manage other tunnel names.
- All scripts support repo-local `./bin/` and `./lib/` directories injected into PATH/DYLD_LIBRARY_PATH (macOS) or LD_LIBRARY_PATH (Linux) for portable tool distribution.
- Logging prefixes: `[wg-easy]` (server), `[wg-client]` (client), `[wg-easy-test]` (test), `[wg-stop-all]` (cancel), `[wg-show]` (show). All log to stderr except `wg_show.sh`.
- Default server: `123.57.216.161` with wg-easy on ports 51820 (WireGuard UDP) / 51821 (Web UI TCP).

## Non-Obvious Behaviors

- **AllowedIPs rewriting:** Client unconditionally rewrites peer `AllowedIPs` to `10.8.0.0/24` (split-tunnel), even if the server config specifies `0.0.0.0/0`.
- **PersistentKeepalive enforcement:** Client always sets `PersistentKeepalive = 25` to prevent NAT/firewall tunnel sleep.
- **Peer forwarding hooks in SQLite:** Server persists iptables rules in wg-easy's database (`/opt/wg-easy/data/wg-easy.db`) so they survive container recreation. Both IPv4 and IPv6 rules are maintained.
- **Host change after first boot:** Editing `.env` alone is insufficient — the host value is also persisted in the `user_configs_table` in SQLite. Client endpoints may also need updating in `clients_table`.
- **Proxy fallback:** Server uses a three-mode proxy strategy (`auto`/`always`/`never`) with fallback to `http://127.0.0.1:11066` when Docker image pulls fail.
- **Config normalization runs unconditionally** in the client — not just on `--up` or `--startup-install`, but on every invocation that resolves a config path.
