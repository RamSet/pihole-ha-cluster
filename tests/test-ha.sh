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

# Declare the peer_* maps exactly as the daemon does, rather than listing the
# ones these tests happen to set. An undeclared name makes bash read the
# subscript as arithmetic, so the first IP lookup dies with "invalid arithmetic
# operator" and the extracted function returns nothing -- the test then fails
# for its own reason, not the code's. That is what happened when peer_auth
# joined get_fail_reason and this line did not.
eval "$(grep -E '^declare -A peer_' "$HA_SRC")"
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
# should_i_serve gates every activation path on this node's own DNS health, the
# same precondition should_i_hold_vip uses. Extract it too — an undefined helper
# returns 127, which reads as "unhealthy" and fails these tests for its own
# reason rather than the code's.
eval "$(extract_fn "$HA_SRC" is_dns_healthy)"
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
# Sync timers must still fire after a reboot once the interval is changed
# ------------------------------------------------------------
# Issue #7: the interval drop-in opened with "OnUnitActiveSec=", which systemd
# reads as "reset every trigger" -- so it also erased the unit's OnActiveSec=.
# What was left counts from a service run, so after a reboot neither timer ever
# fired. Both still reported "active", so the daemon's recovery check and the
# debug bundle both called them healthy.
_t7="$(mktemp -d)"
cp "$SCRIPT_DIR/../pihole-ha-sync.timer" "$SCRIPT_DIR/../pihole-ha-sync-pull.timer" "$_t7/"
(
    PIHOLE_HA_PLATFORM=systemd
    systemctl() { :; }
    eval "$(extract_fn "$SCRIPT_DIR/../pihole-ha-platform" platform_sync_set_interval | sed "s#/etc/systemd/system#$_t7#g")"
    platform_sync_set_interval 1
)
for _unit in pihole-ha-sync.timer pihole-ha-sync-pull.timer; do
    _base_act="$(grep '^OnActiveSec=' "$_t7/$_unit")"
    assert_contains "$_unit ships an OnActiveSec= trigger" "$_base_act" "OnActiveSec="
    _drop="$(cat "$_t7/$_unit.d/interval.conf" 2>/dev/null)"
    # Order matters: anything above the reset line is erased by it.
    _after_reset="${_drop#*"OnUnitActiveSec="$'\n'}"
    assert_contains "$_unit: interval drop-in restores $_base_act after the reset" "$_after_reset" "$_base_act"
    assert_contains "$_unit: interval drop-in sets the new interval" "$_after_reset" "OnUnitActiveSec=1min"
done
rm -rf "$_t7"

# "elapsed" is systemd's state for an active timer with no trigger left.
_timer_probe() {
    local active="$1" sub="$2" snippet="$3"
    bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        PIHOLE_HA_PLATFORM=systemd
        systemctl() {
            case "$*" in
                "is-active --quiet "*)          [[ "'"$active"'" == active ]] ;;
                "show -p SubState --value "*)   echo "'"$sub"'" ;;
                "start --no-block "*)           echo "KICKED ${*: -1}" ;;
            esac
        }
        '"$snippet"'
    ' 2>/dev/null
}
assert_eq "an active but elapsed build timer counts as not running" \
    "" "$(_timer_probe active elapsed 'platform_sync_is_running && echo RUNNING')"
assert_eq "an active but elapsed pull timer counts as not running" \
    "" "$(_timer_probe active elapsed 'platform_sync_pull_is_running && echo RUNNING')"
assert_eq "an active, waiting build timer counts as running" \
    "RUNNING" "$(_timer_probe active waiting 'platform_sync_is_running && echo RUNNING')"
assert_eq "starting an elapsed build timer runs the service once to re-arm it" \
    "KICKED pihole-ha-sync.service" "$(_timer_probe active elapsed platform_sync_enable)"
assert_eq "starting an elapsed pull timer runs the service once to re-arm it" \
    "KICKED pihole-ha-sync-pull.service" "$(_timer_probe active elapsed platform_sync_pull_enable)"
assert_eq "starting a waiting timer does not run the service early" \
    "" "$(_timer_probe active waiting platform_sync_pull_enable)"

# Nodes that already hold the old drop-in must get it rewritten on upgrade.
assert_eq "installer re-applies the interval drop-in on update and on install" \
    "2" "$(grep -cE '^[[:space:]]*_reapply_sync_interval$' "$SCRIPT_DIR/../install.sh")"
assert_contains "the installer re-apply goes through the platform writer" \
    "$(extract_fn "$SCRIPT_DIR/../install.sh" _reapply_sync_interval)" "platform_sync_set_interval"
assert_contains "debug flags a timer that will never fire" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-debug")" '"$_s" == "elapsed"'

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

