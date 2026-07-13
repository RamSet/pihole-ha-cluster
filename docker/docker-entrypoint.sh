#!/bin/bash
# pihole-ha Docker entrypoint — process supervisor replacing systemd
set -uo pipefail

ROLE="ENTRYPOINT"
_log() { local lvl="$1"; shift; echo "$(date '+%Y-%m-%dT%H:%M:%S') [$ROLE] [$lvl] $*"; }
log_info()  { _log "INFO" "$*"; }
log_warn()  { _log "WARN" "$*"; }
log_error() { _log "ERROR" "$*"; }

# --- 0. Populate shared volume with HA web source files ---
if [[ -d /pihole-ha-src ]]; then
    cp /usr/local/share/pihole-ha/ha.lp /pihole-ha-src/ 2>/dev/null || true
    cp /usr/local/share/pihole-ha/ha-api.lp /pihole-ha-src/ 2>/dev/null || true
    cp /usr/local/share/pihole-ha/ha.js /pihole-ha-src/ 2>/dev/null || true
    cp /usr/local/bin/pihole-ha-inject-docker.sh /pihole-ha-src/ 2>/dev/null || true
    chmod 755 /pihole-ha-src/pihole-ha-inject-docker.sh 2>/dev/null || true
    # Stage the DHCP-event hook where the pihole container can exec it (dnsmasq,
    # which runs in that container, calls it via dhcp-script — see step 5b).
    cp /usr/local/bin/new-dhcp-device /pihole-ha-src/ 2>/dev/null || true
    chmod 755 /pihole-ha-src/new-dhcp-device 2>/dev/null || true
    log_info "event=web_inject_files_staged"
fi

# --- 1. Validate required env vars ---
if [[ -z "${PIHOLE_HA_NODES:-}" ]]; then
    log_error "PIHOLE_HA_NODES is required (comma-separated list of node IPs)"
    exit 1
fi
if [[ -z "${PIHOLE_HA_GATEWAY:-}" ]]; then
    log_error "PIHOLE_HA_GATEWAY is required (gateway/router IP)"
    exit 1
fi

# --- 2. Generate config files from env vars (skip if persisted config exists) ---
NODES_CONF="/etc/pihole-ha/nodes.conf"
SYNC_CONF="/etc/pihole-ha/sync.conf"

generate_config() {
    log_info "event=generate_config"

    # Determine primary (first node in list)
    IFS=',' read -ra _nodes <<< "$PIHOLE_HA_NODES"
    local primary="${_nodes[0]}"

    # Resolve DHCP-HA vs DNS-only. Unlike the bare-metal installer, the container
    # can't reliably probe the LAN, so: an explicit PIHOLE_HA_DHCP_HA wins; else
    # infer intent from whether a DHCP scope was configured (start/router given);
    # otherwise default to DNS-only. Without this the daemon defaulted to DHCP-HA
    # and looped on 'dhcp_activate status=failed' on any node not serving DHCP.
    local _dhcp_ha
    if [[ -n "${PIHOLE_HA_DHCP_HA:-}" ]]; then
        _dhcp_ha="$PIHOLE_HA_DHCP_HA"
    elif [[ -n "${PIHOLE_HA_DHCP_START:-}" || -n "${PIHOLE_HA_DHCP_ROUTER:-}" ]]; then
        _dhcp_ha="true"
    else
        _dhcp_ha="false"
    fi
    [[ "$_dhcp_ha" != "true" && "$_dhcp_ha" != "false" ]] && _dhcp_ha="false"

    cat > "$NODES_CONF" <<EOF
CONFIG_VERSION=1
GATEWAY=${PIHOLE_HA_GATEWAY}
VIP=${PIHOLE_HA_VIP:-}
VIP_ENABLED=${PIHOLE_HA_VIP_ENABLED:-false}
HA_ENABLED=${PIHOLE_HA_ENABLED:-true}
DHCP_HA=${_dhcp_ha}
HA_NODES=${PIHOLE_HA_NODES}
EOF

    cat > "$SYNC_CONF" <<EOF
SYNC_ENABLED=${PIHOLE_HA_SYNC_ENABLED:-true}
SYNC_GRAVITY=${PIHOLE_HA_SYNC_GRAVITY:-true}
SYNC_DHCP=${PIHOLE_HA_SYNC_DHCP:-true}
SYNC_DNS=${PIHOLE_HA_SYNC_DNS:-true}
SYNC_SETTINGS=${PIHOLE_HA_SYNC_SETTINGS:-true}
SYNC_PRIMARY=${PIHOLE_HA_SYNC_PRIMARY:-$primary}
EOF

    log_info "event=config_written nodes=$PIHOLE_HA_NODES gateway=$PIHOLE_HA_GATEWAY dhcp_ha=$_dhcp_ha"
}

