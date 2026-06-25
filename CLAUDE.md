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
bash -n serve_scripts.sh
```

There are no automated tests beyond `test_client.sh`, which is a live integration check against a running wg-easy instance.

## Architecture

**Server (`deploy_server.sh`):** Installs Docker, generates a Compose stack at `/opt/wg-easy`, starts wg-easy, and persists peer-to-peer forwarding hooks (iptables rules) in wg-easy's SQLite database via Python. Live iptables rules are applied through `docker exec` to avoid container restarts that would lose peer endpoint state. Settings take CLI flags (`--public-host`, `--vpn-port`, `--ui-port`, `--admin-password`, `--dns`, `--proxy-mode`, …) or the matching `WG_EASY_*` env vars; flags win over an existing `.env`, which wins over the environment, which wins over defaults.

**Client (`deploy_client.sh`):** Fetches or reads a WireGuard config, normalizes it (rewrites `AllowedIPs` to `10.8.0.0/24`, enforces `PersistentKeepalive = 25`), writes it to `~/.config/wireguard/wg_mk.conf`, and installs a startup job by default (launchd on macOS, systemd on Linux) and brings the tunnel up. Use `--no-startup` to skip automatic startup install. Config can come from file, base64, stdin, or the wg-easy API; `--server-ip`/`--server-host` (+ optional `--server-ui-port`) is shorthand for the wg-easy fetch URL and triggers a default deploy (fetch + up + boot persistence) when no other primary action is given. On macOS uses Homebrew + wireguard-go; on Linux uses apt + kernel WireGuard.

**Utilities:** `wg_show.sh` (read-only status — auto-detects and shows a wg-easy **server** section via `docker exec wg-easy wg show` + a **client** section for the `wg_mk` tunnel/config/boot-persistence; pipe-safe for `curl | bash`), `cancel_all_wireguard.sh` (teardown all interfaces), `test_client.sh` (health checks against wg-easy API), `serve_scripts.sh` (HTTP distributor: serves the repo's `.sh` files plus a generated `/install.sh` bootstrap so clients can `curl | bash` without cloning; optional systemd persistence). `serve_scripts.sh` gates the two deploy scripts and `/install.sh` behind HTTP Basic Auth (password generated unless `--auth-pass`/`WG_SERVE_PASSWORD`, baked into the systemd unit and the bootstrap); `--ssh-host <alias>` launches it remotely by SSHing into the alias and installing the service there (pairs with `sync.sh`).

## Key Conventions

- Single managed tunnel name: `wg_mk`. The client script refuses to manage other tunnel names.
- All scripts support repo-local `./bin/` and `./lib/` directories injected into PATH/DYLD_LIBRARY_PATH (macOS) or LD_LIBRARY_PATH (Linux) for portable tool distribution.
- Logging prefixes: `[wg-easy]` (server), `[wg-client]` (client), `[wg-easy-test]` (test), `[wg-stop-all]` (cancel), `[wg-show]` (show), `[wg-serve]` (serve). All log to stderr except `wg_show.sh`.
- Default server: `123.57.216.161` with wg-easy on ports 51820 (WireGuard UDP) / 51821 (Web UI TCP).

## Non-Obvious Behaviors

- **AllowedIPs rewriting:** Client unconditionally rewrites peer `AllowedIPs` to `10.8.0.0/24` (split-tunnel), even if the server config specifies `0.0.0.0/0`.
- **PersistentKeepalive enforcement:** Client always sets `PersistentKeepalive = 25` to prevent NAT/firewall tunnel sleep.
- **Peer forwarding hooks in SQLite:** Server persists iptables rules in wg-easy's database (`/opt/wg-easy/data/wg-easy.db`) so they survive container recreation. Both IPv4 and IPv6 rules are maintained.
- **Host change after first boot:** Editing `.env` alone is insufficient — the host value is also persisted in the `user_configs_table` in SQLite. Client endpoints may also need updating in `clients_table`.
- **Proxy fallback:** Server uses a three-mode proxy strategy (`auto`/`always`/`never`). `auto` (default) goes direct and only enables the proxy when a direct fetch fails (default `http://127.0.0.1:11066`). `always` commits to the proxy for everything: it rewrites `/etc/apt/sources.list` to the official Ubuntu mirrors (backup at `*.wg-easy.bak`), writes a global apt proxy (`/etc/apt/apt.conf.d/99-wg-easy-proxy`), enables the shell proxy for curl, and configures the Docker daemon proxy before the image pull — needed on cloud hosts whose default mirror is provider-internal (e.g. Aliyun's `mirrors.cloud.aliyuncs.com`, reachable only over the intranet) while egress is via an external proxy. `proxy_host`/`proxy_port` strip `user:pass@` userinfo so authenticated proxy URLs parse correctly.
- **Config normalization runs unconditionally** in the client — not just on `--up` or `--startup-install`, but on every invocation that resolves a config path.
- **Client startup is path-bound:** the launchd plist / systemd unit hardcodes `${SCRIPT_DIR}/deploy_client.sh`, so piping the client straight from `curl | bash` would install a boot job pointing at a nonexistent path. `serve_scripts.sh`'s `/install.sh` bootstrap exists to download the client to a stable dir (`/opt/wg_mk` by default) before running it. The server script is self-contained, so `curl .../deploy_server.sh | sudo bash` is fine.
- **Conflicting-interface teardown before deploy:** The client tears down *every* existing `wg_mk` instance before bringing the tunnel up — on macOS `wg-quick` only tracks one utun in `<name>.name`, so `teardown_managed_interfaces` also destroys any orphaned `utun` carrying the `10.8.0.` prefix (`managed_utuns`). Crucially, when `STARTUP_INSTALL` is set, the launchd/systemd boot job is the *single* bring-up path (main no longer also runs a manual `wg-quick up`) — doing both raced and left two interfaces on the same address. The server runs `teardown_conflicting_interfaces` (host-level `ip link show type wireguard`) before `prepare_stack`; wg-easy's `wg0` lives in the container netns and is never matched.
- **serve_scripts.sh port handling:** the `wg_mk-serve` systemd unit is `Type=simple`, which reports "started" before python binds — so the installer cannot rely on `systemctl enable --now`'s exit code. `install_service` therefore pre-checks the port (offering to kill the occupant, or `--kill-port` to force) and `verify_service_started` polls `is-active` + listening state, surfacing the journal on failure instead of a false success. The unit pins `StandardOutput=/StandardError=journal` so the service's logs don't leak into the SSH session during remote launch, and remote launch passes `--no-endpoints` so only the laptop prints the public one-liners (the box only knows its private IP).
