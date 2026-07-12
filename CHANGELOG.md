# Changelog

All notable changes to pihole-ha, newest first. Versions follow the `vMAJOR.MINOR.PATCH` tags in git.

## v3.8.0 — 2026-07-11
- Add hostname filter for new-device DHCP notifications
- README: add unofficial third-party / non-affiliation notice

## v3.7.1 — 2026-07-07
- Keep the full-message Pushover hardening when tagging notifications

## v3.7.0 — 2026-07-07
- Restore per-kind mute controls for Pushover notifications

## v3.6.1 — 2026-07-07
- Panel adapts to Pi-hole dark/light theme automatically
- README: document join-by-IP fallback and 'node not found' troubleshooting

## v3.6.0 — 2026-07-06
- Panel: show the update command on its own line when behind
- Installer: don't miss live nodes behind a slow :8887 (raise scan timeout)

## v3.5.0 — 2026-07-06
- Installer: offer to join a node by IP when auto-discovery finds none

## v3.4.1 — 2026-07-06
- Ensure openssl is installed for sync signing; warn if it's missing

## v3.4.0 — 2026-07-06
- Harden: sign config-sync payloads, escape untrusted DHCP data

## v3.3.0 — 2026-07-06
- Make failover timing configurable in nodes.conf
- Document sync manifest failover to a healthy peer

## v3.2.0 — 2026-07-06
- Harden config sync: robust DHCP-host parsing and manifest failover

## v3.1.1 — 2026-07-06
- Render the HA version badge server-side so it never shows 'unknown'

## v3.1.0 — 2026-07-06
- Add pihole-ha-debug diagnostics collector for troubleshooting
- Clarify config sync is change-gated, not clockwork
- Update README for DNS-only VIP failover, PIN_DNS, and version badge

## v3.0.0 — 2026-07-06
- Add ./release helper to bump VERSION, commit, tag, and push
- Add version badge + update-available indicator to the HA panel
- Add PIN_DNS opt-out for the system-DNS pinning
- Patch the sidebar without python3 (fresh-install/Docker fix)
- Allow the VIP toggle in DNS-only mode (mode-aware authority)
- Fix panel reads failing on password-protected Pi-holes (route matching)
- Delete peer sessions after propagation (close secondary seat leak)
- Fix Pi-hole API session leak that exhausted webserver.api.max_sessions
- DNS-only VIP: prevent split-brain and let the installer enable it
- Add health-based VIP failover for DNS-only deployments
- Fix panel writes failing on password-protected Pi-holes
- Don't abort setup when the Docker daemon is present but not running
- Fix HA panel wiping the password field while typing
- install.sh --uninstall: remove this node from the cluster reliably
- README: note the Docker path is newer/less battle-tested
- README: fix clone URL to pihole-ha-cluster; document --update/--uninstall, deployment modes, and License
- Fix deployment-mode bugs found in testing
- Sync: auto-detect DHCP-HA vs DNS-only deployment + docs
- Initial public release

## Pre-3.0.0 — private development (2026-02 – 2026-06)

History predates the first public release and the semver scheme (the repo was versioned from v3.0.0 onward). Distilled from the original private repo, grouped by month, newest first.

### 2026-06
- Resolve sub-allocated MACs (MA-M/MA-S/IAB), not just 24-bit OUIs
- Use Pi-hole's macvendor.db as the primary MAC vendor source
- Re-check unknown MAC vendors online after a TTL
- Make IEEE OUI DB refresh self-contained and version-independent
- Auto-update local IEEE OUI DB monthly via systemd timer
- Colorize new-device Pushover notification
- DHCP vendor lookup: harden API fallback for offline/failover bursts
- DHCP vendor lookup: local IEEE OUI DB first, throttled API fallback
- Add muteable tags to sync build + pull Pushover notifications

### 2026-05
- Per-kind Pushover mute toggles (7 tags, replicated)
- Remove dead demote_old_primary branch from install scripts
- Consolidate logging + harden two interpolation sites
- Consolidate shared helpers + fix two latent bugs
- Remove dead code: pihole-ha-monitor and dhcp-failover migration
- Restart sync timers on install instead of enable --now
- Preserve multi-MAC DHCP reservations during sync
- Use OnActiveSec instead of OnBootSec in sync timers
- Fix wrong IP in DHCP-device Pushover title when VIP held
- Auto-promote sync publisher when configured primary is down
- Restart FTL after settings apply on standbys
- Skip bootstrap pull when primary has already published

