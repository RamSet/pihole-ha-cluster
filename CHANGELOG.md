# Changelog

All notable changes to pihole-ha, newest first. Versions are the `vMAJOR.MINOR.PATCH` release tags in git; the current one drives the "update available" badge in the HA panel.

## v3.10.13 — 2026-07-17
- Notify: label the picker legend so bold red = ignored is explicit

## v3.10.12 — 2026-07-17
- Notify: highlight ignored hosts in the picker instead of a mirror list

## v3.10.11 — 2026-07-17
- Notify: show host name beside each ignored MAC

## v3.10.10 — 2026-07-17
- Picker: carry all MACs of a multi-MAC reservation, not just the first

## v3.10.9 — 2026-07-17
- Fix static-host picker: parse dnsmasq reservations robustly

## v3.10.8 — 2026-07-17
- Pushover 'Config Synced': show build time in local time, not UTC

## v3.10.7 — 2026-07-17
- Auth status: distinguish 'no password' from 'authenticated'

## v3.10.6 — 2026-07-17
- VIP: make the 'orbit' flavor self-explanatory (clarify it's the VIP)

## v3.10.5 — 2026-07-17
- Panel: subtle astrophysics flavor for cluster state

## v3.10.4 — 2026-07-17
- Revert "Add subtle Star Trek touches: hidden 'lcars' and 'engage' commands"

## v3.10.3 — 2026-07-17
- Add subtle Star Trek touches: hidden 'lcars' and 'engage' commands

## v3.10.2 — 2026-07-16
- Fix build/check time display: emit UTC, render in viewer's local time (#3)
- README: document sync-publisher failover + content-versioned catch-up

## v3.10.1 — 2026-07-15
- sync-pull: adopt a higher config-version even when content is unchanged

## v3.10.0 — 2026-07-15
- Drive catch-up by content-version, not pull-count (fixes multi-node lease loss)

## v3.9.2 — 2026-07-15
- sync-pull: apply dhcp.hosts/dns.hosts after the FTL restart, not before

## v3.9.1 — 2026-07-15
- sync-pull: never apply an empty DHCP-reservation or custom-DNS list

## v3.9.0 — 2026-07-15
- Restore auto-promoting sync publisher with catch-up on primary recovery

## v3.8.5 — 2026-07-14
- pihole-ha update: exec the installer + point the UI at the new command

## v3.8.4 — 2026-07-14
- pihole-ha status: read local status file first; document the command

## v3.8.3 — 2026-07-14
- Add global 'pihole-ha' management command (update from anywhere)

## v3.8.2 — 2026-07-13
- Docker: inject the HA panel without a bind-mounted script

## v3.8.1 — 2026-07-13
- Docker: set DHCP_HA in generated config instead of defaulting to DHCP-HA
- Polish CHANGELOG: curated release notes and themed pre-3.0 summary
- Add CHANGELOG.md with full history; auto-maintain it on release

## v3.8.0 — 2026-07-11
- Filter new-device DHCP notifications by hostname (case-insensitive), alongside the existing MAC ignore list — a match on either silences the alert.
- Added an unofficial / non-affiliation notice to the README.

## v3.7.1 — 2026-07-07
- Hardened Pushover notifications: the full message is always sent, and the per-kind mute tag is carried out-of-band so it can neither truncate an alert nor be smuggled into one.

## v3.7.0 — 2026-07-07
- Restored per-kind Pushover mute controls — silence individual notification types (failover, VIP, sync, new-device, …) without disabling Pushover entirely. Changes replicate to peers.

## v3.6.1 — 2026-07-07
- The HA panel now follows Pi-hole's light/dark theme automatically instead of forcing a light background.
- Documented the join-by-IP fallback and "node not found" troubleshooting in the README.

## v3.6.0 — 2026-07-06
- Installer no longer misses live nodes sitting behind a slow `:8887` (raised the scan timeout).
- The panel shows the update command on its own line when a node is behind.

## v3.5.0 — 2026-07-06
- Installer offers to join a node by IP when auto-discovery finds no existing cluster.

## v3.4.1 — 2026-07-06
- Ensure `openssl` is installed for sync signing, and warn clearly if it's missing.

## v3.4.0 — 2026-07-06
- Config-sync payloads are now HMAC-signed and verified on pull; untrusted DHCP data is escaped before use.

## v3.3.0 — 2026-07-06
- Failover timing is tunable in `nodes.conf` (check interval, activate/deactivate delays).
- Documented sync-manifest failover to a healthy peer.

## v3.2.0 — 2026-07-06
- Hardened config sync with robust DHCP-host parsing and manifest failover.

## v3.1.1 — 2026-07-06
- Version badge is rendered server-side, so it never briefly shows "unknown".

## v3.1.0 — 2026-07-06
- Added the `pihole-ha-debug` diagnostics collector for troubleshooting.
- Clarified that config sync is change-gated, not on a fixed clock.

## v3.0.0 — 2026-07-06 — first public release
- **Failover / VIP:** health-based VIP failover for DNS-only deployments, with split-brain protection; the VIP toggle is allowed in DNS-only mode via mode-aware authority.
- **Auth:** fixed panel reads and writes failing on password-protected Pi-holes; closed a Pi-hole API session leak that exhausted `webserver.api.max_sessions` (including peer-session cleanup after propagation).
- **Web UI:** fixed the panel wiping the password field while typing; added the version badge and update-available indicator.
- **Installer:** added `--update` and `--uninstall`; reliable removal of a node from the cluster; no longer aborts when Docker is installed but not running; patches the sidebar without `python3`; auto-detects DHCP-HA vs DNS-only.
- **Other:** `PIN_DNS` opt-out for system-DNS pinning; the `./release` helper; README and license cleanup.

---

## Pre-3.0.0 — private development (2026-02 – 2026-06)

Before the first public release the project was built out in a private repo and wasn't yet on a semver scheme. This is a condensed summary of that work by area, rather than a commit-by-commit log.

### DHCP failover
- Priority-based automatic failover with anti-flap, instant primary activation, and FTL-crash recovery.
- Manual DHCP master override and a cluster-wide HA enable/disable kill-switch, both propagated to every node.
- Health checks run even when HA is disabled, so the dashboard always reflects real peer state; check interval tuned to 10s.

### Virtual IP
- Optional floating VIP with auto-detected interface, advertised as both DNS server and DHCP server-id.
- Self-healing dnsmasq VIP config that survives Pi-hole upgrades.
- VIP control restricted to the active DHCP master.

### Config sync
- HTTP pull model replacing the original SSH-based sync — no keys, no rsync, no shared filesystem.
- Change-gated payloads covering the gravity DB, DHCP static leases, custom DNS records, adlists, and FTL settings.
- Any node can be promoted to sync publisher, with auto-promotion when the configured primary is down.
- Bootstrap protection so a freshly rebuilt primary can't overwrite good standby config.
- `sync.conf` (interval and per-component toggles) replicated across the cluster.

### Web UI
- Native panel embedded in Pi-hole's admin page at `/admin/ha`, served through a same-origin API proxy that fixes HTTPS mixed-content.
- Priority-order control, per-card descriptions, and sync/settings toggles.

### Notifications
- Built-in Pushover support (replacing an external script), HTML-formatted with a per-node health breakdown.
- Reliable delivery during failover — resolves `pushover.net` via peers or the system resolver when local DNS is flapping.
- `notify.conf` synced across nodes, per-kind mute toggles, and new-device alerts enriched with a MAC-vendor lookup.

### MAC vendor lookup
- Local IEEE OUI database first with a throttled API fallback; the DB self-updates monthly.
- Resolves sub-allocated MACs (MA-M / MA-S / IAB), not just 24-bit OUIs, and uses Pi-hole's own `macvendor.db`.

### Installer & cluster management
- Unified installer, a cluster join/leave API with a "Leave Cluster" button, and a dynamic `nodes.conf` (no hardcoded IPs).
- Auto-detects the Pi-hole web port and existing VIP, resolves port conflicts, and supports a Docker sidecar deployment.

### Security & hardening
- API authentication using Pi-hole's own password; structured logging, input validation, and config versioning.
- Fixes for RCE / XSS / injection vectors and removal of credentials that had been committed.
- `resolv.conf` pinned to `127.0.0.1` and a hardened VIP-claim path.
