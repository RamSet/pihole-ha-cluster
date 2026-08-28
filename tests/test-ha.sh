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
# A RuntimeDirectory must not take the sync state with it
# ------------------------------------------------------------
# /run/pihole-ha holds the manifest, payload and build hash written by
# pihole-ha-sync -- a different unit. systemd deletes RuntimeDirectory when the
# owning unit stops, so without RuntimeDirectoryPreserve every restart of the
# daemon blinds every standby ("no peer has a manifest") until the next build.
for _unit in "$SCRIPT_DIR"/../*.service; do
    grep -q '^RuntimeDirectory=' "$_unit" 2>/dev/null || continue
    assert_contains "$(basename "$_unit"): RuntimeDirectory is preserved across restart" \
        "$(cat "$_unit")" "RuntimeDirectoryPreserve=yes"
done

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
echo
echo "=== Array-valued FTL config keys (CNAMEs, conditional forwarding) ==="
# ------------------------------------------------------------
# FTL prints an array as "[ a, b ]" but only accepts ["a","b"] back:
#   $ pihole-FTL --config dns.cnameRecords "[ x.lan,pi.hole ]"
#   Config setting dns.cnameRecords is invalid: not valid JSON
# So an array key listed in SETTINGS_KEYS is exported in the display form and
# silently rejected on the standby -- apply_settings swallows the error, the
# pull still logs status=ok, and the records never sync. That is exactly how
# local CNAME records went missing on every standby. Assert array keys stay out
# of SETTINGS_KEYS and keep their own JSON file in the payload.
_sync="$SCRIPT_DIR/../pihole-ha-sync"
_pull="$SCRIPT_DIR/../pihole-ha-sync-pull"

# Comments inside the block mention these keys by name, so strip them --
# otherwise the assertion passes/fails on prose rather than on a real entry.
_settings_keys_block="$(sed -n '/^SETTINGS_KEYS=(/,/^)/p' "$_sync" | sed 's/#.*//')"
for _arraykey in dns.cnameRecords dns.revServers dns.hosts dhcp.hosts; do
    assert_not_contains "array key $_arraykey stays out of SETTINGS_KEYS" \
        "$_settings_keys_block" "$_arraykey"
done

assert_contains "CNAMEs are exported as JSON, not FTL's display form" \
    "$(grep -A1 'config dns.cnameRecords' "$_sync")" "ftl_to_json"
assert_contains "conditional forwarding is exported as JSON" \
    "$(grep -A1 'config dns.revServers' "$_sync")" "ftl_to_json"
assert_contains "CNAMEs ride the DNS toggle" "$(cat "$_sync")" 'STAGING_DIR/dns-cnames.json'
assert_contains "CNAME changes are in the change-detection hash" \
    "$(sed -n '/^current_hash()/,/^}/p' "$_sync")" "dns.cnameRecords"
assert_contains "conditional forwarding is in the change-detection hash" \
    "$(sed -n '/^current_hash()/,/^}/p' "$_sync")" "dns.revServers"

# A missing array file means the publisher predates the key. It must be skipped,
# never treated as a fatal payload -- otherwise a fixed standby refuses every
# payload an older primary builds.
assert_not_contains "a missing dns-cnames.json is not a fatal payload error" \
    "$(grep 'pull_fail reason' "$_pull")" "dns-cnames.json"

# The applier itself, run against the real implementation.
_json_is_empty() { local s="${1//[[:space:]]/}"; [[ -z "$s" || "$s" == "[]" ]]; }
eval "$(extract_fn "$_pull" apply_array_key)"
eval "$(extract_fn "$_sync" ftl_to_json)"

# FTL's real display output for two CNAME records, and for conditional
# forwarding -- note the commas *inside* each entry, which is what makes the
# naive "split on comma" conversion wrong.
assert_eq "CNAME display form converts to JSON" \
    '["nas.lan,server.lan","git.lan,server.lan"]' \
    "$(printf '%s' '[ nas.lan,server.lan, git.lan,server.lan ]' | ftl_to_json)"
