#!/bin/bash
# test-ha.sh — Integration tests for pihole-ha
# Run: bash tests/test-ha.sh (no root needed)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Source the real platform helpers — only function definitions, no side
# effects beyond setting PIHOLE_HA_PLATFORM. This means is_valid_ip is
# tested against the actual production implementation.
ROLE="TEST"
source "$SCRIPT_DIR/../pihole-ha-platform"

# ============================================================
echo "=== is_valid_ip ==="

assert_true  "valid: 192.168.1.3"       is_valid_ip "192.168.1.3"
assert_true  "valid: 192.168.1.1"      is_valid_ip "192.168.1.1"
assert_true  "valid: 0.0.0.0"          is_valid_ip "0.0.0.0"
assert_true  "valid: 255.255.255.255"  is_valid_ip "255.255.255.255"
assert_true  "valid: 1.2.3.4"          is_valid_ip "1.2.3.4"
assert_false "invalid: empty"          is_valid_ip ""
assert_false "invalid: 256.1.1.1"      is_valid_ip "256.1.1.1"
assert_false "invalid: 1.2.3.999"      is_valid_ip "1.2.3.999"
assert_false "invalid: abc.def.ghi.jkl" is_valid_ip "abc.def.ghi.jkl"
assert_false "invalid: 1.2.3"          is_valid_ip "1.2.3"
assert_false "invalid: 1.2.3.4.5"      is_valid_ip "1.2.3.4.5"
assert_false "invalid: 192.168.1.3/24"  is_valid_ip "192.168.1.3/24"
assert_false "invalid: spaces"         is_valid_ip "1.2.3. 4"
assert_false "invalid: negative -1.0.0.0" is_valid_ip "-1.0.0.0"

# ============================================================
echo
echo "=== Config version parsing ==="

# Test: CONFIG_VERSION present
tmpconf="$(mktemp)"
printf 'CONFIG_VERSION=1\nGATEWAY=192.168.1.1\n' > "$tmpconf"
CONFIG_VERSION=""
source "$tmpconf"
assert_eq "version=1 parsed" "1" "$CONFIG_VERSION"

# Test: CONFIG_VERSION missing (default)
tmpconf2="$(mktemp)"
printf 'GATEWAY=192.168.1.1\n' > "$tmpconf2"
unset CONFIG_VERSION
source "$tmpconf2"
CONFIG_VERSION="${CONFIG_VERSION:-0}"
assert_eq "version missing defaults to 0" "0" "$CONFIG_VERSION"

rm -f "$tmpconf" "$tmpconf2"

# ============================================================
echo
echo "=== Role detection from node array ==="