# Only "valid":false means the password is wrong. Anything else that comes back
# -- a redirect to https, another service on that port, a rate-limit page, an
# empty body -- is not an answer about the password, and reporting it as one
# sent a reporter hunting a password that was never wrong (Discourse 86667).
_auth_probe() {   # $1 body, $2 http status, $3 curl rc
    # The canned reply travels in the environment, not interpolated into this
    # script: a body containing a double quote closed the string and the probe
    # failed for its own reason.
    PROBE_BODY="$1" PROBE_CODE="$2" PROBE_RC="${3:-0}" bash -c '
        # json_str/json_bool live in the platform library, as the daemon has them
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        AUTH_TIMEOUT=10; AUTH_RETRY_SEC=60
        declare -A peer_password peer_sid peer_auth_next peer_auth_why NODE_PORTS
        peer_password[10.0.0.9]="stored-pw"
        curl() { printf "%s\n%s" "$PROBE_BODY" "$PROBE_CODE"; return "$PROBE_RC"; }
        '"$(sed -n "/^_api_snippet()/,/^}/p" "$SCRIPT_DIR/../pihole-ha")"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" ensure_sid)"'
        ensure_sid 10.0.0.9
        printf "%s|%s" "${peer_sid[10.0.0.9]:-none}" "${peer_auth_why[10.0.0.9]:-none}"
    '
}
assert_contains "a real rejection is still called a rejection" \
    "$(_auth_probe '{"valid":false,"sid":null,"message":"password incorrect"}' 401)" "rejected the password"
assert_contains "an https redirect is not called a wrong password" \
    "$(_auth_probe '<html>301 Moved</html>' 301)" "unexpected reply"
assert_contains "the unexpected reply names the status and port" \
    "$(_auth_probe '<html>301 Moved</html>' 301)" "port 80 (HTTP 301)"
assert_contains "an empty body is not called a wrong password" \
    "$(_auth_probe '' 204)" "unexpected reply"
# FTL sends both spellings (src/api/auth.c): the key api_seats_exceeded and the
# message "API seats exceeded", with HTTP 429. Match either, so a reworded
# message does not turn seat exhaustion back into "wrong password".
assert_contains "seats exhaustion is named from the message" \
    "$(_auth_probe '{"error":{"key":"api_seats_exceeded","message":"API seats exceeded"}}' 429)" "API seats exceeded"
assert_contains "seats exhaustion is named from the key alone" \
    "$(_auth_probe '{"error":{"key":"api_seats_exceeded"}}' 429)" "API seats exceeded"
assert_contains "a timeout is still named" \
    "$(_auth_probe '' 000 28)" "timed out"
assert_contains "a passwordless peer is still not a rejection" \
    "$(_auth_probe '{"valid":true,"sid":null,"message":"password incorrect"}' 200)" "NO Pi-hole password"
assert_eq "a good login still caches the session" \
    "SID42" "$(_auth_probe '{"valid":true,"sid":"SID42"}' 200 | cut -d'|' -f1)"
# The snippet goes into a log line and into status.json, which is assembled by
# hand: a quote or a newline from the peer would break the JSON.
_msg="$(_auth_probe '<html>
"quoted" \back\slash</html>' 500)"
assert_not_contains "the quoted reply carries no double quote" "$_msg" '"'
assert_eq "the quoted reply carries no newline" "0" "$(printf '%s' "$_msg" | wc -l | tr -d ' ')"

# A node checking its OWN Pi-hole must say what it got back. With no API seats
# left, Pi-hole refuses even the credential-free check, and the panel showed a
# bare "API FAIL" beside "No password (open)" -- describing a node that was
# neither open nor merely unreachable (Discourse 86667 again).
_self_probe() {   # $1 body, $2 curl rc
    PROBE_BODY="$1" PROBE_RC="${2:-0}" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        HEALTH_TIMEOUT=2; LOCAL_IP=10.0.0.1
        '"$(grep -E '^declare -A peer_' "$SCRIPT_DIR/../pihole-ha")"'
        declare -A NODE_PORTS; NODE_PORTS[10.0.0.1]=8080
        log_info() { :; }; release_sid() { :; }; get_dhcp() { echo false; }
        curl() { printf "%s" "$PROBE_BODY"; return "$PROBE_RC"; }
        '"$(sed -n "/^_api_snippet()/,/^}/p" "$SCRIPT_DIR/../pihole-ha")"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" peer_requires_password)"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" update_needs_pass)"'
        self_check() {
            local ip="$1"
            '"$(sed -n "/^    if \[\[ \"\$ip\" == \"\$LOCAL_IP\" \]\]; then$/,/^        return$/p" "$SCRIPT_DIR/../pihole-ha" | sed "1d;\$d")"'
        }
        self_check 10.0.0.1
        printf "api=%s auth=%s why=%s" "${peer_api[10.0.0.1]}" "${peer_auth[10.0.0.1]}" "${peer_auth_why[10.0.0.1]:-none}"
    '
}
assert_contains "an open local Pi-hole still reads as open" \
    "$(_self_probe '{"session":{"valid":true,"sid":null}}')" 'api=true auth="none"'
assert_contains "a password-protected node does not call itself passwordless" \
    "$(_self_probe '{"session":{"valid":false,"sid":null}}')" 'auth="self"'
assert_contains "exhausted API seats are named, not reported as FAIL alone" \
    "$(_self_probe '{"error":{"key":"api_seats_exceeded","message":"API seats exceeded"}}')" "out of API seats"
assert_contains "another service on the local port is named" \
    "$(_self_probe '<html>nginx</html>')" "unexpected reply"
assert_contains "the unexpected local reply names the port" \
    "$(_self_probe '<html>nginx</html>')" "port 8080"
assert_contains "a silent local API is not confused with a bad answer" \
    "$(_self_probe '' 7)" "did not answer"
