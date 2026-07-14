# Pi-hole HA

DHCP high availability and config sync for a Pi-hole cluster. Automatic failover, manual master override, config synchronization, and a web UI in Pi-hole's admin page — all over HTTP with no SSH keys or external dependencies. Runs on bare metal (systemd) or Docker (sidecar container).

> **Unofficial third-party project.** pihole-ha is an independent, community-built add-on. It is **not** affiliated with, endorsed by, or sponsored by the Pi-hole project or Pi-hole LLC. Pi-hole® is a registered trademark of Pi-hole LLC. This project uses Pi-hole's supported interfaces (`pihole-FTL --config`, the admin page) but ships no Pi-hole code and is maintained separately. Use at your own risk.

**Version history:** see [CHANGELOG.md](CHANGELOG.md).

## Deployment Modes

pihole-ha auto-detects how your network does DHCP and installs to match — it will **not** enable Pi-hole DHCP behind your back:

- **DHCP-HA** — *Pi-hole is your DHCP server.* Full failover: a standby takes over DHCP if the primary dies, with an optional floating VIP. Selected when Pi-hole DHCP is already active (or when you choose it at install).
- **DNS-only** — *your router or another server does DHCP.* pihole-ha **never touches DHCP**; it keeps your Pi-holes' config (blocklists, custom DNS, FTL settings) in sync and monitors peer health. If you configure a VIP, it also floats that IP to whichever node is answering DNS — so clients pointed at the VIP get real health-based DNS failover, not just two static DNS servers that stall on a dead one.

At install it checks whether Pi-hole DHCP is active, probes the LAN for another DHCP server, inherits the mode from the cluster when joining one, and asks if it's ambiguous (defaulting to the safe **DNS-only**). So installing on a DNS-only network won't create a second, conflicting DHCP server.

## What It Does

- **DHCP Failover** — If the primary Pi-hole goes down, a secondary node automatically takes over DHCP within ~40-80 seconds. When the primary recovers, the secondary yields back. Clients never lose DHCP.
- **Virtual IP (VIP)** — Optional floating IP. In DHCP-HA mode it follows the active DHCP node (clients get it as their DNS server and DHCP server-id, so renewals always reach the right node). In DNS-only mode it follows the highest-priority node that's answering DNS, giving health-based DNS failover. When disabled, clients get all node IPs as DNS servers instead.
- **Config Sync** — The sync primary bundles gravity DB, DHCP static leases, custom DNS records, and FTL settings — and rebuilds that bundle **only when something actually changes**. Standbys check the primary every ~15 minutes and download + apply **only when the config differs** (and even then, FTL only restarts on real changes) — plus an on-demand **Sync Now** button. So nothing transfers or restarts on unchanged data, and no SSH keys are needed.
- **Manual DHCP Master Override** — Force any node to be the DHCP server with one click. The others yield automatically. If the designated master goes down, remaining nodes fall back to priority order.
- **HA Kill-Switch** — Disable all DHCP failover, health checks, and VIP management cluster-wide with one toggle. Propagates to all nodes automatically.
- **Pushover Notifications** — Optional alerts on failover events (activation, deactivation, sync).
- **API Authentication** — Mutating API endpoints are protected using Pi-hole's own password. If the local Pi-hole instance has a password set, all write operations require a valid session ID (SID). Read-only endpoints remain open.
- **Web UI** — A native panel integrated into Pi-hole's admin interface at `/admin/ha` (**Tools > HA Cluster**).
- **Cluster Join/Leave** — Nodes register themselves with the cluster on install via the `/api/nodes/join` API. A "Leave Cluster" button on each node's HA panel removes it from all peers with one click. No manual config editing needed.
- **Docker Support** — Runs as a sidecar container alongside the stock `pihole/pihole` image. No custom Pi-hole fork needed. Interactive installer detects existing Pi-hole containers and preserves volume mounts.
- **Mixed Clusters** — Supports nodes running on different Pi-hole web ports (e.g., bare-metal on port 80 alongside Docker on port 8081) using `IP:PORT` format in the node list.