assert_eq "CNAME with a TTL survives conversion" \
    '["vpn.lan,gw.lan,300"]' \
    "$(printf '%s' '[ vpn.lan,gw.lan,300 ]' | ftl_to_json)"
assert_eq "conditional forwarding converts to JSON" \
    '["true,192.168.1.0/24,192.168.1.1,lan"]' \
    "$(printf '%s' '[ true,192.168.1.0/24,192.168.1.1,lan ]' | ftl_to_json)"

_arr_stage="$(mktemp -d)"
_run_apply() {   # $1=file contents (empty string = no file), $2=gate
    STAGING_DIR="$_arr_stage"
    rm -f "$_arr_stage/dns-cnames.json"
    [[ -n "$1" ]] && printf '%s\n' "$1" > "$_arr_stage/dns-cnames.json"
    APPLIED_SOMETHING=false; APPLY_FAILED=false; HOSTS_APPLIED=false
    log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }
    # Stand-in for FTL that enforces the real contract: JSON accepted, display
    # form rejected. Without this the test cannot tell the fix from the bug.
    pihole-FTL() { [[ "$3" == '['*'"'* || "$3" == "[]" ]]; }
    apply_array_key "$2" dns.cnameRecords dns-cnames.json dns_cnames
    # Runs inside a command substitution, so the flags have to come back out
    # on stdout -- assigning them here would not reach the caller.
    echo "FLAGS hosts_applied=$HOSTS_APPLIED apply_failed=$APPLY_FAILED"
}

_out="$(_run_apply '["nas.lan,server.lan"]' true)"
assert_contains "a JSON CNAME list applies" "$_out" "component=dns_cnames status=ok"
assert_contains "applying CNAMEs triggers the FTL restart" "$_out" "hosts_applied=true"
assert_contains "a successful apply is not marked failed" "$_out" "apply_failed=false"

_out="$(_run_apply '[ nas.lan,server.lan ]' true)"
assert_contains "the old display form is reported as a failure, not swallowed" \
    "$_out" "event=apply_fail component=dns_cnames"
assert_contains "a rejected apply blocks the hash, so the node retries" "$_out" "apply_failed=true"

_out="$(_run_apply '[]' true)"
assert_contains "an empty list never wipes the standby's CNAMEs" \
    "$_out" "event=apply_skip component=dns_cnames"

_out="$(_run_apply '' true)"
assert_not_contains "an older primary with no CNAME file is not an error" "$_out" "apply_failed=true"
assert_not_contains "an older primary with no CNAME file applies nothing" "$_out" "status=ok"

_out="$(_run_apply '["nas.lan,server.lan"]' false)"
assert_not_contains "CNAMEs are not applied when the DNS toggle is off" "$_out" "status=ok"
rm -rf "$_arr_stage"
unset -f pihole-FTL log_info log_warn

# The panel must not promise CNAMEs under a toggle that does not carry them.
assert_not_contains "panel no longer claims CNAMEs live in custom.list" \
    "$(cat "$SCRIPT_DIR/../ha.lp" 2>/dev/null)" "A/AAAA/CNAME) from Pi-hole's custom.list"

# ============================================================
echo
echo "=== Docker FTL reload must not stop the container (issue #5) ==="
# ------------------------------------------------------------
# In Docker the sidecar shares the pihole container's PID and network namespaces
# (pid: "service:pihole"). FTL is that container's main process, so SIGTERM
# stops the container, tears down the namespace, and SIGKILLs whatever the
# sidecar was running -- including the sync-pull that asked for the restart,
# killed before it records the hash it just applied. The node then re-pulls and
# kills itself again every cycle. Reproduced: pihole exits 0, sidecar exits 137,
# last-pull-hash never written. SIGHUP reloads pihole.toml and gravity.db in
# place instead, same PID, container untouched.
_plat="$SCRIPT_DIR/../pihole-ha-platform"
_ftl_restart_fn="$(extract_fn "$_plat" platform_ftl_restart)"
_docker_branch="${_ftl_restart_fn%%else*}"

