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
printf "  ${COL_GREEN}╔═══════════════════════════════════════╗${COL_NC}\\n"
printf "  ${COL_GREEN}║${COL_NC}  ${COL_BOLD}Pi-hole HA Docker Installer${COL_NC}          ${COL_GREEN}║${COL_NC}\\n"
printf "  ${COL_GREEN}║${COL_NC}  DHCP High Availability Cluster       ${COL_GREEN}║${COL_NC}\\n"
printf "  ${COL_GREEN}╚═══════════════════════════════════════╝${COL_NC}\\n"
printf "\\n"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"

# --- 1. Prerequisites ---
if ! command -v docker &>/dev/null; then
    printf "  %b %bdocker not found — install Docker first%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
    exit 1
fi
printf "  %b Docker detected\\n" "${TICK}"

if ! docker compose version &>/dev/null 2>&1; then
    printf "  %b %bdocker compose (v2 plugin) not found%b\\n" "${CROSS}" "${COL_RED}" "${COL_NC}"
    printf "      Install: https://docs.docker.com/compose/install/\\n"
    exit 1
fi
printf "  %b Docker Compose detected\\n" "${TICK}"

# --- 2. Check for existing pihole-ha sidecar ---
existing_sidecar="$(docker ps --filter "ancestor=pihole-ha" --filter "ancestor=docker-pihole-ha" \
    --format '{{.Names}}' 2>/dev/null | head -1)"
if [[ -z "$existing_sidecar" ]]; then
    existing_sidecar="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'pihole-ha' | grep -v 'pihole-ha-' | head -1)" || true
    if [[ -n "$existing_sidecar" ]]; then
        sidecar_image="$(docker inspect --format '{{.Config.Image}}' "$existing_sidecar" 2>/dev/null)" || true
        [[ "$sidecar_image" == pihole/pihole* ]] && existing_sidecar=""
    fi
fi

if [[ -n "$existing_sidecar" ]]; then
    printf "\\n"
    printf "  %b Existing pihole-ha sidecar detected: %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$existing_sidecar" "${COL_NC}"
    printf "\\n"
    printf "      1) Reconfigure — re-run full setup\\n"
    printf "      2) Update      — rebuild image and restart\\n"
    printf "      3) Abort\\n"
    printf "\\n"
    read -erp "  Choose [1/2/3]: " sidecar_choice
    case "$sidecar_choice" in
        1) printf "  %b Reconfiguring...\\n" "${INFO}" ;;
        2)
            printf "  %b Rebuilding and restarting..." "${INFO}"
            cd "$DOCKER_DIR"
            docker compose build --no-cache pihole-ha >/dev/null 2>&1
            docker compose up -d pihole-ha >/dev/null 2>&1
            printf "%b  %b pihole-ha sidecar updated\\n" "${OVER}" "${TICK}"
            exit 0
            ;;
        *) printf "  Aborted.\\n"; exit 0 ;;
    esac
fi

# --- 3. Detect running Pi-hole container ---
printf "  %b Searching for Pi-hole container..." "${INFO}"

pihole_containers="$(docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null \
    | grep -i 'pihole/pihole' || true)"

if [[ -z "$pihole_containers" ]]; then
    printf "%b  %b %bNo running Pi-hole container found%b\\n" "${OVER}" "${CROSS}" "${COL_RED}" "${COL_NC}"
    printf "\\n"
    printf "      Start Pi-hole first, e.g.:\\n"
    printf "        docker run -d --name pihole --network host pihole/pihole:latest\\n"
    printf "\\n"
    exit 1
fi

pihole_count="$(echo "$pihole_containers" | wc -l)"
if [[ "$pihole_count" -eq 1 ]]; then
    pihole_id="$(echo "$pihole_containers" | awk '{print $1}')"
    pihole_name="$(echo "$pihole_containers" | awk '{print $2}')"
    printf "%b  %b Found Pi-hole container: %b%s%b\\n" "${OVER}" "${TICK}" "${COL_BOLD}" "$pihole_name" "${COL_NC}"
else
    printf "%b  %b Multiple Pi-hole containers found:\\n" "${OVER}" "${INFO}"
    i=1
    while IFS=$'\t' read -r _id _name _image; do
        printf "      %d) %s (%s)\\n" "$i" "$_name" "$_image"
        (( i++ ))
    done <<< "$pihole_containers"
    read -erp "  Choose container [1]: " pick
    pick="${pick:-1}"
    pihole_id="$(echo "$pihole_containers" | sed -n "${pick}p" | awk '{print $1}')"
    pihole_name="$(echo "$pihole_containers" | sed -n "${pick}p" | awk '{print $2}')"