## Requirements

### Bare Metal

- 2+ Pi-hole instances (Pi-hole v6+ with `pihole-FTL`)
- Debian/Ubuntu-based OS (uses `apt`, `systemctl`)
- Network connectivity between all nodes on port 8887 (HTTP)
- Root access for installation
- Packages (auto-installed): `socat`, `curl`, `netcat-openbsd`, `arping`, `openssl` (openssl is used to sign/verify config-sync payloads)

### Docker

- Docker and Docker Compose
- Stock `pihole/pihole:latest` image (Pi-hole v6+)
- `network_mode: host` on both containers (required for DHCP broadcast and VIP)
- See [Docker README](docker/README.md) for full setup guide

> **Note:** The bare-metal (systemd) path is the primary, well-tested deployment. The Docker sidecar is newer and less battle-tested — the image builds and the logic is verified, but the full two-container runtime hasn't been exercised as broadly. Report issues if you hit them.

## Network Architecture

```
                   +-----------+
                   |  Gateway  |
                   | (router)  |
                   +-----+-----+
                         |
            DHCP relay target: VIP (.123)
                         |
          +--------------+--------------+
          |              |              |
    +-----+-----+  +----+------+  +----+------+
    |  PRIMARY   |  | SECONDARY |  | TERTIARY  |
    |   .3 (P1)  |  |  .5 (P2)  |  |  .55 (P3) |
    | Pi-hole +  |  | Pi-hole + |  | Pi-hole + |
    | pihole-ha  |  | pihole-ha |  | pihole-ha |
    +------------+  +-----------+  +-----------+
```

All nodes run the same software. Priority order determines who serves DHCP when in automatic mode.

**VIP enabled**: The VIP (`/32`) is added to the active node's interface and removed when it deactivates, with gratuitous ARP to update switch/router tables. Clients receive only the VIP as their DNS server (`dhcp-option=6`) and DHCP server identifier (`dhcp-option=54`), so lease renewals always reach the active node.

**VIP disabled**: No floating IP is managed. Clients receive all node IPs as DNS servers (`dhcp-option=6`), providing redundancy without a VIP. Clients use whichever node answered their DHCP request as the server identifier.

## Installation

Run on **each node** (primary first, then secondaries):

```bash
git clone https://github.com/RamSet/pihole-ha-cluster.git pihole-ha
cd pihole-ha
sudo ./setup.sh
```

`setup.sh` auto-detects whether Pi-hole is running as a Docker container or bare metal and runs the appropriate installer. If both are found, it asks which to use. You can also run `install.sh` (bare metal) or `docker-install.sh` (Docker) directly.

### What the Installer Does

1. **Scans the subnet** in parallel for existing pihole-ha nodes on port 8887
2. **Auto-detects role** — if an existing cluster is found, this node joins as the next standby. If none are found (e.g. the other node is on a different subnet), it offers to **join by IP**: enter an existing node's address and it verifies + joins that node. Otherwise this node becomes PRIMARY.
3. **Preserves cluster priority** — discovered nodes keep their existing order, the new node is appended last
4. **Detects deployment mode** (DHCP-HA vs DNS-only) and **asks about a VIP** (optional in both modes) — requires typing "yes" explicitly to enable. It never enables Pi-hole DHCP on a DNS-only network.
5. **Asks whether to pin system DNS to `127.0.0.1`** (recommended, so the node always resolves independent of the VIP) — decline if your resolver lives elsewhere and you don't want `/etc/resolv.conf` touched. Recorded as `PIN_DNS` and preserved across updates.
6. **Registers with the cluster** — calls `/api/nodes/join` on each existing node so they immediately learn about the new node
7. **Installs and starts services** — scripts, systemd units (bare metal) or Docker compose stack
8. **Injects the HA page** into Pi-hole's admin UI

For manual Docker setup without the installer, see [Docker README](docker/README.md).

