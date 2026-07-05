#!/bin/bash
set -euo pipefail

# --- Pi-hole style colors and icons ---
COL_NC='\e[0m'
COL_BOLD='\e[1m'
COL_GREEN='\e[32m'
COL_RED='\e[91m'
COL_YELLOW='\e[33m'
COL_GRAY='\e[90m'
TICK="[${COL_GREEN}✓${COL_NC}]"
CROSS="[${COL_RED}✗${COL_NC}]"
INFO="[i]"
OVER="\\r\\033[K"

is_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local i; for i in 1 2 3 4; do (( ${BASH_REMATCH[$i]} > 255 )) && return 1; done; return 0
}

printf "\\n"
_bw=37
_brule="$(printf '═%.0s' $(seq 1 $((_bw + 2))))"
printf "  ${COL_GREEN}╔%s╗${COL_NC}\\n" "$_brule"
printf "  ${COL_GREEN}║${COL_NC}  ${COL_BOLD}%-*s${COL_NC}${COL_GREEN}║${COL_NC}\\n" "$_bw" "Pi-hole HA Installer"
printf "  ${COL_GREEN}║${COL_NC}  %-*s${COL_GREEN}║${COL_NC}\\n" "$_bw" "DHCP High Availability Cluster"
printf "  ${COL_GREEN}╚%s╝${COL_NC}\\n" "$_brule"
printf "\\n"

# --- 1. Check root ---
if [[ $EUID -ne 0 ]]; then
    printf "  %b %bRoot privileges required%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
    printf "      Run: sudo ./install.sh\\n"
    exit 1
fi
printf "  %b Running as root\\n" "${TICK}"