fi

# --- 4. Inspect container ---
printf "  %b Inspecting %s..." "${INFO}" "$pihole_name"

# Network mode
net_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$pihole_id")"
restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$pihole_id")"
mounts_json="$(docker inspect --format '{{json .Mounts}}' "$pihole_id")"
env_json="$(docker inspect --format '{{json .Config.Env}}' "$pihole_id")"

# Parse volumes
pihole_etc_vol="" pihole_etc_type="" pihole_etc_src=""
dnsmasq_vol="" dnsmasq_type="" dnsmasq_src=""
extra_volumes=()

while IFS= read -r mount_line; do
    [[ -z "$mount_line" ]] && continue
    m_type="$(echo "$mount_line" | sed -n 's/.*"Type":"\([^"]*\)".*/\1/p')"
    m_src="$(echo "$mount_line" | sed -n 's/.*"Source":"\([^"]*\)".*/\1/p')"
    m_dst="$(echo "$mount_line" | sed -n 's/.*"Destination":"\([^"]*\)".*/\1/p')"
    m_name="$(echo "$mount_line" | sed -n 's/.*"Name":"\([^"]*\)".*/\1/p')"
    case "$m_dst" in
        /etc/pihole)
            pihole_etc_type="$m_type"; pihole_etc_src="$m_src"
            [[ "$m_type" == "volume" ]] && pihole_etc_vol="$m_name"
            ;;
        /etc/dnsmasq.d)
            dnsmasq_type="$m_type"; dnsmasq_src="$m_src"
            [[ "$m_type" == "volume" ]] && dnsmasq_vol="$m_name"
            ;;
        *)
            if [[ "$m_type" == "volume" ]]; then
                extra_volumes+=("$m_name:$m_dst")
            elif [[ "$m_type" == "bind" ]]; then
                extra_volumes+=("$m_src:$m_dst")
            fi
            ;;
    esac
done < <(echo "$mounts_json" | sed 's/},{/}\n{/g' | sed 's/^\[//;s/\]$//')

# Parse environment variables
user_tz="" user_web_port="" user_extra_env=()
while IFS= read -r env_entry; do
    env_entry="${env_entry//\"/}"
    case "$env_entry" in
        TZ=*) user_tz="${env_entry#TZ=}" ;;
        FTLCONF_webserver_api_password=*|WEBPASSWORD=*) ;;
        FTLCONF_webserver_port=*|FTLCONF_WEBSERVER_PORT=*) user_web_port="${env_entry#*=}" ;;
        PIHOLE_HA_*|PATH=*|S6_*|PHP_*|DNSMASQ_*|PIHOLE_DOCKER_TAG=*|FTL_CMD=*|VIRTUAL_HOST=*|ServerIP=*) ;;
        FTLCONF_*) user_extra_env+=("$env_entry") ;;
    esac
done < <(echo "$env_json" | sed 's/^\[//;s/\]$//;s/","/"\n"/g;s/"//g')

# Determine the host-facing web port
# Priority: Docker port mapping > FTL config > env var > default 80
_env_web_port="$user_web_port"  # save env-parsed value
user_web_port=""

# Get internal port from FTL config
_ftl_port="$(docker exec "$pihole_id" pihole-FTL --config webserver.port 2>/dev/null | grep -o '[0-9]*' | head -1)" || true
if [[ -n "$_env_web_port" ]]; then
    _ftl_port="$(echo "$_env_web_port" | sed 's/\[.*\]://g;s/,.*//' | grep -o '[0-9]*' | head -1)"
fi
_ftl_port="${_ftl_port:-80}"