# The panel has to show that reason, or the daemon is explaining itself to a log
# nobody reads while the row still says only FAIL.
assert_contains "the panel prints the reason under a failing API row" \
    "$(cat "$SCRIPT_DIR/../ha.js")" "peer.api === false && peer.auth_why"
assert_contains "the panel renders the self auth state" \
    "$(cat "$SCRIPT_DIR/../ha.js")" 'peer.auth === "self"'

# Every call to a peer's Pi-hole must use that peer's port. The dashboard hard-
# coded 80, so on a cluster where Pi-hole is not on 80 -- ours runs behind nginx
# with FTL on 8080 -- panel propagation could never authenticate.
_dash_src="$(cat "$SCRIPT_DIR/../pihole-ha-dash")"
assert_not_contains "the dashboard does not assume port 80 for a peer login" \
    "$_dash_src" 'http://$ip/api/auth'
assert_contains "the dashboard uses the peer's recorded port" \
    "$_dash_src" '${_NODE_PORTS[$ip]:-80}/api/auth'

# ============================================================
# Pi-hole's API must be parsed by shape, not by whitespace
# ------------------------------------------------------------
# With webserver.api.prettyJSON on, Pi-hole prints "sid":<tab>"...". Every
# compact-only match missed, so a login that HAD succeeded read as a failure and
# its session was abandoned -- one seat per retry until that Pi-hole refused
# every login on the cluster. Reproduced against a real instance: three attempts
# left three orphaned sessions and no sid. (Discourse 86667.)
_json_probe() {   # $1 body, $2 fn, $3 key
    PROBE_BODY="$1" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        '"$2"' "$PROBE_BODY" '"$3"'
    '
}
_compact='{"session":{"valid":true,"sid":"ABC","validity":1800}}'
_spaced='{"session": {"valid": true, "sid": "ABC", "validity": 1800}}'
_tabbed=$'{\n\t"session":\t{\n\t\t"valid":\ttrue,\n\t\t"sid":\t"ABC",\n\t\t"validity":\t1800\n\t}\n}'
for _fmt in compact spaced tabbed; do
    eval "_body=\"\$_$_fmt\""
    assert_eq "$_fmt JSON: the session id is read"  "ABC"  "$(_json_probe "$_body" json_str sid)"
    assert_eq "$_fmt JSON: the boolean is read"     "true" "$(_json_probe "$_body" json_bool valid)"
    assert_eq "$_fmt JSON: the number is read"      "1800" "$(_json_probe "$_body" json_num validity)"
done
assert_eq "a null value yields no string" "" "$(_json_probe '{"sid":	null}' json_str sid)"
assert_eq "a missing key yields nothing"  "" "$(_json_probe '{"other":"x"}' json_str sid)"
assert_eq "false is read as false, not as missing" "false" \
    "$(_json_probe '{"valid" :  false}' json_bool valid)"

# The whole point is the login path, so exercise it with a pretty-printed reply.
_pretty_login=$'{\n\t"session":\t{\n\t\t"valid":\ttrue,\n\t\t"sid":\t"PRETTY42",\n\t\t"message":\t"password correct"\n\t}\n}'
assert_eq "a pretty-printed login is recognised, not abandoned" \
    "PRETTY42" "$(_auth_probe "$_pretty_login" 200 | cut -d'|' -f1)"
_pretty_open=$'{\n\t"session":\t{\n\t\t"valid":\ttrue,\n\t\t"sid":\tnull,\n\t\t"message":\t"no password set"\n\t}\n}'
assert_contains "a pretty-printed passwordless peer is still not a rejection" \
    "$(_auth_probe "$_pretty_open" 200)" "NO Pi-hole password"
assert_contains "a pretty-printed protected node is not called passwordless" \
    "$(_self_probe $'{\n\t"session":\t{\n\t\t"valid":\tfalse\n\t}\n}')" 'auth="self"'

# Class guard: no Pi-hole field may be matched with the colon glued to its
# value again. Comments quote the wire format on purpose, so strip them.
for _f in pihole-ha pihole-ha-dash; do
    _code="$(sed 's/#.*//' "$SCRIPT_DIR/../$_f")"
    assert_not_contains "$_f does not match \"valid\": with no whitespace allowed" "$_code" '"valid":'
    assert_not_contains "$_f does not match \"sid\": with no whitespace allowed"   "$_code" '"sid":"'
    assert_not_contains "$_f does not match \"active\": with no whitespace allowed" "$_code" '"active":'
done

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

# The payload moved off /run in 3.12.12; this tool kept looking in the old place
# and so reported "(none built on this node)" on every node since -- on the very
# line people read to decide whether the publisher is publishing at all.
assert_contains "the debug tool looks for the payload in the blob dir" "$_dbg" 'BLOB_DIR/sync-payload.tar.gz'
assert_contains "it honours a per-node override"                       "$_dbg" "sed -n 's/^SYNC_BLOB_DIR=//p'"
assert_contains "it falls back to the pre-3.12.12 location"            "$_dbg" 'BLOB_DIR="$RUN_DIR"'
# State that genuinely stayed in /run must keep reading from there.
assert_contains "the pull hash is still read from /run" "$_dbg" 'RUN_DIR/last-pull-hash'

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
echo
echo "=== Standing down gives back what the node holds ==="

