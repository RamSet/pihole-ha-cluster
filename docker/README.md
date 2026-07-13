# Pi-hole HA — Docker Sidecar

Run Pi-hole HA as a Docker sidecar alongside the stock `pihole/pihole` image. No custom Pi-hole fork needed.

## Architecture

Two containers per node, both using `network_mode: host`:

```
┌──────────────────────┐  ┌──────────────────────────────────┐
│  pihole (stock)      │  │  pihole-ha (sidecar)             │
│  - pihole-FTL        │  │  - pihole-ha daemon              │
│  - DNS/DHCP/Web      │  │  - pihole-ha-dash (port 8887)    │
│  - ports 53,80,443   │  │  - config sync timer             │
│                      │  │  - VIP management                │
└──────────┬───────────┘  └──────────┬─────────────────────────┘
           │ shared:                 │
           ├── /etc/pihole (volume) ─┤
           ├── /etc/dnsmasq.d (vol) ─┤
           └── PID namespace ────────┘
```

Key design points:

- **`network_mode: host`** on both containers — required for DHCP broadcast, VIP management, and LAN access
- **`pid: "service:pihole"`** on sidecar — shared PID namespace lets pihole-ha signal pihole-FTL for config hot-reload
- **FTL binary** copied from the pihole image at build time — needed for `pihole-FTL --config` CLI
- **Alpine-based sidecar** — lightweight, ~50MB image
- **Config from env vars** — entrypoint generates config on first run; persisted config takes precedence on restarts

## Quick Start (Fresh Install)

```bash
cd docker/
cp .env.example .env
# Edit .env with your node IPs, gateway, etc.
nano .env

# Build and start
docker compose up -d

# Check status
curl localhost:8887/api/status
```

## Adding to an Existing Pi-hole Docker Setup

If you already run Pi-hole in Docker, add the pihole-ha sidecar to your existing compose file.

### Required changes to your Pi-hole service

1. **Switch to `network_mode: host`** — remove any `ports:` mappings (host mode binds directly)
2. **Add capabilities** — `NET_ADMIN`, `NET_RAW`, `SYS_NICE`
3. **Share volumes** — both containers need access to `/etc/pihole` and `/etc/dnsmasq.d`

### Example: adding pihole-ha to existing compose

```yaml
services:
  pihole:
    image: pihole/pihole:latest
    network_mode: host              # was: ports: ["53:53", "80:80"]
    cap_add: [NET_ADMIN, NET_RAW, SYS_NICE]
    volumes:
      - ./etc-pihole:/etc/pihole    # keep your existing mounts
      - ./etc-dnsmasq:/etc/dnsmasq.d
    environment:
      TZ: America/New_York
      FTLCONF_webserver_api_password: ${PIHOLE_PASSWORD:-}
    restart: unless-stopped

  pihole-ha:
    build:
      context: /path/to/pihole-ha   # repo root
      dockerfile: docker/Dockerfile
    network_mode: host
    pid: "service:pihole"           # shares PID namespace with pihole
    cap_add: [NET_ADMIN, NET_RAW]
    depends_on: [pihole]
    env_file: .env
    volumes:
      - ./etc-pihole:/etc/pihole    # same as pihole service
      - ./etc-dnsmasq:/etc/dnsmasq.d
      - pihole-ha-conf:/etc/pihole-ha
    restart: unless-stopped

volumes:
  pihole-ha-conf:
```

### Create your `.env`

```bash
# Required
PIHOLE_HA_NODES=192.168.1.10,192.168.1.11    # all node IPs, primary first
PIHOLE_HA_GATEWAY=192.168.1.1

# Optional
PIHOLE_PASSWORD=your-pihole-password
PIHOLE_WEB_PORT=80                            # Pi-hole web port on this node
PIHOLE_HA_VIP_ENABLED=false
PIHOLE_HA_DHCP_HA=false                       # true = this node's Pi-hole serves DHCP (failover); false = DNS-only. If unset, inferred: true when a DHCP scope below is set, else false.
PIHOLE_HA_DHCP_START=192.168.1.50
PIHOLE_HA_DHCP_END=192.168.1.200
PIHOLE_HA_DHCP_ROUTER=192.168.1.1
```

> **DNS-only vs DHCP-HA:** if your Pi-hole doesn't serve DHCP, leave the `PIHOLE_HA_DHCP_*` scope out (or set `PIHOLE_HA_DHCP_HA=false`) — otherwise the node assumes it should take over DHCP and logs `dhcp_activate status=failed`.

See `.env.example` for all available options.

### Per-Node Pi-hole Web Ports

If nodes run Pi-hole on different ports (e.g., Docker on 8081, bare metal on 80), append `:PORT` to the node IP in `PIHOLE_HA_NODES`:

```bash
PIHOLE_HA_NODES=192.168.1.10,192.168.1.11:8081
```

Nodes without a port suffix default to port 80. This lets the health check daemon probe each peer's Pi-hole API on the correct port.

## Multi-Node Setup

Run the same setup on each node. Every node uses the same `PIHOLE_HA_NODES` list (primary first). The sidecar auto-detects its role based on its IP position in the list.

**Node 1 (primary):**
```
PIHOLE_HA_NODES=192.168.1.10,192.168.1.11
```

**Node 2 (secondary):**
```
PIHOLE_HA_NODES=192.168.1.10,192.168.1.11
```

Same value on both — the node whose IP comes first in the list is primary.

## Management

- **Dashboard:** `http://<node-ip>:8887/`
- **Status API:** `curl http://<node-ip>:8887/api/status`
- **Logs:** `docker compose logs -f pihole-ha`

## Admin Panel Integration

The HA page is automatically injected into Pi-hole's admin UI at container startup. Access it at `http://<node-ip>:<pihole-port>/admin/ha`. The sidecar stages the HA source files to a shared volume, and an inject script running in the Pi-hole container copies them to the web root and patches the sidebar.

If the HA page disappears after a Pi-hole container rebuild, restart both containers:
```bash
docker compose restart
```

## Important Notes

- **`network_mode: host` is required.** Bridge mode won't work — DHCP needs broadcast access and VIP needs to manage host network interfaces.
- **Port conflicts:** With host networking, Pi-hole binds directly to ports 53 and the configured web port. If port 80 is in use, set `PIHOLE_WEB_PORT` to a different port (e.g., 8081) and add `:PORT` to this node in `PIHOLE_HA_NODES`.
- **Config persistence:** The `/etc/pihole-ha` volume preserves config across container restarts. Set `PIHOLE_HA_FORCE_CONFIG=true` to regenerate from env vars on every start.
