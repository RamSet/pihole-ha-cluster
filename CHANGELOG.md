# Changelog

All notable changes to pihole-ha, newest first. Versions are the `vMAJOR.MINOR.PATCH` release tags in git; the current one drives the "update available" badge in the HA panel.

## v3.14.0 — 2026-09-18
- A node that cannot log in to a peer no longer seizes DHCP and the VIP from it
- New `STANDBY_ONLY` in nodes.conf: a node that will never take over
- Stop reporting "API unreachable" for a peer whose API is answering and refusing the login

## v3.13.5 — 2026-09-18
- Read the last line of auth.conf even when the file has no trailing newline

## v3.13.4 — 2026-09-17
- Stop reporting a peer that has no Pi-hole password as having rejected ours
- Make pressing Save retry straight away, even when the password is unchanged

## v3.13.3 — 2026-09-17
- Say why a password save was refused, instead of silently restoring the password box
- Tell a rejected session apart from not being able to check the session at all
- Stop a busy node's session check timing out at 2s and being reported as a bad password

## v3.13.2 — 2026-09-17
- Stop the Auth row spinning forever when a peer login never succeeds
- Say why a login failed in the panel, not just in the log
- Name the common trap by name: auth.conf is per-node, so a password saved on one node is not on the others
- Retry a peer login immediately when its password changes, instead of waiting out the backoff

## v3.13.1 — 2026-09-17
- Make the login timeout tunable in Docker too, via `PIHOLE_HA_AUTH_TIMEOUT`
- Point a login-timeout message at the knob that exists on that deployment

## v3.13.0 — 2026-09-17
- Wait longer for a peer login, and show a countdown instead of appearing to hang
- Say why a login failed: too slow, wrong password, unreachable, or out of API seats
- Back off after a failed login instead of re-hashing the password every 10 seconds
- New `AUTH_TIMEOUT` (default 10s) and `AUTH_RETRY_SEC` (default 60s) in `nodes.conf`

## v3.12.17 — 2026-09-16
- Keep sync timers firing after a reboot once the interval is changed

## v3.12.16 — 2026-08-27
- Report the local payload again in the diagnostics

## v3.12.15 — 2026-08-27
- Report the hash that actually changes, and stop failed builds inflating the version

## v3.12.14 — 2026-08-26
- Let each node choose where its sync files are stored

## v3.12.13 — 2026-08-24
- Reclaim the old memory-disk payload when updating, not only on a fresh install

## v3.12.12 — 2026-08-24
- Stop the config payload from filling memory on small systems

## v3.12.11 — 2026-08-23
- Say what actually failed when the HA panel cannot load

## v3.12.10 — 2026-08-22
- Fix the installer failing on Arch and misreporting the Pi-hole port

## v3.12.9 — 2026-08-21
- Make Docker nodes honour the sync interval you set

## v3.12.8 — 2026-08-20
- Fix Docker nodes both claiming the primary role, and a stalled first start

## v3.12.7 — 2026-08-20
- Stop Docker nodes crash-looping when config syncs

## v3.12.6 — 2026-08-20
- Sync local CNAME records to the standby nodes

## v3.12.5 — 2026-08-05
- Stop a daemon restart from deleting the sync manifest and payload

## v3.12.4 — 2026-08-05
- Restart a stopped sync timer instead of stalling until the next role change
- Name a publisher holding no manifest as the fault in the debug bundle

## v3.12.3 — 2026-08-05
- Collect sync state, sync logs and a cluster manifest table in the debug bundle
- Never mistake the VIP for the node's own address
- Fix DHCP notifications silently dying on a root-only notify.conf
- Uninstall: remove pihole-ha-monitor, and unpatch the sidebar robustly
- Stop reporting a connection error when the dashboard answered
- inject: set sidebar.lp mode explicitly after patching

## v3.12.2 — 2026-08-01
- Log every DHCP lease-hook invocation and skip reason

## v3.12.1 — 2026-08-01
- Enable both sync timers on every node so role changes cannot break sync
- Fix sync timers never firing when installed or enabled after boot

## v3.12.0 — 2026-08-01
- Make Add Node work from either side, and probe before joining

## v3.11.0 — 2026-08-01
- Drive DHCP state through the platform layer, document join/leave
- Make cluster join/leave safe and add it to the UI
- Replace per-tick forks in check_peer with bash builtins

## v3.10.17 — 2026-07-19
- Uninstall: revert host changes so Pi-hole is left as it was

## v3.10.16 — 2026-07-17
- Overview: stack state badge above last-check date on narrow screens

## v3.10.15 — 2026-07-17
- Overview: render system-state + last-check as right-aligned label badges

## v3.10.14 — 2026-07-17
- Notify: make ignored-host highlight red in every theme

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