assert_not_contains "docker reload never SIGTERMs FTL" "$_docker_branch" "kill -TERM"
assert_not_contains "docker reload never plain-kills FTL" "$_docker_branch" 'kill "$pid"'
assert_contains     "docker reload signals FTL with SIGHUP" "$_docker_branch" "kill -HUP"
assert_contains     "bare-metal still uses systemctl restart" "$_ftl_restart_fn" "systemctl restart pihole-FTL"

# The reload must report failure if FTL did not survive it, so an apply that
# silently lost its daemon is not recorded as a success.
assert_contains "docker reload verifies FTL is still alive" "$_docker_branch" "kill -0"

# ============================================================
echo
echo "=== Docker provisioning: peer auth + DNS pin ==="
# ------------------------------------------------------------
# A peer only counts as alive if an AUTHENTICATED call to its Pi-hole API
# succeeds, and that password comes from auth.conf. On bare metal the operator
# types it into the panel; a container has nobody to type it in, so auth.conf
# stayed empty, every peer check 401'd, and each node -- which always counts
# itself alive -- elected itself publisher. Two publishers, versions ratcheting,
# and the only symptom a repeated sync_promote. Verified in a two-node Docker
# cluster: seeding auth.conf is what made the roles settle.
_entry="$SCRIPT_DIR/../docker/docker-entrypoint.sh"
assert_contains "docker seeds peer API passwords"       "$(cat "$_entry")" "seed_auth_conf"
assert_contains "seeded entries use the PASS_<ip> key"  "$(cat "$_entry")" 'PASS_${_ip//./_}'
assert_contains "a password already set is never overwritten" \
    "$(extract_fn "$_entry" seed_auth_conf)" 'grep -q "^${_key}=" /etc/pihole-ha/auth.conf'
assert_contains "seeded auth.conf is not world-readable" \
    "$(extract_fn "$_entry" seed_auth_conf)" "chmod 600"

# PIN_DNS was reachable on bare metal but had no Docker equivalent, so a
# container could never opt out of having its resolver rewritten.
assert_contains "PIN_DNS is settable in docker" "$(cat "$_entry")" 'PIN_DNS=${PIHOLE_HA_PIN_DNS:-true}'

# Pinning to a local resolver that is not answering does not degrade DNS, it
# removes it -- and on a fresh container it deadlocks startup outright: FTL is
# waiting on gravity, and gravity cannot download once the only working resolver
# is gone. Observed live; the cluster would not boot until it was broken by hand.
_pin_fn="$(extract_fn "$SCRIPT_DIR/../pihole-ha" enforce_dns_pin)"
assert_contains "dns pin waits for the local resolver to answer" "$_pin_fn" "nc -z -w1 127.0.0.1 53"
assert_contains "deferring the pin is reported"                  "$_pin_fn" "event=dns_pin_deferred"
# The deferral must come BEFORE resolv.conf is rewritten, or it defers nothing.
_before_write="${_pin_fn%%resolv.conf directly*}"
assert_contains "the check runs before resolv.conf is touched" "$_before_write" "dns_pin_deferred"

# Deferring is only safe if something re-tries it. Called once at startup, a
# deferred pin would never be applied at all -- the node would silently keep the
# resolver the pin exists to replace. It must also run inside the check loop.
_ha_src="$(cat "$SCRIPT_DIR/../pihole-ha")"
_loop_body="${_ha_src##*while true; do}"
assert_contains "a deferred dns pin is retried by the main loop" "$_loop_body" "enforce_dns_pin"

echo
echo "=== Signature rejection must not cry tampering at a benign race ==="
# ------------------------------------------------------------
# A publisher that rebuilds between our manifest read and our download leaves us
# holding bytes that do not match the signature we were given. That is a race,
# not an attack, and it clears itself. Seen live: one pull rejected seconds after
# the publisher's service restarted, the next pull verified fine.
_sigblock="$(sed -n '/_want_sig=/,/^fi$/p' "$SCRIPT_DIR/../pihole-ha-sync-pull")"
assert_contains "a moved signature is re-checked before rejecting" "$_sigblock" "_now_sig"
assert_contains "a mid-download rebuild retries instead of failing" "$_sigblock" "event=pull_retry"
assert_contains "an unsigned peer gets its own actionable message"  "$_sigblock" "UNSIGNED payload"
assert_contains "the unsigned case names the fix"                   "$_sigblock" "cluster.key to"
# A real mismatch must still be a hard reject -- this guard must never soften.
assert_contains "a genuine mismatch is still rejected" "$_sigblock" "event=pull_reject"