### Managing a Node — the `pihole-ha` Command

After install, a global `pihole-ha` command is available from any directory (no need to be in the clone):

```bash
pihole-ha update       # update this node to the latest release (fetches fresh from GitHub)
pihole-ha status       # version, service state, and this node's role / VIP / DHCP
pihole-ha version      # installed version + whether an update is available
pihole-ha restart      # restart the daemon and dashboard
pihole-ha logs [-f]    # daemon + dashboard logs (add -f to follow)
pihole-ha debug        # run the diagnostics collector
pihole-ha uninstall    # remove pihole-ha (Pi-hole is left untouched)
```

`update` pulls a fresh copy of the latest release and runs the installer, so it works no matter where (or whether) the original clone still exists. Commands that change the system re-run with `sudo` automatically. The classic `cd <clone> && sudo ./install.sh --update` still works too — and is how an existing install first picks up the `pihole-ha` command.

### Configuration Files

All config lives in `/etc/pihole-ha/`:

| File | Purpose |
|------|---------|
| `nodes.conf` | Gateway, VIP, VIP/HA toggles, node list, DHCP range |
| `sync.conf` | Sync toggle, component toggles, sync primary |
| `master.conf` | DHCP master override (`auto` or a node IP) |
| `auth.conf` | Per-node Pi-hole API passwords (for locked instances) |
| `notify.conf` | Pushover notification credentials |

Example `nodes.conf`:
```
CONFIG_VERSION=1
GATEWAY=192.168.1.1
VIP=192.168.1.123
VIP_ENABLED=true
HA_ENABLED=true
DHCP_HA=true
PIN_DNS=true
HA_NODES=192.168.1.3,192.168.1.5,192.168.1.55,192.168.1.81:8081
DHCP_START=192.168.1.11
DHCP_END=192.168.1.150
```

Nodes in `HA_NODES` can optionally include a `:PORT` suffix for the Pi-hole web port. Nodes without a port default to 80. This allows mixed clusters where some nodes run Pi-hole on non-standard ports (e.g., Docker nodes on 8081 alongside bare-metal nodes on 80).

| Setting | Values | Default | Description |
|---------|--------|---------|-------------|
| `CONFIG_VERSION` | integer | `1` | Config format version (warns on mismatch, never blocks) |
| `VIP_ENABLED` | `true`/`false` | `true` | Enable floating VIP management |
| `HA_ENABLED` | `true`/`false` | `true` | Master kill-switch for all HA functions |
| `DHCP_HA` | `true`/`false` | `true` | `true` = DHCP-HA mode (manage DHCP + VIP). `false` = DNS-only (never touch DHCP; VIP follows the DNS-healthy primary if set) |
| `PIN_DNS` | `true`/`false` | `true` | Pin this host's resolver to `127.0.0.1`. `false` = never touch system DNS |
| `CHECK_INTERVAL` | seconds | `10` | How often each node health-checks its peers. Failover ≈ `CHECK_INTERVAL × ACTIVATE_AFTER` |
| `ACTIVATE_AFTER` | integer | `2` | Consecutive failed checks before a standby takes over (the last node waits +2 to avoid a tie). Lower = faster failover, higher = ignores brief blips |
| `DEACTIVATE_AFTER` | integer | `3` | Consecutive healthy checks before a standby yields back to a recovered primary |
| `HEALTH_TIMEOUT` | seconds | `2` | Per-check timeout for ping / DNS:53 / API |
| `HA_NODES` | CSV | *(required)* | Node IPs in priority order. Format: `IP` or `IP:PORT` |

**Tuning failover speed:** the defaults are conservative (secondary takes over in ~20s) to avoid failing over on a transient blip. For faster failover, lower `CHECK_INTERVAL` — e.g. `CHECK_INTERVAL=3` gives ~6s (secondary) / ~12s (tertiary) while still requiring 2 consecutive down-checks. Going below ~2s or `ACTIVATE_AFTER=1` risks flapping on brief network hiccups.