# Reported by a user: a node sat at "HA disabled" with vip_held:true while a
# healthy primary held the same address. Declining to take over and letting go
# are different things, and the branches that meant "not participating" only did
# the first.
eval "$(extract_fn "$HA_SRC" stand_down)"

_sd_dhcp="" _sd_vip="" _sd_log=""
get_dhcp()   { echo "$_sd_dhcp"; }
set_dhcp()   { _sd_dhcp="$1"; }
has_vip()    { [[ "$_sd_vip" == "held" ]]; }
remove_vip() { _sd_vip="released"; }
log_warn()   { _sd_log+="$* "; }
log_error()  { _sd_log+="$* "; }

DHCP_HA=true; _sd_dhcp="true"; _sd_vip="held"; _sd_log=""
stand_down "HA disabled"
assert_eq "stand down releases DHCP"    "false"    "$_sd_dhcp"
assert_eq "stand down releases the VIP" "released" "$_sd_vip"
assert_contains "the release is logged with its reason" "$_sd_log" "released=dhcp,vip"

# The regression: the VIP release used to sit inside the "DHCP is on" branch, so
# a node holding the VIP with DHCP already off kept it for good.
DHCP_HA=true; _sd_dhcp="false"; _sd_vip="held"; _sd_log=""
stand_down "STANDBY_ONLY"
assert_eq "VIP released even when DHCP is already off" "released" "$_sd_vip"
assert_contains "the VIP-only release is logged" "$_sd_log" "released=vip"

# DNS-only: another server owns DHCP, so standing down must not touch it.
DHCP_HA=false; _sd_dhcp="true"; _sd_vip="held"; _sd_log=""
stand_down "HA disabled"
assert_eq "DNS-only stand down leaves DHCP alone"      "true"     "$_sd_dhcp"
assert_eq "DNS-only stand down still releases the VIP" "released" "$_sd_vip"

# Steady state: holding nothing is silent, so this cannot fill the log every cycle.
DHCP_HA=true; _sd_dhcp="false"; _sd_vip="none"; _sd_log=""
stand_down "STANDBY_ONLY"
assert_eq "holding nothing releases nothing, quietly" "" "$_sd_log"

# A node that cannot release must keep reporting rather than die mid-loop.
remove_vip() { return 1; }
DHCP_HA=true; _sd_dhcp="false"; _sd_vip="held"; _sd_log=""
assert_true     "a failed release is not fatal" stand_down "STANDBY_ONLY"
assert_contains "a failed release is logged"    "$_sd_log" "stand_down_failed"

# ------------------------------------------------------------
# Every branch that means "not participating" must stand down, not merely return.
# Structural, because these live in the main loop and cannot be run here — but
# the bug was precisely that some of them returned on their own.
_ha_loop="$(cat "$HA_SRC")"; _ha_loop="${_ha_loop##*--- Main Loop ---}"
assert_contains "HA_ENABLED=false stands down" "$_ha_loop" 'stand_down "HA disabled"'
assert_contains "STANDBY_ONLY stands down"     "$_ha_loop" 'stand_down "STANDBY_ONLY"'
assert_contains "DNS-only stands down when HA is off" \
    "$(extract_fn "$HA_SRC" dns_only_vip_cycle)" 'stand_down "HA disabled"'

# STANDBY_ONLY is the operator's brake, so it has to be read before any branch
# that returns early: while it sat below them, a DNS-only node never reached it
# at all, and a standalone or FTL-down node kept whatever it was holding.
_before_dns_only="${_ha_loop%%if [[ \"\$DHCP_HA\" != \"true\" ]]*}"
assert_contains "STANDBY_ONLY is checked before the DNS-only branch" \
    "$_before_dns_only" 'stand_down "STANDBY_ONLY"'
# Split on the standalone branch's own status line: `NODE_COUNT == 1` also appears
# in the startup notification above the loop, which would cut in the wrong place.
_before_standalone="${_ha_loop%%write_status \"Standalone*}"
assert_contains "STANDBY_ONLY is checked before the standalone branch" \
    "$_before_standalone" 'stand_down "STANDBY_ONLY"'

# ============================================================
echo
echo "=== A node that could not register comes up passive ==="

# The installer printed the failure and then enabled the daemon anyway, with a
# full HA_NODES list the cluster knew nothing about. Whatever blocked the join is
# the same condition that makes this node's health checks read its peers as down,
# so it promoted itself and fought a healthy primary for the VIP.
_join_fail="$(cat "$SCRIPT_DIR/../install.sh")"
_join_fail="${_join_fail##*Could not register with any existing nodes}"
_join_fail="${_join_fail%%--- 24. Inject HA page*}"
assert_contains "a failed join sets STANDBY_ONLY=true" "$_join_fail" "STANDBY_ONLY=true"
assert_contains "an existing STANDBY_ONLY line is overwritten, not duplicated" \
    "$_join_fail" 's/^STANDBY_ONLY=.*/STANDBY_ONLY=true/'
assert_contains "the operator is told how to lift it" "$_join_fail" "STANDBY_ONLY=false"

# ============================================================
echo
echo "=== A scanned node is identified by its own address, not by its VIP ==="