# ============================================================
echo
echo "=== Docker must honour the configured sync interval ==="
# ------------------------------------------------------------
# SYNC_INTERVAL lives in sync.conf in MINUTES, is written by the HA panel and
# synced cluster-wide. Bare metal applies it by rewriting a systemd timer
# drop-in. A container has no timer, so its supervisor has to apply it -- and it
# did not: the interval was read from the environment once at startup and
# sync.conf was never consulted, so changing it in the panel did nothing at all
# and the container kept its boot value for life. Reported as "cluster isn't
# syncing automatically" (it was, just never on the cadence that was set).
_entry="$SCRIPT_DIR/../docker/docker-entrypoint.sh"
_entry_src="$(cat "$_entry")"

assert_contains "the supervisor reads SYNC_INTERVAL from sync.conf" \
    "$(extract_fn "$_entry" read_sync_interval)" "'^SYNC_INTERVAL=' \"\$SYNC_CONF\""
assert_contains "sync.conf minutes are converted to seconds" \
    "$(extract_fn "$_entry" read_sync_interval)" '_m * 60'
assert_contains "the env var remains the bootstrap default" "$_entry_src" 'PIHOLE_HA_SYNC_INTERVAL:-900'
assert_contains "a zero or junk interval falls back to the default" \
    "$(extract_fn "$_entry" read_sync_interval)" 'SYNC_INTERVAL_DEFAULT'

# Reading it once at startup is what the bug was -- it has to be re-read in the
# loop, or a change made after boot is still ignored.
_sup_loop="${_entry_src##*while true; do}"
assert_contains "the interval is re-read every supervisor cycle" "$_sup_loop" "read_sync_interval"
assert_contains "an interval change is reported"                 "$_sup_loop" "sync_interval_changed"
# ...and the re-read must happen BEFORE the elapsed-time comparison, or the new
# value only takes effect one full old-interval later.
_before_check="${_sup_loop%%NOW - LAST_SYNC*}"
assert_contains "the re-read precedes the elapsed check" "$_before_check" "read_sync_interval"

# The platform helper's docker branch is deliberately empty; it must stay empty
# only because the supervisor does the work, so guard the claim.
assert_contains "bare metal still writes a timer drop-in" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha-platform" platform_sync_set_interval)" 'OnUnitActiveSec=${minutes}min'

# ============================================================
echo
echo "=== Installers must not depend on \`hostname -I\` (issue #6) ==="
# ------------------------------------------------------------
# Arch ships inetutils' hostname, which has no -I, so the installer aborted with
# "hostname: invalid option -- 'I'" before it could do anything. Where -I does
# exist it prints every address on the box in no defined order, so taking the
# first field hands back 172.17.0.1 as readily as the LAN address on any host
# running Docker. Verified in a BusyBox environment (same limitation as Arch):
# hostname -I fails outright and detect_local_ip returns the correct address.
for _inst in install.sh docker-install.sh; do
    _src="$SCRIPT_DIR/../$_inst"
    # Strip comments -- the fix documents the old call by name on purpose.
    _code="$(sed 's/#.*//' "$_src")"
    assert_not_contains "$_inst does not call hostname -I" "$_code" "hostname -I"
    assert_contains     "$_inst defines detect_local_ip"   "$(cat "$_src")" "detect_local_ip() {"
    assert_contains     "$_inst derives the IP from the default route" \
        "$(extract_fn "$_src" detect_local_ip)" "ip -o route get"
    # The no-default-route fallback must not hand back a bridge address.
    assert_contains "$_inst fallback skips bridge interfaces" \
        "$(extract_fn "$_src" detect_local_ip)" "docker[0-9]*|br-"
done