## How It Works

### DHCP Failover (`pihole-ha`)

The core daemon runs on every node (systemd service or Docker supervisor). Every 10 seconds it:

1. **Pings the gateway** — if unreachable, takes no action (prevents split-brain during LAN outages)
2. **Health-checks every peer** with 3 checks:
   - Ping (ICMP)
   - DNS port 53 (TCP)
   - Pi-hole API (`/api/config/dhcp/active`)
3. **Decides whether to serve DHCP** based on `should_i_serve()`:
   - **Auto mode**: Primary always serves. Secondaries only serve if all higher-priority nodes fail all 3 health checks.
   - **Manual mode**: The designated master always serves. Others yield to it. If the designated master is down, remaining nodes fall back to priority order (skipping the downed master).
4. **Activates or deactivates DHCP** with staggered thresholds to prevent flapping:
   - Activation: P1/P2 need 2 consecutive checks (40s), P3 needs 4 checks (80s)
   - Deactivation: All nodes need 3 consecutive checks (60s)
5. **Manages the VIP** (if `VIP_ENABLED=true`) — adds it on activation with gratuitous ARP, removes it on deactivation
6. **Updates DHCP options** — writes `/etc/dnsmasq.d/09-pihole-ha.conf`:
   - VIP enabled: `dhcp-option=6,<VIP>` + `dhcp-option=54,<VIP>` (single DNS + server-id)
   - VIP disabled: `dhcp-option=6,<node1>,<node2>,<node3>` (all nodes as DNS)
7. **Writes status JSON** to `/run/pihole-ha/status.json` for the dashboard

### Config Sync

Two scripts handle config distribution:

**`pihole-ha-sync`** (runs on sync primary, every 15 min via systemd timer or Docker supervisor):
- Computes a hash of all enabled config components (gravity DB, DHCP hosts, DNS records, FTL settings)
- If the hash changed (or `--force`), builds a `tar.gz` payload and a JSON manifest
- Stores them in `/run/pihole-ha/` where the dashboard API serves them

**`pihole-ha-sync-pull`** (runs on standby nodes, every 15 min via systemd timer or Docker supervisor):
- Fetches the manifest from the sync primary via HTTP (`:8887/api/sync/manifest`); if the primary is unreachable, it falls back to any other node that has a manifest, so a standby still receives config while the primary is down
- Compares the hash — if different, downloads the payload (`:8887/api/sync/payload`)
- Applies each component:
  - **Gravity DB**: copies to `/etc/pihole/gravity.db`, restarts `pihole-FTL` only if the md5 changed
  - **DHCP static leases**: applies via `pihole-FTL --config dhcp.hosts`
  - **Custom DNS records**: applies via `pihole-FTL --config dns.hosts`
  - **FTL settings**: applies DNS, blocking, cache, and misc settings via `pihole-FTL --config`

Sync is entirely over HTTP on port 8887. No SSH keys, no rsync, no shared filesystem.

### DHCP Master Override

The master override adds a manual control layer on top of automatic failover:

| `master.conf` | Behavior |
|----------------|----------|
| `DHCP_MASTER=auto` | Default. Priority-based failover (P1 > P2 > P3) |
| `DHCP_MASTER=192.168.1.5` | Force .5 as DHCP server. Others yield to it. If .5 goes down, remaining nodes fail over by priority among themselves. |

The setting is live-reloaded every check cycle (10s) — no service restart needed. When set via the web UI, it propagates to all nodes in the cluster automatically.

### Virtual IP (VIP)

The VIP is an optional floating IP address, controlled by `VIP_ENABLED` in `nodes.conf`. In **DHCP-HA** mode it follows DHCP mastership (and its DHCP options are written to `09-pihole-ha.conf`, below). In **DNS-only** mode it follows the highest-priority node that's answering DNS, giving clients pointed at the VIP health-based DNS failover — no DHCP options are written; you point clients at the VIP via your own DHCP server. The UI toggle is driven by the DHCP master (DHCP-HA) or the primary node (DNS-only).