# A node answers on its own address and on the VIP it holds, reporting the same
# "ip" both times, so whichever address the scan reads first names the other one.
# Numeric order let .200 win and .201 was announced as the VIP of itself.
_inst_src="$(cat "$SCRIPT_DIR/../install.sh")"
if [[ "$_inst_src" != *$'\n_scan_order=()'* ]]; then
    # Slicing below would otherwise eval the whole installer. Fail loudly instead.
    assert_eq "install.sh still builds a scan order" "present" "missing"
else
    _order_code="_scan_order=()${_inst_src#*$'\n'_scan_order=()}"
    _order_code="${_order_code%%for _i in *}"
    # .200 is the VIP, held by .201, which also answers for itself. .205 is a
    # plain node. The two that identify themselves must be taken first.
    _scan_probe=("192.168.111.200" "192.168.111.201" "192.168.111.205")
    _scan_real=("192.168.111.201" "192.168.111.201" "192.168.111.205")
    eval "$_order_code"
    assert_eq "addresses that identify themselves are read first" \
        "1 2 0" "${_scan_order[*]}"

    # No VIP in play: order is untouched, so a normal scan reads in numeric order.
    _scan_probe=("192.168.111.3" "192.168.111.5")
    _scan_real=("192.168.111.3" "192.168.111.5")
    eval "$_order_code"
    assert_eq "a scan without a VIP keeps numeric order" "0 1" "${_scan_order[*]}"

    # An unreachable node whose VIP still answers: the alias is all there is, and
    # it must still be reported rather than dropped.
    _scan_probe=("192.168.111.200")
    _scan_real=("192.168.111.201")
    eval "$_order_code"
    assert_eq "a lone alias is still scanned" "0" "${_scan_order[*]}"
fi
assert_contains "the skipped address is named as the VIP, not as the node" \
    "$_inst_src" "VIP held by %s, skipped"

# ============================================================
echo
echo "=== A failed join says why, per peer ==="

# "Could not register with any existing nodes" was the entire report, because
# curl -sf hides the body on an HTTP error and collapses a refused connection, a
# timeout and a 500 into one non-zero exit.
eval "$(extract_fn "$SCRIPT_DIR/../install.sh" _join_call)"
eval "$(extract_fn "$SCRIPT_DIR/../install.sh" _join_reason)"

# A stub curl standing in for the real one: prints a body, then the status code
# on its own line, exactly as -w '\n%{http_code}' does.
_fake_code="200" _fake_body='{"ok":true}'
curl() { printf '%s\n%s' "$_fake_body" "$_fake_code"; }

_fake_code="200" _fake_body='{"ok":true}'
assert_true "a 200 is a successful call"      _join_call "http://peer:8887/api/nodes/join"
_join_call http://x
assert_eq   "the body lands in a variable, without the code" '{"ok":true}' "$_JOIN_BODY"
_fake_code="500" _fake_body='oops'
assert_false "a 500 is not a successful call"  _join_call "http://peer:8887/api/nodes/join"
_join_call http://x
assert_eq   "the status code is kept for the reason" "500" "$_JOIN_CODE"

# The results must come back in variables, not on stdout. Written the other way
# first: the installer captured the body with $(...), so the code was set in a
# subshell, never reached _join_reason, and every failure came out as the default
# case. Nothing above catches that — only the call site does.
_inst_join="$(cat "$SCRIPT_DIR/../install.sh")"
assert_not_contains "the installer does not call _join_call in a subshell" \
    "$_inst_join" '$(_join_call'
assert_contains "the installer reads the body from the variable" \
    "$_inst_join" '_join_resp="$_JOIN_BODY"'

# curl that cannot connect: no body, code 000.
_fake_code="000" _fake_body=""
_join_call http://x
assert_contains "an unreachable peer is named as unreachable, not as a bad password" \
    "$(_join_reason)" "port 8887"
assert_contains "and points at what actually blocks it" \
    "$(_join_reason)" "firewall"

_JOIN_CODE="500"
assert_contains "an HTTP error reports its code" "$(_join_reason 'Internal Error')" "HTTP 500"
assert_contains "an HTTP error reports what the peer said" \
    "$(_join_reason 'Internal Error')" "Internal Error"

_JOIN_CODE="401"
assert_contains "a refusal after login is named as one" "$(_join_reason '')" "refused the join"

_JOIN_CODE="200"
assert_contains "a 200 that is not a join is distinguished from one that is" \
    "$(_join_reason '{"ok":false,"error":"unknown node"}')" "without confirming"
assert_contains "and quotes the reply" \
    "$(_join_reason '{"ok":false,"error":"unknown node"}')" "unknown node"
assert_contains "an empty 200 still says something" "$(_join_reason '')" "empty reply"

# A peer that answers with an HTML error page must not bury the installer output.
_JOIN_CODE="502"
_long_reason="$(_join_reason "$(printf '<html>\n<body>\n%s\n</body>' "$(printf 'x%.0s' {1..400})")")"
assert_not_contains "a multi-line body is flattened to one line" "$_long_reason" $'\n'
assert_true "a long body is trimmed" [ "${#_long_reason}" -lt 200 ]
unset -f curl

# The reasons have to reach the operator, in both the total and partial failure
# branches — collecting them and printing nothing is the bug over again.
_reg_block="$(cat "$SCRIPT_DIR/../install.sh")"
_reg_block="${_reg_block##*--- 22. Register this node}"
assert_eq "both join outcomes print their reasons" "2" \
    "$(grep -c 'for _jw in' <<< "$_reg_block")"