# A host with two NICs on one LAN has two valid answers; only the operator knows
# which one the peers will use. The reporter had to edit the script by hand.
assert_contains "docker installer lets the operator override the detected IP" \
    "$(cat "$SCRIPT_DIR/../docker-install.sh")" "LAN IP [\$detected_ip]"

echo
echo "=== Pi-hole port probe must use an endpoint that exists ==="
# ------------------------------------------------------------
# /api/info 404s on Pi-hole v6 -- confirmed against two live instances -- so the
# probe could never succeed on any port for anyone. The installer then concluded
# no Pi-hole was anywhere, found the port in use (by Pi-hole itself), and
# reported "Port 80 is in use by another service (not Pi-hole)".
_probe="$(extract_fn "$SCRIPT_DIR/../docker-install.sh" _is_pihole_port)"
assert_not_contains "the probe does not use the 404-ing /api/info" "$_probe" '/api/info"'
assert_contains     "the probe uses a real endpoint"               "$_probe" "/api/info/ftl"
# A password-protected Pi-hole answers 401 -- still proof Pi-hole is listening.
assert_contains "a password-protected Pi-hole still counts as Pi-hole" "$_probe" '"key":"unauthorized"'
# curl -f suppresses the body on a 401, which is exactly what is being matched.
assert_not_contains "the probe does not use curl -f" "$_probe" "curl -sf"

# ============================================================
echo
echo "=== Panel errors must name the component that actually failed ==="
# ------------------------------------------------------------
# The panel's status call goes to Pi-hole's OWN web server (ha-api, same
# origin); it reads the status file directly and never touches port 8887. Every
# failure -- 404, a login redirect, a Lua error, a timeout -- used to print
# "Cannot reach the local HA service on port 8887", which sent a user off
# debugging a socat listener that was healthy the whole time while the real
# cause went unmentioned. Confirmed against a password-protected Pi-hole: the
# panel API answers 302 to the login page, which jQuery reports as a parse
# error, not as a connection failure.
_js="$(cat "$SCRIPT_DIR/../ha.js")"
assert_not_contains "the panel no longer blames port 8887 for every failure" \
    "$_js" "Cannot reach the local HA service on port 8887"
assert_contains "a login redirect is reported as a session problem" "$_js" "parsererror"
assert_contains "a missing ha-api page names the injector fix"       "$_js" "pihole-ha-inject"
assert_contains "an HTTP status is surfaced to the user"             "$_js" "xhr.status"
assert_contains "the failure handler receives the xhr"               "$_js" "showHaError(null, xhr, textStatus)"
assert_not_contains "the static fallback text drops the 8887 claim" \
    "$(cat "$SCRIPT_DIR/../ha.lp")" "Cannot reach the local HA service on port 8887"

echo
echo "=== A peer we cannot authenticate to must say so ==="
# ------------------------------------------------------------
# A peer that fails authentication is treated as DOWN, so every node elects
# itself publisher and nothing is ever pulled: config sync stops dead with no
# error anywhere. Verified live by emptying auth.conf on a running cluster.
_ha_src="$(cat "$SCRIPT_DIR/../pihole-ha")"
assert_contains "an unauthenticatable peer is logged"          "$_ha_src" "event=peer_auth_missing"
assert_contains "a rejected password is logged distinctly"     "$_ha_src" "event=peer_auth_denied"
assert_contains "the warning names the file and key to set"    "$_ha_src" 'PASS_${ip//./_}'
assert_contains "the warning says sync will not run"           "$_ha_src" "config sync will not run"
# Must not fire for our own address: a failed self-check never gates publishing,
# so claiming sync is broken there would be false.
assert_contains "the warning is limited to real peers" "$_ha_src" '"$ip" != "$LOCAL_IP" && "${peer_auth_warned[$ip]:-}"'
# Must not repeat every 10s check cycle.
assert_contains "the warning is emitted once per peer" "$_ha_src" "peer_auth_warned[\$ip]=\"true\""