| `VIP_ENABLED` | DHCP options written to `09-pihole-ha.conf` | Behavior |
|---------------|----------------------------------------------|----------|
| `true` | `dhcp-option=6,<VIP>` + `dhcp-option=54,<VIP>` | Clients see one stable DNS endpoint. DHCP renewals always target the VIP, which follows the active node. |
| `false` | `dhcp-option=6,<node1>,<node2>,<node3>` | Clients see all node IPs as DNS. No VIP is managed. Clients renew against whichever node answered. |

- `dhcp-option=6` = DNS servers advertised to clients (RFC 2132)
- `dhcp-option=54` = DHCP Server Identifier — tells clients which server to contact for renewals/releases

VIP can be toggled from the web UI (dashboard or `/admin/ha`). The toggle propagates to all nodes automatically via the `/api/vip/toggle` endpoint. The daemon live-reloads `VIP_ENABLED` every check cycle (10s) — no restart needed.

### HA Kill-Switch

`HA_ENABLED` in `nodes.conf` is a master kill-switch that disables all HA functions cluster-wide:

- DHCP failover stops — no activation or deactivation decisions are made
- Health checks still run (so the dashboard shows peer status), but results don't trigger any actions
- VIP management is paused
- The daemon continues running and writing status, but reports "HA disabled"

Toggle from the web UI or the API (`/api/ha/toggle`). The toggle propagates to all nodes automatically — one click disables/enables the entire cluster. Useful for maintenance windows or debugging.

### Why Port 8887?

Pi-hole's admin interface runs inside Pi-hole's embedded web server (lighttpd/CivetWeb on port 80). It uses Lua templates (`.lp` files) that run server-side. This is great for the integrated `/admin/ha` page, but it has limitations:

- **No cross-node API calls from Lua** without shelling out to curl
- **No persistent background service** — Lua pages only run on request
- **CORS restrictions** when the browser tries to fetch status from other nodes

The `pihole-ha-dash` API server on port 8887 solves this:

- **`pihole-ha-dash`** is a bash script using `socat` to handle HTTP requests
- It serves the status JSON, sync payloads, and all API endpoints directly
- It's the transport layer for config sync (primary serves payloads, standbys pull them)
- It handles propagation of settings (sync primary promotion, DHCP master override) by curling peer nodes

The Pi-hole admin page (`/admin/ha`) is the only UI. Its JavaScript talks to a same-origin Lua API proxy (`ha-api.lp`) that curls `localhost:8887` server-side, so the browser never contacts port 8887 directly.

**In short**: port 8887 is the cluster's **internal API** (node-to-node and local proxy only). Port 80 (`/admin/ha`) is the Pi-hole-integrated UI that proxies through it.

> **Security note:** Port 8887 is an internal API. Reads are unauthenticated, and writes are unauthenticated too unless the local Pi-hole has an admin password set (in which case mutating calls require a valid Pi-hole session). Keep 8887 on a trusted LAN — do **not** port-forward it or expose it to the internet.

## Security

pihole-ha is designed for a **trusted LAN**. Two controls harden it beyond that baseline:

**Control-plane authentication.** The `:8887` API's *read* endpoints are always open, but every *write* (toggles, master/priority/VIP changes, node join/leave, notify config, saving peer passwords) requires a valid Pi-hole session — **whenever the local Pi-hole has an admin password set**. So the simplest hardening is: give Pi-hole an admin password, and the cluster's control plane is authenticated automatically. On a password-less Pi-hole those writes are open to the LAN, so also consider firewalling `:8887` to just the cluster node IPs.

**Signed config sync (recommended).** Standbys apply whatever config the sync payload contains (DNS records, FTL settings, gravity DB), so a rogue peer or a MITM on the plain-HTTP transfer could otherwise push malicious config. To prevent that, put the **same secret** in `/etc/pihole-ha/cluster.key` on **every** node:

```bash
# generate once, then copy the SAME file to every node (chmod 600):
sudo sh -c 'umask 077; openssl rand -hex 32 > /etc/pihole-ha/cluster.key'
sudo systemctl restart pihole-ha-sync.timer pihole-ha-sync-pull.timer   # or just wait for the next cycle
```

When the key is present, the primary HMAC-signs each payload and standbys **reject anything without a matching signature** — a rogue source can't forge it without the key. Add it to all nodes together (a keyed standby will reject an unkeyed primary's unsigned payloads). No key = legacy unsigned behavior.

## Web Interface

### Pi-hole Admin Page (`/admin/ha`)

Access at `http://<node-ip>/admin/ha` (requires Pi-hole admin login). Integrated into Pi-hole's AdminLTE interface with:

- **Node selector** — view status from each node's perspective
- **Node cards** — live status (DHCP Active / Standby / Unreachable), health checks, client count, lease count
- **Cluster overview cards** (color-coded small-boxes)
- **Health check tables** per node with auth status and password input for locked instances
- **DHCP Master panel** with button group
- **Config Sync panel** with toggles and promote buttons
- **Pushover Notifications panel** — enable/disable, configure credentials, send test

The HA page is injected into Pi-hole's sidebar under **Tools > HA Cluster**. A systemd path watcher (`pihole-ha-inject.path`) re-injects it automatically after Pi-hole updates.

## Files

### Scripts (`/usr/local/bin/`)

| Script | Purpose |
|--------|---------|
| `pihole-ha` | Core DHCP failover daemon |
| `pihole-ha-dash` | Cluster API server (port 8887) — status, sync payloads, cluster actions |
| `pihole-ha-sync` | Build sync payload (primary only; checks every 15 min, rebuilds only on change) |
| `pihole-ha-sync-pull` | Pull sync payload (standbys only; checks every 15 min, pulls only on change) |
| `pihole-ha-inject` | Inject HA page into Pi-hole web UI (bare metal) |
| `pihole-ha-debug` | Diagnostics collector — `sudo pihole-ha-debug` prints a redacted support bundle |
| `pihole-ha-platform` | Platform abstraction layer (`/usr/local/lib/pihole-ha/`) — detects systemd vs Docker, provides unified functions for FTL restart, sync timer management, etc. |

### Pi-hole Admin Integration (`/usr/local/share/pihole-ha/`)

| File | Purpose |
|------|---------|
| `ha.lp` | Pi-hole admin page (Lua template) |
| `ha-api.lp` | Same-origin API proxy for the admin page |
| `ha.js` | Admin page JavaScript (polling, rendering, click handlers) |

### Installers

| File | Purpose |
|------|---------|
| `setup.sh` | Unified installer — auto-detects Docker or bare metal, runs the right installer |
| `install.sh` | Bare metal installer (systemd services, interactive) |
| `docker-install.sh` | Docker installer (detects Pi-hole container, generates compose stack, interactive) |

### Docker Files (`docker/`)

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build: copies `pihole-FTL` from pihole image, Alpine 3.21 sidecar |
| `docker-compose.yml` | Two-container stack (pihole + pihole-ha sidecar) with shared volumes |
| `docker-entrypoint.sh` | Process supervisor replacing systemd — manages daemon, dash, and sync loops |
| `pihole-ha-inject-docker.sh` | Injects HA page into Pi-hole's admin UI at container startup |
| `.env.example` | All configurable environment variables with defaults |

### Runtime (`/run/pihole-ha/`)

| File | Purpose |
|------|---------|
| `status.json` | Current node status, peer health, written every 10s by `pihole-ha` |
| `sync-payload.tar.gz` | Config payload built by sync primary |
| `sync-manifest.json` | Payload metadata (hash, timestamp, components) |

### Systemd Units