if [[ "${PIHOLE_HA_FORCE_CONFIG:-false}" == "true" ]] || [[ ! -f "$NODES_CONF" ]]; then
    generate_config
else
    log_info "event=config_exists action=skip reason=\"using persisted config\""
fi

# --- 3. Create runtime dirs and ensure empty config files exist ---
mkdir -p /run/pihole-ha
touch /etc/pihole-ha/master.conf /etc/pihole-ha/auth.conf /etc/pihole-ha/notify.conf

# --- 4. Wait for pihole-FTL (shared PID namespace with pihole container) ---
log_info "event=waiting_for_ftl"
waited=0
while (( waited < 60 )); do
    if pgrep -x pihole-FTL >/dev/null 2>&1; then
        log_info "event=ftl_detected waited=${waited}s"
        break
    fi
    sleep 1
    (( waited++ ))
done

if ! pgrep -x pihole-FTL >/dev/null 2>&1; then
    log_error "event=ftl_timeout reason=\"pihole-FTL not found after 60s\""
    exit 1
fi

# --- 5. Configure DHCP in FTL if env vars provided ---
if [[ -n "${PIHOLE_HA_DHCP_START:-}" ]]; then
    pihole-FTL --config dhcp.start "$PIHOLE_HA_DHCP_START" >/dev/null 2>&1 || true
fi
if [[ -n "${PIHOLE_HA_DHCP_END:-}" ]]; then
    pihole-FTL --config dhcp.end "$PIHOLE_HA_DHCP_END" >/dev/null 2>&1 || true
fi
if [[ -n "${PIHOLE_HA_DHCP_ROUTER:-}" ]]; then
    pihole-FTL --config dhcp.router "$PIHOLE_HA_DHCP_ROUTER" >/dev/null 2>&1 || true
fi

# --- 5b. Register the new-device DHCP hook (parity with bare-metal install) ---
# dnsmasq runs in the pihole container and reads /etc/dnsmasq.d (a shared volume);
# it execs the hook staged at /pihole-ha-src/new-dhcp-device (also shared). The
# hook itself no-ops unless Pushover + DHCP notifications are enabled in
# notify.conf, so registering it unconditionally is safe. Activates on FTL's next
# reload (e.g. the first gravity sync).
_dhcp_script_conf="/etc/dnsmasq.d/10-pihole-ha-dhcp-script.conf"
if [[ -d /etc/dnsmasq.d && ! -f "$_dhcp_script_conf" ]]; then
    printf "dhcp-script=/pihole-ha-src/new-dhcp-device\n" > "$_dhcp_script_conf" 2>/dev/null \
        && pihole-FTL --config misc.etc_dnsmasq_d true >/dev/null 2>&1 \
        && log_info "event=dhcp_hook_registered" \
        || log_warn "event=dhcp_hook_register_failed"
fi

# --- 5c. Refresh the IEEE OUI (MAC vendor) DB in the background (non-fatal) ---
/usr/local/bin/pihole-ha-oui-update >/dev/null 2>&1 &
LAST_OUI="$(date +%s)"
OUI_INTERVAL=2592000   # 30 days

# --- 6. Set sync flag files based on role ---
LOCAL_IP="$(ip -o route get 1.0.0.0 2>/dev/null | sed -n 's/.*src \([^ ]*\).*/\1/p')"
# Parse nodes (strip port suffix for IP matching)
IFS=',' read -ra _RAW_NODES <<< "$PIHOLE_HA_NODES"
NODES=()
for _rn in "${_RAW_NODES[@]}"; do NODES+=("${_rn%%:*}"); done
SYNC_PRIMARY="${PIHOLE_HA_SYNC_PRIMARY:-${NODES[0]}}"
SYNC_PRIMARY="${SYNC_PRIMARY%%:*}"
# Also read from sync.conf if it exists
[[ -f "$SYNC_CONF" ]] && . "$SYNC_CONF"