# ============================================================
echo
echo "=== Bulk sync artifacts must not live on tmpfs ==="
# ------------------------------------------------------------
# /run is tmpfs sized at ~10% of RAM: 182M on a 1GB Raspberry Pi. The payload
# carries a full gravity.db copy -- tens of megabytes -- and /tmp is tmpfs on a
# stock Pi too, so staging doubled the cost. A reported cluster filled tmpfs,
# tar failed with "tar.gz creation failed", and then the daemon could no longer
# write status.json either, so the admin panel reported a problem nowhere near
# the cause. Small transient state stays in /run; the blobs go on disk.
_sync_src="$(cat "$SCRIPT_DIR/../pihole-ha-sync")"
_pull_src="$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")"

assert_contains "the payload is written to disk"   "$_sync_src" 'PAYLOAD_FILE="$SYNC_BLOB_DIR/sync-payload.tar.gz"'
assert_contains "the manifest is written to disk"  "$_sync_src" 'MANIFEST_FILE="$SYNC_BLOB_DIR/sync-manifest.json"'
assert_contains "the blob dir is a disk path"      "$_sync_src" 'SYNC_BLOB_DIR="/var/lib/pihole-ha"'
assert_not_contains "the payload is not in /run"   "$_sync_src" 'PAYLOAD_FILE="$SYNC_DIR'
assert_not_contains "build staging is not in /tmp" "$_sync_src" 'STAGING_DIR="/tmp/'
assert_not_contains "pull staging is not in /tmp"  "$_pull_src" 'STAGING_DIR="/tmp/'
# Small, genuinely transient state SHOULD stay in /run.
assert_contains "the build hash stays in /run" "$_sync_src" 'HASH_FILE="$SYNC_DIR/last-sync-hash"'
assert_contains "the pull hash stays in /run"  "$_pull_src" 'LAST_HASH_FILE="$SYNC_DIR/last-pull-hash"'
# A failed build must say why -- "tar.gz creation failed" alone explains nothing.
assert_contains "a failed build reports free space" "$_sync_src" "free_mb="
# The dash must still find a payload built by the previous version.
assert_contains "the dash falls back to the old tmpfs path" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" '/run/pihole-ha/sync-payload.tar.gz'
# Upgrades must reclaim the tmpfs the old layout consumed.
assert_contains "the installer reclaims the old tmpfs payload" \
    "$(cat "$SCRIPT_DIR/../install.sh")" "rm -f /run/pihole-ha/sync-payload.tar.gz"
# ...and specifically on the --update path. A standby never runs the build
# script, which is the only other thing that clears the old copy, so an upgrade
# that skips this leaves tens of megabytes of tmpfs occupied forever.
_upd_branch="$(sed -n '/--update/,/^fi$/p' "$SCRIPT_DIR/../install.sh")"
assert_contains "the update path reclaims it too" "$_upd_branch" "rm -f /run/pihole-ha/sync-payload.tar.gz"
assert_contains "the update path creates the disk dir" "$_upd_branch" "mkdir -p /var/lib/pihole-ha"

echo
echo "=== A truncated status file must never replace a good one ==="
# ------------------------------------------------------------
# When the filesystem filled, each printf failed but the truncated leftover was
# moved over the live status.json anyway, so the panel read invalid JSON and
# reported something unrelated. Verified on a real full tmpfs: the previous
# status file is kept and still parses.
_ws="$(extract_fn "$SCRIPT_DIR/../pihole-ha" write_status)"
assert_contains "an incomplete status file is rejected"     "$_ws" 'tail -c 3'
assert_contains "the failure is reported with free space"   "$_ws" "event=status_write_failed"
assert_contains "the previous status file is kept"          "$_ws" "keeping the previous one"
# The guard has to run BEFORE the file is promoted, or it guards nothing.
_before_mv="${_ws%%mv \"\$tmp\"*}"
assert_contains "the check precedes the promotion" "$_before_mv" "status_write_failed"