if [[ "$net_mode" != "host" ]]; then
    # Bridge mode — host port may differ from internal port
    _mapped_port="$(docker inspect --format "{{(index (index .NetworkSettings.Ports \"${_ftl_port}/tcp\") 0).HostPort}}" "$pihole_id" 2>/dev/null)" || true
    [[ -n "$_mapped_port" && "$_mapped_port" =~ ^[0-9]+$ ]] && user_web_port="$_mapped_port"
fi

# Host mode or no mapping found — internal port = host port
user_web_port="${user_web_port:-$_ftl_port}"

# Check if the configured port is actually available for Pi-hole
_is_pihole_port() { curl -sf --max-time 2 "http://localhost:${1}/api/info" 2>/dev/null | grep -q "FTL" 2>/dev/null; }
_port_in_use() { ss -tlnH "sport = :${1}" 2>/dev/null | grep -q . 2>/dev/null; }

if ! _is_pihole_port "$user_web_port"; then
    # Port is not serving Pi-hole — try common alternatives
    _found_alt=false
    for _try_port in 8080 8888 8443 443 3000; do
        if _is_pihole_port "$_try_port"; then
            printf "  %b Port %s is not Pi-hole, found Pi-hole on port %b%s%b\\n" "${INFO}" "$user_web_port" "${COL_BOLD}" "$_try_port" "${COL_NC}"
            user_web_port="$_try_port"
            _found_alt=true
            break
        fi
    done
    if [[ "$_found_alt" == "false" ]]; then
        # Pi-hole web is not running on any known port (likely port conflict)
        if _port_in_use "$user_web_port"; then
            printf "  %b %bPort %s is in use by another service (not Pi-hole)%b\\n" "${CROSS}" "${COL_RED}" "$user_web_port" "${COL_NC}"
            # Find a free port
            _new_port=""
            for _try_port in 8080 8888 8443 3000 9080; do
                if ! _port_in_use "$_try_port"; then
                    _new_port="$_try_port"
                    break
                fi
            done
            _new_port="${_new_port:-8080}"
            read -erp "  Pi-hole web port [$_new_port]: " _input_port
            user_web_port="${_input_port:-$_new_port}"
        fi
    fi
fi

printf "%b  %b Container inspected\\n" "${OVER}" "${TICK}"

printf "  %b Network:     %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$net_mode" "${COL_NC}"
printf "  %b Restart:     %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$restart_policy" "${COL_NC}"
printf "  %b Web port:    %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$user_web_port" "${COL_NC}"
printf "  %b Timezone:    %b%s%b\\n" "${INFO}" "${COL_BOLD}" "${user_tz:-not set}" "${COL_NC}"
if [[ -n "$pihole_etc_type" ]]; then
    if [[ "$pihole_etc_type" == "volume" ]]; then
        printf "  %b /etc/pihole: %bvolume (%s)%b\\n" "${INFO}" "${COL_BOLD}" "$pihole_etc_vol" "${COL_NC}"
    else
        printf "  %b /etc/pihole: %bbind (%s)%b\\n" "${INFO}" "${COL_BOLD}" "$pihole_etc_src" "${COL_NC}"
    fi
fi
if [[ -n "$dnsmasq_type" ]]; then
    if [[ "$dnsmasq_type" == "volume" ]]; then
        printf "  %b /etc/dnsmasq.d: %bvolume (%s)%b\\n" "${INFO}" "${COL_BOLD}" "$dnsmasq_vol" "${COL_NC}"
    else
        printf "  %b /etc/dnsmasq.d: %bbind (%s)%b\\n" "${INFO}" "${COL_BOLD}" "$dnsmasq_src" "${COL_NC}"
    fi
fi

# --- 5. Warn if not host network ---
if [[ "$net_mode" != "host" ]]; then
    printf "\\n"
    printf "  ${COL_RED}╔═══════════════════════════════════════════════════════════╗${COL_NC}\\n"
    printf "  ${COL_RED}║  WARNING: Pi-hole is NOT in host network mode           ║${COL_NC}\\n"
    printf "  ${COL_RED}║  DHCP broadcast and VIP require network_mode: host      ║${COL_NC}\\n"
    printf "  ${COL_RED}║  The generated compose will use host networking.        ║${COL_NC}\\n"
    printf "  ${COL_RED}╚═══════════════════════════════════════════════════════════╝${COL_NC}\\n"
    printf "\\n"
    read -erp "  Continue with host networking? [y/N]: " net_confirm
    [[ "$net_confirm" =~ ^[Yy] ]] || { printf "  Aborted.\\n"; exit 0; }
fi

# --- 6. Auto-detect local IP and gateway ---
local_ip="$(hostname -I | awk '{print $1}')"
detected_gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
detected_gw="${detected_gw:-}"
subnet="$(echo "$local_ip" | cut -d. -f1-3)"

printf "\\n"
printf "  %b Local IP:    %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$local_ip" "${COL_NC}"
printf "  %b Gateway:     %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$detected_gw" "${COL_NC}"
printf "  %b Subnet:      %b%s.0/24%b\\n" "${INFO}" "${COL_BOLD}" "$subnet" "${COL_NC}"
printf "\\n"

# --- 7. Interactive questions ---

# 7a. Gateway
read -erp "  Gateway IP [$detected_gw]: " input_gw
gateway="${input_gw:-$detected_gw}"
if ! is_valid_ip "$gateway"; then
    printf "  %b %bInvalid gateway IP: %s%b\\n" "${CROSS}" "${COL_RED}" "$gateway" "${COL_NC}"
    exit 1
fi
printf "  %b Gateway: %s\\n" "${TICK}" "$gateway"

# 7b. Pi-hole web password
printf "\\n"
read -ersp "  Pi-hole web password [leave blank for no password]: " user_password
printf "\\n"
if [[ -n "$user_password" ]]; then
    printf "  %b Password: (set)\\n" "${TICK}"
else
    printf "  %b Password: (none)\\n" "${TICK}"
fi

# 7c. Scan subnet for existing HA nodes
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
    # Extract VIP address from the primary node
    if [[ -z "${cluster_vip:-}" ]]; then
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

# 7d. Build node list
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

# Auto-fill: discovered nodes first (preserve priority), this node last
for i in "${!discovered_nodes[@]}"; do
    _add_node "${discovered_nodes[$i]}" "${discovered_ports[$i]}"
done
_add_node "$local_ip" "$user_web_port"

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
        # Manual entry
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
            _port_def="80"
            [[ "$_ip" == "$local_ip" ]] && _port_def="$user_web_port"
            read -erp "  Node $n Pi-hole web port [$_port_def]: " _port
            _port="${_port:-$_port_def}"
            _add_node "$_ip" "$_port"
        done
    fi
else
    # No discovered nodes — manual entry for remaining
    printf "\\n"
    printf "  %b Node 1: %b%s%b (this node, port %s)\\n" "${TICK}" "${COL_BOLD}" "$local_ip" "${COL_NC}" "$user_web_port"
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
    # Find which node is primary from the scan data
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

_node_entry() {
    local ip="$1" port="${node_ports[$1]:-80}"
    [[ "$port" != "80" ]] && echo "$ip:$port" || echo "$ip"
}

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

# --- 10. VIP ---
printf "\\n"
printf "  %b ${COL_BOLD}Virtual IP (VIP)${COL_NC}\\n" "${INFO}"
printf "      A VIP is a floating IP that moves to whichever node is serving DHCP.\\n"
printf "      It can be used as a DNS address that survives failover.\\n"
printf "\\n"
if [[ -n "$cluster_vip" ]]; then
    printf "  %b Cluster VIP detected: %b%s%b\\n" "${TICK}" "${COL_BOLD}" "$cluster_vip" "${COL_NC}"
    vip_enabled="true"
    vip="$cluster_vip"
else
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
printf "  %b Web port:   %b%s%b\\n" "${INFO}" "${COL_BOLD}" "$user_web_port" "${COL_NC}"
if [[ "$is_primary" == "true" ]]; then
    printf "  %b Role:       %bPRIMARY — builds sync payloads%b\\n" "${INFO}" "${COL_GREEN}" "${COL_NC}"
else
    printf "  %b Role:       %bSECONDARY — pulls from primary%b\\n" "${INFO}" "${COL_YELLOW}" "${COL_NC}"
fi
printf "\\n"
printf "  %b Old container (%s) will be stopped\\n" "${INFO}" "$pihole_name"
printf "  %b New compose stack will start in docker/\\n" "${INFO}"
printf "\\n"
read -erp "  Proceed? [Y/n]: " proceed
[[ "$proceed" =~ ^[Nn] ]] && { printf "  Aborted.\\n"; exit 0; }

# --- 12. Generate docker/.env ---
printf "\\n"
printf "  %b Generating docker/.env..." "${INFO}"

cat > "$DOCKER_DIR/.env" <<EOF
# Generated by docker-install.sh — $(date '+%Y-%m-%d %H:%M:%S')

# --- Required ---
PIHOLE_HA_NODES=$ha_nodes_str
PIHOLE_HA_GATEWAY=$gateway

# --- Pi-hole ---
PIHOLE_PASSWORD=${user_password}
PIHOLE_WEB_PORT=${user_web_port}
TZ=${user_tz:-America/New_York}

# --- VIP ---
PIHOLE_HA_VIP_ENABLED=$vip_enabled
PIHOLE_HA_VIP=${vip}

# --- HA ---
PIHOLE_HA_ENABLED=true
PIHOLE_HA_FORCE_CONFIG=true

# --- Config sync ---
PIHOLE_HA_SYNC_ENABLED=true
PIHOLE_HA_SYNC_GRAVITY=true
PIHOLE_HA_SYNC_DHCP=true
PIHOLE_HA_SYNC_DNS=true
PIHOLE_HA_SYNC_SETTINGS=true
EOF

printf "%b  %b docker/.env created\\n" "${OVER}" "${TICK}"

# --- 13. Generate docker/docker-compose.yml ---
printf "  %b Generating docker/docker-compose.yml..." "${INFO}"

# Build volume entries
pihole_vols=""
sidecar_vols=""
external_vols=()

if [[ "$pihole_etc_type" == "volume" && -n "$pihole_etc_vol" ]]; then
    pihole_vols+="      - ${pihole_etc_vol}:/etc/pihole"$'\n'
    sidecar_vols+="      - ${pihole_etc_vol}:/etc/pihole"$'\n'
    external_vols+=("$pihole_etc_vol")
elif [[ "$pihole_etc_type" == "bind" && -n "$pihole_etc_src" ]]; then
    pihole_vols+="      - ${pihole_etc_src}:/etc/pihole"$'\n'
    sidecar_vols+="      - ${pihole_etc_src}:/etc/pihole"$'\n'
else
    pihole_vols+="      - pihole-etc:/etc/pihole"$'\n'
    sidecar_vols+="      - pihole-etc:/etc/pihole"$'\n'
fi

if [[ "$dnsmasq_type" == "volume" && -n "$dnsmasq_vol" ]]; then
    pihole_vols+="      - ${dnsmasq_vol}:/etc/dnsmasq.d"$'\n'
    sidecar_vols+="      - ${dnsmasq_vol}:/etc/dnsmasq.d"$'\n'
    external_vols+=("$dnsmasq_vol")
elif [[ "$dnsmasq_type" == "bind" && -n "$dnsmasq_src" ]]; then
    pihole_vols+="      - ${dnsmasq_src}:/etc/dnsmasq.d"$'\n'
    sidecar_vols+="      - ${dnsmasq_src}:/etc/dnsmasq.d"$'\n'
else
    pihole_vols+="      - pihole-dnsmasq:/etc/dnsmasq.d"$'\n'
    sidecar_vols+="      - pihole-dnsmasq:/etc/dnsmasq.d"$'\n'
fi

extra_env_block=""
for ev in "${user_extra_env[@]+"${user_extra_env[@]}"}"; do
    [[ -z "$ev" ]] && continue
    env_key="${ev%%=*}"
    env_val="${ev#*=}"
    extra_env_block+="      ${env_key}: \"${env_val}\""$'\n'
done

vol_decl_block=""
for ev in "${external_vols[@]+"${external_vols[@]}"}"; do
    [[ -z "$ev" ]] && continue
    vol_decl_block+="  ${ev}:"$'\n'
    vol_decl_block+="    external: true"$'\n'
done

if [[ "$pihole_etc_type" != "volume" && "$pihole_etc_type" != "bind" ]] || [[ -z "$pihole_etc_type" ]]; then
    vol_decl_block+="  pihole-etc:"$'\n'
fi
if [[ "$dnsmasq_type" != "volume" && "$dnsmasq_type" != "bind" ]] || [[ -z "$dnsmasq_type" ]]; then
    vol_decl_block+="  pihole-dnsmasq:"$'\n'
fi

vol_decl_block+="  pihole-ha-conf:"$'\n'
vol_decl_block+="  pihole-ha-run:"$'\n'
vol_decl_block+="  pihole-ha-src:"$'\n'
vol_decl_block+="  pihole-ha-ieee:"

compose_restart="${restart_policy:-unless-stopped}"
[[ "$compose_restart" == "no" || -z "$compose_restart" ]] && compose_restart="unless-stopped"

cat > "$DOCKER_DIR/docker-compose.yml" <<EOF
# Generated by docker-install.sh — $(date '+%Y-%m-%d %H:%M:%S')
services:
  pihole:
    image: pihole/pihole:latest
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_NICE
    entrypoint: /pihole-ha-inject/pihole-ha-inject-docker.sh
    volumes:
${pihole_vols}      - pihole-ha-src:/pihole-ha-src:ro
      - pihole-ha-run:/run/pihole-ha:ro
      - pihole-ha-conf:/etc/pihole-ha:ro
      - pihole-ha-ieee:/var/lib/ieee-data:ro
      - ./pihole-ha-inject-docker.sh:/pihole-ha-inject/pihole-ha-inject-docker.sh:ro
    environment:
      TZ: \${TZ:-America/New_York}
      FTLCONF_webserver_api_password: \${PIHOLE_PASSWORD:-}
      FTLCONF_webserver_port: \${PIHOLE_WEB_PORT:-80}
${extra_env_block}    restart: ${compose_restart}

  pihole-ha:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    network_mode: host
    pid: "service:pihole"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    depends_on:
      - pihole
    env_file: .env
    volumes:
${sidecar_vols}      - pihole-ha-conf:/etc/pihole-ha
      - pihole-ha-run:/run/pihole-ha
      - pihole-ha-src:/pihole-ha-src
      - pihole-ha-ieee:/var/lib/ieee-data
    restart: ${compose_restart}

volumes:
${vol_decl_block}
EOF

printf "%b  %b docker/docker-compose.yml created\\n" "${OVER}" "${TICK}"

# --- 14. Stop old container ---
printf "  %b Stopping old container (%s)..." "${INFO}" "$pihole_name"

old_compose_project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$pihole_id" 2>/dev/null)" || true
old_compose_dir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$pihole_id" 2>/dev/null)" || true

if [[ -n "$old_compose_project" && -n "$old_compose_dir" && -d "$old_compose_dir" ]]; then
    (cd "$old_compose_dir" && docker compose down 2>/dev/null) || docker stop "$pihole_id" 2>/dev/null || true
else
    docker stop "$pihole_id" 2>/dev/null || true
fi

printf "%b  %b Old container stopped\\n" "${OVER}" "${TICK}"

# --- 15. Build and start ---
printf "  %b Building pihole-ha sidecar image...\\n" "${INFO}"
cd "$DOCKER_DIR"
docker compose build --progress=plain pihole-ha 2>&1 | sed 's/\x1b\[[0-9;]*m//g'

printf "  %b Starting compose stack..." "${INFO}"
docker compose up -d >/dev/null 2>&1
printf "%b  %b Compose stack started\\n" "${OVER}" "${TICK}"

# --- 16. Wait for API ---
printf "  %b Waiting for HA API..." "${INFO}"
api_ok=false
for _ in $(seq 1 30); do
    if curl -sf --max-time 2 "http://127.0.0.1:8887/api/status" &>/dev/null; then
        api_ok=true
        break
    fi
    sleep 2
done

if [[ "$api_ok" == "true" ]]; then
    printf "%b  %b HA API responding on port 8887\\n" "${OVER}" "${TICK}"
else
    printf "%b  %b %bAPI not responding yet on port 8887%b\\n" "${OVER}" "${CROSS}" "${COL_YELLOW}" "${COL_NC}"
    printf "      Check: docker compose -f %s/docker-compose.yml logs -f pihole-ha\\n" "$DOCKER_DIR"
fi

# --- 18. Register this node with existing cluster nodes ---
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
            # Need auth — get SID from Pi-hole on that node
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
    else
        printf "%b  %b %bCould not register with any existing nodes%b\\n" "${OVER}" "${CROSS}" "${COL_RED}" "${COL_NC}"
    fi
fi

# --- 19. Done ---
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
printf "  %b HA Page:    %bhttp://%s:%s/admin/ha%b\\n" "${INFO}" "${COL_GREEN}" "$local_ip" "$user_web_port" "${COL_NC}"
printf "  %b Dashboard:  %bhttp://%s:8887%b\\n" "${INFO}" "${COL_GREEN}" "$local_ip" "${COL_NC}"
printf "\\n"
printf "  %b Compose:    %s/docker-compose.yml\\n" "${INFO}" "$DOCKER_DIR"
printf "  %b Env:        %s/.env\\n" "${INFO}" "$DOCKER_DIR"
printf "  %b Logs:       docker compose -f %s/docker-compose.yml logs -f\\n" "${INFO}" "$DOCKER_DIR"
printf "\\n"