if [[ "$LOCAL_IP" == "$SYNC_PRIMARY" ]]; then
    touch /run/pihole-ha/sync-enabled
    rm -f /run/pihole-ha/sync-pull-enabled
    log_info "event=role role=sync_primary"
else
    touch /run/pihole-ha/sync-pull-enabled
    rm -f /run/pihole-ha/sync-enabled
    log_info "event=role role=sync_standby primary=$SYNC_PRIMARY"
fi

# --- 7. Signal handling ---
DAEMON_PID="" DASH_PID=""

cleanup() {
    log_info "event=shutdown"
    [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>/dev/null || true
    [[ -n "$DASH_PID" ]] && kill "$DASH_PID" 2>/dev/null || true
    # Release VIP if held
    local iface vip vip_enabled
    vip_enabled="$(grep '^VIP_ENABLED=' "$NODES_CONF" 2>/dev/null | cut -d= -f2)"
    vip="$(grep '^VIP=' "$NODES_CONF" 2>/dev/null | cut -d= -f2)"
    if [[ "$vip_enabled" == "true" && -n "$vip" ]]; then
        iface="$(ip -o route get "${PIHOLE_HA_GATEWAY}" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p')"
        if [[ -n "$iface" ]]; then
            ip addr del "$vip/32" dev "$iface" 2>/dev/null || true
            log_info "event=vip_released ip=$vip"
        fi
    fi
    wait
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- 8. Start pihole-ha daemon ---
log_info "event=starting_daemon"
/usr/local/bin/pihole-ha &
DAEMON_PID=$!
echo "$DAEMON_PID" > /run/pihole-ha/daemon.pid

# --- 9. Start pihole-ha-dash socat server ---
log_info "event=starting_dash"
/usr/local/bin/pihole-ha-dash &
DASH_PID=$!

# --- 10. Supervisor loop ---
SYNC_INTERVAL="${PIHOLE_HA_SYNC_INTERVAL:-900}"  # 15 min default
LAST_SYNC=0

log_info "event=supervisor_started sync_interval=${SYNC_INTERVAL}s"

while true; do
    sleep 5

    # Restart daemon if dead
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        log_warn "event=daemon_died action=restart"
        /usr/local/bin/pihole-ha &
        DAEMON_PID=$!
        echo "$DAEMON_PID" > /run/pihole-ha/daemon.pid
    fi

    # Restart dash if dead
    if ! kill -0 "$DASH_PID" 2>/dev/null; then
        log_warn "event=dash_died action=restart"
        /usr/local/bin/pihole-ha-dash &
        DASH_PID=$!
    fi

    # Handle restart-requested flag (from platform_ha_daemon_restart)
    if [[ -f /run/pihole-ha/restart-requested ]]; then
        rm -f /run/pihole-ha/restart-requested
        log_info "event=daemon_restart_requested"
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
        /usr/local/bin/pihole-ha &
        DAEMON_PID=$!
        echo "$DAEMON_PID" > /run/pihole-ha/daemon.pid
    fi

    # Run sync timers
    NOW="$(date +%s)"
    if (( NOW - LAST_SYNC >= SYNC_INTERVAL )); then
        if [[ -f /run/pihole-ha/sync-enabled ]]; then
            log_info "event=sync_build_trigger"
            /usr/local/bin/pihole-ha-sync &>/dev/null &
        elif [[ -f /run/pihole-ha/sync-pull-enabled ]]; then
            log_info "event=sync_pull_trigger"
            /usr/local/bin/pihole-ha-sync-pull &>/dev/null &
        fi
        LAST_SYNC="$NOW"
    fi

    # Monthly IEEE OUI DB refresh (parity with bare-metal timer)
    if (( NOW - LAST_OUI >= OUI_INTERVAL )); then
        log_info "event=oui_refresh_trigger"
        /usr/local/bin/pihole-ha-oui-update >/dev/null 2>&1 &
        LAST_OUI="$NOW"
    fi
done