# ============================================================
echo
echo "=== The sync storage location is per-node and overridable ==="
# ------------------------------------------------------------
# Storage layout is a property of the machine, not the cluster: one node may
# have an SSD at /mnt/ssd and its peer none. sync.conf is shipped INSIDE the
# payload and applied on every node, so putting a path there would push one
# machine's layout onto peers that cannot honour it. nodes.conf is local.
for _f in pihole-ha-sync pihole-ha-sync-pull; do
    _src="$(cat "$SCRIPT_DIR/../$_f")"
    assert_contains "$_f honours SYNC_BLOB_DIR from nodes.conf" "$_src" 'SYNC_BLOB_DIR="${SYNC_BLOB_DIR:-/var/lib/pihole-ha}"'
    assert_contains "$_f rejects a relative path"               "$_src" '"$SYNC_BLOB_DIR" != /*'
    assert_contains "$_f falls back instead of failing"         "$_src" "event=blob_dir_unusable"
done
# It must NOT be written into the file that gets synced to every node.
_syncconf_block="$(sed -n '/cat > "\$SYNC_CONF"/,/^EOF$/p' "$SCRIPT_DIR/../docker/docker-entrypoint.sh")"
assert_not_contains "the storage path is not put in the synced sync.conf" "$_syncconf_block" "SYNC_BLOB_DIR"
_nodesconf_block="$(sed -n '/cat > "\$NODES_CONF"/,/^EOF$/p' "$SCRIPT_DIR/../docker/docker-entrypoint.sh")"
assert_contains "docker writes it to the per-node nodes.conf" "$_nodesconf_block" "SYNC_BLOB_DIR="
# The dash serves the payload, so it has to look in the same place.
assert_contains "the dash honours the override" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" '_BLOB_DIR="${SYNC_BLOB_DIR:-/var/lib/pihole-ha}"'
# Logging identity must be set before anything that can log, or the warning
# above comes out with an empty role tag.
for _f in pihole-ha-sync pihole-ha-sync-pull; do
    _head="$(sed -n '1,/Where the bulk sync artifacts live/p' "$SCRIPT_DIR/../$_f")"
    assert_contains "$_f sets its log identity before validating the path" "$_head" "PIHOLE_HA_LOG_TAG="
done
assert_contains "the option is documented" "$(cat "$SCRIPT_DIR/../README.md")" "SYNC_BLOB_DIR"

# ============================================================
echo
echo "=== Diagnostics must report the hash that actually moves ==="
# ------------------------------------------------------------
# The debug tool's manifest table filled its HASH column from gravity_md5, which
# only changes when the blocklists change. Two nodes days apart in config showed
# an identical frozen value, directly beneath a line telling the reader to look
# at whichever node's hash differs. Confirmed live: config hash 31750dd1...,
# gravity_md5 c59f12a9... -- the table was showing the wrong one.
_dbg="$(cat "$SCRIPT_DIR/../pihole-ha-debug")"
_hash_line="$(grep -n '_h=' "$SCRIPT_DIR/../pihole-ha-debug" | head -1)"
assert_not_contains "the HASH column is not gravity_md5" "$_hash_line" "gravity_md5"
assert_contains     "the HASH column reads the config hash" "$_hash_line" '"hash"'

echo
echo "=== A failed build must not advance the config version ==="
# ------------------------------------------------------------
# The version was written to disk before the payload was built, so every failed
# build advanced it with nothing to match. A node whose disk was full reached
# version 112 while still serving the payload it built at version 2 -- and the
# version is what peers compare to decide who is newer. Verified live: a build
# that fails leaves the file untouched, the next successful one advances it.
_sync_src="$(cat "$SCRIPT_DIR/../pihole-ha-sync")"
# The write must come after the manifest exists, not before the build.
_after_manifest="${_sync_src##*mv \"\$MANIFEST_FILE.tmp\" \"\$MANIFEST_FILE\"}"
assert_contains "the version is persisted only after the manifest is written" \
    "$_after_manifest" 'echo "$CONFIG_VERSION" > "$VER_FILE"'
# ...and nowhere before it.
_before_build="${_sync_src%%log_info \"event=build_start*}"
assert_not_contains "the version is not persisted before the build" \
    "$_before_build" 'echo "$CONFIG_VERSION" > "$VER_FILE"'
# The bump must not be announced for a build that then fails.
assert_contains "the bump is logged where it is persisted" \
    "$_after_manifest" "event=version_bump"

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