NODES=("192.168.1.3" "192.168.1.5" "192.168.1.55")
ROLES_ARR=("PRIMARY" "SECONDARY" "TERTIARY")
NODE_COUNT=${#NODES[@]}

# Test: find local IP in list
LOCAL_IP="192.168.1.5"
MY_IDX=-1
for (( i=0; i<NODE_COUNT; i++ )); do
    [[ "$LOCAL_IP" == "${NODES[$i]}" ]] && { MY_IDX=$i; break; }
done
assert_eq "found .5 at index 1" "1" "$MY_IDX"
assert_eq "role is SECONDARY" "SECONDARY" "${ROLES_ARR[$MY_IDX]}"

# Test: IP not in list
LOCAL_IP="192.168.1.99"
MY_IDX=-1
for (( i=0; i<NODE_COUNT; i++ )); do
    [[ "$LOCAL_IP" == "${NODES[$i]}" ]] && { MY_IDX=$i; break; }
done
assert_eq "unknown IP gives -1" "-1" "$MY_IDX"

# ============================================================
echo
echo "=== Node list reorder (demote) ==="

# Simulate reorder: new_primary=192.168.1.55, original order: .3,.5,.55
_HA_NODES=("192.168.1.3" "192.168.1.5" "192.168.1.55")
_new_primary="192.168.1.55"
_new_nodes="$_new_primary"
for _dn in "${_HA_NODES[@]}"; do
    [[ "$_dn" == "$_new_primary" ]] && continue
    _new_nodes+=",$_dn"
done
assert_eq "reorder puts .55 first" "192.168.1.55,192.168.1.3,192.168.1.5" "$_new_nodes"

# ============================================================
echo
echo "=== Structured log output format ==="

out="$(log_info "event=test key=value")"
assert_contains "log contains [TEST]"  "$out" "[TEST]"
assert_contains "log contains [INFO]"  "$out" "[INFO]"
assert_contains "log contains event="  "$out" "event=test"
assert_contains "log has ISO timestamp" "$out" "T"

out_warn="$(log_warn "event=warning")"
assert_contains "warn contains [WARN]" "$out_warn" "[WARN]"

out_err="$(log_error "event=error")"
assert_contains "error contains [ERROR]" "$out_err" "[ERROR]"

# ============================================================
echo
echo "=== Auth check logic (mock) ==="

# Mock: no auth required
_AUTH_CHECKED="" _AUTH_REQUIRED=""
_pihole_has_auth() { return 1; }  # no auth
_validate_sid() { return 1; }
_check_auth() {
    local qs="$1"
    if [[ -z "$_AUTH_CHECKED" ]]; then
        _pihole_has_auth && _AUTH_REQUIRED="true" || _AUTH_REQUIRED="false"
        _AUTH_CHECKED="1"
    fi
    [[ "$_AUTH_REQUIRED" != "true" ]] && return 0
    local sid=""
    IFS='&' read -ra _ap <<< "$qs"
    for _a in "${_ap[@]}"; do [[ "$_a" == sid=* ]] && sid="${_a#sid=}"; done
    _validate_sid "$sid"
}

assert_true "no auth: any request passes" _check_auth ""
assert_true "no auth: no SID needed" _check_auth "ip=1.2.3.4"

# Mock: auth required, valid SID
_AUTH_CHECKED="" _AUTH_REQUIRED=""
_pihole_has_auth() { return 0; }  # auth required
_validate_sid() { [[ "$1" == "valid-sid-123" ]]; }

assert_false "auth required: no SID fails" _check_auth "ip=1.2.3.4"
assert_true  "auth required: valid SID passes" _check_auth "ip=1.2.3.4&sid=valid-sid-123"

# Reset and test invalid SID
_AUTH_CHECKED="" _AUTH_REQUIRED=""
assert_false "auth required: invalid SID fails" _check_auth "sid=wrong-sid"

# ============================================================
echo
echo "=== Peer-state lookups for non-members (crashloop regression) ==="

# A DHCP_MASTER pinned to a node that has left the cluster is never health
# checked, so peer_* has no entry for it. Under `set -u` a bare lookup aborted
# pihole-ha at startup and systemd restarted it forever.
HA_SRC="$SCRIPT_DIR/../pihole-ha"
eval "$(extract_fn "$HA_SRC" is_serving)"
eval "$(extract_fn "$HA_SRC" get_fail_reason)"
eval "$(extract_fn "$HA_SRC" is_cluster_member)"

declare -A peer_ping peer_dns peer_api peer_dhcp
peer_ping["10.33.47.3"]="true";  peer_dns["10.33.47.3"]="true"
peer_api["10.33.47.3"]="true";   peer_dhcp["10.33.47.3"]="true"
peer_ping["10.33.47.5"]="false"; peer_dns["10.33.47.5"]="false"
peer_api["10.33.47.5"]="false";  peer_dhcp["10.33.47.5"]="null"

assert_true  "is_serving survives unknown IP under set -u"      no_unbound_error is_serving "10.33.47.99"
assert_true  "get_fail_reason survives unknown IP under set -u" no_unbound_error get_fail_reason "10.33.47.99"
assert_false "is_serving false for unknown IP"                 is_serving "10.33.47.99"
assert_true  "is_serving true for healthy member"              is_serving "10.33.47.3"
assert_false "is_serving false for unhealthy member"           is_serving "10.33.47.5"
assert_eq    "unknown IP reported as non-member" \
             "not a cluster member" "$(get_fail_reason 10.33.47.99)"
assert_contains "unhealthy member reports real failures" "$(get_fail_reason 10.33.47.5)" "ping failed"

# ============================================================
echo
echo "=== Cluster membership checks ==="

NODES=("10.33.47.55" "10.33.47.3")
assert_true  "member .55 recognised"      is_cluster_member "10.33.47.55"
assert_true  "member .3 recognised"       is_cluster_member "10.33.47.3"
assert_false "departed .5 not a member"   is_cluster_member "10.33.47.5"
assert_false "empty string not a member"  is_cluster_member ""

# ============================================================
echo
echo "=== Stale DHCP_MASTER falls back to priority order ==="

# A pin naming a departed node reads as "master is down" to is_serving, which
# made every remaining node take over DHCP at once.
eval "$(extract_fn "$HA_SRC" should_i_serve)"
NODES=("10.33.47.55" "10.33.47.3")
LOCAL_IP="10.33.47.3"; MY_IDX=1
peer_ping["10.33.47.55"]="true"; peer_dns["10.33.47.55"]="true"
peer_api["10.33.47.55"]="true";  peer_dhcp["10.33.47.55"]="true"

DHCP_MASTER="10.33.47.5"   # departed node
assert_true  "stale pin does not abort under set -u" no_unbound_error should_i_serve
DHCP_MASTER="10.33.47.5"
assert_false "stale pin: standby yields to healthy P1 instead of taking over" should_i_serve

DHCP_MASTER="10.33.47.5"; LOCAL_IP="10.33.47.55"; MY_IDX=0
assert_true  "stale pin: P1 serves by priority order" should_i_serve

# The pin must be normalised, not just worked around: leaving it set makes
# build_reason report "Manual master 10.33.47.5 down" about a node that was
# deliberately removed, which is what sent .5 into taking over DHCP.
DHCP_MASTER="10.33.47.5"; LOCAL_IP="10.33.47.3"; MY_IDX=1
should_i_serve >/dev/null 2>&1
assert_eq "stale pin normalised to auto" "auto" "$DHCP_MASTER"

DHCP_MASTER="10.33.47.55"; LOCAL_IP="10.33.47.3"; MY_IDX=1
should_i_serve >/dev/null 2>&1
assert_eq "valid pin left untouched" "10.33.47.55" "$DHCP_MASTER"

DHCP_MASTER="auto"; LOCAL_IP="10.33.47.3"; MY_IDX=1
assert_false "auto: standby yields while P1 healthy" should_i_serve
peer_dhcp["10.33.47.55"]="false"
assert_true  "auto: standby takes over when P1 stops serving" should_i_serve

# ============================================================
echo
echo "=== Node list validation (config injection guard) ==="

DASH_SRC="$SCRIPT_DIR/../pihole-ha-dash"
eval "$(extract_fn "$DASH_SRC" _valid_node_list)"

assert_true  "valid: single IP"          _valid_node_list "10.33.47.5"
assert_true  "valid: two IPs"            _valid_node_list "10.33.47.55,10.33.47.3"
assert_true  "valid: IP with port"       _valid_node_list "10.33.47.55:8080,10.33.47.3"
assert_false "invalid: empty list"       _valid_node_list ""
assert_false "invalid: bad octet"        _valid_node_list "10.33.47.300"
assert_false "invalid: port 0"           _valid_node_list "10.33.47.5:0"
assert_false "invalid: port too large"   _valid_node_list "10.33.47.5:70000"
assert_false "invalid: non-numeric port" _valid_node_list "10.33.47.5:http"
assert_false "injection: command sub"    _valid_node_list '10.33.47.5,$(id)'
assert_false "injection: semicolon"      _valid_node_list "10.33.47.5:80;id"
assert_false "injection: backtick"       _valid_node_list '10.33.47.5,`id`'
assert_false "injection: newline+assign" _valid_node_list "10.33.47.5
HA_ENABLED=false"

# ============================================================
echo
echo "=== Join broadcast targets ==="

# The joining node must be told the new membership too — a node whose HA_NODES
# does not contain itself exits 1 on startup and crashloops.
eval "$(extract_fn "$DASH_SRC" _broadcast_nodes)"
platform_get_local_ip() { echo "10.33.47.55"; }
# _broadcast_nodes backgrounds each _propagate, so the stub has to record to a
# file — a variable written in the subshell never reaches the parent.
_bcast_log="$(mktemp)"
_propagate() { echo "$1" >> "$_bcast_log"; }

_broadcast_nodes "10.33.47.55,10.33.47.3,10.33.47.5"
wait 2>/dev/null
_bcast_targets="$(cat "$_bcast_log")"
assert_contains     "broadcast reaches existing peer .3" "$_bcast_targets" "10.33.47.3"
assert_contains     "broadcast reaches joining node .5"  "$_bcast_targets" "10.33.47.5"
assert_not_contains "broadcast skips self (.55)"         "$_bcast_targets" "10.33.47.55"

: > "$_bcast_log"
_broadcast_nodes "10.33.47.55:8080,10.33.47.3"
wait 2>/dev/null
_bcast_targets="$(cat "$_bcast_log")"
assert_contains     "broadcast strips port from target"          "$_bcast_targets" "10.33.47.3"
assert_not_contains "broadcast skips self even with port suffix" "$_bcast_targets" "8080"
rm -f "$_bcast_log"

# ============================================================
echo
echo "=== Departing node stays a member of its own config ==="

# The original bug: leave rewrote the departing node's HA_NODES to a list that
# excluded itself, so MY_IDX stayed -1 and the daemon exited 1 forever.
_leave_ip="10.33.47.5"; _local="10.33.47.5"
_all=("10.33.47.55" "10.33.47.3" "10.33.47.5")
_remaining=""
for _n in "${_all[@]}"; do
    [[ "$_n" == "$_leave_ip" ]] && continue
    [[ -n "$_remaining" ]] && _remaining+=","
    _remaining+="$_n"
done
# Self-leave must produce a standalone list, not the remaining-members list.
_result="$([[ "$_leave_ip" == "$_local" ]] && echo "$_local" || echo "$_remaining")"
assert_eq "self-leave yields standalone list" "10.33.47.5" "$_result"

MY_IDX=-1
IFS=',' read -ra _rn <<< "$_result"
for (( i=0; i<${#_rn[@]}; i++ )); do
    [[ "$_local" == "${_rn[$i]}" ]] && { MY_IDX=$i; break; }
done
assert_eq "departing node still finds itself (no 'Unknown IP' exit)" "0" "$MY_IDX"

# Removing someone else must keep the local node in the list.
_leave_ip="10.33.47.5"; _local="10.33.47.55"
_result="$([[ "$_leave_ip" == "$_local" ]] && echo "$_local" || echo "$_remaining")"
assert_eq "remote-leave yields remaining members" "10.33.47.55,10.33.47.3" "$_result"
assert_contains "remote-leave keeps local node listed" "$_result" "$_local"

# ============================================================
echo
echo "=== Safety guards present in daemon and dashboard ==="

# These guard inline loop/handler logic that cannot be extracted as functions,
# so assert the guard still exists rather than silently losing it in a refactor.
# The guard must sit in the main loop *ahead* of the serve/yield decision —
# a bare grep for "NODE_COUNT == 1" also matches the STANDALONE role line and
# would keep passing if the loop guard were deleted.
_guard_ln="$(grep -n 'Standalone - no peers to fail over to' "$HA_SRC" | head -1 | cut -d: -f1)"
_serve_ln="$(grep -n 'if should_i_serve; then' "$HA_SRC" | head -1 | cut -d: -f1)"
assert_true "daemon: lone-node loop guard exists" test -n "$_guard_ln"
assert_eq   "daemon: lone-node guard precedes the failover decision" "yes" \
    "$([[ -n "$_guard_ln" && -n "$_serve_ln" ]] && (( _guard_ln < _serve_ln )) && echo yes || echo no)"
assert_eq   "daemon: lone-node guard short-circuits the loop" "yes" \
    "$(sed -n "${_guard_ln},$((_guard_ln + 1))p" "$HA_SRC" | grep -q 'continue' && echo yes || echo no)"
assert_true "daemon: sync publisher election skipped when alone" \
    grep -q 'NODE_COUNT > 1 )) || return 0' "$HA_SRC"
assert_true "daemon: lone node reported as STANDALONE not PRIMARY" \
    grep -q 'ROLES=("STANDALONE")' "$HA_SRC"
assert_true "dash: self-leave disables HA on departing node" \
    grep -q '_conf_set "HA_ENABLED" "false"' "$DASH_SRC"
assert_true "dash: self-leave stands DHCP down" \
    grep -q 'pihole-FTL --config dhcp.active false' "$DASH_SRC"
assert_true "dash: leave resets a stale DHCP_MASTER pin" \
    grep -q 'DHCP_MASTER=auto' "$DASH_SRC"
assert_true "dash: propagated join validates the pushed list" \
    grep -q '_valid_node_list "$_join_list"' "$DASH_SRC"
assert_true "dash: leave notifies the departing node" \
    grep -q 'nodes/leave?node=$_leave_ip&propagated=1' "$DASH_SRC"

# ============================================================
echo
echo "=== Join direction and target probing ==="

# Adding used to mean "append them to my list and make me P1" regardless of
# what the target already was, so a standalone node joining an established
# cluster silently demoted that cluster's primary. And an address with nothing
# at it was accepted, leaving the local node P1 of a cluster whose only peer
# never answers — which is enough for it to take the VIP and start DHCP.
eval "$(extract_fn "$DASH_SRC" _probe_node_list)"

_get_peer_sid() { echo ""; }   # no password configured in these tests

# Reachable node reporting a two-node cluster
curl() { cat <<'JSON'
{"nodes":[{"ip":"192.0.2.10","role":"PRIMARY","p":1,"port":80},{"ip":"192.0.2.11","role":"SECONDARY","p":2,"port":80}],"gateway":"192.0.2.1","pihole_port":80}
JSON
}
_probed="$(_probe_node_list 192.0.2.10)"
assert_eq "probe returns both cluster members" "192.0.2.10
192.0.2.11" "$_probed"
assert_eq "probe counts a 2-node cluster" "2" "$(printf '%s\n' "$_probed" | grep -c .)"

# Reachable but standalone
curl() { echo '{"nodes":[{"ip":"192.0.2.20","role":"STANDALONE","p":1,"port":80}],"gateway":"192.0.2.1","pihole_port":80}'; }
assert_eq "probe counts a standalone node" "1" "$(_probe_node_list 192.0.2.20 | grep -c .)"

# Unreachable: curl fails
curl() { return 7; }
assert_false "probe fails on an unreachable node" _probe_node_list 192.0.2.99
assert_eq    "unreachable probe yields no members" "0" "$(_probe_node_list 192.0.2.99 | grep -c .)"

# Reachable, but not pihole-ha (no "nodes" key)
curl() { echo '{"error":"not found"}'; }
assert_false "probe fails when the response is not a node list" _probe_node_list 192.0.2.98

# The gateway field must never be mistaken for a cluster member
curl() { echo '{"nodes":[{"ip":"192.0.2.10","role":"STANDALONE","p":1,"port":80}],"gateway":"192.0.2.1","pihole_port":80}'; }
assert_not_contains "probe ignores the gateway address" "$(_probe_node_list 192.0.2.10)" "192.0.2.1
"
unset -f curl

# Direction rules, as applied by the join handler
_decide() {   # target_count local_count target_has_us -> direction
    local tc="$1" lc="$2" hasus="$3"
    if (( tc == 0 )); then echo "reject_unreachable"
    elif (( tc > 1 && lc == 1 )); then echo "join_theirs"
    elif (( tc > 1 && lc > 1 )) && [[ "$hasus" != "true" ]]; then echo "reject_two_clusters"
    else echo "add_to_mine"; fi
}
assert_eq "unreachable target is rejected"                "reject_unreachable"  "$(_decide 0 1 false)"
assert_eq "standalone joining a cluster joins theirs"     "join_theirs"         "$(_decide 3 1 false)"
assert_eq "cluster adding a standalone absorbs it"        "add_to_mine"         "$(_decide 1 2 false)"
assert_eq "two standalones form a new cluster"            "add_to_mine"         "$(_decide 1 1 false)"
assert_eq "two different clusters are refused"            "reject_two_clusters" "$(_decide 2 2 false)"
assert_eq "re-adding a node that already lists us is ok"  "add_to_mine"         "$(_decide 2 2 true)"

assert_true "dash: join probes the target before mutating" \
    grep -q '_target_list="$(_probe_node_list "$_join_ip")"' "$DASH_SRC"
assert_true "dash: unreachable target changes nothing" \
    grep -q 'did not respond on port 8887' "$DASH_SRC"
assert_true "dash: standalone forwards its own join to the cluster" \
    grep -q '_forward_join "$_join_ip" "$_self_ip"' "$DASH_SRC"

# ============================================================
echo
echo "=== Syntax check all scripts ==="

# ============================================================
# Sync role reconciliation must be level-triggered
# ------------------------------------------------------------
# Issue #4: the primary believed it was the publisher and its build timer was
# not running. The promote block only fires on a role CHANGE, so nothing ever
# re-checked it -- no manifest was served, and every standby logged "no peer has
# a manifest" forever with nothing above INFO to say why.
_msr="$(extract_fn "$SCRIPT_DIR/../pihole-ha" manage_sync_role)"
assert_contains "publisher re-checks its build timer every cycle" \
    "$_msr" "platform_sync_is_running"
assert_contains "standby re-checks its pull timer every cycle" \
    "$_msr" "platform_sync_pull_is_running"
assert_contains "a stopped timer is reported, not fixed in silence" \
    "$_msr" "sync_timer_recovered"
# Behavioural, not textual: run the function in the exact state that used to
# deadlock -- already the publisher (no transition), build timer stopped -- and
# assert it starts the timer anyway.
_run_msr() {
    local ap="$1" current="$2" running="$3"
    bash -c '
        SYNC_CONF=/nonexistent; NODE_COUNT=2; LOCAL_IP=192.168.20.22
        SYNC_ROLE_FILE=/dev/null
        acting_primary_ip() { echo "'"$ap"'"; }
        read_sync_primary()  { echo "'"$current"'"; }
        write_sync_primary() { :; }
        catch_up_from_peers() { :; }
        notify() { :; }
        log_info() { :; }; log_warn() { :; }
        platform_sync_is_running()      { [[ "'"$running"'" == yes ]]; }
        platform_sync_pull_is_running() { true; }
        platform_sync_enable()       { echo "STARTED_BUILD"; }
        platform_sync_pull_enable()  { echo "STARTED_PULL"; }
        platform_sync_disable()      { :; }
        platform_sync_pull_disable() { :; }
        '"$_msr"'
        manage_sync_role
    ' 2>/dev/null
}
assert_eq "publisher with a stopped build timer starts it (no role change)" \
    "STARTED_BUILD" "$(_run_msr 192.168.20.22 192.168.20.22 no)"
assert_eq "publisher with a running build timer is left alone" \
    "" "$(_run_msr 192.168.20.22 192.168.20.22 yes)"

# The debug bundle must not describe the publisher as a standby -- that wording
# pointed away from the faulting node in issue #4.
assert_contains "debug flags a publisher with no manifest" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-debug")" "THIS IS THE PUBLISHER"

# ============================================================
# platform_get_local_ip must never return the VIP
# ------------------------------------------------------------
# `hostname -I` guarantees no ordering, so on a VIP-holding node the VIP can be
# listed first. Returning it makes every caller fail its HA_NODES lookup and die
# with "Unknown IP" -- daemon, sync build and sync pull at once, on the node
# healthy enough to be holding the VIP.
_ip_probe() {
    local order="$1"
    bash -c "
        hostname() { [[ \"\$1\" == -I ]] && echo '$order'; }
        sed() {
            case \"\$*\" in
                *HA_NODES*) echo '192.168.20.22,192.168.20.23' ;;
                *VIP=*)     echo '192.168.20.24' ;;
            esac
        }
        source '$SCRIPT_DIR/../pihole-ha-platform' 2>/dev/null
        platform_get_local_ip
    "
}
assert_eq "local IP is the node, not the VIP (VIP listed first)" \
    "$(_ip_probe '192.168.20.24 192.168.20.22')" "192.168.20.22"
assert_eq "local IP is the node, not the VIP (node listed first)" \
    "$(_ip_probe '192.168.20.22 192.168.20.24')" "192.168.20.22"
assert_eq "local IP still works with a single address" \
    "$(_ip_probe '192.168.20.22')" "192.168.20.22"

# ============================================================
# The debug bundle must carry sync evidence
# ------------------------------------------------------------
# Issue #4 arrived undiagnosable: a sync complaint whose bundle contained no
# sync state and no sync logs, collected on the healthy node. The failing node
# in a sync fault is almost never the one the bundle came from.
_dbg="$SCRIPT_DIR/../pihole-ha-debug"
assert_contains "debug collects the sync build log"  "$(cat "$_dbg")" "pihole-ha-sync "
assert_contains "debug collects the sync pull log"   "$(cat "$_dbg")" "pihole-ha-sync-pull"
assert_contains "debug reports the sync state"       "$(cat "$_dbg")" "CONFIG SYNC STATE"
assert_contains "debug compares every node's manifest" "$(cat "$_dbg")" "api/sync/manifest"
assert_contains "debug says which node publishes"    "$(cat "$_dbg")" "publisher here?"

# ============================================================
# notify.conf must be readable by pihole-FTL's user
# ------------------------------------------------------------
# dnsmasq runs the dhcp-script as `pihole`, not root. A root-only notify.conf
# makes new-device notifications vanish silently -- the hook reads nothing and
# reports "pushover disabled", which reads like a setting rather than a bug.
# This cost a live outage of DHCP notifications on the primary; assert the
# installer never tightens it back to root-only.
_inst="$SCRIPT_DIR/../install.sh"
assert_contains "installer gives notify.conf to the pihole group" \
    "$(grep -A1 'chown root:pihole /etc/pihole-ha/notify.conf' "$_inst" 2>/dev/null)" \
    "chmod 640"
if grep -qE '^\s*chmod 600 /etc/pihole-ha/notify\.conf' "$_inst" 2>/dev/null; then
    printf "  FAIL  installer must not make notify.conf root-only\n"
    (( _FAIL++ )); (( _TOTAL++ ))
else
    printf "  PASS  installer must not make notify.conf root-only\n"
    (( _PASS++ )); (( _TOTAL++ ))
fi
assert_contains "dhcp hook reports an unreadable notify.conf distinctly" \
    "$(cat "$SCRIPT_DIR/../new-dhcp-device" 2>/dev/null)" \
    "notify_conf_unreadable"

# ============================================================

all_ok=true
for script in pihole-ha pihole-ha-dash pihole-ha-sync pihole-ha-sync-pull install.sh; do
    fpath="$SCRIPT_DIR/../$script"
    if [[ -f "$fpath" ]]; then
        if bash -n "$fpath" 2>&1; then
            printf "  PASS  syntax: %s\n" "$script"
            (( _PASS++ )); (( _TOTAL++ ))
        else
            printf "  FAIL  syntax: %s\n" "$script"
            (( _FAIL++ )); (( _TOTAL++ ))
            all_ok=false
        fi
    fi
done

# ============================================================
echo
test_summary
exit $?