# ============================================================
echo "=== sync.conf is parsed, never sourced ==="

# sync.conf travels inside the config-sync payload: pihole-ha-sync ships it and
# pihole-ha-sync-pull writes it verbatim. It was then `.`-sourced in nine places
# as root, so a peer that published a payload executed shell on every node.
PLATFORM_SRC="$SCRIPT_DIR/../pihole-ha-platform"
eval "$(extract_fn "$PLATFORM_SRC" is_valid_ip)"
eval "$(extract_fn "$PLATFORM_SRC" load_sync_conf)"

assert_eq "no script sources sync.conf any more" "" \
    "$(grep -rln '\. "\$SYNC_CONF"' "$SCRIPT_DIR/.." --include='pihole-ha*' --include='*.sh' 2>/dev/null)"

_sc="$(mktemp)"
_PWNED=""
cat > "$_sc" <<'CONF'
SYNC_ENABLED=true
_PWNED=$(id -u)
SYNC_GRAVITY=false
CONF
SYNC_ENABLED=false SYNC_GRAVITY=true
load_sync_conf "$_sc"
assert_eq "a command substitution is not executed" "" "$_PWNED"
assert_eq "whitelisted keys before it still load"  "true"  "$SYNC_ENABLED"
assert_eq "whitelisted keys after it still load"   "false" "$SYNC_GRAVITY"

# An unknown key must not become a variable at all — that is how HA_ENABLED or
# SYNC_BLOB_DIR would be smuggled in from a peer's payload.
printf 'HA_ENABLED=false\nSYNC_BLOB_DIR=/tmp/evil\n' > "$_sc"
HA_ENABLED=true SYNC_BLOB_DIR=/var/lib/pihole-ha
load_sync_conf "$_sc"
assert_eq "an unlisted key is ignored"          "true" "$HA_ENABLED"
assert_eq "the blob dir cannot arrive by sync"  "/var/lib/pihole-ha" "$SYNC_BLOB_DIR"

# Values are shape-checked, and a rejected value leaves the caller's default.
printf 'SYNC_PRIMARY=10.33.47.3\nSYNC_INTERVAL=30\n' > "$_sc"
SYNC_PRIMARY="10.33.47.55" SYNC_INTERVAL=15
load_sync_conf "$_sc"
assert_eq "a valid primary is taken"   "10.33.47.3" "$SYNC_PRIMARY"
assert_eq "a valid interval is taken"  "30"         "$SYNC_INTERVAL"

printf 'SYNC_PRIMARY=10.33.47.3;id\nSYNC_INTERVAL=0\nSYNC_ENABLED=yes\n' > "$_sc"
SYNC_PRIMARY="10.33.47.55" SYNC_INTERVAL=15 SYNC_ENABLED=true
load_sync_conf "$_sc"
assert_eq "a non-IP primary is refused"        "10.33.47.55" "$SYNC_PRIMARY"
assert_eq "an out-of-range interval is refused" "15"         "$SYNC_INTERVAL"
assert_eq "a non-boolean toggle is refused"     "true"       "$SYNC_ENABLED"

# An accepted interval is stored base-10. "08" is in range, so it is kept — and
# would then abort the first plain (( x * 60 )) downstream as invalid octal,
# which is exactly how the sync timer gets its interval.
printf 'SYNC_INTERVAL=08\n' > "$_sc"
SYNC_INTERVAL=15
load_sync_conf "$_sc"
assert_eq "a zero-padded interval is normalised" "8" "$SYNC_INTERVAL"
assert_true "and survives arithmetic" [ "$(( SYNC_INTERVAL * 60 ))" -eq 480 ]

# An absent key must leave the caller's default alone: every call site sets its
# own defaults first and relies on that.
: > "$_sc"
SYNC_ENABLED=false
load_sync_conf "$_sc"
assert_eq "an absent key keeps the caller's default" "false" "$SYNC_ENABLED"

printf 'SYNC_INTERVAL=45' > "$_sc"   # deliberately no trailing newline
SYNC_INTERVAL=15
load_sync_conf "$_sc"
assert_eq "a final line without a newline is not dropped" "45" "$SYNC_INTERVAL"
rm -f "$_sc"

# ============================================================
echo
echo "=== An unreachable Pi-hole must not read as 'no password set' ==="

# _check_auth collapsed "no password" and "could not ask" into one boolean, so a
# slow or restarting FTL opened every mutating endpoint. sync-pull restarts FTL
# on every config apply, so the window recurred on a timer.
eval "$(extract_fn "$DASH_SRC" _check_auth)"
_AUTH_FAIL_WHY="" _AUTH_CHECKED="" _AUTH_REQUIRED=""
_validate_sid() { return 0; }

_pihole_has_auth() { return 2; }   # cannot tell
assert_false "a write is refused when Pi-hole cannot be reached" _check_auth "sid=whatever"
assert_contains "the refusal says why" "$_AUTH_FAIL_WHY" "refusing the write"

# "cannot tell" must not be cached — the next request has to ask again.
_AUTH_CHECKED="" _AUTH_REQUIRED=""
_check_auth "sid=x" >/dev/null 2>&1
assert_eq "an unknown answer is not cached" "" "$_AUTH_CHECKED"