# --- 1b. Uninstall mode (install.sh --uninstall [-y]) ---
if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
    printf "\\n  %b ${COL_BOLD}Uninstall pihole-ha from this node${COL_NC}\\n" "${INFO}"
    if [[ "${2:-}" != "-y" && "${2:-}" != "--yes" ]]; then
        read -erp "  This removes services, config, and the admin panel here. Continue? [y/N]: " _u_ok
        [[ "$_u_ok" =~ ^[Yy] ]] || { printf "  Aborted.\\n"; exit 0; }
    fi

    # Leave the cluster: notify every peer DIRECTLY to drop this node. Don't rely on
    # the local dash to propagate — it's about to be stopped. Peers + this node's own
    # cluster IP are read from nodes.conf.
    printf "  %b Leaving cluster..." "${INFO}"
    if [[ -f /etc/pihole-ha/nodes.conf ]]; then
        _u_nodes="$(sed -n 's/^HA_NODES=//p' /etc/pihole-ha/nodes.conf)"
        IFS=',' read -ra _u_peers <<< "$_u_nodes"
        _u_self=""
        for _u_e in "${_u_peers[@]}"; do
            _u_eip="${_u_e%%:*}"
            ip -o -4 addr show 2>/dev/null | grep -qw "$_u_eip" && { _u_self="$_u_eip"; break; }
        done
        [[ -z "$_u_self" ]] && _u_self="$(hostname -I | awk '{print $1}')"
        for _u_e in "${_u_peers[@]}"; do
            _u_pip="${_u_e%%:*}"
            [[ "$_u_pip" == "$_u_self" ]] && continue
            curl -sf --max-time 5 "http://$_u_pip:8887/api/nodes/leave?node=${_u_self}&propagated=1" >/dev/null 2>&1 || true
        done
    fi
    printf "%b  %b Left cluster (peers notified)\\n" "${OVER}" "${TICK}"

    # Release the VIP if this node currently holds it
    if [[ -f /etc/pihole-ha/nodes.conf ]]; then
        _u_vip="$(grep '^VIP=' /etc/pihole-ha/nodes.conf | cut -d= -f2)"
        _u_ve="$(grep '^VIP_ENABLED=' /etc/pihole-ha/nodes.conf | cut -d= -f2)"
        _u_gw="$(grep '^GATEWAY=' /etc/pihole-ha/nodes.conf | cut -d= -f2)"
        if [[ "$_u_ve" == "true" && -n "$_u_vip" ]]; then
            _u_if="$(ip -o route get "${_u_gw:-1.1.1.1}" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
            [[ -n "$_u_if" ]] && ip addr del "${_u_vip}/32" dev "$_u_if" 2>/dev/null || true
        fi
    fi

    # Stop and disable every unit
    printf "  %b Stopping services..." "${INFO}"
    for _u in pihole-ha pihole-ha-dash pihole-ha-sync.timer pihole-ha-sync-pull.timer \
              pihole-ha-inject.path pihole-ha-ieee-update.timer pihole-ha-sync.service \
              pihole-ha-sync-pull.service pihole-ha-inject.service pihole-ha-ieee-update.service; do
        systemctl stop "$_u" 2>/dev/null || true
        systemctl disable "$_u" 2>/dev/null || true
    done
    printf "%b  %b Services stopped and disabled\\n" "${OVER}" "${TICK}"

    # Remove dnsmasq hooks BEFORE deleting the binary they reference, so dnsmasq
    # doesn't fail on a missing dhcp-script when FTL reloads
    rm -f /etc/dnsmasq.d/09-pihole-ha.conf /etc/dnsmasq.d/10-pihole-ha-dhcp-script.conf
    _u_lines="$(pihole-FTL --config misc.dnsmasq_lines 2>/dev/null || true)"
    if [[ "$_u_lines" == *"new_dhcp_device"* ]]; then
        _u_clean="$(printf '%s' "$_u_lines" | sed 's/,"dhcp-script=[^"]*"//;s/"dhcp-script=[^"]*",//;s/"dhcp-script=[^"]*"//')"
        pihole-FTL --config misc.dnsmasq_lines "$_u_clean" >/dev/null 2>&1 || true
    fi

    # Remove binaries and systemd units
    rm -f /usr/local/bin/pihole-ha /usr/local/bin/pihole-ha-dash /usr/local/bin/pihole-ha-sync \
          /usr/local/bin/pihole-ha-sync-pull /usr/local/bin/pihole-ha-inject \
          /usr/local/bin/new_dhcp_device /usr/local/bin/pihole-ha-oui-update
    rm -f /etc/systemd/system/pihole-ha*.service /etc/systemd/system/pihole-ha*.timer /etc/systemd/system/pihole-ha*.path
    systemctl daemon-reload 2>/dev/null || true

    # Remove the admin-panel files and revert the sidebar nav patch
    rm -f /var/www/html/admin/ha.lp /var/www/html/admin/ha-api.lp /var/www/html/admin/scripts/js/ha.js
    _u_sidebar="/var/www/html/admin/scripts/lua/sidebar.lp"
    if [[ -f "$_u_sidebar" ]] && grep -q 'HA Cluster' "$_u_sidebar"; then
        python3 - "$_u_sidebar" <<'PYEOF' 2>/dev/null || true
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\s*<!-- HA Cluster -->.*?</li>\n', '\n', s, flags=re.S)
s = s.replace("'network', 'ha'})", "'network'})")
open(p, 'w').write(s)
PYEOF
    fi

    # Remove config, shared, lib, runtime, and the OUI database
    rm -rf /etc/pihole-ha /usr/local/share/pihole-ha /usr/local/lib/pihole-ha /run/pihole-ha /var/lib/ieee-data

    # Reload FTL so the removed dnsmasq hooks take effect
    systemctl restart pihole-FTL >/dev/null 2>&1 || pihole restartdns >/dev/null 2>&1 || true

    printf "\\n  %b pihole-ha removed from this node.\\n" "${TICK}"
    printf "  %b Pi-hole's web port was left as-is; reset it manually if you changed it for the cluster.\\n" "${INFO}"
    exit 0
fi

# --- 1c. Update mode: refresh code only, keep config + cluster membership ---
if [[ "${1:-}" == "--update" ]]; then
    printf "\\n  %b ${COL_BOLD}Update pihole-ha (code only)${COL_NC}\\n" "${INFO}"
    _src="$(cd "$(dirname "$0")" && pwd)"
    if [[ ! -f "$_src/pihole-ha" || ! -f "$_src/pihole-ha-dash" ]]; then
        printf "  %b %bRun this from the pihole-ha repo dir (git pull first)%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
        exit 1
    fi
    # scripts
    for _s in pihole-ha pihole-ha-dash pihole-ha-sync pihole-ha-sync-pull pihole-ha-inject; do
        [[ -f "$_src/$_s" ]] && { cp "$_src/$_s" "/usr/local/bin/$_s"; chmod 755 "/usr/local/bin/$_s"; }
    done
    [[ -f "$_src/new-dhcp-device" ]] && { cp "$_src/new-dhcp-device" /usr/local/bin/new_dhcp_device; chmod 755 /usr/local/bin/new_dhcp_device; }
    [[ -f "$_src/pihole-ha-oui-update" ]] && { cp "$_src/pihole-ha-oui-update" /usr/local/bin/pihole-ha-oui-update; chmod 755 /usr/local/bin/pihole-ha-oui-update; }
    # platform library
    if [[ -f "$_src/pihole-ha-platform" ]]; then
        mkdir -p /usr/local/lib/pihole-ha
        cp "$_src/pihole-ha-platform" /usr/local/lib/pihole-ha/pihole-ha-platform
        chmod 755 /usr/local/lib/pihole-ha/pihole-ha-platform
    fi
    # web UI source (admin panel; www/ only exists in the internal build)
    mkdir -p /usr/local/share/pihole-ha
    for _w in ha.lp ha-api.lp ha.js; do [[ -f "$_src/$_w" ]] && cp "$_src/$_w" "/usr/local/share/pihole-ha/$_w"; done
    if [[ -d "$_src/www" ]]; then
        mkdir -p /usr/local/share/pihole-ha/www
        cp "$_src/www/"* /usr/local/share/pihole-ha/www/ 2>/dev/null || true
    fi
    # systemd unit files (in case any changed)
    for _u in "$_src"/pihole-ha*.service "$_src"/pihole-ha*.timer "$_src"/pihole-ha*.path; do
        [[ -f "$_u" ]] && cp "$_u" /etc/systemd/system/
    done
    systemctl daemon-reload 2>/dev/null || true
    # re-inject the admin panel with the refreshed files
    [[ -x /usr/local/bin/pihole-ha-inject ]] && /usr/local/bin/pihole-ha-inject >/dev/null 2>&1 || true
    # restart the running services so the new code takes effect
    for _svc in pihole-ha pihole-ha-dash; do
        systemctl is-enabled "$_svc" >/dev/null 2>&1 && systemctl restart "$_svc" 2>/dev/null || true
    done
    printf "  %b Code, web UI, and units updated; services restarted\\n" "${TICK}"
    printf "  %b Config and cluster membership left unchanged.\\n" "${INFO}"
    exit 0
fi

# --- 2. Check Pi-hole installed ---
if ! command -v pihole-FTL &>/dev/null; then
    printf "  %b %bPi-hole (pihole-FTL) not found%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
    printf "      Install Pi-hole first: https://pi-hole.net\\n"
    exit 1
fi
printf "  %b Pi-hole detected\\n" "${TICK}"

# --- 3. Auto-detect local IP and gateway ---
local_ip="$(hostname -I | awk '{print $1}')"
detected_gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
detected_gw="${detected_gw:-}"
subnet="$(echo "$local_ip" | cut -d. -f1-3)"

printf "  %b Local IP:    %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$local_ip" "${COL_NC}"
printf "  %b Gateway:     %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$detected_gw" "${COL_NC}"
printf "  %b Subnet:      %b%s.0/24%b\\n" "${INFO}" "${COL_BOLD}" "$subnet" "${COL_NC}"
printf "\\n"

# --- 4. Gateway ---
read -erp "  Gateway IP [$detected_gw]: " input_gw
gateway="${input_gw:-$detected_gw}"
if ! is_valid_ip "$gateway"; then
    printf "  %b %bInvalid gateway IP: %s%b\\n" "${CROSS}" "${COL_RED}" "$gateway" "${COL_NC}"
    exit 1
fi
printf "  %b Gateway: %s\\n" "${TICK}" "$gateway"

# --- 5. Scan subnet for existing HA nodes ---
printf "\\n"
printf "  %b Scanning for existing HA nodes...\\n" "${INFO}"
discovered_nodes=()
discovered_ports=()
cluster_vip=""
declare -A _seen_real_ips

# Parallel scan: fire all probes as background jobs writing to temp dir
_scan_dir="$(mktemp -d)"
trap "rm -rf '$_scan_dir'" EXIT
for octet in $(seq 1 254); do
    probe_ip="$subnet.$octet"
    [[ "$probe_ip" == "$local_ip" ]] && continue
    (
        resp="$(curl -sf --connect-timeout 0.15 --max-time 0.5 "http://$probe_ip:8887/api/status" 2>/dev/null)" || exit 0
        [[ -z "$resp" ]] && exit 0
        echo "$resp" > "$_scan_dir/$octet"
    ) &
done
# Progress while waiting
_total_jobs="$(jobs -p | wc -l)"
while [[ "$(jobs -rp | wc -l)" -gt 0 ]]; do
    _remaining="$(jobs -rp | wc -l)"
    _done=$(( _total_jobs - _remaining ))
    printf "%b      Probing... %d/%d" "${OVER}" "$_done" "$_total_jobs"
    sleep 0.2
done
printf "%b      Probing... done\\n" "${OVER}"

# Collect results (sort numerically so .3 is processed before .123)
for f in $(ls "$_scan_dir"/ 2>/dev/null | sort -n); do
    [[ -f "$_scan_dir/$f" ]] || continue
    octet="$f"
    probe_ip="$subnet.$octet"
    probe_json="$(cat "$_scan_dir/$f")"
    real_ip="$(echo "$probe_json" | sed -n 's/.*"node":{[^}]*"ip":"\([^"]*\)".*/\1/p' | head -1)"
    real_ip="${real_ip:-$probe_ip}"
    if [[ -n "${_seen_real_ips[$real_ip]:-}" ]]; then
        printf "      %b%s%b — VIP (same node as %s), skipped\\n" "${COL_YELLOW}" "$probe_ip" "${COL_NC}" "$real_ip"
        continue
    fi
    _seen_real_ips["$real_ip"]=1
    probe_role="$(echo "$probe_json" | sed -n 's/.*"node":{[^}]*"role":"\([^"]*\)".*/\1/p' | head -1)"
    # Extract VIP address from the cluster
    if [[ -z "$cluster_vip" ]]; then
        _probe_vip="$(echo "$probe_json" | sed -n 's/.*"vip":"\([^"]*\)".*/\1/p' | head -1)"
        _probe_vip_enabled="$(echo "$probe_json" | sed -n 's/.*"vip_enabled":\([a-z]*\).*/\1/p' | head -1)"
        if [[ -n "$_probe_vip" && "$_probe_vip_enabled" == "true" ]]; then
            cluster_vip="$_probe_vip"
        fi
    fi
    probe_port="$(curl -sf --connect-timeout 0.15 --max-time 0.5 "http://$probe_ip:8887/api/config" 2>/dev/null \
        | sed -n 's/.*"pihole_port":\([0-9]*\).*/\1/p' | head -1 || true)"
    probe_port="${probe_port:-80}"
    printf "  %b Found %b%s%b — %s (port %s)\\n" "${TICK}" "${COL_BOLD}" "$real_ip" "${COL_NC}" "$probe_role" "$probe_port"
    discovered_nodes+=("$real_ip")
    discovered_ports+=("$probe_port")
done
rm -rf "$_scan_dir"

if [[ ${#discovered_nodes[@]} -eq 0 ]]; then
    printf "  %b No existing HA nodes found\\n" "${INFO}"
fi

# --- 6. Build node list ---
declare -A node_ports
all_nodes=()
all_node_entries=()

_add_node() {
    local ip="$1" port="$2"
    all_nodes+=("$ip")
    node_ports["$ip"]="$port"
    if [[ "$port" != "80" ]]; then
        all_node_entries+=("$ip:$port")
    else
        all_node_entries+=("$ip")
    fi
}

# Detect the port Pi-hole's web/API is actually reachable on. Don't guess from a
# fixed list — probe every port FTL is configured for AND every port pihole-FTL
# is actually listening on, so Pi-hole is found on whatever port it runs.
_is_pihole_port() { curl -s --max-time 2 "http://localhost:${1}/api/auth" 2>/dev/null | grep -q '"session"' 2>/dev/null; }
_port_in_use() { ss -tlnH "sport = :${1}" 2>/dev/null | grep -q . 2>/dev/null; }

_ftl_cfg_ports="$(pihole-FTL --config webserver.port 2>/dev/null | grep -oE '[0-9]+')"
_ftl_live_ports="$(ss -lntpH 2>/dev/null | awk '/pihole-FTL/{n=split($4,a,":"); print a[n]}')"
_cands="$(printf '%s\n%s\n' "$_ftl_cfg_ports" "$_ftl_live_ports" | grep -E '^[0-9]+$' | awk '$1>0' | sort -un)"
_local_web_port=""
for _p in $_cands; do
    if _is_pihole_port "$_p"; then _local_web_port="$_p"; break; fi
done

if [[ -n "$_local_web_port" ]]; then
    printf "  %b Pi-hole detected on port %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$_local_web_port" "${COL_NC}"
else
    # Pi-hole's API is not reachable on any port it is bound to — most likely its
    # port is occupied by another service (e.g. on the IPv4 side). Pick a free
    # port, confirm, and move Pi-hole there so it matches the cluster record.
    _cfg_first="$(printf '%s\n' "$_ftl_cfg_ports" | grep -E '^[0-9]+$' | head -1)"; _cfg_first="${_cfg_first:-80}"
    printf "  %b %bPi-hole API not reachable on port %s (in use by another service?)%b\\n" "${CROSS}" "${COL_RED}" "$_cfg_first" "${COL_NC}"
    _new_port=""
    for _try_port in 8080 8888 8443 3000 9080; do
        if ! _port_in_use "$_try_port"; then _new_port="$_try_port"; break; fi
    done
    _new_port="${_new_port:-8080}"
    read -erp "  Pi-hole web port [$_new_port]: " _input_port
    _local_web_port="${_input_port:-$_new_port}"
    printf "  %b Moving Pi-hole web server to port %s..." "${INFO}" "$_local_web_port"
    pihole-FTL --config webserver.port "${_local_web_port}o,443os,[::]:${_local_web_port}o,[::]:443os" >/dev/null 2>&1
    systemctl restart pihole-FTL >/dev/null 2>&1 || pihole restartdns >/dev/null 2>&1 || true
    for _w in $(seq 1 10); do _is_pihole_port "$_local_web_port" && break; sleep 1; done
    if _is_pihole_port "$_local_web_port"; then
        printf "%b  %b Pi-hole web server now on port %s\\n" "${OVER}" "${TICK}" "$_local_web_port"
    else
        printf "%b  %b %bPi-hole did not answer on port %s after restart — verify manually%b\\n" "${OVER}" "${CROSS}" "${COL_RED}" "$_local_web_port" "${COL_NC}"
    fi
fi
printf "  %b Local Pi-hole web port: %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$_local_web_port" "${COL_NC}"

# Auto-fill: discovered nodes first (preserve priority), this node last
for i in "${!discovered_nodes[@]}"; do
    _add_node "${discovered_nodes[$i]}" "${discovered_ports[$i]}"
done
_add_node "$local_ip" "$_local_web_port"

if [[ ${#all_nodes[@]} -gt 1 ]]; then
    # Show auto-filled list and confirm
    printf "\\n"
    printf "  %b Node list (this node + discovered):\\n" "${INFO}"
    for i in "${!all_nodes[@]}"; do
        _p="${node_ports[${all_nodes[$i]}]}"
        _label=""
        [[ "${all_nodes[$i]}" == "$local_ip" ]] && _label=" (this node)"
        if [[ "$_p" != "80" ]]; then
            printf "      %b%d)%b %s:%s%s\\n" "${COL_BOLD}" "$((i+1))" "${COL_NC}" "${all_nodes[$i]}" "$_p" "$_label"
        else
            printf "      %b%d)%b %s%s\\n" "${COL_BOLD}" "$((i+1))" "${COL_NC}" "${all_nodes[$i]}" "$_label"
        fi
    done
    printf "\\n"
    read -erp "  Use this node list? [Y/n]: " use_list
    if [[ "$use_list" =~ ^[Nn] ]]; then
        all_nodes=()
        all_node_entries=()
        node_ports=()
        declare -A node_ports
        printf "\\n"
        printf "  %b Enter node IPs manually:\\n" "${INFO}"
        printf "\\n"
        for n in 1 2 3; do
            local_default=""
            [[ $n -eq 1 ]] && local_default="$local_ip"
            required="true"
            [[ $n -eq 3 ]] && required="false"
            if [[ -n "$local_default" ]]; then
                read -erp "  Node $n IP [$local_default]: " _ip
                _ip="${_ip:-$local_default}"
            else
                read -erp "  Node $n IP [skip]: " _ip
            fi
            [[ -z "$_ip" ]] && { [[ "$required" == "true" ]] && { printf "  %b %bNode %s IP is required%b\\n" "${CROSS}" "${COL_RED}" "$n" "${COL_NC}"; exit 1; }; continue; }
            if ! is_valid_ip "$_ip"; then
                printf "  %b %bInvalid IP: %s%b\\n" "${CROSS}" "${COL_RED}" "$_ip" "${COL_NC}"
                exit 1
            fi
            read -erp "  Node $n Pi-hole web port [80]: " _port
            _port="${_port:-80}"
            _add_node "$_ip" "$_port"
        done
    fi
else
    # No discovered nodes — manual entry for remaining
    printf "\\n"
    printf "  %b Node 1: %b%s%b (this node)\\n" "${TICK}" "${COL_BOLD}" "$local_ip" "${COL_NC}"
    printf "\\n"
    for n in 2 3; do
        required="true"
        [[ $n -eq 3 ]] && required="false"
        read -erp "  Node $n IP [skip]: " _ip
        [[ -z "$_ip" ]] && { [[ "$required" == "true" ]] && { printf "  %b %bNode 2 IP is required%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"; exit 1; }; continue; }
        if ! is_valid_ip "$_ip"; then
            printf "  %b %bInvalid IP: %s%b\\n" "${CROSS}" "${COL_RED}" "$_ip" "${COL_NC}"
            exit 1
        fi
        read -erp "  Node $n Pi-hole web port [80]: " _port
        _port="${_port:-80}"
        _add_node "$_ip" "$_port"
    done
fi

# Find local node index
my_idx=-1
for i in "${!all_nodes[@]}"; do
    [[ "$local_ip" == "${all_nodes[$i]}" ]] && { my_idx=$i; break; }
done
[[ $my_idx -lt 0 ]] && my_idx=0

# --- 8. Determine role ---
is_primary=false
existing_primary=""

if [[ ${#discovered_nodes[@]} -gt 0 ]]; then
    # Existing cluster found — this node joins as secondary automatically
    for i in "${!discovered_nodes[@]}"; do
        _check_ip="${discovered_nodes[$i]}"
        _check_json="$(curl -sf --connect-timeout 0.15 --max-time 0.5 "http://$_check_ip:8887/api/status" 2>/dev/null || true)"
        [[ -z "$_check_json" ]] && continue
        _check_role="$(echo "$_check_json" | sed -n 's/.*"node":{[^}]*"role":"\([^"]*\)".*/\1/p' | head -1)"
        if [[ "$_check_role" == "PRIMARY" ]]; then
            existing_primary="$_check_ip"
            break
        fi
    done
    printf "  %b Joining existing cluster as %bSECONDARY%b\\n" "${TICK}" "${COL_YELLOW}" "${COL_NC}"
else
    # No existing nodes — this node becomes primary
    is_primary=true
    printf "  %b No existing cluster — this node will be %bPRIMARY%b\\n" "${TICK}" "${COL_GREEN}" "${COL_NC}"
fi

# Helper: get node entry (IP:PORT or just IP) for a given IP
_node_entry() {
    local ip="$1" port="${node_ports[$1]:-80}"
    [[ "$port" != "80" ]] && echo "$ip:$port" || echo "$ip"
}

# Reorder node list: primary first, then the rest
_reorder_nodes() {
    local first="$1"
    local ordered_ips=("$first") ordered_entries=("$(_node_entry "$first")")
    for _n in "${all_nodes[@]}"; do
        [[ "$_n" == "$first" ]] && continue
        ordered_ips+=("$_n")
        ordered_entries+=("$(_node_entry "$_n")")
    done
    all_nodes=("${ordered_ips[@]}")
    all_node_entries=("${ordered_entries[@]}")
}

if [[ "$is_primary" == "true" ]]; then
    _reorder_nodes "$local_ip"
elif [[ -n "$existing_primary" ]]; then
    _reorder_nodes "$existing_primary"
fi

# Rebuild ha_nodes_str and my_idx after reordering
ha_nodes_str="$(IFS=,; echo "${all_node_entries[*]}")"
my_idx=-1
for i in "${!all_nodes[@]}"; do
    [[ "$local_ip" == "${all_nodes[$i]}" ]] && { my_idx=$i; break; }
done
[[ $my_idx -lt 0 ]] && my_idx=0

priority=$((my_idx + 1))
if [[ "$is_primary" == "true" ]]; then
    role_name="PRIMARY (P1)"
else
    role_name="STANDBY (P${priority})"
fi

# --- 9b. Deployment mode: DHCP-HA vs DNS-only (a cluster-wide property) ---
# DHCP-HA: Pi-hole serves DHCP with failover. DNS-only: another server does DHCP
# and we never touch dhcp.active/VIP (just sync + monitor). Installing DHCP-HA on
# a DNS-only LAN would create a second DHCP server, so detect and default safe.
_dhcp_mode="dhcp"
if [[ ${#discovered_nodes[@]} -gt 0 ]]; then
    # Joining an existing cluster — inherit its mode. A standby's own dhcp.active
    # is always false and would misfire, so the cluster decides. Peers on an older
    # dash won't report dhcp_ha; default to DHCP-HA (what pre-existing clusters are).
    for _mp in "${discovered_nodes[@]}"; do
        _mode_ha="$(curl -sf --max-time 5 "http://$_mp:8887/api/config" 2>/dev/null | sed -n 's/.*"dhcp_ha":"\([a-z]*\)".*/\1/p' || true)"
        if [[ -n "$_mode_ha" ]]; then
            [[ "$_mode_ha" == "false" ]] && _dhcp_mode="dns"
            break
        fi
    done
    printf "  %b Deployment: %b%s%b (inherited from cluster)\\n" "${TICK}" "${COL_BOLD}" "$([[ "$_dhcp_mode" == "dns" ]] && echo DNS-only || echo DHCP-HA)" "${COL_NC}"
elif [[ "$(pihole-FTL --config dhcp.active 2>/dev/null)" == "true" ]]; then
    printf "  %b Pi-hole DHCP is active — %bDHCP-HA%b deployment\\n" "${TICK}" "${COL_BOLD}" "${COL_NC}"
else
    _ext_dhcp=""
    if command -v nmap >/dev/null 2>&1; then
        _ext_dhcp="$(nmap --script broadcast-dhcp-discover 2>/dev/null | sed -n 's/.*Server Identifier: \([0-9.]*\).*/\1/p' | grep -vx "$local_ip" | head -1 || true)"
    fi
    if [[ -n "$_ext_dhcp" ]]; then
        _dhcp_mode="dns"
        printf "  %b Another DHCP server found at %b%s%b — %bDNS-only%b deployment (Pi-hole DHCP left off)\\n" "${INFO}" "${COL_BOLD}" "$_ext_dhcp" "${COL_NC}" "${COL_BOLD}" "${COL_NC}"
    else
        printf "\\n  %b Pi-hole is not currently serving DHCP. Choose deployment:\\n" "${INFO}"
        printf "      ${COL_BOLD}1)${COL_NC} DHCP-HA   — Pi-hole becomes your DHCP server, with failover + VIP\\n"
        printf "      ${COL_BOLD}2)${COL_NC} DNS-only  — another server does DHCP; config sync + redundancy only\\n"
        read -erp "  Deployment type [2]: " _mode_choice
        [[ "$_mode_choice" == "1" ]] && _dhcp_mode="dhcp" || _dhcp_mode="dns"
    fi
fi
_dhcp_ha_val="true"; [[ "$_dhcp_mode" == "dns" ]] && _dhcp_ha_val="false"

# --- 10. VIP (DHCP-HA only; a VIP follows the DHCP master) ---
if [[ "$_dhcp_mode" == "dns" ]]; then
    vip_enabled="false"; vip=""
    printf "  %b VIP skipped (DNS-only deployment)\\n" "${INFO}"
elif [[ -n "$cluster_vip" ]]; then
    printf "  %b Cluster VIP detected: %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$cluster_vip" "${COL_NC}"
    vip_enabled="true"
    vip="$cluster_vip"
else
    printf "\\n"
    printf "  %b ${COL_BOLD}Virtual IP (VIP)${COL_NC}\\n" "${INFO}"
    printf "      A VIP is a floating IP that moves to whichever node is serving DHCP.\\n"
    printf "      It can be used as a DNS address that survives failover.\\n"
    printf "\\n"
    read -erp "  Enable VIP? (must type 'yes') [yes/NO]: " vip_choice
    if [[ "$vip_choice" == "yes" ]]; then
        vip_enabled="true"
        read -erp "  Virtual IP (VIP) address: " vip
        if [[ -z "$vip" ]]; then
            printf "  %b %bVIP address is required when VIP is enabled%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
            exit 1
        fi
        if ! is_valid_ip "$vip"; then
            printf "  %b %bInvalid VIP: %s%b\\n" "${CROSS}" "${COL_RED}" "$vip" "${COL_NC}"
            exit 1
        fi
        printf "  %b VIP: %s\\n" "${TICK}" "$vip"
    else
        vip_enabled="false"
        vip=""
        printf "  %b VIP disabled\\n" "${TICK}"
    fi
fi

# --- 11. Summary ---
printf "\\n"
printf "  ${COL_GREEN}╔═══════════════════════════════════════╗${COL_NC}\\n"
printf "  ${COL_GREEN}║${COL_NC}  ${COL_BOLD}Configuration Summary${COL_NC}                ${COL_GREEN}║${COL_NC}\\n"
printf "  ${COL_GREEN}╚═══════════════════════════════════════╝${COL_NC}\\n"
printf "\\n"
printf "  %b This node:  %b%s%b — %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$local_ip" "${COL_NC}" "${COL_BOLD}" "$role_name" "${COL_NC}"
printf "  %b Gateway:    %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$gateway" "${COL_NC}"
if [[ "$vip_enabled" == "true" ]]; then
    printf "  %b VIP:        %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$vip" "${COL_NC}"
else
    printf "  %b VIP:        %bdisabled%b\\n" "${INFO}" "${COL_YELLOW}" "${COL_NC}"
fi
printf "  %b Nodes:      %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$ha_nodes_str" "${COL_NC}"
if [[ "$is_primary" == "true" ]]; then
    printf "  %b Role:       %bPRIMARY — builds sync payloads%b\\n" "${INFO}" "${COL_GREEN}" "${COL_NC}"
else
    printf "  %b Role:       %bSECONDARY — pulls from primary%b\\n" "${INFO}" "${COL_YELLOW}" "${COL_NC}"
fi
printf "\\n"
read -erp "  Proceed with installation? [Y/n]: " proceed
[[ "$proceed" =~ ^[Nn] ]] && { printf "  Aborted.\\n"; exit 0; }

# --- 12. Install dependencies ---
printf "\\n"
_need_pkgs=()
for pkg in socat curl netcat-openbsd arping; do
    dpkg -s "$pkg" &>/dev/null || _need_pkgs+=("$pkg")
done
if [[ ${#_need_pkgs[@]} -gt 0 ]]; then
    printf "  %b Installing: %s..." "${INFO}" "${_need_pkgs[*]}"
    if apt-get update -qq && apt-get install -y -qq "${_need_pkgs[@]}" 2>/dev/null; then
        printf "%b  %b Dependencies installed\\n" "${OVER}" "${TICK}"
    else
        printf "%b  %b %bFailed to install some dependencies%b\\n" "${OVER}" "${CROSS}" "${COL_RED}" "${COL_NC}"
    fi
else
    printf "  %b All dependencies already installed\\n" "${TICK}"
fi

# --- 13. Install scripts ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

printf "  %b Installing platform abstraction..." "${INFO}"
mkdir -p /usr/local/lib/pihole-ha
cp "$SCRIPT_DIR/pihole-ha-platform" /usr/local/lib/pihole-ha/pihole-ha-platform
chmod 755 /usr/local/lib/pihole-ha/pihole-ha-platform
printf "%b  %b Platform abstraction installed\\n" "${OVER}" "${TICK}"

printf "  %b Installing scripts..." "${INFO}"
for script in pihole-ha pihole-ha-dash pihole-ha-sync pihole-ha-sync-pull pihole-ha-inject; do
    cp "$SCRIPT_DIR/$script" /usr/local/bin/$script
    chmod 755 /usr/local/bin/$script
done
cp "$SCRIPT_DIR/new-dhcp-device" /usr/local/bin/new_dhcp_device
chmod 755 /usr/local/bin/new_dhcp_device
cp "$SCRIPT_DIR/pihole-ha-oui-update" /usr/local/bin/pihole-ha-oui-update
chmod 755 /usr/local/bin/pihole-ha-oui-update
printf "%b  %b Scripts installed\\n" "${OVER}" "${TICK}"

printf "  %b Installing web UI files..." "${INFO}"
mkdir -p /usr/local/share/pihole-ha
cp "$SCRIPT_DIR/ha.lp" /usr/local/share/pihole-ha/ha.lp
cp "$SCRIPT_DIR/ha-api.lp" /usr/local/share/pihole-ha/ha-api.lp
cp "$SCRIPT_DIR/ha.js" /usr/local/share/pihole-ha/ha.js
printf "%b  %b Web UI files installed\\n" "${OVER}" "${TICK}"

printf "  %b Installing systemd services..." "${INFO}"
cp "$SCRIPT_DIR/pihole-ha.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-dash.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-sync.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-sync.timer" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-sync-pull.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-sync-pull.timer" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-inject.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-inject.path" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-ieee-update.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-ha-ieee-update.timer" /etc/systemd/system/
systemctl daemon-reload
printf "%b  %b Systemd services installed\\n" "${OVER}" "${TICK}"

# --- 15. Write /etc/pihole-ha/nodes.conf ---
printf "  %b Writing configuration..." "${INFO}"
mkdir -p /etc/pihole-ha
cat > /etc/pihole-ha/nodes.conf <<NCONF
CONFIG_VERSION=1
GATEWAY=$gateway
VIP=$vip
VIP_ENABLED=$vip_enabled
HA_ENABLED=true
DHCP_HA=$_dhcp_ha_val
HA_NODES=$ha_nodes_str
NCONF
printf "%b  %b Configuration written to /etc/pihole-ha/nodes.conf\\n" "${OVER}" "${TICK}"

# --- 16. Configure DHCP role ---
if [[ "$_dhcp_mode" == "dns" ]]; then
    printf "  %b DNS-only deployment — leaving Pi-hole DHCP untouched\\n" "${INFO}"
else
    printf "  %b Configuring DHCP role..." "${INFO}"
    if [[ "$is_primary" == "true" ]]; then
        if pihole-FTL --config dhcp.active true >/dev/null 2>&1; then
            printf "%b  %b DHCP enabled (primary)\\n" "${OVER}" "${TICK}"
        else
            printf "%b  %b %bDHCP not enabled — set a DHCP range in Pi-hole (Settings > DHCP), then re-run%b\\n" "${OVER}" "${CROSS}" "${COL_YELLOW}" "${COL_NC}"
        fi
    else
        pihole-FTL --config dhcp.active false >/dev/null 2>&1 || true
        printf "%b  %b DHCP disabled (standby — auto-activates on failover)\\n" "${OVER}" "${TICK}"
    fi
fi

# --- 17. Configure DHCP options (DHCP-HA only) ---
if [[ "$_dhcp_mode" != "dns" ]]; then
if [[ "$vip_enabled" == "true" && -n "$vip" ]]; then
    printf "  %b Configuring DHCP options (DNS=%s)..." "${INFO}" "$vip"
    cat > /etc/dnsmasq.d/09-pihole-ha.conf <<DNSCONF
# pihole-ha: DHCP options for clients
dhcp-option=6,$vip
dhcp-option=54,$vip
DNSCONF
else
    dns_list=""
    for _ip in "${all_nodes[@]}"; do
        [[ -n "$dns_list" ]] && dns_list+=","
        dns_list+="$_ip"
    done
    printf "  %b Configuring DHCP options (DNS=%s)..." "${INFO}" "$dns_list"
    cat > /etc/dnsmasq.d/09-pihole-ha.conf <<DNSCONF
# pihole-ha: DHCP options for clients
dhcp-option=6,$dns_list
DNSCONF
fi
printf "%b  %b DHCP options configured\\n" "${OVER}" "${TICK}"
systemctl restart pihole-FTL 2>/dev/null || true
fi

# --- 17b. Pin DNS to localhost on every active resolver path ---
# Critical: if /etc/resolv.conf points at the VIP and the VIP holder dies,
# the surviving node loses its own DNS (notifications fail, scripts break).
# Each Pi-hole runs FTL on 127.0.0.1#53 — always resolve locally.
printf "  %b Pinning system DNS to 127.0.0.1..." "${INFO}"
_pinned=()

# NetworkManager (Raspberry Pi OS Bookworm default)
if command -v nmcli &>/dev/null; then
    while IFS= read -r nm_con; do
        [[ -z "$nm_con" ]] && continue
        nmcli con mod "$nm_con" ipv4.dns "127.0.0.1" ipv4.ignore-auto-dns yes 2>/dev/null || true
        nmcli con up "$nm_con" >/dev/null 2>&1 || true
    done < <(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep -v ':lo$' | cut -d: -f1)
    _pinned+=("NetworkManager")
fi

# dhcpcd (Raspberry Pi OS Lite, older Raspbian)
if [[ -f /etc/dhcpcd.conf ]]; then
    sed -i '/# pihole-ha BEGIN/,/# pihole-ha END/d' /etc/dhcpcd.conf
    cat >> /etc/dhcpcd.conf <<'DHCPCD'
# pihole-ha BEGIN
static domain_name_servers=127.0.0.1
# pihole-ha END
DHCPCD
    systemctl restart dhcpcd 2>/dev/null || true
    _pinned+=("dhcpcd")
fi

# systemd-resolved (Debian/Ubuntu cloud images)
if systemctl is-active systemd-resolved &>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/pihole-ha.conf <<'RESOLVED'
[Resolve]
DNS=127.0.0.1
Domains=~.
DNSStubListener=no
RESOLVED
    systemctl restart systemd-resolved 2>/dev/null || true
    _pinned+=("systemd-resolved")
fi

# Final guarantee: write /etc/resolv.conf directly. If it's a managed symlink
# (systemd-resolved stub), break the link so our value sticks.
if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
fi
# Strip any prior immutable flag so we can rewrite
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf <<'RESOLV'
# pihole-ha: pin DNS to local FTL (do not edit — managed by pihole-ha installer)
nameserver 127.0.0.1
options edns0 trust-ad
RESOLV
_pinned+=("/etc/resolv.conf")

printf "%b  %b DNS pinned to 127.0.0.1 (%s)\\n" "${OVER}" "${TICK}" "$(IFS=,; echo "${_pinned[*]}")"

# Verify local resolution actually works through 127.0.0.1
printf "  %b Verifying local DNS resolution..." "${INFO}"
if command -v dig &>/dev/null && dig +short +timeout=3 +tries=1 @127.0.0.1 pi-hole.net A 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+'; then
    printf "%b  %b Local DNS resolves through 127.0.0.1\\n" "${OVER}" "${TICK}"
elif getent hosts pi-hole.net >/dev/null 2>&1; then
    printf "%b  %b Local DNS resolves through 127.0.0.1\\n" "${OVER}" "${TICK}"
else
    printf "%b  %b WARNING: 127.0.0.1 not resolving — check pihole-FTL\\n" "${OVER}" "${CROSS}"
fi

# --- 17c. Seed Pi-hole defaults (adlists, DHCP hosts, dnsmasq scripts) ---
printf "  %b Configuring Pi-hole defaults..." "${INFO}"

# Adlists
_adlists=(
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    "https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt"
    "https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt"
    "https://v.firebog.net/hosts/Admiral.txt"
    "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext"
    "https://www.github.developerdan.com/hosts/lists/ads-and-tracking-extended.txt"
    "https://www.github.developerdan.com/hosts/lists/amp-hosts-extended.txt"
    "https://raw.githubusercontent.com/bigdargon/hostsVN/master/hosts"
    "https://raw.githubusercontent.com/Sekhan/TheGreatWall/master/TheGreatWall.txt"
    "https://raw.githubusercontent.com/Bryantdl7/pihole-blocklists/main/dns-https-block.txt"
    "https://raw.githubusercontent.com/jpgpi250/piholemanual/master/DOH/DOHadb.txt"
    "https://raw.githubusercontent.com/RamSet/ad-hosts-blocking/main/ad-hosts"
    "https://raw.githubusercontent.com/RamSet/ad-hosts-blocking/main/cryptojack-hosts"
    "https://raw.githubusercontent.com/RamSet/ad-hosts-blocking/main/malware-hosts"
)
_existing_adlists="$(pihole-FTL sqlite3 /etc/pihole/gravity.db "SELECT COUNT(*) FROM adlist" 2>/dev/null)"
if [[ "$_existing_adlists" -le 1 ]] 2>/dev/null; then
    for _url in "${_adlists[@]}"; do
        pihole-FTL sqlite3 /etc/pihole/gravity.db \
            "INSERT OR IGNORE INTO adlist (address,enabled) VALUES ('$_url',1);" 2>/dev/null
    done
    printf "%b  %b Adlists seeded (%d lists)\\n" "${OVER}" "${TICK}" "${#_adlists[@]}"
else
    printf "%b  %b Adlists already configured (%s lists)\\n" "${OVER}" "${TICK}" "$_existing_adlists"
fi

# DHCP static hosts — configured by user via Pi-hole admin panel or sync from primary

# dhcp-script hook — new-device notifications fire on DHCP lease events, so only
# relevant when Pi-hole serves DHCP. Skip entirely in DNS-only deployments.
_dhcp_script_conf="/etc/dnsmasq.d/10-pihole-ha-dhcp-script.conf"
if [[ "$_dhcp_mode" == "dns" ]]; then
    printf "  %b DHCP script hook skipped (DNS-only)\\n" "${INFO}"
elif [[ ! -f "$_dhcp_script_conf" ]]; then
    printf "dhcp-script=/usr/local/bin/new_dhcp_device\\n" > "$_dhcp_script_conf"
    pihole-FTL --config misc.etc_dnsmasq_d true >/dev/null 2>&1
    # Clear any legacy misc.dnsmasq_lines entry for this hook
    _existing_lines="$(pihole-FTL --config misc.dnsmasq_lines 2>/dev/null)"
    if [[ "$_existing_lines" == *"new_dhcp_device"* ]]; then
        _cleaned="$(printf '%s' "$_existing_lines" | sed 's/,"dhcp-script=[^"]*"//;s/"dhcp-script=[^"]*",//;s/"dhcp-script=[^"]*"//')"
        [[ "$_cleaned" == "[]" || "$_cleaned" == "[,]" ]] && _cleaned="[]"
        pihole-FTL --config misc.dnsmasq_lines "$_cleaned" >/dev/null 2>&1
    fi
    printf "  %b DHCP script hook configured — restarting FTL to apply...\\n" "${TICK}"
    systemctl restart pihole-FTL >/dev/null 2>&1
    printf "  %b pihole-FTL restarted\\n" "${TICK}"
else
    printf "  %b DHCP script hook already present\\n" "${TICK}"
fi

# Upstream DNS: only point Pi-hole at a local unbound if one is actually present.
# Most installs don't run unbound; clobbering the upstream would break DNS resolution.
_unbound_present=false
if command -v unbound >/dev/null 2>&1 || command -v unbound-checkconf >/dev/null 2>&1; then
    _unbound_present=true
elif ss -H -lun 2>/dev/null | grep -q ':5335[[:space:]]' || ss -H -ltn 2>/dev/null | grep -q ':5335[[:space:]]'; then
    _unbound_present=true
fi
_upstream="$(pihole-FTL --config dns.upstreams 2>/dev/null)"
if [[ "$_unbound_present" == "true" && "$_upstream" != *"127.0.0.1#5335"* ]]; then
    pihole-FTL --config dns.upstreams '["127.0.0.1#5335"]' >/dev/null 2>&1
    pihole-FTL --config dns.cache.size 10000 >/dev/null 2>&1
    printf "  %b Upstream DNS set to local unbound (127.0.0.1#5335)\\n" "${TICK}"
elif [[ "$_unbound_present" != "true" ]]; then
    printf "  %b No local unbound detected; leaving Pi-hole upstream DNS unchanged\\n" "${INFO}"
fi

# --- 18. Create sync config ---
if [[ ! -f /etc/pihole-ha/sync.conf ]]; then
    if [[ "$is_primary" == "true" ]]; then
        _sync_primary="$local_ip"
    else
        _sync_primary="${all_nodes[0]}"
    fi
    cat > /etc/pihole-ha/sync.conf <<CONF
SYNC_ENABLED=true
SYNC_GRAVITY=true
SYNC_DHCP=true
SYNC_DNS=true
SYNC_SETTINGS=true
SYNC_INTERVAL=15
SYNC_PRIMARY=$_sync_primary
CONF
    printf "  %b Sync config created (SYNC_PRIMARY=%s)\\n" "${TICK}" "$_sync_primary"
else
    if ! grep -q "^SYNC_PRIMARY=" /etc/pihole-ha/sync.conf; then
        if [[ "$is_primary" == "true" ]]; then
            _sync_primary="$local_ip"
        else
            _sync_primary="${all_nodes[0]}"
        fi
        echo "SYNC_PRIMARY=$_sync_primary" >> /etc/pihole-ha/sync.conf
        printf "  %b Added SYNC_PRIMARY=%s to existing sync.conf\\n" "${TICK}" "$_sync_primary"
    else
        printf "  %b Sync config already exists\\n" "${TICK}"
    fi
fi

# --- 19. Create master.conf ---
if [[ ! -f /etc/pihole-ha/master.conf ]]; then
    echo "DHCP_MASTER=auto" > /etc/pihole-ha/master.conf
    printf "  %b Master config created (auto mode)\\n" "${TICK}"
fi

# --- 20. Create notify.conf ---
if [[ ! -f /etc/pihole-ha/notify.conf ]]; then
    cat > /etc/pihole-ha/notify.conf <<'CONF'
# Pushover notifications (set PO_USER and PO_TOKEN from pushover.net)
PO_ENABLED=false
PO_USER=
PO_TOKEN=
PO_TITLE=pihole-ha
DHCP_NOTIFY_ENABLED=false
DHCP_NOTIFY_IGNORED_MACS=
CONF
    printf "  %b Notify config created (Pushover disabled by default)\\n" "${TICK}"
fi
# notify.conf may hold the Pushover token — keep it root-only.
chmod 600 /etc/pihole-ha/notify.conf 2>/dev/null || true

# --- 20b. Pull notify.conf from existing peers (ignored MACs, etc.) ---
if [[ ${#discovered_nodes[@]} -gt 0 ]]; then
    for _peer in "${discovered_nodes[@]}"; do
        _peer_notify="$(curl -sf --max-time 5 "http://$_peer:8887/api/notify/config" 2>/dev/null)" || continue
        [[ -z "$_peer_notify" ]] && continue
        _peer_macs="$(echo "$_peer_notify" | grep -o '"dhcp_ignored_macs":"[^"]*"' | cut -d'"' -f4)"
        if [[ -n "$_peer_macs" ]]; then
            sed -i "s|^DHCP_NOTIFY_IGNORED_MACS=.*|DHCP_NOTIFY_IGNORED_MACS=$_peer_macs|" /etc/pihole-ha/notify.conf
            printf "  %b Pulled ignored MACs from %s\\n" "${TICK}" "$_peer"
        fi
        break
    done
fi

# --- 21. Enable and start services ---
printf "  %b Starting services..." "${INFO}"
systemctl enable --now pihole-ha.service >/dev/null 2>&1
systemctl enable --now pihole-ha-dash.service >/dev/null 2>&1
printf "%b  %b Services started\\n" "${OVER}" "${TICK}"

if [[ "$is_primary" == "true" ]]; then
    printf "  %b Enabling sync build timer..." "${INFO}"
    systemctl enable pihole-ha-sync.timer >/dev/null 2>&1
    systemctl restart pihole-ha-sync.timer >/dev/null 2>&1
    systemctl disable pihole-ha-sync-pull.timer 2>/dev/null || true
    systemctl stop pihole-ha-sync-pull.timer 2>/dev/null || true
    printf "%b  %b Sync build timer enabled (every 15 min)\\n" "${OVER}" "${TICK}"
else
    printf "  %b Enabling sync pull timer..." "${INFO}"
    systemctl enable pihole-ha-sync-pull.timer >/dev/null 2>&1
    systemctl restart pihole-ha-sync-pull.timer >/dev/null 2>&1
    systemctl disable pihole-ha-sync.timer 2>/dev/null || true
    systemctl stop pihole-ha-sync.timer 2>/dev/null || true
    printf "%b  %b Sync pull timer enabled (every 15 min)\\n" "${OVER}" "${TICK}"
fi

# --- 22. Register this node with existing cluster nodes ---
if [[ ${#discovered_nodes[@]} -gt 0 ]]; then
    _local_entry="$(_node_entry "$local_ip")"
    printf "  %b Registering this node with cluster..." "${INFO}"
    _join_ok=0 _join_fail=0
    for _ji in "${!discovered_nodes[@]}"; do
        _peer="${discovered_nodes[$_ji]}"
        _join_resp="$(curl -sf --max-time 5 "http://$_peer:8887/api/nodes/join?node=$_local_entry" 2>/dev/null)" || true
        if echo "$_join_resp" | grep -q '"ok":true'; then
            _join_ok=$(( _join_ok + 1 ))
        elif echo "$_join_resp" | grep -q '"auth_required"'; then
            if [[ -z "${_join_pass:-}" ]]; then
                printf "%b  %b Remote node %s requires authentication\\n" "${OVER}" "${INFO}" "$_peer"
                read -ersp "      Enter Pi-hole password for cluster nodes: " _join_pass
                printf "\\n"
                printf "  %b Registering this node with cluster..." "${INFO}"
            fi
            _peer_pihole_port="${node_ports[$_peer]:-80}"
            _join_sid="$(curl -s --max-time 5 -X POST "http://$_peer:$_peer_pihole_port/api/auth" \
                -H "Content-Type: application/json" \
                -d "{\"password\":\"$_join_pass\"}" 2>/dev/null | grep -o '"sid":"[^"]*"' | cut -d'"' -f4)"
            if [[ -n "$_join_sid" && "$_join_sid" != "null" ]]; then
                _join_resp="$(curl -sf --max-time 5 "http://$_peer:8887/api/nodes/join?node=$_local_entry&sid=$_join_sid" 2>/dev/null)" || true
                if echo "$_join_resp" | grep -q '"ok":true'; then
                    _join_ok=$(( _join_ok + 1 ))
                else
                    _join_fail=$(( _join_fail + 1 ))
                fi
            else
                _join_fail=$(( _join_fail + 1 ))
            fi
        else
            _join_fail=$(( _join_fail + 1 ))
        fi
    done
    if [[ $_join_fail -eq 0 ]]; then
        printf "%b  %b Registered with %d node(s)\\n" "${OVER}" "${TICK}" "$_join_ok"
    elif [[ $_join_ok -gt 0 ]]; then
        printf "%b  %b Registered with %d node(s), %d failed\\n" "${OVER}" "${INFO}" "$_join_ok" "$_join_fail"
    elif [[ $_join_fail -gt 0 ]]; then
        printf "%b  %b %bCould not register with any existing nodes%b\\n" "${OVER}" "${CROSS}" "${COL_RED}" "${COL_NC}"
    fi
fi

# --- 24. Inject HA page ---
printf "  %b Injecting HA page into Pi-hole web UI..." "${INFO}"
/usr/local/bin/pihole-ha-inject >/dev/null 2>&1
systemctl enable pihole-ha-inject.path >/dev/null 2>&1
printf "%b  %b HA page injected (auto-re-injects after Pi-hole updates)\\n" "${OVER}" "${TICK}"

# --- Keep the local IEEE OUI (MAC vendor) DB fresh: enable monthly refresh ---
printf "  %b Enabling monthly IEEE OUI DB refresh..." "${INFO}"
systemctl enable --now pihole-ha-ieee-update.timer >/dev/null 2>&1
# Pull a current snapshot immediately so we don't start from the package's
# stale build-time copy (runs in the background; failure is non-fatal).
systemctl start pihole-ha-ieee-update.service >/dev/null 2>&1 &
printf "%b  %b IEEE OUI DB auto-update scheduled (monthly)\\n" "${OVER}" "${TICK}"

sleep 2

# --- 25. Verify services ---
s1="$(systemctl is-active pihole-ha 2>/dev/null)"
s2="$(systemctl is-active pihole-ha-dash 2>/dev/null)"

if [[ "$s1" == "active" ]]; then
    printf "  %b Failover daemon: active\\n" "${TICK}"
else
    printf "  %b %bFailover daemon: %s%b\\n" "${CROSS}" "${COL_RED}" "$s1" "${COL_NC}"
fi
if [[ "$s2" == "active" ]]; then
    printf "  %b Dashboard API: active\\n" "${TICK}"
else
    printf "  %b %bDashboard API: %s%b\\n" "${CROSS}" "${COL_RED}" "$s2" "${COL_NC}"
fi

if [[ "$is_primary" == "true" ]]; then
    s3="$(systemctl is-active pihole-ha-sync.timer 2>/dev/null || echo "n/a")"
    [[ "$s3" == "active" ]] && printf "  %b Sync build timer: active\\n" "${TICK}" || printf "  %b Sync build timer: %s\\n" "${CROSS}" "$s3"
else
    s3="$(systemctl is-active pihole-ha-sync-pull.timer 2>/dev/null || echo "n/a")"
    [[ "$s3" == "active" ]] && printf "  %b Sync pull timer: active\\n" "${TICK}" || printf "  %b Sync pull timer: %s\\n" "${CROSS}" "$s3"
fi

# --- 26. Done ---
printf "\\n"
printf "  ${COL_GREEN}╔═══════════════════════════════════════╗${COL_NC}\\n"
printf "  ${COL_GREEN}║${COL_NC}  ${COL_BOLD}Installation Complete!${COL_NC}               ${COL_GREEN}║${COL_NC}\\n"
printf "  ${COL_GREEN}╚═══════════════════════════════════════╝${COL_NC}\\n"
printf "\\n"
printf "  %b Role:       %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$role_name" "${COL_NC}"
if [[ "$vip_enabled" == "true" ]]; then
    printf "  %b VIP:        %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$vip" "${COL_NC}"
else
    printf "  %b VIP:        %bdisabled%b\\n" "${INFO}" "${COL_YELLOW}" "${COL_NC}"
fi
printf "  %b Nodes:      %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$ha_nodes_str" "${COL_NC}"
printf "\\n"
if [[ "$_local_web_port" != "80" ]]; then
    printf "  %b HA Page:    %bhttp://%s:%s/admin/ha%b\\n" "${INFO}" "${COL_GREEN}" "$local_ip" "$_local_web_port" "${COL_NC}"
else
    printf "  %b HA Page:    %bhttp://%s/admin/ha%b\\n" "${INFO}" "${COL_GREEN}" "$local_ip" "${COL_NC}"
fi
printf "  %b Dashboard:  %bhttp://%s:8887%b\\n" "${INFO}" "${COL_GREEN}" "$local_ip" "${COL_NC}"
printf "  %b Logs:       journalctl -u pihole-ha -f\\n" "${INFO}"
printf "\\n"
printf "  %b Node Conf:  /etc/pihole-ha/nodes.conf\\n" "${INFO}"
printf "  %b Sync Conf:  /etc/pihole-ha/sync.conf\\n" "${INFO}"
printf "  %b Notify:     /etc/pihole-ha/notify.conf" "${INFO}"
if grep -q 'PO_ENABLED=true' /etc/pihole-ha/notify.conf 2>/dev/null; then
    printf " %b(enabled)%b" "${COL_GREEN}" "${COL_NC}"
else
    printf " %b(disabled)%b" "${COL_YELLOW}" "${COL_NC}"
fi
printf "\\n\\n"