### 2026-04
- Self-heal DNS pin on daemon startup
- Run Pushover notify synchronously in oneshot sync scripts
- Fix sync timers going dark after interval change
- Apply FTL settings after gravity restart
- Replicate sync.conf (interval, component toggles) across the cluster
- Sync DHCP scope across nodes; show source in sync notification
- Pin resolv.conf to 127.0.0.1 and harden VIP claim
- Include receiving node role/IP in sync notification
- Sync notify.conf across nodes and bake defaults into install
- Fix notify settings not propagating to peers
- Propagate notify settings to all peers on save
- Fix MAC picker dirty flag and save with existing credentials
- Add DHCP notification settings to both UIs
- Include node role and IP in DHCP notification title
- Use notify.conf for DHCP notifications; daemon ensures dhcp-script hook
- Use dnsmasq.d file for dhcp-script hook instead of misc.dnsmasq_lines
- Restart pihole-FTL after configuring dhcp-script hook
- Fix dhcp-script hook being wiped by config sync
- Remove personal DHCP static host list from installer
- Handle network outage during bootstrap: abort if fresh node and no standbys reachable
- Add bootstrap protection: primary pulls from standbys when they have newer config
- Always include adlists in sync payload
- Add new-dhcp-device script to repo and fix notification formatting
- Add configurable sync interval with UI dropdown
- Add descriptive text to all HA admin panel cards
- Add descriptions to Config Sync card in HA panel
- Seed Pi-hole defaults on fresh install: adlists, DHCP hosts, scripts
- Bake Pushover credentials into installer defaults
- Remove inline onclick handlers blocked by Pi-hole v6 CSP
- Fix Pushover toggle not updating UI when notifyCfg is null
- Fix Pushover toggle on fresh installs creating notify.conf
- Add PAT token to clone command in README
- Pin DNS to 127.0.0.1 in installer when NetworkManager is present

### 2026-03
- Fix Pushover notifications dropping silently during failover
- Fix Pushover notifications: spacing in preview and DNS resolution
- Strip ANSI colors from docker compose build output
- Match Pi-hole's official color scheme in all installers
- Detect port conflicts: find free port when Pi-hole port is taken
- Auto-detect Pi-hole web port instead of assuming port 80
- Fix scan result order: sort numerically to prevent VIP misidentification
- Auto-detect VIP from existing cluster during install
- Fix setup.sh banner alignment and false bare-metal detection
- Fix README: use public repo URL, consolidate install instructions
- Add unified installer, cluster join/leave API, and Leave Cluster button
- Add Docker sidecar support and per-node port configuration

### 2026-02
- Remove unused SETTINGS_ARRAY_KEYS variable from sync scripts
- Fix ha.lp: separate sync_settings local declaration for Lua compat
- Add FTL Settings toggle to Pi-hole admin panel integration
- Add FTL settings sync component (SYNC_SETTINGS)
- Fix is_valid_ip called before definition in pihole-ha daemon
- Update README with auth, structured logging, config versioning, tests, and extracted web UI docs
- Fix auth: detect Pi-hole port, add glob suffixes for SID query strings
- Add structured logging, config versioning, input validation, API auth, static web UI, and tests
- Auto-detect primary during install, prevent dual-primary conflict
- Expand Pushover notifications with per-node health breakdown
- Add priority order UI control with cluster propagation
- Fix installer to match new VIP DHCP option logic and add HA_ENABLED to nodes.conf
- Update README with VIP DHCP option behavior, HA kill-switch, and new API endpoints
- VIP enabled: advertise only VIP as DNS + DHCP server-id; VIP disabled: all node IPs
- Add network diagnostic monitor for debugging connectivity issues
- Run health checks even when HA is disabled so dashboard shows peer status
- Disable Pi-hole multiDNS on startup to prevent duplicate dhcp-option=6
- Add HA disable/enable kill-switch with cluster-wide propagation
- Fix FTL restart loop that caused DHCP clients to lose connectivity
- Restrict VIP toggle to active DHCP master only
- Add VIP enable/disable toggle to dashboard and Pi-hole admin panel
- Make VIP optional, advertise all node IPs as DNS servers via DHCP
- Fix sync exporting TOML-style arrays that fail on import
- Fix DHCP failover: instant primary activation, anti-flap, FTL crash recovery
- Make dnsmasq VIP config self-healing — survives Pi-hole upgrades
- Fix DHCP clients losing DNS during failover — advertise VIP as DNS server
- Add comprehensive README with full system documentation
- Fix standalone dashboard showing FAIL instead of Standby for DHCP off
- Add DHCP master override — manual node promotion for DHCP serving
- Add dynamic node config — nodes.conf replaces all hardcoded IPs
- Add sync primary promotion — any node can be promoted to build/distribute config payloads
- Replace external pushover script with built-in Pushover config
- Fix auth spinner race condition with optimistic UI update
- Show spinner after auth save instead of keeping password field
- Reload auth.conf every cycle instead of only at startup
- Fix curl_local: quote URL to prevent shell & interpretation
- Fix auth/set endpoint: remove local keyword outside function
- Add Pi-hole API authentication support
- Add client count and lease count to overview cards
- Fix DHCP lease count: grep -o 
- Show active DHCP lease count in health table
- Show DHCP as Active/Standby instead of OK/FAIL
- Replace checkbox toggles with div-based toggles
- Fix sync panel hidden by JS: remove hide/show and overlay refs
- Fix blank sync panel: remove overlays, add server-side config
- Fix sync panel race condition and overlay bugs
- Add same-origin API proxy to fix HTTPS mixed content
- Add native Pi-hole web UI integration (/admin/ha)
- Fix migration: use is-active/is-enabled instead of list-unit-files
- Rename to Pi-hole HA, add configurable sync settings panel
- Replace SSH-based sync with HTTP pull model
- Add Pi-hole config sync from primary to standby nodes
- Beautify pushover notifications with HTML colors
- Reduce check interval from 20s to 10s for faster failover
- Add space after Monitor Started and DEACTIVATED in notifications
- Add yielded-to info in deactivation notification
- Add VIP management, auto-detect interface, trailing space in pushover