_AUTH_CHECKED="" _AUTH_REQUIRED=""
_pihole_has_auth() { return 1; }   # genuinely no password set
assert_true "a genuinely passwordless node still allows writes" _check_auth ""

_AUTH_CHECKED="" _AUTH_REQUIRED=""
_pihole_has_auth() { return 0; }   # password set
assert_true "a password-protected node still validates the sid" _check_auth "sid=good"

# ============================================================
echo
echo "=== A node that cannot answer DNS never asserts DHCP ==="

# should_i_hold_vip has always required local DNS health; should_i_serve did
# not, so a primary whose FTL was up but not serving kept DHCP and the VIP while
# a secondary took them too, and neither side ever yielded.
NODES=("10.33.47.55" "10.33.47.3")
peer_ping["10.33.47.55"]="true"; peer_dns["10.33.47.55"]="true"
peer_api["10.33.47.55"]="true";  peer_dhcp["10.33.47.55"]="true"

DHCP_MASTER="auto"; LOCAL_IP="10.33.47.55"; MY_IDX=0
peer_dns["10.33.47.55"]="false"
assert_false "index 0 stands down when its own DNS is dead" should_i_serve

DHCP_MASTER="10.33.47.55"
assert_false "a pinned master stands down when its own DNS is dead" should_i_serve

peer_dns["10.33.47.55"]="true"
DHCP_MASTER="auto"
assert_true  "index 0 serves again once its DNS recovers" should_i_serve

# The guard must not abort the daemon for a node missing from the peer maps.
LOCAL_IP="10.33.47.99"; MY_IDX=0
assert_true  "an unknown local ip does not abort under set -u" no_unbound_error should_i_serve
assert_false "an unknown local ip does not serve"              should_i_serve

# ============================================================
echo
echo "=== Cluster key helper ==="

KEY_SRC="$SCRIPT_DIR/../pihole-ha-cluster-key"
eval "$(extract_fn "$KEY_SRC" _peers)"

_keyconf="$(mktemp -d)"
NODES_CONF="$_keyconf/nodes.conf"
printf 'HA_NODES=10.33.47.55,10.33.47.3:8081,10.33.47.5\n' > "$NODES_CONF"
_local_ip() { echo "10.33.47.3"; }

_peerlist="$(_peers | tr '\n' ' ')"
assert_contains     "peers include the other nodes"   "$_peerlist" "10.33.47.55"
assert_contains     "peers include the third node"    "$_peerlist" "10.33.47.5"
assert_not_contains "peers exclude this node"         "$_peerlist" "10.33.47.3 "
assert_not_contains "the web port is stripped for ssh" "$_peerlist" "8081"

# A node not listed in HA_NODES must still see every peer, not silently none.
_local_ip() { echo "10.33.47.99"; }
assert_eq "an unlisted node still lists all peers" "3" "$(_peers | wc -l)"

: > "$NODES_CONF"
assert_eq "no nodes.conf entries yields no peers" "0" "$(_peers | wc -l)"
rm -rf "$_keyconf"

# The key must never reach argv — /proc/<pid>/cmdline is world-readable, which is
# the same mistake install.sh makes with the Pi-hole password.
_keysrc_body="$(cat "$KEY_SRC")"
assert_not_contains "the key is not interpolated into an ssh command" \
    "$_keysrc_body" 'ssh -o ConnectTimeout=10 "$dest" "umask 077; cat > ~/$REMOTE_TMP" "$(cat'
assert_contains "the key is piped to ssh on stdin instead" \
    "$_keysrc_body" 'cat > ~/$REMOTE_TMP" < "$KEY_FILE"'
assert_contains "the key is created under a restrictive umask" \
    "$_keysrc_body" 'umask 077; openssl rand -hex 32'

# /etc/pihole-ha may legitimately be 0750 root:pihole so the DHCP hook can read
# notify.conf. The remote step must not clamp it the way install.sh does.
assert_contains     "the remote step creates the dir without re-moding it" "$_keysrc_body" "sudo mkdir -p '\$CONF_DIR'"
# Comments are stripped: the script explains in prose why it avoids this, and
# the prose must not be what satisfies the assertion.
_keysrc_code="$(grep -vE '^[[:space:]]*#' "$KEY_SRC")"
assert_not_contains "the remote step does not clamp the config dir"        "$_keysrc_code" "install -d -m 700"

# It has to be installed, or `pihole-ha cluster-key` is a dead subcommand.
_inst="$(cat "$SCRIPT_DIR/../install.sh")"
assert_contains "the installer installs it"      "$_inst" "pihole-ha-debug pihole-ha-cluster-key"
assert_contains "the uninstaller removes it"     "$_inst" "/usr/local/bin/pihole-ha-cluster-key"
assert_contains "the docker image ships it"      "$(cat "$SCRIPT_DIR/../docker/Dockerfile")" "COPY pihole-ha-cluster-key"
assert_contains "the CLI exposes it"             "$(cat "$SCRIPT_DIR/../pihole-ha-cli")" "cluster-key|key)"

# ============================================================
echo
echo "=== Updates follow the repo that was installed ==="