| Unit | Type | Purpose |
|------|------|---------|
| `pihole-ha.service` | daemon | Core failover monitor |
| `pihole-ha-dash.service` | daemon | Cluster API on port 8887 |
| `pihole-ha-sync.timer` | timer | Build sync payload every 15 min (primary) |
| `pihole-ha-sync-pull.timer` | timer | Pull sync payload every 15 min (standbys) |
| `pihole-ha-inject.path` | path | Re-inject HA page when Pi-hole sidebar changes |

## API Endpoints (port 8887)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/status` | GET | Node status JSON (health checks, DHCP state, peers) |
| `/api/version` | GET | Installed version + latest upstream version + `update_available` flag |
| `/api/dhcp/master-config` | GET | Current DHCP master override setting |
| `/api/dhcp/master?ip=<auto\|ip>` | GET | Set DHCP master (propagates to all nodes) |
| `/api/sync/config` | GET | Sync configuration (enabled, components, primary) |
| `/api/sync/manifest` | GET | Sync payload manifest (hash, timestamp, size) |
| `/api/sync/payload` | GET | Download sync payload tarball |
| `/api/sync/promote?ip=<ip>` | GET | Set sync primary (propagates to all nodes) |
| `/api/sync/toggle/<key>` | GET | Toggle sync component (enabled/gravity/dhcp/dns) |
| `/api/sync/now` | GET | Trigger immediate sync build or pull |
| `/api/ha/config` | GET | HA enabled state |
| `/api/ha/toggle` | GET | Toggle HA kill-switch (propagates to all nodes) |
| `/api/vip/config` | GET | VIP settings and current DHCP master status |
| `/api/vip/toggle` | GET | Toggle VIP enabled/disabled (propagates to all nodes) |
| `/api/auth/set?ip=<ip>&password=<pw>` | GET | Save Pi-hole API password for a peer |
| `/api/notify/config` | GET | Pushover notification config |
| `/api/notify/save?enabled=...&user=...&token=...&title=...` | GET | Save Pushover config |
| `/api/notify/toggle` | GET | Toggle Pushover on/off |
| `/api/notify/test` | GET | Send test Pushover notification |
| `/api/auth/check` | GET | Check if Pi-hole password auth is required |
| `/api/config` | GET | Cluster bootstrap config (nodes, gateway, Pi-hole port) |
| `/api/nodes/join?node=<ip[:port]>` | GET | Add a node to the cluster (propagates to update all peers) |
| `/api/nodes/leave?node=<ip>` | GET | Remove a node from the cluster (propagates to all peers) |
| `/api/priority/set?order=<csv>` | GET | Set node priority order (propagates to all nodes) |
| `/api/role/demote?ip=<ip>` | GET | Demote current primary, promote target node |

**Authentication**: If the local Pi-hole instance has a password set, all mutating endpoints (toggle, set, save, promote, demote) require a `sid` query parameter with a valid Pi-hole session ID. Read-only endpoints (`/api/status`, `/api/config`, `/api/auth/check`, manifests, payloads) are always open. On 401, the `/admin/ha` panel prompts for the peer's Pi-hole password.

## Logs

All scripts use structured logging with ISO 8601 timestamps, role tags, and key=value fields:

```
2026-02-15T10:23:45 [PRIMARY] [INFO] event=startup ip=192.168.1.3 priority=1 interval=10s
2026-02-15T10:23:55 [PRIMARY] [WARN] event=gateway_unreachable gateway=192.168.1.1
2026-02-15T10:24:05 [PRIMARY] [INFO] event=dhcp_activate reason="all higher-priority nodes down"
```

```bash
# Failover daemon
journalctl -u pihole-ha -f

# Cluster API
journalctl -u pihole-ha-dash -f

# Sync (primary builds)
journalctl -u pihole-ha-sync

# Sync (standbys pull)
journalctl -u pihole-ha-sync-pull
```

## Troubleshooting

**Start here:** run the diagnostics collector and read (or share) its output — it gathers version, config (secrets redacted), service status, cluster/peer health, Pi-hole DNS/DHCP settings, VIP state, what FTL is listening on, `dig` tests against localhost **and** the VIP, and recent logs:

```bash
sudo pihole-ha-debug              # print to screen
sudo pihole-ha-debug > ha.txt     # save to a file to attach when asking for help
```

A common failover gotcha it surfaces: if `dig @127.0.0.1` resolves but `dig @<VIP>` does not, FTL isn't answering on the VIP — check `dns.listeningMode` and that the VIP is on the interface.


**Cluster API not responding on port 8887**
```bash
# Bare metal:
sudo systemctl status pihole-ha-dash
sudo systemctl restart pihole-ha-dash

# Docker:
docker compose logs pihole-ha
docker compose restart pihole-ha
```

**DHCP not failing over**
```bash
# Check health from the node's perspective:
curl -s localhost:8887/api/status | python3 -m json.tool
# Look at peers → ping/dns/api/dhcp fields
```

**Installer says "No existing HA nodes found" (but the other node is up)**
- Confirm both nodes are on the **same subnet** — auto-discovery only scans the local `/24`.
- From the new node, check the other is reachable: `curl http://<other-ip>:8887/api/status` should return JSON.
- If it's reachable but wasn't found, the scan may have timed out (slow hardware) — the installer will prompt to **enter the node's IP directly**; type it in to join. Re-run `sudo ./install.sh` if you already finished the install as a separate node.

**Peer API checks failing (api: false)**
- Check the peer's Pi-hole web port — if non-standard, add `:PORT` to the node in `HA_NODES`
- Example: `HA_NODES=192.168.1.10,192.168.1.11:8081`

**Sync not working**
```bash
# On primary — check if payload exists:
ls -la /run/pihole-ha/sync-payload.tar.gz
# On standby — check pull logs (bare metal):
journalctl -u pihole-ha-sync-pull --since "1 hour ago"
# On standby — check pull logs (Docker):
docker compose logs pihole-ha | grep SYNC-PULL
# Manual trigger:
sudo /usr/local/bin/pihole-ha-sync --force      # on primary
sudo /usr/local/bin/pihole-ha-sync-pull --force  # on standby
```

**Pi-hole API shows "Locked" in health checks**
- The peer has a Pi-hole admin password set
- Go to `/admin/ha`, find the node's health table, enter the password in the Auth row
- Password is saved to `/etc/pihole-ha/auth.conf` and picked up next check cycle

**HA page missing from Pi-hole sidebar after update**
```bash
# Bare metal:
sudo /usr/local/bin/pihole-ha-inject
sudo systemctl status pihole-ha-inject.path

# Docker: restart both containers to re-inject
docker compose restart
```

## Tests

Run integration tests (no root needed):

```bash
bash tests/test-ha.sh
```

Tests cover IP validation, config version parsing, role detection, node reorder logic, structured log format, auth check logic, and syntax checking of all scripts.

## Removing a Node

### From the Web UI

Click the **Leave Cluster** button on the node's own card at `/admin/ha`. This removes the node from all peers automatically via the `/api/nodes/leave` endpoint.

### From the CLI

```bash
# Remove node 192.168.1.55 from the cluster (run from any node):
curl "http://localhost:8887/api/nodes/leave?node=192.168.1.55"
# Propagates to all other nodes automatically
```

## Updating

The HA Cluster panel shows the installed version and flags when a newer release is available (checked once a day against this repo). To update, pull the latest and refresh the installed code in place — config and cluster membership (including your `PIN_DNS` choice) are left untouched:

```bash
cd pihole-ha && git pull
sudo ./install.sh --update
```

## Uninstall

### Bare Metal

From the cloned repo. This leaves the cluster (so peers drop this node), stops and disables all services, and removes the binaries, config, and admin-panel injection:

```bash
sudo ./install.sh --uninstall      # add -y to skip the confirmation prompt
```

### Docker

```bash
# Leave the cluster first:
curl "http://localhost:8887/api/nodes/leave?node=$(hostname -I | awk '{print $1}')"

cd pihole-ha/docker
docker compose down
```

## License

[Apache License 2.0](LICENSE).