# pihole-ha-cli used to hardcode the upstream repo, so `pihole-ha update` on a
# fork fetched upstream and overwrote the fork's own changes.
eval "$(extract_fn "$SCRIPT_DIR/../pihole-ha-platform" platform_repo_info)"

_rt="$(mktemp -d)"
_mkrepo() {   # $1 = remote url, $2 = branch
    rm -rf "$_rt/r"; git init -q "$_rt/r" 2>/dev/null
    git -C "$_rt/r" config remote.origin.url "$1"
    git -C "$_rt/r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null
    git -C "$_rt/r" branch -M "${2:-main}" 2>/dev/null
}
_field() { sed -n "s/^$1=//p" <<< "$2"; }

if command -v git >/dev/null 2>&1; then
    _mkrepo "git@github.com:Eriobis/pihole-ha-cluster.git" main
    _info="$(platform_repo_info "$_rt/r")"
    assert_eq "an ssh remote is rewritten to https" \
        "https://github.com/Eriobis/pihole-ha-cluster.git" "$(_field REPO_URL "$_info")"
    assert_eq "the fork's slug is recorded" "Eriobis/pihole-ha-cluster" "$(_field REPO_SLUG "$_info")"

    _mkrepo "https://github.com/Eriobis/pihole-ha-cluster.git" feature-x
    _info="$(platform_repo_info "$_rt/r")"
    assert_eq "the installed branch is recorded, not assumed main" \
        "feature-x" "$(_field REPO_BRANCH "$_info")"

    _mkrepo "ssh://git@gitlab.com/team/ha.git" main
    assert_eq "a non-github host still resolves" "gitlab.com" \
        "$(_field REPO_HOST "$(platform_repo_info "$_rt/r")")"

    # Anything we cannot turn into a fetch URL must yield nothing, so the caller
    # keeps its upstream default rather than writing a broken repo.conf.
    _mkrepo "/srv/local/bare.git" main
    assert_eq "a local path yields nothing" "" "$(platform_repo_info "$_rt/r" 2>/dev/null)"
    _mkrepo 'https://github.com/evil$(id)/repo.git' main
    assert_eq "a remote with shell metacharacters is refused" "" "$(platform_repo_info "$_rt/r" 2>/dev/null)"
else
    echo "  SKIP  git not available"
fi

# The CLI must derive its fetch URLs from repo.conf, and degrade sanely.
CLI_SRC="$SCRIPT_DIR/../pihole-ha-cli"
_cliurls() {   # $1 = repo.conf path -> "TARBALL|RAW|SLUG|BRANCH"
    PIHOLE_HA_REPO_CONF="$1" bash -c '
        PIHOLE_HA_REPO_CONF="'"$1"'"
        source "'"$CLI_SRC"'" help >/dev/null 2>&1
        printf "%s|%s|%s|%s" "$REPO_TARBALL" "$RAW_VERSION_URL" "$REPO_SLUG" "$REPO_BRANCH"' 2>/dev/null
}

printf 'REPO_URL=https://github.com/Eriobis/pihole-ha-cluster.git\nREPO_HOST=github.com\nREPO_SLUG=Eriobis/pihole-ha-cluster\nREPO_BRANCH=feature-x\n' > "$_rt/gh.conf"
_u="$(_cliurls "$_rt/gh.conf")"
assert_contains "the tarball points at the fork"        "$_u" "github.com/Eriobis/pihole-ha-cluster/archive"
assert_contains "the tarball uses the installed branch" "$_u" "feature-x.tar.gz"
assert_contains "the version check follows the fork"    "$_u" "raw.githubusercontent.com/Eriobis/pihole-ha-cluster/feature-x/VERSION"
assert_not_contains "upstream is not consulted"         "$_u" "RamSet"

printf 'REPO_URL=https://gitlab.com/team/ha.git\nREPO_HOST=gitlab.com\nREPO_SLUG=team/ha\nREPO_BRANCH=main\n' > "$_rt/gl.conf"
_u="$(_cliurls "$_rt/gl.conf")"
assert_contains "a non-github host still gets a tarball url" "$_u" "gitlab.com/team/ha/archive"
assert_contains "the github-only version check is disabled"  "$_u" "|main"
assert_not_contains "no raw.githubusercontent url is invented" "$_u" "raw.githubusercontent"

_u="$(_cliurls "$_rt/absent.conf")"
assert_contains "without repo.conf it falls back to upstream" "$_u" "RamSet/pihole-ha-cluster"
rm -rf "$_rt"

# All three writers/readers have to agree, or the fork is followed only by half
# the tooling.
_inst="$(cat "$SCRIPT_DIR/../install.sh")"
assert_contains "the installer records it on a fresh install" "$_inst" '_write_repo_conf "$SCRIPT_DIR"'
assert_contains "the installer records it on update"          "$_inst" '_write_repo_conf "$_src"'
assert_contains "setup.sh exports the detected repo"          "$(cat "$SCRIPT_DIR/../setup.sh")" "PIHOLE_HA_REPO_SLUG"
assert_contains "the dashboard update check follows it too"   "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" "REPO_SLUG=//p"

# ============================================================

all_ok=true
for script in pihole-ha pihole-ha-dash pihole-ha-sync pihole-ha-sync-pull install.sh pihole-ha-cluster-key pihole-ha-cli; do
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
