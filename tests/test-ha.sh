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

# ------------------------------------------------------------
# ...and when the :8887 API is the thing that failed, say THAT, instead of
# leaving the controls looking like they are still loading.
#
# ha-api proxies :8887 for every action except the status file, so one dead API
# kills every control at once. Reported from a three-node cluster on v3.19.29:
# the HA failover toggle and the VIP toggle did nothing at all, the DHCP master
# override said "set-master failed", the sync toggles said "toggle failed", and
# Cluster Members / Failover Priority sat on "Loading..." forever -- five
# symptoms, one cause, and nothing on the page naming it.
_lp="$(cat "$SCRIPT_DIR/../ha-api.lp")"

# curl already knows which failure it was. Each of these is a different thing
# for the operator to go and do, so each has to survive to the page.
assert_contains "a refused connection names both deployments' causes" "$_lp" "cannot connect to the pihole-ha API on"
assert_contains "and tells a Docker user what to fix"                 "$_lp" "network_mode: service:pihole"
assert_contains "a timeout is reported as a timeout"                  "$_lp" "did not answer within"
assert_contains "a missing curl names where FTL runs, not a container" "$_lp" "curl is not installed where pihole-FTL runs"
assert_contains "an empty reply is not reported as a refusal"         "$_lp" "answered with nothing"
assert_contains "and an unmapped curl exit carries its number"        "$_lp" "curl exit "

# The reason is useless if the call sites throw it away: every proxied action
# must pass it on. Verified against the real interpreter (Lua 5.5, pihole-FTL
# lua) with a real curl: refused -> exit 7 message, PATH without curl -> 127
# message, a served 200 -> the body alone with no sentinel left in it.
_curl_sites="$(grep -c 'curl_local(' "$SCRIPT_DIR/../ha-api.lp")"
_err_sites="$(grep -c 'content or err or' "$SCRIPT_DIR/../ha-api.lp")"
assert_true "every proxied action carries the reason to the page" \
    [ "$_err_sites" -ge 20 ]
assert_eq "no action swallows it" "" \
    "$(grep -n "mg.write(content or '" "$SCRIPT_DIR/../ha-api.lp")"
assert_contains "the exit status is carried back in the stream"  "$_lp" "ha-exit:%s"
assert_contains "and stripped off before the body is returned"   "$_lp" 'result:gsub("\n?%-%-ha%-exit:%d+%s*$", "")'
assert_contains "the manifest fetch from the primary reports too" "$_lp" 'curl_fetch("http://" .. primary'

# ------------------------------------------------------------
# A failed spawn is not a missing curl.
#
# io.popen returns nil plus "<command>: <strerror>" when pihole-FTL cannot fork
# or open a pipe. That reason was thrown away and every such failure was printed
# as "the panel could not run curl inside the Pi-hole container" -- which three
# bare-metal nodes on the forum then saw, flickering across the page, while curl
# was installed and the API was answering normally. Verified against the real
# interpreter (pihole-FTL lua, v6.7) by holding 1021 fds: io.popen returns nil,
# the reason extracts as "No file descriptors available", and a retry once the
# fds are free succeeds.
assert_eq "no failure is reported as an unrunnable curl" "" \
    "$(grep -n "could not run curl" "$SCRIPT_DIR/../ha-api.lp")"
assert_contains "a refused spawn is named as one"        "$_lp" "could not start curl to reach the pihole-ha API"
assert_contains "and does not blame the API for it"      "$_lp" "The API itself may be fine"
assert_contains "the C library's reason is kept"         "$_lp" "local handle, perr = io.popen(cmd)"
assert_contains "and reported"                           "$_lp" "json_error(spawn_reason(perr))"
assert_contains "a momentary refusal is retried once"    "$_lp" "handle, perr = io.popen(cmd)"
assert_eq "the retry is the only second spawn" "2" "$(grep -cE 'io\.popen\(' "$SCRIPT_DIR/../ha-api.lp")"
# Both callers share the one spawn path, so a fix here cannot miss one.
for _fn in curl_local curl_primary_manifest; do
    _blk="$(sed -n "/^local function $_fn/,/^end/p" "$SCRIPT_DIR/../ha-api.lp")"
    assert_contains "$_fn goes through the shared fetch" "$_blk" "curl_fetch("
    assert_not_contains "$_fn does not spawn on its own" "$_blk" "io.popen"
done

# The command string carries the caller's session id, and these messages get
# pasted into forum posts. Only a short, quote-free strerror tail is shown.
_spawn="$(sed -n '/^local function spawn_errtext/,/^end/p' "$SCRIPT_DIR/../ha-api.lp")"
assert_contains "only the reason after the last colon is taken" "$_spawn" 'err:match(":%s*([^:]+)%s*$")'
assert_contains "a session id is never printed"                 "$_spawn" 'tail:find("sid=")'
assert_contains "nor the URL it was in"                         "$_spawn" 'tail:find("http")'
assert_contains "nor anything that could break out of the JSON" "$_spawn" '<>'
assert_contains "and the length is bounded"                     "$_spawn" "#tail > 80"
assert_contains "an unparseable reason degrades to no reason"    "$_spawn" "return nil"

# ------------------------------------------------------------
# The API is not always on this page's loopback.
#
# This page runs inside pihole-FTL; the API runs in the pihole-ha sidecar. With
# the shipped compose (both on the host network) one loopback serves both -- but
# a Pi-hole container on a bridge network has a loopback of its own with nothing
# on it, so every control fails with "cannot connect" while curl on the host
# answers fine. Reported from a three-node bridge-networked cluster that had
# just upgraded, and reproduced in a bridge container: 127.0.0.1:8887 gives curl
# exit 7 while the host's own LAN address serves the same request. What the two
# always share is /run/pihole-ha, and the sidecar's status file there names an
# address that does work. Verified in the live interpreter (pihole-FTL lua on a
# node): loopback refused -> the body comes back from the node IP; both refused
# -> the message below; loopback answering -> no second request at all.
_cl="$(sed -n '/^local function curl_local/,/^end/p' "$SCRIPT_DIR/../ha-api.lp")"
assert_contains "loopback is still tried first"                   "$_cl" 'curl_fetch("http://127.0.0.1:8887" .. endpoint'
assert_contains "a working loopback returns before any fallback"  "$_cl" "if body then return body end"
assert_contains "only a refused connection is retried elsewhere"  "$_cl" 'if code ~= "7" then return nil, err end'
assert_contains "the second address comes from the status file"   "$_cl" "local host = node_api_host()"
assert_contains "and nothing is retried without one"              "$_cl" "if not host then return nil, err end"
assert_contains "the retry goes to this node's own API"           "$_cl" 'curl_fetch("http://" .. host .. ":8887" .. endpoint'
# That gate can only fire if the exit status survives the fetch.
assert_contains "the fetch hands its exit status back"            "$_lp" 'curl_reason(code or "?", where, timeout)), code'
# Two refusals are not a namespace split, so the message must not send the
# operator back to a compose file that is already right.
_un="$(sed -n '/^local function unreachable_reason/,/^end/p' "$SCRIPT_DIR/../ha-api.lp")"
assert_contains "both addresses are named when both refuse"       "$_un" '127.0.0.1:8887 or '
assert_contains "a package install is told what to check"         "$_un" "systemctl status pihole-ha-dash"
assert_contains "a Docker install too"                            "$_un" "sidecar container is running"
assert_not_contains "and neither is blamed on the network mode"   "$_un" "network_mode"
# The address lands in a shell'd curl URL, so the pattern has to be the guard.
_nh="$(sed -n '/^local function node_api_host/,/^end/p' "$SCRIPT_DIR/../ha-api.lp")"
assert_contains "the node address is read from the status file"   "$_nh" '/run/pihole-ha/status.json'
assert_contains "and taken from this node's own entry, not a peer's" "$_nh" '"node"%s*:%s*{(.-)}'
assert_contains "nothing but an IPv4 address is accepted"         "$_nh" '"(%d+%.%d+%.%d+%.%d+)"'
assert_contains "and loopback there means no fallback at all"     "$_nh" 'ip == "127.0.0.1"'
# Class guard: one place builds a loopback URL, so every proxied action gets the
# fallback and none can grow its own.
assert_eq "no action reaches loopback on its own" "1" \
    "$(grep -c 'http://127' "$SCRIPT_DIR/../ha-api.lp")"

# Every panel that reads its state from :8887 has to show the reason when that
# read fails -- the five that were dead on G241's cluster, by name.
for _v in sync:renderSync master:renderMaster prio:renderPriority vip:renderVip ha:renderHa; do
    _var="${_v%%:*}Err"; _ren="${_v##*:}"
    assert_eq "$_var is set on both failure paths" "2" \
        "$(grep -cE "$_var = .*apiReason" "$SCRIPT_DIR/../ha.js")"
    # The renderer's early return is what used to leave "Loading..." in place.
    _block="$(sed -n "/function $_ren()/,/^    }/p" "$SCRIPT_DIR/../ha.js")"
    assert_contains "$_ren shows the reason instead of a pending read" \
        "$_block" "showPanelError"
done

# A toggle that cannot act must not look like one that did nothing.
assert_contains "the VIP toggle reports why it failed"      "$_js" 'showPanelError($("#vip-result"), apiReason(data))'
assert_contains "the HA toggle reports why it failed"       "$_js" 'showPanelError($("#ha-result"), apiReason(data))'
assert_contains "and both have somewhere to report it"      "$(cat "$SCRIPT_DIR/../ha.lp")" 'id="vip-result"'
assert_contains "the HA panel too"                          "$(cat "$SCRIPT_DIR/../ha.lp")" 'id="ha-result"'
# The reason is attacker-adjacent text from a config file; it goes through the
# escaper like everything else the panel prints.
assert_contains "the reason is HTML-escaped"                "$_js" "escapeHtml(reason"
# These spans also hold the result of a click ("Saved", "Sync started"), so a
# poll clears only its own message and leaves that alone.
assert_contains "a recovered panel clears only its own error" "$_js" 'clearPanelError($("#master-result"))'
assert_contains "and a click result is not eaten by a poll"   "$_js" '$el.find(".ha-api-error").remove()'

# Timestamps. The clock follows the viewer's locale, with a per-browser
# override: a browser reports a region, not a clock preference -- an en-US
# locale prints "3:50:16 PM" however the desktop clock is set, and Chrome does
# not read the OS 12/24-hour switch -- so the locale alone gives a viewer who
# wants 24-hour on a failover page no way to ask for it. Asked for on the forum.
_fmt="$(sed -n '/function fmtTime/,/^    }/p' "$SCRIPT_DIR/../ha.js")"
assert_contains "the clock follows the locale by default"   "$_fmt" "return d.toLocaleString();"
assert_contains "24-hour can be pinned"                     "$_fmt" 'pref === "24") return d.toLocaleString(undefined, { hour12: false })'
assert_contains "12-hour can be pinned"                     "$_fmt" 'pref === "12") return d.toLocaleString(undefined, { hour12: true })'
assert_contains "and every timestamp reads the choice"      "$_fmt" "clockPref()"
assert_contains "the choice survives a reload"              "$_js" "localStorage.setItem(CLOCK_KEY"
# localStorage throws in a private window and can be blocked outright; a clock
# that disappears there would be a worse bug than the one being fixed.
_pref="$(sed -n '/function clockPref/,/^    }/p' "$SCRIPT_DIR/../ha.js")"
assert_contains "blocked storage falls back to the locale"  "$_pref" 'return "auto";'
assert_contains "a read is guarded"                         "$_pref" "catch (e)"
assert_contains "and only the two pins are honored"         "$_pref" 'if (v === "12" || v === "24") return v;'
assert_contains "a blocked write is not fatal either"       "$(sed -n '/function setClockPref/,/^    }/p' "$SCRIPT_DIR/../ha.js")" "catch (e)"
# A preference with nothing to set it with is not a preference.
_lp_clock="$(cat "$SCRIPT_DIR/../ha.lp")"
assert_contains "the panel offers the control"              "$_lp_clock" 'id="ha-clock-fmt"'
for _o in auto 24 12; do
    assert_contains "clock option $_o is offered"           "$_lp_clock" "<option value=\"$_o\">"
done
assert_contains "the control opens on the current choice"   "$_js" '$("#ha-clock-fmt").val(clockPref())'
# Status redraws every 5s and sync every 15s; waiting that long to see the
# format change looks like the control did nothing.
_clock_ch="$(sed -n '/on("change", "#ha-clock-fmt"/,/^    });/p' "$SCRIPT_DIR/../ha.js")"
assert_contains "a change is stored"                        "$_clock_ch" "setClockPref("
assert_contains "and redraws the status clock at once"      "$_clock_ch" "pollStatus();"
assert_contains "and the sync timestamps with it"           "$_clock_ch" "renderSync();"

echo
echo "=== The DHCP options we advertise must be ones dnsmasq will honour ==="
# ------------------------------------------------------------
# dhcp-option=54 (server identifier) must never be written.
#
# dnsmasq always sends its own server identifier, built from the address the
# DHCP context came from, and sends a configured one *as well* whenever the
# client asks for option 54 in its parameter request list. The client then gets
# two Server-IDs in one DHCPOFFER; one that takes the second (the VIP) echoes it
# in its DHCPREQUEST and dnsmasq answers "wrong server-ID" -- the VIP is not
# context->local, the escape hatch that would accept any local interface address
# needs tftp_ok (TFTP is off), and Pi-hole sets dhcp-authoritative, so the
# client is NAKed rather than ignored and loops. GitHub #10, reported for
# PlayStation consoles, which ask for option 54.
#
# Measured against a live DHCP master before the fix: a DISCOVER whose request
# list included 54 was answered with Server-IDs [node, VIP]; without it, [node].
assert_eq "no writer advertises a server identifier" "" \
    "$(grep -hnE '^[^#]*dhcp-option=54' "$SCRIPT_DIR/../pihole-ha" "$SCRIPT_DIR/../install.sh")"
assert_contains "the installer still advertises the VIP as DNS" \
    "$(cat "$SCRIPT_DIR/../install.sh")" 'dhcp-option=6,$vip'

eval "$(extract_fn "$HA_SRC" build_dns_option)"
VIP_ENABLED="true"; VIP="10.0.0.9"; NODES=(10.0.0.1 10.0.0.2)
assert_eq "VIP mode advertises the VIP as DNS and nothing else" \
    "dhcp-option=6,10.0.0.9" "$(build_dns_option)"
VIP_ENABLED="false"
assert_eq "without a VIP every node is advertised as DNS" \
    "dhcp-option=6,10.0.0.1,10.0.0.2" "$(build_dns_option)"
# A VIP that is configured but blank must not produce "dhcp-option=6," either.
VIP_ENABLED="true"; VIP=""
assert_eq "a blank VIP falls back to the node list" \
    "dhcp-option=6,10.0.0.1,10.0.0.2" "$(build_dns_option)"

# Every existing install carries the bad line in its drop-in. The daemon has to
# notice the file no longer matches what it wants and rewrite it, or the fix
# never reaches anyone who upgrades.
_dns_opt_fn="$(extract_fn "$HA_SRC" ensure_dns_option)"
assert_contains "a stale drop-in is rewritten on upgrade" "$_dns_opt_fn" '"$(cat "$DNSMASQ_HA")" == "$full"'
assert_contains "and FTL is restarted so clients see it"  "$_dns_opt_fn" "platform_ftl_restart"
assert_contains "but not on a DNS-only node"              "$_dns_opt_fn" '[[ "$DHCP_HA" != "true" ]] && return 0'
unset -f build_dns_option
unset VIP_ENABLED VIP NODES

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
# The container supervisor must not swallow the sync's output
# ------------------------------------------------------------
# On Docker the build and the pull were started with their output sent to
# /dev/null, so build_start, build_complete, "skip reason=no changes" and
# every error vanished. A user reported a change that never reached his
# standby and had nothing in the container log to show for it — and neither
# did I (Discourse 86667 #191). systemd users have had these lines all along.
_sup="$(cat "$SCRIPT_DIR/../docker/docker-entrypoint.sh")"
assert_not_contains "the build's output is not discarded" "$_sup" 'pihole-ha-sync &>/dev/null'
assert_not_contains "nor the pull's"                      "$_sup" 'pihole-ha-sync-pull &>/dev/null'
assert_contains "the build still runs in the background"  "$_sup" '/usr/local/bin/pihole-ha-sync &'
assert_contains "and so does the pull"                    "$_sup" '/usr/local/bin/pihole-ha-sync-pull &'
# A comment edit really does move the publisher's change hash — verified on a
# live node — so detection was never the problem here; the silence was.
assert_contains "the change hash covers the whole gravity database" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync" current_hash)" "md5sum /etc/pihole/gravity.db"

# ============================================================
# Telling FTL to reload has to actually reach it
# ------------------------------------------------------------
# On a live node `pgrep -x pihole-FTL` returns TWO pids. The Docker reload
# collected them into one string and passed that to kill, which rejects it, so
# the signal was never delivered -- while the caller logged "ftl=restarted".
# A standby swapped gravity.db underneath an FTL that kept serving the old one
# (it holds the file open), and the panel showed stale domain and list counts
# until the container was restarted by hand (Discourse 86667 #189). Confirmed
# against a live FTL: the old code returns failure and FTL's reload count does
# not move; the fixed one moves it.
_reload_probe() {   # $1 = pids pgrep reports, $2 = pids kill accepts
    local log; log="$(mktemp)"
    P_PIDS="$1" P_OK="$2" P_LOG="$log" bash -c '
        PIHOLE_HA_PLATFORM=docker
        pgrep() { [[ -n "$P_PIDS" ]] && printf "%s\n" $P_PIDS; }
        kill() {
            [[ "$1" == "-0" ]] && return 0
            local target="${*: -1}"
            echo "SIGNALLED $target" >> "$P_LOG"
            [[ " $P_OK " == *" $target "* ]]
        }
        sleep() { :; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-platform" platform_ftl_restart)"'
        platform_ftl_restart && echo RELOADED || echo FAILED
    '
    cat "$log" 2>/dev/null; rm -f "$log"
}
assert_contains "both FTL processes are signalled" "$(_reload_probe "1968043 1968051" "1968043 1968051")" "SIGNALLED 1968051"
assert_contains "and the first one too"            "$(_reload_probe "1968043 1968051" "1968043 1968051")" "SIGNALLED 1968043"
assert_contains "two pids is a success, not a failure" "$(_reload_probe "1968043 1968051" "1968043 1968051")" "RELOADED"
assert_contains "a single pid still works"         "$(_reload_probe "194" "194")" "RELOADED"
assert_contains "no FTL at all is a failure"       "$(_reload_probe "" "")" "FAILED"
# One of them going away between pgrep and kill is normal, not a failure.
assert_contains "one deliverable signal is enough" "$(_reload_probe "100 101" "101")" "RELOADED"
assert_contains "none deliverable is a failure"    "$(_reload_probe "100 101" "")" "FAILED"
# And a reload that did not happen must not be reported as success.
_pull_reload="$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")"
assert_contains "a failed reload is reported"      "$_pull_reload" "status=stale"
assert_contains "and says what the node is serving" "$_pull_reload" "still serving the previous one"
assert_contains "and the pull is marked failed so it retries" "$_pull_reload" 'APPLY_FAILED=true'

# ============================================================
# Two nodes serving DHCP must be said out loud
# ------------------------------------------------------------
# pihole-ha enables DHCP on one node and disables it on the rest, but a user
# who switched it on by hand in every Pi-hole got leases from all of them —
# clients with addresses and no working gateway, which is miserable to
# diagnose from the client end (Discourse 86667 #180).
_conflict_probe() {   # $1 = our dhcp state, $2.. = peers' states
    P_SELF="$1" P_A="${2:-false}" P_B="${3:-false}" bash -c '
        DHCP_HA=true; LOCAL_IP=10.0.0.1; ROLE=PRIMARY
        NODES=(10.0.0.1 10.0.0.2 10.0.0.3)
        declare -A peer_dhcp
        peer_dhcp[10.0.0.1]="$P_SELF"; peer_dhcp[10.0.0.2]="$P_A"; peer_dhcp[10.0.0.3]="$P_B"
        dhcp_conflict_warned=false
        log_warn() { echo "WARN $*"; }; notify() { :; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" warn_if_dhcp_conflict)"'
        warn_if_dhcp_conflict
        warn_if_dhcp_conflict      # second call: must not repeat
    '
}
assert_contains "two servers at once is reported"   "$(_conflict_probe true true)" "event=dhcp_conflict"
assert_contains "and the other node is named"       "$(_conflict_probe true true)" "10.0.0.2"
assert_contains "both others are named"             "$(_conflict_probe true true true)" "10.0.0.3"
assert_eq "it is said once, not every cycle" "1" \
    "$(_conflict_probe true true | grep -c 'event=dhcp_conflict')"
assert_eq "one server is normal and silent"  ""  "$(_conflict_probe true false false)"
assert_eq "a standby with none is silent"    ""  "$(_conflict_probe false true false)"
assert_contains "the tag is registered for muting" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" "dhcp_conflict"

# ============================================================
# Hand the VIP over when the heir can serve, and stop ARPing every cycle
# ------------------------------------------------------------
# Two things a reporter saw after the previous fixes (Discourse 86667 #178):
# a steady stream of "who-has <VIP>" from the standby, which was the orphan
# probe running every cycle; and the VIP dark for a minute after a switchover,
# because the standby released it to a node whose port 53 was open while FTL
# was still loading gravity.
# The cadence is a trade between ARP noise and how fast a stranded VIP is
# noticed, so it is a knob rather than a constant — and 0 turns the check off
# for anyone who would rather have silence.
_hasrc_probe="$(cat "$SCRIPT_DIR/../pihole-ha")"
assert_contains "the probe interval can be set in nodes.conf" "$_hasrc_probe" 'VIP_PROBE_EVERY:-10'
assert_contains "a junk value falls back to the default"      "$_hasrc_probe" 'VIP_PROBE_EVERY=10'
assert_contains "zero disables the probe entirely" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha" dns_only_vip_cycle)" '(( VIP_PROBE_EVERY > 0 ))'
assert_contains "and it is documented" \
    "$(cat "$SCRIPT_DIR/../README.md")" "VIP_PROBE_EVERY"

assert_contains "the stranded-VIP probe has its own slower clock" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "VIP_PROBE_EVERY"
assert_contains "and the cycle respects it" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha" dns_only_vip_cycle)" 'EPOCHSECONDS >= vip_probe_next'
# The clock must advance when a probe RUNS. Advancing it only when the probe
# came back unanswered left the normal case probing every cycle, which is what
# the reporter was still seeing after the rate limit "landed".
_cycle_src="$(extract_fn "$SCRIPT_DIR/../pihole-ha" dns_only_vip_cycle)"
_probe_block="${_cycle_src#*EPOCHSECONDS >= vip_probe_next}"
assert_contains "the clock advances before the result is examined" \
    "${_probe_block%%vip_is_answered*}" "vip_probe_next=\$(( EPOCHSECONDS + VIP_PROBE_EVERY ))"

_answers_probe() {   # $1 = dig exit code, "nodig" for no dig at all
    P_RC="$1" bash -c '
        HEALTH_TIMEOUT=1
        if [[ "$P_RC" != nodig ]]; then
            dig() { return "$P_RC"; }
            command() { [[ "$1" == "-v" && "$2" == "dig" ]] && return 0; builtin command "$@"; }
        else
            command() { [[ "$1" == "-v" && "$2" == "dig" ]] && return 1; builtin command "$@"; }
        fi
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" peer_answers_dns)"'
        peer_answers_dns 10.0.0.2 && echo SERVING || echo NOT_YET
    '
}
assert_eq "a peer that replies is ready"            "SERVING" "$(_answers_probe 0)"
assert_eq "a peer that does not reply is not"       "NOT_YET" "$(_answers_probe 9)"
# No dig: fall back to the old behaviour rather than never handing over.
assert_eq "without dig we do not block the handover" "SERVING" "$(_answers_probe nodig)"


# ============================================================
# A port is a number, whatever the environment hands us
# ------------------------------------------------------------
# A user's status JSON came back saying:
#   "this node's own Pi-hole API on port 80    # The HOST port for Pi-hole
#    webgui did not answer"
# His PIHOLE_WEB_PORT carried an inline comment from a .env file, and the whole
# string went into a URL (Discourse 86667 #175).
_port_probe() { bash -c '
    source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
    log_warn() { echo "WARN $*"; }
    sane_port "$1" "${2:-80}"' _ "$1" "${2:-}"; }
assert_contains "a plain port is used as-is"      "$(_port_probe 8080)" "8080"
assert_not_contains "and says nothing about it"   "$(_port_probe 8080)" "WARN"
assert_contains "a trailing comment is trimmed"   "$(_port_probe '80   # the host port')" "80"
assert_contains "and the trimming is reported"    "$(_port_probe '80   # the host port')" "event=port_trimmed"
assert_contains "something that is not a port falls back" "$(_port_probe 'notaport')" "80"
assert_contains "and is reported"                 "$(_port_probe 'notaport')" "event=port_invalid"
assert_contains "so does a number out of range"   "$(_port_probe 99999)" "event=port_invalid"
assert_contains "an empty value falls back too"   "$(_port_probe '')" "80"
# Every place a port is taken has to go through it, or the next one leaks.
_ha_ports="$(cat "$SCRIPT_DIR/../pihole-ha")"
assert_not_contains "the node list parse does not take a port raw" \
    "$_ha_ports" 'NODE_PORTS["${_rn%%:*}"]="${_rn##*:}"'
assert_not_contains "nor does the environment override" \
    "$_ha_ports" 'NODE_PORTS["$LOCAL_IP"]="$PIHOLE_WEB_PORT"'
assert_eq "all three sites validate" "3" "$(grep -c 'sane_port' <<< "$_ha_ports")"

# ============================================================
# The PID-namespace dependency has to be documented, including its escape
# ------------------------------------------------------------
# "failed to join PID namespace: container <id> is not running" means the
# target exists but was not running at that instant -- a race, not a stale
# reference, which reads "No such container" instead. Reproduced both, plus the
# part that actually bites: after a failed join the sidecar stays exited and
# the restart policy never retries it (Discourse 86667 #174).
_docker_readme="$(cat "$SCRIPT_DIR/../docker/README.md")"
assert_contains "the join failure is explained"          "$_docker_readme" "failed to join PID namespace"
assert_contains "and that the restart policy will not fix it" \
    "$_docker_readme" "restart policy will not do it for you"
assert_contains "and that nothing needs recreating"      "$_docker_readme" "nothing has to be recreated"
assert_contains "pid: host is offered as the way out"    "$_docker_readme" "pid: host"
# Matched on a fragment the prose cannot line-wrap away.
assert_contains "with its trade-off stated"              "$_docker_readme" "process on the host, not just"
# Ordering still belongs in the compose we generate.
assert_contains "the generated compose orders the sidecar after Pi-hole" \
    "$(cat "$SCRIPT_DIR/../docker/docker-compose.yml")" "depends_on"

# ============================================================
# Don't hand a stranded VIP back to a node that cannot hold it
# ------------------------------------------------------------
# Claiming a stranded VIP is only half of it: the standby then yields again,
# because the peer still answers DNS, and the address flaps — a reporter
# measured it answering for 17s and silent for 12s, repeatedly (Discourse
# 86667). So once we have picked up a stranded VIP, we keep it until the node
# we are meant to defer to shows its HA daemon is actually running. Safe in the
# conservative direction: we are the only holder, so refusing to let go cannot
# produce two.
_alive_probe() {   # $1 = curl exit, $2 = body
    P_RC="$1" P_BODY="$2" bash -c '
        CHECK_INTERVAL=10; HEALTH_TIMEOUT=1
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        curl() { printf "%s" "$P_BODY"; return "$P_RC"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" peer_ha_alive)"'
        peer_ha_alive 10.0.0.2 && echo ALIVE || echo DEAD
    '
}
_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_old="$(date -u -d "-10 min" +%Y-%m-%dT%H:%M:%SZ)"
assert_eq "a freshly written status means the daemon is running" "ALIVE" \
    "$(_alive_probe 0 "{\"timestamp\":\"$_now\"}")"
# The dash keeps answering after the daemon stops; the status file goes stale.
assert_eq "a stale status means it is not"                       "DEAD" \
    "$(_alive_probe 0 "{\"timestamp\":\"$_old\"}")"
assert_eq "no answer at all means it is not"                     "DEAD" "$(_alive_probe 7 '')"
assert_eq "an answer without a timestamp means it is not"        "DEAD" "$(_alive_probe 0 '{"node":{}}')"

_hold_probe() {   # $1 = claimed-stranded?, $2 = heir's daemon alive?
    P_CLAIMED="$1" P_ALIVE="$2" P_ANSWERS="${3:-yes}" bash -c '
        VIP=10.0.0.9; IFACE=eth0; VIP_ENABLED=true; HA_ENABLED=true
        GATEWAY=10.0.0.1; MY_IDX=1; NODES=(10.0.0.1 10.0.0.2); LOCAL_IP=10.0.0.2
        ROLE=SECONDARY; DEACTIVATE_AFTER=3; ACTIVATE_AFTER=2
        activate_count=0; deactivate_count=0; vip_orphan_count=0
        vip_claimed_stranded="$P_CLAIMED"
        log_info() { :; }; log_warn() { :; }; notify() { :; }
        ping() { return 0; }
        is_dns_healthy() { return 0; }
        should_i_hold_vip() { return 1; }     # a higher-priority node answers DNS
        has_vip() { return 0; }               # and we are holding the address
        peer_ha_alive() { [[ "$P_ALIVE" == yes ]]; }
        peer_answers_dns() { [[ "${P_ANSWERS:-yes}" == yes ]]; }
        remove_vip() { echo RELEASED; }
        add_vip() { :; }; vip_is_answered() { return 0; }
        write_status() { echo "STATUS: $1"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" dns_only_vip_cycle)"'
        dns_only_vip_cycle
    '
}
assert_contains "a stranded VIP is kept while the heir's daemon is down" \
    "$(_hold_probe true no)" "its HA daemon is not running"
assert_not_contains "and is not released"          "$(_hold_probe true no)"  "RELEASED"
# Once it can take it, the normal countdown resumes.
assert_not_contains "a living heir gets the normal release countdown" \
    "$(_hold_probe true yes)" "its HA daemon is not running"
# A VIP held normally is unaffected by any of this.
assert_not_contains "a normally-held VIP is unaffected" \
    "$(_hold_probe false no)" "its HA daemon is not running"
# Its daemon being back is not the same as it being able to serve: port 53
# opens before FTL has loaded gravity, and releasing then leaves the VIP dark.
assert_contains "a heir still starting up keeps the VIP here" \
    "$(_hold_probe true yes no)" "not answering queries yet"
assert_not_contains "and it is not released"  "$(_hold_probe true yes no)" "RELEASED"
assert_not_contains "a heir that answers gets the normal countdown" \
    "$(_hold_probe true yes yes)" "not answering queries yet"

# ============================================================
# A VIP nobody is holding must be picked up
# ------------------------------------------------------------
# A standby yields to any higher-priority node that answers ping and DNS. When
# that node's Pi-hole is up but its HA daemon is not — a container that failed
# to restart — the standby releases the VIP and the peer never claims it:
# minutes of clients broadcasting "who-has <VIP>" into silence (Discourse
# 86667 #167). Gating the yield on the peer's HA API would instead leave both
# nodes holding the address when that API is simply unreachable, so the
# standby asks the question that cannot be wrong: does anything answer for it.
_answered_probe() {   # $1 = what arping prints
    P_OUT="$1" bash -c '
        VIP=10.0.0.9; IFACE=eth0
        arping() { printf "%s\n" "$P_OUT"; return 1; }
        command() { [[ "$1" == "-v" && "$2" == "arping" ]] && return 0; builtin command "$@"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" vip_is_answered)"'
        vip_is_answered && echo OWNED || echo UNOWNED
    '
}
assert_eq "a reply means someone holds it" "OWNED" \
    "$(_answered_probe '2 packets transmitted, 1 packets received,  50% unanswered')"
assert_eq "no reply from a probe that ran means nobody does" "UNOWNED" \
    "$(_answered_probe '2 packets transmitted, 0 packets received, 100% unanswered')"
assert_eq "iputils wording is understood too" "UNOWNED" \
    "$(_answered_probe 'Sent 2 probes (2 broadcast(s)) Received 0 response(s)')"
assert_eq "and its positive case" "OWNED" \
    "$(_answered_probe 'Sent 2 probes (2 broadcast(s)) Received 2 response(s)')"
# The dangerous direction: a probe that could not run must never read as
# "nobody owns it", or a standby claims an address another node is holding.
# Caught in testing — as an unprivileged user every probe came back silent,
# including the gateway's.
assert_eq "a probe that could not run reads as owned" "OWNED" \
    "$(_answered_probe 'arping: Could not open raw socket: Operation not permitted')"
assert_eq "an unknown interface reads as owned" "OWNED" \
    "$(_answered_probe 'arping: Unknown interface eth9')"
assert_eq "no arping at all reads as owned" "OWNED" \
    "$(bash -c '
        VIP=10.0.0.9; IFACE=eth0
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" vip_is_answered)"'
        vip_is_answered && echo OWNED || echo UNOWNED')"
assert_contains "claiming a stranded VIP needs several silent checks" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "VIP_ORPHAN_AFTER"
assert_contains "and says why it claimed" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "event=vip_orphaned"
assert_contains "a node whose own DNS is down never claims" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha" dns_only_vip_cycle)" 'is_dns_healthy "$LOCAL_IP" &&'

# ============================================================
# A VIP another daemon put there is not ours to claim or to fail to remove
# ------------------------------------------------------------
# has_vip matches the address with ANY prefix, but remove_vip deleted /32. On a
# node where keepalived had added the same address as /24, the node therefore
# believed it held the VIP and could not release it:
#   vip_remove status=failed error="RTNETLINK answers: Address not available"
# It then kept reporting a VIP that another daemon owned, while nothing on the
# LAN answered for it (Discourse 86667 #161).
_vip_prefix_probe() {   # $1 = the `ip addr show` line to present
    P_LINE="$1" bash -c '
        VIP=192.168.1.100; IFACE=eth0
        ip() { printf "%s\n" "$P_LINE"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" vip_prefix)"'
        vip_prefix
    '
}
assert_eq "our own /32 is read back"        "32" "$(_vip_prefix_probe '    inet 192.168.1.100/32 scope global eth0')"
assert_eq "a foreign /24 is read back"      "24" "$(_vip_prefix_probe '    inet 192.168.1.100/24 brd 192.168.1.255 scope global eth0')"
assert_eq "an absent address yields nothing" ""  "$(_vip_prefix_probe '    inet 192.168.1.7/24 scope global eth0')"
_remove_probe() {   # $1 = prefix present on the interface
    # remove_vip captures the command's output into $err, so the stub records
    # the invocation to a file instead of stdout.
    local log; log="$(mktemp)"
    P_LOG="$log" P_PLEN="$1" bash -c '
        VIP=192.168.1.100; IFACE=eth0
        log_info() { echo "INFO $*"; }; log_error() { echo "ERROR $*"; }
        has_vip() { return 0; }
        vip_prefix() { printf "%s" "$P_PLEN"; }
        ip() { echo "CMD: $*" >> "$P_LOG"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" remove_vip)"'
        remove_vip
    '
    cat "$log"; rm -f "$log"
}
assert_contains "removal uses the prefix that is actually there" \
    "$(_remove_probe 24)" "addr del 192.168.1.100/24"
assert_contains "and still handles our own /32" \
    "$(_remove_probe 32)" "addr del 192.168.1.100/32"
# Claiming an address another daemon owns must be said out loud, not absorbed.
_claim_probe() {   # $1 = prefix already present
    P_PLEN="$1" bash -c '
        VIP=192.168.1.100; IFACE=eth0; VIP_ENABLED=true
        log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }; log_error() { :; }
        notify() { :; }; announce_vip() { :; }
        ensure_iface() { return 0; }
        has_vip() { return 0; }
        vip_prefix() { printf "%s" "$P_PLEN"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" add_vip)"'
        add_vip
    '
}
assert_contains "a VIP with a foreign prefix is flagged" "$(_claim_probe 24)" "event=vip_foreign"
assert_contains "and names the likely owner"             "$(_claim_probe 24)" "keepalived"
assert_not_contains "our own /32 is not flagged"         "$(_claim_probe 32)" "event=vip_foreign"

# "Unknown IP: x.x.x.x" told nobody what it had been compared against.
_hasrc3="$(cat "$SCRIPT_DIR/../pihole-ha")"
assert_contains "the identity error prints the node list"  "$_hasrc3" 'not in the cluster node list (HA_NODES='
assert_contains "and names the Docker override"            "$_hasrc3" "PIHOLE_HA_LOCAL_IP"
assert_contains "and explains why a changed list was ignored" "$_hasrc3" "PIHOLE_HA_FORCE_CONFIG=true"

# ============================================================
# Holding the VIP must be re-announced, not announced once
# ------------------------------------------------------------
# A takeover announces once. A reporter captured clients broadcasting
# "who-has <VIP>" for six minutes with nothing answering, then everything
# recovering the instant another takeover sent a fresh burst — a lost or
# ignored announcement is invisible until ARP entries age out (Discourse
# 86667 #156). keepalived re-announces for the same reason.
_reann_probe() {   # $1 = holds the VIP?, $2 = seconds from now until next due
    # The real call redirects to /dev/null, so the stub records to a file; and
    # EPOCHSECONDS cannot be faked, so timings are measured against it.
    local log; log="$(mktemp)"
    P_HAS="$1" P_IN="$2" P_LOG="$log" bash -c '
        VIP_ENABLED=true; VIP_ANNOUNCE_EVERY=60
        VIP_ANNOUNCE_NEXT=$(( EPOCHSECONDS + P_IN ))
        has_vip() { [[ "$P_HAS" == yes ]]; }
        announce_vip() { echo ANNOUNCED >> "$P_LOG"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" reannounce_vip)"'
        reannounce_vip; wait 2>/dev/null
        echo "due_in=$(( VIP_ANNOUNCE_NEXT - EPOCHSECONDS )) next_raw=$VIP_ANNOUNCE_NEXT"
    '
    cat "$log" 2>/dev/null; rm -f "$log"
}
assert_contains "the holder re-announces when due"        "$(_reann_probe yes 0)"  "ANNOUNCED"
assert_contains "and schedules the next one a minute out" "$(_reann_probe yes 0)"  "due_in=60"
assert_not_contains "it does not announce before due"     "$(_reann_probe yes 30)" "ANNOUNCED"
assert_contains "and leaves that schedule alone"          "$(_reann_probe yes 30)" "due_in=30"
assert_not_contains "a node without the VIP says nothing" "$(_reann_probe no 0)"   "ANNOUNCED"
# Losing the VIP must re-arm, or the node that takes it back waits out the timer.
# Re-armed means "due immediately", i.e. the timer is reset to zero rather than
# left in the future — otherwise retaking the VIP waits out the old schedule.
assert_contains "losing the VIP re-arms the next claim"   "$(_reann_probe no 999)" "next_raw=0"
assert_contains "the loop re-announces every cycle"     "$(cat "$SCRIPT_DIR/../pihole-ha")" "reannounce_vip            #"

# ============================================================
# A node must be able to be told its own address
# ------------------------------------------------------------
# Identity is detected from the addresses this process can see. That is the
# host's on a normal install and the container's on a bridge network — a 172.x
# that matches no HA_NODES entry, so the daemon exits "Unknown IP" with no way
# to correct it (Discourse 86667 #151).
_ip_override() { PIHOLE_HA_LOCAL_IP="$1" bash -c '
    source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
    hostname() { [[ "$1" == -I ]] && echo "172.18.0.5"; }
    ip() { :; }
    platform_get_local_ip'; }
assert_eq "an explicit node address is used"      "192.168.1.10" "$(_ip_override 192.168.1.10)"
assert_eq "a malformed one is ignored, not trusted" "172.18.0.5"  "$(_ip_override 'not-an-ip')"
assert_eq "unset leaves detection alone"            "172.18.0.5"  "$(_ip_override '')"
assert_contains "the bridge-network setup is documented" \
    "$(cat "$SCRIPT_DIR/../docker/README.md")" "PIHOLE_HA_LOCAL_IP"

# ============================================================
# Taking the VIP must actually be announced on the LAN
# ------------------------------------------------------------
# Captured on a live interface, the old `arping -U -c3 -I <iface> <VIP>` put
# this on the wire:
#
#   ARP, Request who-has <VIP> (ff:ff:ff:ff:ff:ff) tell <node address>
#
# A request FOR the VIP from the node's own address — nothing learns the new
# MAC from it. Habets arping (the "arping" package on Alpine and Debian)
# defaults the sender to the interface address and only -S overrides it, while
# iputils-arping's -U sets sender = target. So whether a failover was announced
# at all depended on which implementation happened to be installed, and where
# it was not, clients kept the old MAC until their ARP entry aged out — minutes
# (Discourse 86667 #150: "the VIP came back but did not answer for several
# minutes"). The fixed command emits "who-has <VIP> tell <VIP>", verified with
# tcpdump.
_announce_probe() {   # $1 = arping identity line, $2 = exit code, $3 = output
    # The function captures arping's output, so the stub records what it was
    # called with in a file rather than on stdout, which never comes back.
    local log; log="$(mktemp)"
    P_LOG="$log" P_ID="$1" P_RC="$2" P_OUT="$3" bash -c '
        VIP=10.0.0.9; IFACE=eth0
        log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }
        arping() {
            if [[ "$1" == "-h" ]]; then printf "%s\n" "$P_ID"; return 0; fi
            echo "CMD: $*" >> "$P_LOG"
            printf "%s\n" "$P_OUT"
            return "$P_RC"
        }
        command() { [[ "$1" == "-v" && "$2" == "arping" ]] && return 0; builtin command "$@"; }
        sleep() { :; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" announce_vip)"'
        announce_vip
    '
    cat "$log"; rm -f "$log"
}
_hab="ARPing 2.25, by Thomas Habets <thomas@habets.se>"
_ipu="Usage: arping [-fqbDUAV] [-c count] ... (iputils)"
_quiet="ARPING 10.0.0.9 Timeout --- 10.0.0.9 statistics --- 3 packets transmitted, 0 packets received"
assert_contains "Habets arping is told which address to announce" \
    "$(_announce_probe "$_hab" 1 "$_quiet")" "-S 10.0.0.9"
assert_not_contains "iputils arping is not given -S, its -U already does it" \
    "$(_announce_probe "$_ipu" 0 "$_quiet")" "-S 10.0.0.9"
assert_contains "the announcement names the interface" \
    "$(_announce_probe "$_hab" 1 "$_quiet")" "-I eth0"
# Nobody answers an announcement, so "0 packets received" is success, not failure.
assert_contains "no replies is not treated as a failure" \
    "$(_announce_probe "$_hab" 1 "$_quiet")" "status=ok"
# A real error says so on stderr instead of counting replies.
assert_contains "a genuine arping error is reported" \
    "$(_announce_probe "$_hab" 2 "arping: Unknown iface eth0")" "status=failed"
# Two bursts: one can land while the previous holder is still answering.
assert_eq "it announces twice" "2" \
    "$(_announce_probe "$_hab" 1 "$_quiet" | grep -c '^CMD: ')"
# And if arping is not installed at all, say what the consequence is.
assert_contains "a missing arping is called out" \
    "$(bash -c '
        VIP=10.0.0.9; IFACE=eth0
        log_warn() { echo "WARN $*"; }; log_info() { echo "INFO $*"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" announce_vip)"'
        announce_vip')" "arping is not installed"
assert_contains "taking the VIP triggers the announcement" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha" add_vip)" "announce_vip"

# ============================================================
# "Last synced" must answer "is sync alive", not "when did it last change"
# ------------------------------------------------------------
# The timestamp was only recorded on the paths that downloaded a payload, so in
# the steady state -- remote hash unchanged, which is almost always -- the
# puller exited early and recorded nothing. A user watched it sit at 11:55 for
# four hours on a healthy cluster and reasonably asked why (Discourse 86667
# #148). It is the same complaint he had about "Last build", in the line I
# added to answer it.
_pullmark_probe() {   # $1 = the log event to look for around the exit
    grep -B4 "$1" "$SCRIPT_DIR/../pihole-ha-sync-pull" | grep -c '_record_pull' || true
}
assert_eq "the steady-state check records a successful sync" "1" \
    "$(_pullmark_probe 'reason=\\"already up to date\\"')"
assert_eq "so does a pull that applied something" "1" "$(_pullmark_probe 'status=applied')"
# Failures must NOT look like a successful sync.
assert_eq "a peer with no manifest records nothing" "0" \
    "$(_pullmark_probe 'reason=\\"no peer has a manifest\\"')"
assert_eq "an unparseable manifest records nothing" "0" \
    "$(_pullmark_probe 'reason=\\"could not parse manifest\\"')"
assert_eq "a refused rollback records nothing" "0" "$(_pullmark_probe 'event=pull_reject_older')"
# One definition, early enough for every caller.
assert_eq "the recorder is defined once" "1" \
    "$(grep -c '^_record_pull() {' "$SCRIPT_DIR/../pihole-ha-sync-pull")"

# ============================================================
# "Nothing changed" is no reason to skip when there is nothing published
# ------------------------------------------------------------
# The hash the publisher compares against and the payload it serves lived in
# different places — on Docker the hash was on a volume and /var/lib/pihole-ha
# was not — so a recreated container came back believing it was up to date
# while serving nothing. Standbys then log "no peer has a manifest" until some
# unrelated change happens to trigger a build. A Docker user's "Last build"
# vanished after a redeploy and never came back (Discourse 86667 #146).
_skip_probe() {   # $1 = "present" or "missing"
    local dir; dir="$(mktemp -d)"
    if [[ "$1" == present ]]; then echo payload > "$dir/p"; echo manifest > "$dir/m"; fi
    PAYLOAD_FILE="$dir/p" MANIFEST_FILE="$dir/m" bash -c '
        CURRENT=abc; PREVIOUS=abc; FORCE=false
        log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }
        '"$(sed -n '/^if \[\[ "\$CURRENT" == "\$PREVIOUS" && "\$FORCE" != "true" \]\]; then/,/^fi$/p' "$SCRIPT_DIR/../pihole-ha-sync")"'
        echo "reached-the-build"
    '
    rm -rf "$dir"
}
assert_contains "an unchanged config with a payload still skips" "$(_skip_probe present)" "no changes"
assert_not_contains "and does not reach the build"               "$(_skip_probe present)" "reached-the-build"
assert_contains "a missing payload rebuilds instead of skipping" "$(_skip_probe missing)" "reached-the-build"
assert_contains "and says why"                                   "$(_skip_probe missing)" "event=rebuild"
# ...which only matters because the payload now survives a redeploy at all.
assert_contains "the compose keeps the payload on a volume" \
    "$(cat "$SCRIPT_DIR/../docker/docker-compose.yml")" "pihole-ha-blob:/var/lib/pihole-ha"
assert_contains "and the docs example does too" \
    "$(cat "$SCRIPT_DIR/../docker/README.md")" "pihole-ha-blob:/var/lib/pihole-ha"
# A publisher has no "last synced" — say so rather than leaving a blank label.
assert_contains "a publisher explains its empty sync time" \
    "$(cat "$SCRIPT_DIR/../ha.js")" "this node publishes (never pulls)"

# ============================================================
# Everything the sidecar stages must actually be in the sidecar image
# ------------------------------------------------------------
# The entrypoint staged /usr/local/share/pihole-ha/VERSION into the shared
# volume for the panel to pick up, the Dockerfile never copied it into the
# image, and the copy ended in "|| true" — so for three releases every Docker
# install read "Pi-hole HA vunknown" and nothing said why. My own end-to-end
# test passed because the fixture supplied the file the image lacked
# (Discourse 86667 #144).
#
# Derived, not listed: whatever the entrypoint stages from that directory has
# to be COPYed into the image, so the next addition cannot repeat this.
_staged_files="$(grep -oE '^ *_stage [A-Za-z0-9._-]+' "$SCRIPT_DIR/../docker/docker-entrypoint.sh" | awk '{print $2}' | sort -u)"
assert_contains "the entrypoint stages the version file" "$_staged_files" "VERSION"
for _f in $_staged_files; do
    assert_contains "the image contains $_f, which the entrypoint stages" \
        "$(cat "$SCRIPT_DIR/../docker/Dockerfile")" "/usr/local/share/pihole-ha/$_f"
done
# And a missing one must be audible rather than swallowed.
assert_contains "a file missing from the image is reported" \
    "$(cat "$SCRIPT_DIR/../docker/docker-entrypoint.sh")" "event=stage_missing"
assert_not_contains "staging no longer discards its errors" \
    "$(cat "$SCRIPT_DIR/../docker/docker-entrypoint.sh")" 'cp /usr/local/share/pihole-ha/VERSION /pihole-ha-src/ 2>/dev/null || true'

# ============================================================
# A DNS-only cluster must not label every node "Standby"
# ------------------------------------------------------------
# The node cards were labelled from dhcp_active alone. On a DNS-only cluster no
# node ever activates DHCP, so every card read "Standby" — including the one
# holding the VIP and answering every query. Two users asked what it meant
# (Discourse 86667 #141).
assert_contains "the daemon tells the panel which kind of cluster this is" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" '"dhcp_ha":%s'
_card_probe() {   # $1 dhcp_ha, $2 vip_enabled, $3 vip_held
    node -e '
        var dhcpHa = process.argv[1] === "true";
        var vipEnabled = process.argv[2] === "true";
        var vipHeld = process.argv[3] === "true";
        var reachable = true, dhcpActive = false, isDesignatedMaster = false, manualMaster = false;
        var statusData = { dhcp_ha: dhcpHa };
        var label = "";
        var $status = { text: function (t) { label = t; } };
        var bgClass;
        var dnsOnly = statusData.dhcp_ha === false;
        if (!reachable) { bgClass = "bg-red"; $status.text("UNREACHABLE"); }
        else if (dnsOnly) {
            if (vipHeld) { bgClass = "bg-green"; $status.text("Serving DNS (VIP)"); }
            else if (!vipEnabled) { bgClass = "bg-green"; $status.text("Serving DNS"); }
            else { bgClass = "bg-aqua"; $status.text("Standby"); }
        }
        else if (dhcpActive) { $status.text("DHCP Active"); }
        else { $status.text("Standby"); }
        console.log(label);
    ' "$1" "$2" "$3"
}
assert_eq "the DNS-only node holding the VIP says so"  "Serving DNS (VIP)" "$(_card_probe false true true)"
assert_eq "a DNS-only standby still says Standby"      "Standby"           "$(_card_probe false true false)"
assert_eq "DNS-only with no VIP: every node is serving" "Serving DNS"      "$(_card_probe false false false)"
assert_eq "a DHCP cluster keeps its own labels"        "Standby"           "$(_card_probe true true false)"
# The branch has to be reached before the DHCP ones, or it never runs.
assert_contains "the DNS-only branch precedes the DHCP labels" \
    "$(sed -n '/var dnsOnly = statusData.dhcp_ha === false/,/dhcpActive && isDesignatedMaster/p' "$SCRIPT_DIR/../ha.js")" \
    "Serving DNS (VIP)"

# ============================================================
# The HA page renders inside the PI-HOLE container, so it needs what it reads
# ------------------------------------------------------------
# ha.lp is served by Pi-hole's own web server and opens /etc/pihole-ha/*,
# /run/pihole-ha/status.json and the VERSION file from its OWN filesystem. On
# Docker those live in the sidecar, so anything not mounted or staged across
# renders blank -- a user saw VIP_ENABLED=true with no address, an empty Config
# Sync panel and "Pi-hole HA vunknown" (Discourse 86667 #137).
_lp_reads="$(grep -oE 'io.open\("[^"]+"' "$SCRIPT_DIR/../ha.lp" | cut -d'"' -f2 | sort -u)"
for _path in $_lp_reads; do
    case "$_path" in
        /etc/pihole-ha/*)
            assert_contains "the compose mounts $_path into the pihole container" \
                "$(cat "$SCRIPT_DIR/../docker/docker-compose.yml")" "pihole-ha-conf:/etc/pihole-ha"
            assert_contains "and the docs example does too" \
                "$(cat "$SCRIPT_DIR/../docker/README.md")" "pihole-ha-conf:/etc/pihole-ha:ro" ;;
        /run/pihole-ha/*)
            assert_contains "the compose mounts $_path into the pihole container" \
                "$(cat "$SCRIPT_DIR/../docker/docker-compose.yml")" "pihole-ha-run:/run/pihole-ha"
            assert_contains "and the docs example does too" \
                "$(cat "$SCRIPT_DIR/../docker/README.md")" "pihole-ha-run:/run/pihole-ha:ro" ;;
        /usr/local/share/pihole-ha/VERSION)
            # Not a mount: the sidecar stages it and the inject copies it in.
            assert_contains "the sidecar stages the version file" \
                "$(cat "$SCRIPT_DIR/../docker/docker-entrypoint.sh")" "_stage VERSION"
            assert_contains "and the inject installs it where ha.lp reads it" \
                "$(cat "$SCRIPT_DIR/../docker/pihole-ha-inject-docker.sh")" 'cp "$SRCDIR/VERSION" /usr/local/share/pihole-ha/VERSION' ;;
    esac
done

# ============================================================
# Config the container is ignoring must say so, and a standby must be able to
# see when IT last synced
# ------------------------------------------------------------
# Both from a Docker user setting up a two-node cluster (Discourse 86667 #135).
#
# nodes.conf is generated once and the volume keeps it, so PIHOLE_HA_VIP added
# after the first start did nothing and the file kept VIP= empty. Indistinguish-
# able from guessing the wrong variable name, which is what he concluded.
_ignored_probe() {   # $1 = env VIP, $2 = VIP already in nodes.conf
    local conf; conf="$(mktemp)"
    printf 'GATEWAY=10.0.0.1\nVIP=%s\nVIP_ENABLED=false\nHA_NODES=10.0.0.2,10.0.0.3\n' "$2" > "$conf"
    NODES_CONF="$conf" PIHOLE_HA_VIP="$1" bash -c '
        log_warn() { echo "WARN $*"; }
        '"$(sed -n '/^    _ignored=""/,/^    fi$/p' "$SCRIPT_DIR/../docker/docker-entrypoint.sh")"'
    '
    rm -f "$conf"
}
assert_contains "an env var the container is ignoring is named" \
    "$(_ignored_probe 192.168.1.100 "")" "PIHOLE_HA_VIP"
assert_contains "the warning says how to apply it" \
    "$(_ignored_probe 192.168.1.100 "")" "PIHOLE_HA_FORCE_CONFIG=true"
assert_eq "a value that already matches is not reported" "" \
    "$(_ignored_probe 192.168.1.100 192.168.1.100)"
assert_eq "an unset variable is not reported" "" "$(_ignored_probe "" "")"

# The panel could only show the publisher's build time. On a standby that
# answers a different question than "did I actually receive it?".
assert_contains "a completed pull is recorded, applied or not" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" "_record_pull unchanged"
assert_contains "and when it changed something"  \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" "_record_pull applied"
assert_contains "it is kept on disk, not in /run" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" "/etc/pihole-ha/sync-last-pull"
assert_contains "the sync API exposes it"  \
    "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" '"last_pull":"%s","last_pull_status":"%s"'
assert_contains "the panel shows when this node last synced" \
    "$(cat "$SCRIPT_DIR/../ha.js")" 'Last synced: '
# It reads the response the panel already fetches; a different variable name
# would silently render nothing.
assert_contains "and reads it from the object the panel already has" \
    "$(cat "$SCRIPT_DIR/../ha.js")" 'syncCfg && syncCfg.last_pull'
assert_contains "the VIP address variable is documented, not just its toggle" \
    "$(cat "$SCRIPT_DIR/../docker/README.md")" "PIHOLE_HA_VIP=192.168.1.100"

# ============================================================
# The Docker panel injection must not hijack or deadlock Pi-hole's startup
# ------------------------------------------------------------
# Two traps a Synology user walked into (Discourse 86667 #130), both of them in
# what the docs told him to paste.
#
# The inject script ended with `exec start.sh`, which is the STOCK image's
# entrypoint. A combined image starts at its own script -- mpgirro's
# /custom-entrypoint.sh launches unbound and then Pi-hole -- so start.sh skips
# unbound, and a node whose upstream is 127.0.0.1#5335 then answers nothing.
_entrypoint_probe() {   # $1 = PIHOLE_HA_ENTRYPOINT, $2 = "custom" if /custom-entrypoint.sh exists
    P_EP="$1" P_CUSTOM="$2" bash -c '
        PIHOLE_HA_ENTRYPOINT="$P_EP"
        # the real resolution block, lifted from the script
        '"$(sed -n '/^_real_entrypoint=/,/^exec "\$_real_entrypoint"/p' "$SCRIPT_DIR/../docker/pihole-ha-inject-docker.sh" | sed 's/^exec /echo EXEC /; s/\[\[ -x \/custom-entrypoint.sh \]\]/[[ "$P_CUSTOM" == custom ]]/')"'
    ' 2>/dev/null | tail -1
}
assert_contains "a combined image hands off to its own entrypoint" \
    "$(_entrypoint_probe "" custom)" "EXEC /custom-entrypoint.sh"
assert_contains "the stock image still hands off to start.sh" \
    "$(_entrypoint_probe "" none)" "EXEC start.sh"
assert_contains "an explicit entrypoint wins over both" \
    "$(_entrypoint_probe /opt/mine.sh custom)" "EXEC /opt/mine.sh"

# The documented entrypoint waited for the sidecar forever. On a node whose
# Pi-hole IS the LAN's DNS that deadlocks: the sidecar image cannot be built
# because nothing resolves, and nothing resolves because Pi-hole is waiting for
# the sidecar. Exactly what happened to him.
for _f in docker/docker-compose.yml docker/README.md; do
    _src="$(cat "$SCRIPT_DIR/../$_f")"
    assert_not_contains "$_f: the panel wait is not unbounded" \
        "$_src" "until [ -f /pihole-ha-src/pihole-ha-inject-docker.sh ]; do sleep 1; done"
    assert_contains "$_f: the wait is capped"            "$_src" '-lt 90'
    assert_contains "$_f: and Pi-hole starts regardless" "$_src" 'exec start.sh'
done
assert_contains "the docs name the combined-image entrypoint override" \
    "$(cat "$SCRIPT_DIR/../docker/README.md")" "PIHOLE_HA_ENTRYPOINT=/custom-entrypoint.sh"
assert_contains "and warn to build the image before changing the entrypoint" \
    "$(cat "$SCRIPT_DIR/../docker/README.md")" "Build the sidecar image before you add this entrypoint"

# ============================================================
# A Pi-hole container is one running pihole-FTL, not one named pihole/pihole
# ------------------------------------------------------------
# The Docker installer looked for an image called "pihole/pihole", so a combined
# image -- Pi-hole and unbound in one container, mpgirro/pihole-unbound -- was
# reported as "no running Pi-hole container found" (Discourse 86667 #125).
# Verified against the real image: it carries /usr/bin/pihole-FTL v6.8, the same
# version as the stock image this sidecar builds from.
_detect_probe() {   # $1 = docker ps table, $2 = ids that have pihole-FTL
    P_PS="$1" P_HAS="$2" bash -c '
        docker() {
            case "$1" in
                ps)   printf "%s\n" "$P_PS" ;;
                exec) [[ " $P_HAS " == *" $2 "* ]] ;;
            esac
        }
        '"$(sed -n '/^# Find it by what it IS/,/^done$/p' "$SCRIPT_DIR/../docker-install.sh")"'
        printf "%s" "${pihole_containers:-NONE}"
    '
}
_ps_combined=$'c1\tpihole\tmpgirro/pihole-unbound:latest\nc2\tgrafana\tgrafana/grafana'
assert_contains "a combined pihole+unbound image is found" \
    "$(_detect_probe "$_ps_combined" "c1")" "mpgirro/pihole-unbound"
# Named like anything at all: the fallback pass asks every container.
_ps_disguised=$'c1\tweather-box\talpine\nc2\tgrafana\tgrafana/grafana'
assert_contains "a container named nothing like Pi-hole is still found" \
    "$(_detect_probe "$_ps_disguised" "c1")" "weather-box"
assert_eq "nothing running Pi-hole finds nothing" "NONE" \
    "$(_detect_probe "$_ps_disguised" "")"
# The sidecar carries pihole-FTL too, to drive --config. It must not nominate
# itself as the Pi-hole container.
_ps_with_sidecar=$'c1\tpihole\tpihole/pihole:latest\nc2\tpihole-ha\tdocker-pihole-ha'
_both="$(_detect_probe "$_ps_with_sidecar" "c1 c2")"
assert_contains "the real Pi-hole container is picked"     "$_both" "pihole/pihole"
assert_not_contains "and the sidecar is not picked as one" "$_both" "docker-pihole-ha"
assert_not_contains "detection no longer keys on the image name" \
    "$(sed -n '/^# Find it by what it IS/,/^done$/p' "$SCRIPT_DIR/../docker-install.sh")" "grep -i 'pihole/pihole'"
# The sidecar's FTL binary writes pihole.toml for an FTL it does not run, so it
# has to be buildable from whichever image is actually in use.
assert_contains "the sidecar can be built from another Pi-hole image" \
    "$(cat "$SCRIPT_DIR/../docker/Dockerfile")" 'ARG PIHOLE_IMAGE=pihole/pihole:latest'
assert_contains "and that argument is what the build stage uses" \
    "$(cat "$SCRIPT_DIR/../docker/Dockerfile")" 'FROM ${PIHOLE_IMAGE} AS pihole-src'

# ============================================================
# An unchanged list must not restart FTL either
# ------------------------------------------------------------
# The compare-before-write added for the scalar settings missed the
# array-valued keys: dns.hosts, dns.cnameRecords, dhcp.hosts and dns.revServers
# were still written unconditionally, each setting HOSTS_APPLIED, which is
# enough to restart FTL at the end of the pull. So on any cluster with local DNS
# records every applied pull still restarted FTL -- ~10s unfiltered on the node
# holding the VIP (Discourse 86667 #120: the fix was half a fix).
_array_probe() {   # $1 key, $2 file, $3 label, $4 what FTL already holds (display form)
    local dir; dir="$(mktemp -d)"
    printf '["1.2.3.4 host.lan"]' > "$dir/$2"
    P_CUR="$4" STAGING_DIR="$dir" P_KEY="$1" P_LABEL="$3" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        COMP_DNS=true; COMP_DHCP=true; COMP_SETTINGS=true
        HOSTS_APPLIED=false; APPLIED_SOMETHING=false; APPLY_FAILED=false
        log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }
        pihole-FTL() { [[ $# -eq 2 ]] && printf "%s" "$P_CUR"; return 0; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" _json_is_empty)"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" _array_is_current)"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" apply_dns_hosts)"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" apply_dhcp_hosts)"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" apply_array_key)"'
        case "$P_LABEL" in
            dns_hosts)  apply_dns_hosts ;;
            dhcp_hosts) apply_dhcp_hosts ;;
            *)          apply_array_key true "$P_KEY" '"$2"' "$P_LABEL" ;;
        esac
        echo "restart_needed=$HOSTS_APPLIED"
    '
    rm -rf "$dir"
}
for _case in "dns.hosts:dns-hosts.json:dns_hosts" "dhcp.hosts:dhcp-hosts.json:dhcp_hosts" "dns.cnameRecords:dns-cnames.json:dns_cnames"; do
    IFS=: read -r _k _f _l <<< "$_case"
    _same="$(_array_probe "$_k" "$_f" "$_l" '[ 1.2.3.4 host.lan ]')"
    assert_contains "$_l identical to ours is not rewritten" "$_same" "status=unchanged"
    assert_contains "$_l unchanged does not restart FTL"     "$_same" "restart_needed=false"
    _diff="$(_array_probe "$_k" "$_f" "$_l" '[ 9.9.9.9 other.lan ]')"
    assert_contains "$_l that differs is applied"            "$_diff" "status=ok"
    assert_contains "$_l that differs does restart FTL"      "$_diff" "restart_needed=true"
done

# The comparison only works because it goes through the same converter the
# publisher built the payload with, so there is exactly one of those.
assert_eq "the array converter is defined once, in the shared library" "1" \
    "$(grep -c '^ftl_to_json() {' "$SCRIPT_DIR/../pihole-ha-platform" "$SCRIPT_DIR/../pihole-ha-sync" "$SCRIPT_DIR/../pihole-ha-sync-pull" | awk -F: '{t+=$2} END {print t}')"
assert_contains "the puller compares through it" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" _array_is_current)" "ftl_to_json"
# The hard case is a MAC-led reservation: commas inside the record must not split
# it, or the comparison never matches and every pull writes.
assert_eq "a MAC-led reservation round-trips exactly" \
    '["00:08:9B:E8:50:62,10.33.47.2,QNAP","1.2.3.4 host.lan"]' \
    "$(bash -c 'source "'"$SCRIPT_DIR"'/../pihole-ha-platform"; printf "%s" "[ 00:08:9B:E8:50:62,10.33.47.2,QNAP, 1.2.3.4 host.lan ]" | ftl_to_json')"

# ============================================================
# Stopping must stop, and an unchanged setting must not restart FTL
# ------------------------------------------------------------
# Both reported after a 3.19.0 upgrade on a live pair (Discourse 86667 #118).
#
# A trap on TERM runs the handler and then CARRIES ON -- bash does not exit for
# you -- so the daemon kept looping after systemd asked it to stop and was
# SIGKILLed when TimeoutStopSec expired. Measured on a real node: 90s and
# "Failed with result 'timeout'" on every update and reboot, 0s after the fix.
# The loop's sleep has to be interruptible too, or the handler waits it out.
_term_probe() {
    local dir; dir="$(mktemp -d)"
    {
        echo '#!/bin/bash'
        echo 'CHECK_INTERVAL=30'
        echo "_shutdown_release() { echo released >> $dir/ran; }"
        # the real trap lines and the real sleep, lifted from the daemon
        sed -n '/^_shutdown_done=false$/,/^trap ._shutdown_once; exit 0. INT TERM$/p' "$SCRIPT_DIR/../pihole-ha"
        echo 'while true; do'
        sed -n '/^    sleep "\$CHECK_INTERVAL" &$/,/^    wait \$! 2>\/dev\/null || true$/p' "$SCRIPT_DIR/../pihole-ha"
        echo 'done'
    } > "$dir/loop.sh"
    chmod +x "$dir/loop.sh"
    # If the daemon's trap or sleep lines ever move, this probe would build an
    # empty loop and pass without testing anything.
    if ! grep -q 'wait \$!' "$dir/loop.sh" || ! grep -q '_shutdown_once' "$dir/loop.sh"; then
        rm -rf "$dir"; echo "PROBE DID NOT FIND THE LOOP"; return 0
    fi
    "$dir/loop.sh" & local pid=$!
    sleep 0.5
    local start; start="$(date +%s)"
    kill -TERM "$pid" 2>/dev/null
    local waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do sleep 0.5; waited=$(( waited + 1 )); done
    local took=$(( $(date +%s) - start ))
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        echo "STILL RUNNING after ${took}s"
    else
        # Promptly = well inside the 30s sleep this loop is sitting in, which is
        # the thing that used to hold the signal.
        (( took < 5 )) && echo -n "exited promptly (${took}s), " || echo -n "exited LATE (${took}s), "
        echo "handler ran $(grep -c released "$dir/ran" 2>/dev/null || echo 0) time(s)"
    fi
    rm -rf "$dir"
}
_term_result="$(_term_probe)"
assert_contains "SIGTERM during the sleep stops the daemon" "$_term_result" "exited"
assert_contains "and it stops without waiting out the interval" "$_term_result" "exited promptly"
# EXIT fires too when the handler exits, so the release must be idempotent or it
# runs twice and logs a VIP release twice on every stop.
assert_contains "the shutdown release runs exactly once" "$_term_result" "handler ran 1 time(s)"

# Settings were written unconditionally on every pull, and writing anything at
# all restarts FTL -- so a payload whose settings already matched still cost a
# restart, which on the VIP holder is ~10s of answering unfiltered while gravity
# reloads. It also made any change to the synced KEY SET look like a config
# change on every node at once.
_settings_probe() {   # $1 = value this node already has
    local dir; dir="$(mktemp -d)"
    printf '{"dns.blockTTL":"2"}' > "$dir/settings.json"
    P_CUR="$1" STAGING_DIR="$dir" bash -c '
        COMP_SETTINGS=true
        log_info() { echo "INFO $*"; }; log_warn() { :; }; log_error() { echo "ERROR $*"; }
        pihole-FTL() {
            # read: report what this node holds; write: succeed
            [[ $# -eq 2 ]] && { printf "%s" "$P_CUR"; return 0; }
            return 0
        }
        SETTINGS_APPLIED=false; APPLIED_SOMETHING=false; APPLY_FAILED=false
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" apply_settings)"'
        apply_settings
        echo "restart_needed=$SETTINGS_APPLIED"
    '
    rm -rf "$dir"
}
assert_contains "settings identical to ours are not rewritten" \
    "$(_settings_probe 2)" "status=unchanged"
assert_contains "and nothing identical triggers an FTL restart" \
    "$(_settings_probe 2)" "restart_needed=false"
assert_contains "a genuinely different setting is applied" \
    "$(_settings_probe 999)" "status=ok"
assert_contains "and that one does restart FTL" \
    "$(_settings_probe 999)" "restart_needed=true"

# FTL answers before it has finished loading gravity, so a node that just
# restarted is briefly not blocking. Reporting that as broken notifies on every
# sync that swaps the blocklist.
_age_probe() {   # $1 = seconds since pihole-FTL started
    P_AGE="$1" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        pihole-FTL() {
            case "$*" in
                *"dns.blocking.active"*) printf "true" ;;
                *g.domain*)              printf "a.test\nb.test\nc.test\n" ;;
                *"count(*) FROM adlist_by_group"*) printf "32" ;;
                *"FROM adlist WHERE"*)   printf "17" ;;
            esac
        }
        pgrep() { echo 4242; }
        ps() { printf "%s\n" "$P_AGE"; }
        ip() { printf "1: lo inet 127.0.0.1/8 scope host lo\n"; }
        dig() { printf "93.184.1.1\n"; }   # every canary domain resolves: broken
        blocking_canary /dev/null
    '
}
assert_eq "a node whose FTL just restarted is not called broken" "unknown" "$(_age_probe 5)"
assert_contains "once FTL has settled the verdict stands" "$(_age_probe 600)" "broken:"
# ============================================================
# A pause is local, and the publisher role must not move on one missed check
# ------------------------------------------------------------
# Reported after running v3.18.1 on two nodes (Discourse 86667 #113).
#
# dns.blocking.active was in the synced settings, so pausing the publisher
# published the pause. A build inside a 5-minute pause left a standby paused for
# half an hour -- answering ad domains with real IPs while reporting itself
# "paused", which every filtering health check reads as healthy-by-choice.
_sync_keys="$(cat "$SCRIPT_DIR/../pihole-ha-sync")"
assert_not_contains "a pause is not a synced setting" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync" export_settings)$(sed -n '/^SETTINGS_KEYS=(/,/^)/p' "$SCRIPT_DIR/../pihole-ha-sync")" \
    "dns.blocking.active"
# And a node on an older version will still send one, so refuse it on arrival.
assert_contains "an arriving pause is refused, whoever sent it" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" '"$_skey" == "dns.blocking.active"'
# Upstreams stay out by default -- a node resolving through its own unbound must
# not be pointed at an unbound it does not have -- but can be opted in.
assert_not_contains "upstreams are not synced by default" \
    "$(sed -n '/^SETTINGS_KEYS=(/,/^)/p' "$SCRIPT_DIR/../pihole-ha-sync")" "dns.upstreams"
# The opt-in ships upstreams as their own JSON file, NOT through the scalar
# settings: FTL prints an array as "[ a, b ]" and parses a written one as JSON
# (src/config/cli.c), so a value taken from the settings list is refused by
# every standby. Confirmed against live FTL: writing back its own display form
# exits 2, writing the JSON form is accepted. That is what 3.19.0 shipped, and
# why a reporter saw his secondaries keep the old list.
assert_contains "upstreams are staged as their own JSON file" "$_sync_keys" 'ftl_to_json > "$STAGING_DIR/dns-upstreams.json"'
assert_contains "and only when the cluster opted in"          "$_sync_keys" '[[ "$SYNC_UPSTREAMS" == "true" ]]'
assert_contains "a change to them triggers a build"           "$_sync_keys" '"$SYNC_UPSTREAMS" == "true" ]] && pihole-FTL --config dns.upstreams'
assert_not_contains "upstreams never ride in the scalar settings" "$_sync_keys" 'SETTINGS_KEYS+=(dns.upstreams)'
assert_contains "the standby applies them as an array" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" "apply_array_key true dns.upstreams dns-upstreams.json"
# apply_array_key refuses an empty list, so sync can never leave a node with no
# resolvers at all.
assert_contains "an empty upstream list is refused like the other arrays" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha-sync-pull" apply_array_key)" "_json_is_empty"

# A mistyped toggle used to sit in sync.conf doing nothing at all.
_typo_probe() {
    local conf; conf="$(mktemp)"
    printf 'SYNC_ENABLED=true
SYNC_UPTREAMS=true
' > "$conf"
    P_CONF="$conf" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        log_warn() { echo "WARN $*"; }
        load_sync_conf "$P_CONF"
        echo "enabled=$SYNC_ENABLED upstreams=${SYNC_UPSTREAMS:-unset}"
    '
    rm -f "$conf"
}
assert_contains "a mistyped sync toggle is reported" "$(_typo_probe)" "sync_conf_unknown_key key=SYNC_UPTREAMS"
assert_contains "and the rest of the file still loads" "$(_typo_probe)" "enabled=true"
# A key the loader does not know is silently ignored, which is worse than an error.
assert_contains "the loader accepts the new toggle" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha-platform" load_sync_conf)" "SYNC_UPSTREAMS"

# The publisher role moved on the first missed check, and each hand-off costs a
# build, a pull and an FTL restart on both sides -- a dropped query when it lands
# on the node holding the VIP.
_pub_probe() {   # $1 fails recorded, $2 currently alive (yes/no)
    P_FAILS="$1" P_ALIVE="$2" bash -c '
        PUBLISH_AFTER=3
        declare -A publish_fail
        publish_fail[10.0.0.2]="$P_FAILS"
        is_alive_for_publish() { [[ "$P_ALIVE" == yes ]]; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" can_publish)"'
        can_publish 10.0.0.2 && echo KEEPS || echo DROPS
    '
}
assert_eq "a single missed check does not move the publisher" "KEEPS" "$(_pub_probe 1 no)"
assert_eq "two missed checks still do not"                    "KEEPS" "$(_pub_probe 2 no)"
assert_eq "the third consecutive miss does"                   "DROPS" "$(_pub_probe 3 no)"
assert_eq "a node that answers again can publish at once"     "KEEPS" "$(_pub_probe 9 yes)"
assert_contains "the role election uses the debounced view" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha" acting_primary_ip)" "can_publish"
assert_contains "the counter is updated once per cycle" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "update_publish_liveness"
assert_contains "recovery resets the counter" \
    "$(extract_fn "$SCRIPT_DIR/../pihole-ha" update_publish_liveness)" 'publish_fail[$ip]=0'

# A node's identity must never be taken from a floating VIP: it lands in
# nodes.conf, auth.conf's keys and sync.conf, and the node then fails to find
# itself in its own cluster. The route source address is exactly what a VIP
# holder answers with, so these all feed it a VIP and expect the real address.
_ip_detect() {   # $1 = `ip -o -4 addr show` output
    ADDRS="$1" bash -c '
        ip() {
            case "$*" in
                *"route show default"*) echo "default via 10.0.0.1 dev eth0 proto static" ;;
                *"route get"*)          echo "10.0.0.1 dev eth0 src 10.0.4.1 uid 0" ;;
                *"addr show"*)          printf "%s\n" "$ADDRS" ;;
            esac
        }
        '"$(sed -n '/^detect_local_ip()/,/^}/p' "$SCRIPT_DIR/../install.sh")"'
        detect_local_ip
    '
}
assert_eq "a /32 VIP is not taken as this node's address" "10.0.4.7" \
    "$(_ip_detect '2: eth0    inet 10.0.4.7/24 brd 10.0.4.255 scope global eth0
2: eth0    inet 10.0.4.1/32 scope global eth0')"
# keepalived's VIP: same LAN, narrower prefix, no kernel flag. Order carries it.
assert_eq "a same-LAN keepalived VIP is not taken either" "10.0.4.7" \
    "$(_ip_detect '2: eth0    inet 10.0.4.7/22 brd 10.0.7.255 scope global eth0
2: eth0    inet 10.0.4.1/24 scope global eth0')"
# ...and when it is listed first, the kernel's own "secondary" flag carries it.
assert_eq "a secondary-flagged VIP listed first is skipped" "10.0.4.7" \
    "$(_ip_detect '2: eth0    inet 10.0.4.1/24 scope global secondary eth0:vip
2: eth0    inet 10.0.4.7/22 brd 10.0.7.255 scope global eth0')"
# A node whose only address is a /32 really does have that address.
assert_eq "a /32-only interface still yields an address" "10.0.4.1" \
    "$(_ip_detect '2: eth0    inet 10.0.4.1/32 scope global eth0')"

_inst="$(cat "$SCRIPT_DIR/../install.sh")"
assert_contains "the detected node IP is offered for correction" "$_inst" "This node's IP ["
assert_contains "a corrected IP must exist on this machine"      "$_inst" "Not an address on this machine"
# Repointing someone's resolver is not a thing to report after doing it.
assert_contains "the unbound switch is asked, not assumed"  "$_inst" "Point Pi-hole's upstream DNS at it"
assert_contains "the summary says what will happen to upstream" "$_inst" "will be set to local unbound"
assert_contains "declining is honoured"                      "$_inst" 'set_unbound_upstream" == "true"'

# ============================================================
# A blocklist that blocks nothing must not spread, and must be noticed
# ------------------------------------------------------------
# Every check on a payload asks whether the FILE arrived intact: signature,
# manifest checksum, config-version direction. A wiped-but-valid gravity.db
# passes all of them -- right checksum, new hash, therefore a NEWER version --
# and installs over the last good copy in the cluster. Reported against another
# sync tool after a double gravity rebuild emptied a primary and a house ran
# unfiltered for a day (Discourse 86667 #106, lovelaze/nebula-sync#271).
_sane_probe() {   # $1 gravity rows, $2 enabled adlists ("-" = table unreadable)
    # A real (non-empty) file: the helper rejects an empty one on sight, which
    # would make every case below pass for the wrong reason.
    local db; db="$(mktemp)"; printf 'not-really-sqlite' > "$db"
    P_DB="$db" P_DOM="$1" P_ADS="$2" P_MAPS="${3:-32}" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        pihole-FTL() {
            case "$*" in
                *adlist_by_group*) [[ "$P_MAPS" == "-" ]] || printf "%s" "$P_MAPS" ;;
                *"FROM gravity"*)  [[ "$P_DOM" == "-" ]] || printf "%s" "$P_DOM" ;;
                *"FROM adlist"*)   [[ "$P_ADS" == "-" ]] || printf "%s" "$P_ADS" ;;
            esac
        }
        out="$(gravity_is_sane "$P_DB")" && echo "SANE" || echo "REFUSE: $out"
    '
    rm -f "$db"
}
assert_contains "a populated blocklist is accepted"        "$(_sane_probe 120000 14)" "SANE"
assert_contains "no domains with adlists enabled is refused" "$(_sane_probe 0 14)" "REFUSE"
assert_contains "the refusal says what is wrong"           "$(_sane_probe 0 14)" "no blocked domains"
# Someone with no lists enabled has an empty blocklist on purpose.
assert_contains "no domains and no enabled adlists is fine" "$(_sane_probe 0 0)" "SANE"
assert_contains "a missing gravity table is refused"        "$(_sane_probe - 14)" "REFUSE"
assert_contains "a missing adlist table is refused"         "$(_sane_probe 5 -)" "REFUSE"
# Never turn "cannot check" into "refuse to sync".
assert_contains "no pihole-FTL means no opinion" \
    "$(bash -c 'source "'"$SCRIPT_DIR"'/../pihole-ha-platform"; gravity_is_sane /dev/null && echo SANE')" "SANE"

# A blocklist with domains but no group mappings applies to nobody: `pihole -g`
# after a wipe rebuilds the gravity table and not the mappings, so a half-repaired
# node looks fully stocked and blocks nothing. Verified against a real 2.4M-row
# database with adlist_by_group emptied.
assert_contains "domains with no group mappings are refused" "$(_sane_probe 2394709 17 0)" "REFUSE"
assert_contains "the refusal says nothing is assigned to a group" \
    "$(_sane_probe 2394709 17 0)" "none is assigned to a group"
assert_contains "mappings present is accepted"           "$(_sane_probe 2394709 17 32)" "SANE"
# No enabled lists at all is someone blocking by regex or denylist only.
assert_contains "no enabled adlists and no mappings is fine" "$(_sane_probe 0 0 0)" "SANE"
# Cannot read the mapping table: no opinion, same rule as everywhere else here.
assert_contains "an unreadable mapping table is not a refusal" "$(_sane_probe 2394709 17 -)" "SANE"

assert_contains "the publisher checks before shipping a blocklist" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync")" 'gravity_is_sane /etc/pihole/gravity.db'
assert_contains "the publisher refuses rather than publishing it" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync")" "refusing to publish this blocklist"
assert_contains "the standby checks the staged copy before installing" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" 'gravity_is_sane "$STAGING_DIR/gravity.db"'
assert_contains "the standby keeps its own copy instead" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")" "keeping the one this node already has"

# The canary. ping, :53, the API and DHCP all pass on a Pi-hole that answers
# everything instead of blocking it.
_canary_probe() {   # $1 blocking.active, $2 domains (space separated), $3.. answers per domain
    local active="$1" domains="$2"; shift 2
    P_ACTIVE="$active" P_DOMAINS="$domains" P_ANSWERS="$*" P_ADS="${P_ADS:-17}" P_MAPS="${P_MAPS:-32}" bash -c '
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        pihole-FTL() {
            case "$*" in
                *"dns.blocking.active"*) printf "%s" "$P_ACTIVE" ;;
                *client_by_group*)       : ;;
                *g.domain*)              printf "%s\n" $P_DOMAINS ;;
                *"count(*) FROM adlist_by_group"*) printf "%s" "${P_MAPS:-32}" ;;
                *"FROM adlist WHERE"*)   printf "%s" "${P_ADS:-17}" ;;
                *"FROM gravity"*)        printf "%s\n" $P_DOMAINS ;;
            esac
        }
        ip() { printf "1: lo inet 127.0.0.1/8 scope host lo\n"; }
        dig() {
            local want="${*: -2}"; want="${want%% *}"
            local i=1 d
            for d in $P_DOMAINS; do
                if [[ "$d" == "$want" ]]; then
                    local a; a="$(printf "%s\n" $P_ANSWERS | sed -n "${i}p")"
                    [[ "$a" == "NONE" ]] || printf "%s\n" "$a"
                    return 0
                fi
                i=$(( i + 1 ))
            done
        }
        blocking_canary /dev/null
    '
}
assert_eq "blocking switched off is not a fault" "paused" \
    "$(_canary_probe false "a.test b.test c.test" NONE NONE NONE)"
assert_contains "a blocklist that resolves is reported broken" \
    "$(_canary_probe true "a.test b.test c.test" 93.184.1.1 104.18.2.2 NONE)" "broken:"
assert_contains "the reason names a domain and what it resolved to" \
    "$(_canary_probe true "a.test b.test c.test" 93.184.1.1 104.18.2.2 NONE)" "resolves to"
assert_eq "null-route answers read as blocking"  "ok" \
    "$(_canary_probe true "a.test b.test c.test" 0.0.0.0 0.0.0.0 0.0.0.0)"
# NXDOMAIN mode: a block looks like no answer at all.
assert_eq "empty answers read as blocking"       "ok" \
    "$(_canary_probe true "a.test b.test c.test" NONE NONE NONE)"
# One resolving domain is an allowlist entry as easily as a fault: say nothing.
assert_eq "a single resolving domain is inconclusive" "unknown" \
    "$(_canary_probe true "a.test b.test c.test" 93.184.1.1 NONE NONE)"
assert_eq "IP mode answers with our own address read as blocking" "ok" \
    "$(_canary_probe true "a.test b.test c.test" 127.0.0.1 127.0.0.1 NONE)"
# Nothing to sample has two causes and they are not the same fault. No mappings
# at all: the node blocks nothing and must say so, because "unknown" notifies
# nobody -- a mappings wipe on the reporter's backup node let doubleclick.net
# through while this read as no opinion. Mappings that just do not cover THIS
# client is an ordinary per-group setup and untestable from here.
assert_contains "enabled lists with no mappings at all is broken" \
    "$(P_ADS=17 P_MAPS=0 _canary_probe true "")" "broken:"
assert_eq "mappings that miss this client stay unknown" "unknown" \
    "$(P_ADS=17 P_MAPS=32 _canary_probe true "")"
assert_eq "no enabled lists at all stays unknown" "unknown" \
    "$(P_ADS=0 P_MAPS=0 _canary_probe true "")"

# A refused publish used to be silent: an error line, a build time that stops
# moving, and no notification, so a cluster could sit un-synced unnoticed.
_sync_src="$(cat "$SCRIPT_DIR/../pihole-ha-sync")"
assert_contains "a refused publish notifies"        "$_sync_src" "NOTIFY_TAG=sync_refused"
assert_contains "the refusal is logged as its own event" "$_sync_src" "event=build_refused"
assert_contains "losing every adlist is refused"    "$_sync_src" "every adlist is now disabled"
assert_contains "the refusal names the way out"     "$_sync_src" "pihole-ha-sync --force"
assert_contains "--force still publishes"           "$_sync_src" '[[ -z "$_refuse" && "$FORCE" != "true" ]]'
# The baseline must only move on a publish that actually happened, or a refusal
# rewrites the history it is compared against.
assert_contains "the adlist baseline is written after the build" "$_sync_src" 'ADLIST_COUNT_FILE'
assert_contains "the new refusal tag is registered" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" "sync_refused"

assert_contains "the daemon keeps the canary off the per-cycle path" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "BLOCKING_EVERY"
assert_contains "a node that stops blocking says so" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "event=blocking_broken"
assert_contains "the state reaches the panel and the bundle" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" '"blocking":"%s"'
# A tag nothing knows about cannot be muted, and the panel rejects the save.
assert_contains "the new notification tag is registered" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-dash")" 'blocking_broken'
assert_contains "diagnostics report blocking per node" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-debug")" "NOT BLOCKING"

# ============================================================
# A priority-order change must reach every node, or heal itself
# ------------------------------------------------------------
# The panel announced a new order once, in the background, to each peer, and
# reported success whatever happened. A node busy for those few seconds missed
# it and kept the old order forever: config sync carries gravity, DNS, DHCP and
# settings, never HA_NODES, so nothing else was ever going to correct it. A
# three-node cluster ran split until its owner hand-edited the file (Discourse
# 86667 #100). Nodes now converge on the highest generation.
_order_probe() {   # $1 local HA_NODES, $2 local gen, $3 from, $4 peer gen, $5 peer order
    local conf; conf="$(mktemp)"
    printf 'GATEWAY=10.0.0.1\nHA_NODES=%s\nNODES_GEN=%s\nVIP=10.0.0.9\n' "$1" "$2" > "$conf"
    NODES_CONF="$conf" HA_NODES="$1" NODES_GEN="$2" \
    P_FROM="$3" P_GEN="$4" P_ORDER="$5" bash -c '
        log_warn() { :; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" adopt_node_order)"'
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" _write_nodes_gen)"'
        adopt_node_order "$P_FROM" "$P_GEN" "$P_ORDER" || echo "REFUSED"
        sed -n "s/^HA_NODES=//p;s/^NODES_GEN=/gen /p" "$NODES_CONF" | tr "\n" " "
    '
    rm -f "$conf"
}
assert_contains "a newer order from a peer is adopted" \
    "$(_order_probe "10.0.0.1,10.0.0.2,10.0.0.3" 4 10.0.0.2 7 "10.0.0.3,10.0.0.1,10.0.0.2")" \
    "10.0.0.3,10.0.0.1,10.0.0.2 gen 7"
# An entry may carry that node's web port, which is ours to know and not in the
# peer's gift: adopting its text wholesale could drop the port we reach it on.
assert_contains "adopting an order keeps our own port annotations" \
    "$(_order_probe "10.0.0.1:8080,10.0.0.2,10.0.0.3" 1 10.0.0.2 2 "10.0.0.3,10.0.0.1,10.0.0.2")" \
    "10.0.0.3,10.0.0.1:8080,10.0.0.2"
assert_contains "an order over a different membership is refused" \
    "$(_order_probe "10.0.0.1,10.0.0.2,10.0.0.3" 1 10.0.0.2 9 "10.0.0.4,10.0.0.1,10.0.0.2")" "REFUSED"
assert_contains "a shorter list is refused" \
    "$(_order_probe "10.0.0.1,10.0.0.2,10.0.0.3" 1 10.0.0.2 9 "10.0.0.2,10.0.0.1")" "REFUSED"
# Same order at a newer generation: nothing to rewrite, but record the
# generation or we ask the same peer the same question forever.
assert_contains "an identical order still advances our generation" \
    "$(_order_probe "10.0.0.1,10.0.0.2" 3 10.0.0.2 8 "10.0.0.1,10.0.0.2")" "10.0.0.1,10.0.0.2 gen 8"

_reconcile_probe() {   # $1 local gen, $2..: "gen|order" per peer reply
    P_GEN="$1"; shift
    P_R1="${1:-}" P_R2="${2:-}" P_LOCALGEN="$P_GEN" bash -c '
        NODE_COUNT=3; LOCAL_IP=10.0.0.1; NODES=(10.0.0.1 10.0.0.2 10.0.0.3)
        HA_NODES="10.0.0.1,10.0.0.2,10.0.0.3"; NODES_GEN="$P_LOCALGEN"; HEALTH_TIMEOUT=1
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        curl() {
            local url="${*: -1}"
            case "$url" in
                *10.0.0.2*) [[ -n "$P_R1" ]] || return 1
                            printf "{\"nodes\":\"%s\",\"gen\":%s}" "${P_R1#*|}" "${P_R1%%|*}" ;;
                *10.0.0.3*) [[ -n "$P_R2" ]] || return 1
                            printf "{\"nodes\":\"%s\",\"gen\":%s}" "${P_R2#*|}" "${P_R2%%|*}" ;;
            esac
        }
        adopt_node_order() { echo "ADOPT from=$1 gen=$2 order=$3"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" reconcile_node_order)"'
        reconcile_node_order
    '
}
assert_contains "a peer holding a newer order is adopted from" \
    "$(_reconcile_probe 2 "5|10.0.0.2,10.0.0.1,10.0.0.3")" "ADOPT from=10.0.0.2 gen=5"
assert_eq "an equal generation is left alone" "" "$(_reconcile_probe 5 "5|10.0.0.2,10.0.0.1,10.0.0.3")"
assert_eq "an older generation is left alone"  "" "$(_reconcile_probe 9 "5|10.0.0.2,10.0.0.1,10.0.0.3")"
assert_eq "a peer that does not answer is skipped" "" "$(_reconcile_probe 1)"
assert_contains "a silent peer does not stop us reading the next one" \
    "$(_reconcile_probe 1 "" "4|10.0.0.3,10.0.0.1,10.0.0.2")" "ADOPT from=10.0.0.3 gen=4"
# An old node answers this endpoint without a generation. Treat that as nothing
# to learn, never as generation zero.
assert_eq "a peer with no generation is ignored" "" \
    "$(P_LOCALGEN=0 bash -c '
        NODE_COUNT=2; LOCAL_IP=10.0.0.1; NODES=(10.0.0.1 10.0.0.2)
        HA_NODES="10.0.0.1,10.0.0.2"; NODES_GEN=0; HEALTH_TIMEOUT=1
        source "'"$SCRIPT_DIR"'/../pihole-ha-platform"
        curl() { printf "{\"nodes\":\"10.0.0.2,10.0.0.1\"}"; }
        adopt_node_order() { echo "ADOPT"; }
        '"$(extract_fn "$SCRIPT_DIR/../pihole-ha" reconcile_node_order)"'
        reconcile_node_order')"
assert_contains "the daemon reconciles the order every cycle" \
    "$(cat "$SCRIPT_DIR/../pihole-ha")" "reconcile_node_order      # adopt"

_dash_prio="$(cat "$SCRIPT_DIR/../pihole-ha-dash")"
assert_contains "the order endpoint advertises its generation" "$_dash_prio" '"nodes":"%s","gen":%s'
assert_contains "an announcement that is not newer is ignored"  "$_dash_prio" '"ignored":"not newer"'
assert_contains "a new order outranks every generation in the cluster" "$_dash_prio" '_prio_gen=$(( _prio_gen + 1 ))'
assert_contains "the announcement carries the generation" "$_dash_prio" 'gen=$_prio_gen&propagated=1'
assert_contains "diagnostics compare the order across nodes" \
    "$(cat "$SCRIPT_DIR/../pihole-ha-debug")" "DIFFERENT ORDER"

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
# The DHCP branch releases inline rather than through stand_down, because it
# draws a distinction stand_down deliberately does not: the configured master
# keeps serving DHCP when HA is switched off, so the kill switch never takes
# DHCP off the LAN by itself. The VIP is always released — it is a floating
# address, and a frozen holder can never yield it.
_ha_off="${_ha_loop#*if [[ \"\$HA_ENABLED\" != \"true\" \]]; then}"
_ha_off="${_ha_off%%write_status \"HA disabled\"*}"
assert_contains "HA_ENABLED=false releases the VIP"            "$_ha_off" 'remove_vip'
assert_contains "HA_ENABLED=false hands DHCP back"             "$_ha_off" 'set_dhcp false'
assert_contains "but only on a node that is not the master"    "$_ha_off" 'am_configured_master'
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
echo
echo "=== The manifest is signed, not just the payload ==="

PLAT_SRC="$SCRIPT_DIR/../pihole-ha-platform"
eval "$(extract_fn "$PLAT_SRC" platform_sync_hmac)"
eval "$(extract_fn "$PLAT_SRC" platform_sync_manifest_canon)"

if command -v openssl >/dev/null 2>&1; then
    _sd="$(mktemp -d)"
    openssl rand -hex 32 > "$_sd/key"
    echo "payload-bytes" > "$_sd/payload"
    _psig="$(platform_sync_hmac "$_sd/key" < "$_sd/payload")"

    # ts hash ver md5 size payload_sig gravity dhcp dns settings notify syncconf
    _msig() { platform_sync_manifest_canon "2026-09-20T10:00:00" "abc123" "$1" "md5x" "14" "${3:-$_psig}" \
                  "$2" true true true true true | platform_sync_hmac "$_sd/key"; }
    _good="$(_msig 7 true)"

    assert_eq "publisher and puller derive the same manifest signature" "$_good" "$(_msig 7 true)"

    # The rollback / version-wedge attack: replay a validly signed payload under
    # a forged config_version. This is what the payload-only signature allowed.
    assert_false "a forged config_version no longer verifies" [ "$_good" = "$(_msig 999999 true)" ]
    # Silent component suppression: clear one flag and the standby stops getting
    # that component while still recording itself up to date.
    assert_false "a flipped component flag no longer verifies" [ "$_good" = "$(_msig 7 false)" ]
    # The manifest must be bound to the tarball it describes.
    assert_false "swapping in another payload's signature fails" [ "$_good" = "$(_msig 7 true deadbeef)" ]

    # C6: a truncated or empty key must not silently become a key everyone knows.
    : > "$_sd/empty"
    assert_false "an empty cluster.key produces no signature" platform_sync_hmac "$_sd/empty"
    printf 'short\n' > "$_sd/short"
    assert_false "a too-short cluster.key is refused"         platform_sync_hmac "$_sd/short"
    assert_false "a missing cluster.key produces no signature" platform_sync_hmac "$_sd/nope"
    rm -rf "$_sd"
else
    echo "  SKIP  openssl not available"
fi

_syncsrc="$(cat "$SCRIPT_DIR/../pihole-ha-sync")"
_pullsrc="$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")"
# Appended, not substituted: a puller from before this change greps only
# "signature", so an upgraded publisher must keep working for it.
assert_contains "the payload signature field is still published" "$_syncsrc" '"signature":"%s"'
assert_contains "the manifest signature is published alongside"  "$_syncsrc" '"manifest_sig":"%s"'
# C4: the version-adopt shortcut ran before any verification, so one spoofed
# manifest could pin sync-version high and freeze the node permanently.
_verify_at="$(grep -n 'manifest signature invalid' <<< "$_pullsrc" | head -1 | cut -d: -f1)"
_adopt_at="$(grep -n 'event=version_adopt' <<< "$_pullsrc" | head -1 | cut -d: -f1)"
assert_true "the manifest is verified before a version is adopted" [ "$_verify_at" -lt "$_adopt_at" ]
_download_at="$(grep -n 'api/sync/payload' <<< "$_pullsrc" | head -1 | cut -d: -f1)"
assert_true "and before the payload is downloaded"                 [ "$_verify_at" -lt "$_download_at" ]
# A missing openssl used to warn and apply anyway -- the one case where the
# operator had explicitly asked for verification.
assert_contains "a missing openssl now rejects instead of warning" "$_pullsrc" "refusing to apply a payload this node cannot verify"
assert_not_contains "the old fail-open warning is gone"            "$_pullsrc" "payload NOT verified"

# ============================================================
echo
echo "=== Pushover credentials stay off the unauthenticated payload ==="

# /api/sync/payload is an unauthenticated read endpoint, so everything in the
# tarball is LAN-readable. notify.conf carried PO_USER/PO_TOKEN in cleartext.
assert_contains "the publisher strips the credentials"   "$_syncsrc" "grep -vE '^(PO_USER|PO_TOKEN)=' /etc/pihole-ha/notify.conf > \"\$STAGING_DIR/notify.conf\""
assert_contains "change detection uses the same filter"  "$_syncsrc" "grep -vE '^(PO_USER|PO_TOKEN)=' /etc/pihole-ha/notify.conf 2>/dev/null | md5sum"
# A plain cp would now wipe every standby's credentials on the first pull.
assert_contains "the puller merges instead of overwriting" "$_pullsrc" 'notify.conf.merged'
assert_contains "the puller keeps this node's PO_USER"     "$_pullsrc" "_po_user="
assert_not_contains "the puller no longer clamps it to 0600" "$_pullsrc" 'chmod 600 /etc/pihole-ha/notify.conf'
assert_contains "the puller preserves 0640 root:pihole"      "$_pullsrc" 'chmod 640 /etc/pihole-ha/notify.conf'

# The filter itself has to keep the settings and drop only the secrets.
_nc="$(mktemp)"
printf 'PO_ENABLED=true\nPO_USER=uSecret\nPO_TOKEN=tSecret\nPO_TITLE=ha\nDHCP_NOTIFY_ENABLED=true\n' > "$_nc"
_filtered="$(grep -vE '^(PO_USER|PO_TOKEN)=' "$_nc")"
assert_not_contains "the user is not shipped"      "$_filtered" "uSecret"
assert_not_contains "the token is not shipped"     "$_filtered" "tSecret"
assert_contains     "the settings still ship"      "$_filtered" "PO_ENABLED=true"
assert_contains     "the DHCP toggle still ships"  "$_filtered" "DHCP_NOTIFY_ENABLED=true"
rm -f "$_nc"

# The dash writes this file too, and did so at the default umask.
_dashsrc="$(cat "$SCRIPT_DIR/../pihole-ha-dash")"
assert_eq "every dash write creates notify.conf before filling it" "3" \
    "$(grep -c 'umask 027; : > "\$_NOTIFY_CONF"' <<< "$_dashsrc")"

# ============================================================
echo
echo "=== Failover counters and the HA kill-switch ==="

# ACTIVATE_AFTER is documented as "consecutive failed checks", but activate_count
# was only cleared after N healthy ticks in a row while any single unhealthy tick
# incremented it -- so 50% packet loss accumulated into a takeover.
_simulate() {   # $1 = pattern of u/d ticks, $2 = ACTIVATE_AFTER -> "TAKEOVER" or "held"
    local pattern="$1" after="$2" a=0 st=0 i c
    for (( i=0; i<${#pattern}; i++ )); do
        c="${pattern:$i:1}"
        if [[ "$c" == "d" ]]; then
            (( a++ ))
            (( a >= after )) && { echo "TAKEOVER"; return; }
        else
            a=$(( a > 0 ? a - 1 : 0 ))
            (( st++ ))
            (( st >= after )) && { a=0; st=0; }
        fi
    done
    echo "held"
}
assert_eq "alternating up/down does not take over"   "held"     "$(_simulate "dududududu" 2)"
assert_eq "two failures in a row still take over"    "TAKEOVER" "$(_simulate "udd" 2)"
assert_eq "a sustained outage still takes over"      "TAKEOVER" "$(_simulate "uuuddd" 2)"
assert_eq "one glitch alone never takes over"        "held"     "$(_simulate "uuuduuu" 2)"

_hasrc="$(cat "$SCRIPT_DIR/../pihole-ha")"
assert_contains "the daemon decays activation progress" "$_hasrc" 'activate_count=$(( activate_count > 0 ? activate_count - 1 : 0 ))'
# One ICMP packet was a full "node down" verdict.
assert_contains "peer health sends more than one ping"  "$_hasrc" 'ping -c2'

# The kill-switch froze a node in place -- including while it held DHCP and the
# VIP, which is how a partially-propagated toggle produced two DHCP servers.
eval "$(extract_fn "$SCRIPT_DIR/../pihole-ha" am_configured_master)"
NODES=("10.33.47.55" "10.33.47.3")

DHCP_MASTER="auto"; LOCAL_IP="10.33.47.55"; MY_IDX=0
assert_true  "index 0 is the configured master in auto mode"  am_configured_master
DHCP_MASTER="auto"; LOCAL_IP="10.33.47.3";  MY_IDX=1
assert_false "a standby is not, in auto mode"                 am_configured_master
DHCP_MASTER="10.33.47.3"
assert_true  "a pinned node is the configured master"         am_configured_master
DHCP_MASTER="10.33.47.55"
assert_false "a node that is not the pin is not"              am_configured_master
# A pin naming a departed node must fall back to priority, not strand the role.
DHCP_MASTER="10.33.47.99"; LOCAL_IP="10.33.47.55"; MY_IDX=0
assert_true  "a stale pin falls back to priority order"       am_configured_master

# The VIP follows the same rule as DHCP: the configured master keeps what it is
# serving, everyone else hands it back. Releasing it on every node would take DNS
# off the network, because dhcp-option=6 is the VIP alone whenever one is set.
# The exception is a master that cannot answer DNS itself — the one case where a
# live peer rightly claims the same address and a frozen holder cannot yield.
assert_contains "disabling HA releases the VIP off the master" \
    "$_hasrc" 'if ! am_configured_master || ! is_dns_healthy "$LOCAL_IP"; then
            has_vip && remove_vip'
assert_contains "and stands a serving standby down" "$_hasrc" 'event=ha_disabled_standdown'

# ============================================================
echo
echo "=== Homelab reliability: shutdown, node removal, clock, disk ==="

_hasrc2="$(cat "$SCRIPT_DIR/../pihole-ha")"
_pullsrc2="$(cat "$SCRIPT_DIR/../pihole-ha-sync-pull")"

# The VIP is added with `ip addr add`, so nothing removes it when the daemon
# goes away. A stop, a `pihole-ha update` or a crash left it bound with no
# process managing it, and another node then claimed the same address.
assert_contains "shutdown releases the VIP"        "$_hasrc2" "event=shutdown_release_vip"
assert_contains "the release is wired to EXIT"      "$_hasrc2" "trap '_shutdown_once' EXIT"
# INT/TERM must EXIT after releasing, not fall back into the loop: that is what
# left systemd waiting out its stop timeout and SIGKILLing the daemon.
assert_contains "and INT/TERM exit after releasing"  "$_hasrc2" "trap '_shutdown_once; exit 0' INT TERM"
# DHCP must NOT be dropped on shutdown: dhcp.active outlives this process, and a
# node that is legitimately the DHCP server should survive a daemon restart.
assert_not_contains "shutdown does not disable DHCP" "$_hasrc2" '_shutdown_release() {
    release_all_sids
    if has_vip; then
        log_info'"'"'
        set_dhcp false'

# Removed from HA_NODES: the election walked NODES past the end of the array,
# which under set -u killed the daemon while it held the VIP, and systemd then
# restart-looped it as an unmanaged second DHCP server.
assert_contains "removal is detected"              "$_hasrc2" "event=removed_from_cluster"
assert_contains "and sets a sentinel index"        "$_hasrc2" "MY_IDX=-1"
assert_contains "the main loop gates on it"        "$_hasrc2" 'if (( MY_IDX < 0 )); then'
assert_contains "and hands DHCP back"              "$_hasrc2" "event=removed_standdown"

# A tuned ACTIVATE_AFTER was reset to the built-in default the first time
# HA_NODES changed -- exactly when the cluster is least stable.
assert_not_contains "the reload path has no hardcoded delay" "$_hasrc2" '            ACTIVATE_AFTER=4'
assert_eq "both paths use the configured base" "2" \
    "$(grep -c 'ACTIVATE_AFTER=\$(( _ACTIVATE_BASE + 2 ))' <<< "$_hasrc2")"

# Wall-clock rate limiting wedges on a Pi with no RTC: the first NTP sync steps
# the clock backwards, `now - last` goes negative, and the limit never expires.
assert_contains     "FTL restart limiting is monotonic" "$_hasrc2" '_mono() {'
assert_contains     "it reads /proc/uptime"             "$_hasrc2" "< /proc/uptime"
assert_not_contains "no wall clock in the rate limit"   "$_hasrc2" 'now="$(date +%s)"'

# master.conf resets to "auto" before parsing, so a dropped final line does not
# mean "no update" -- it means the pin is lost, and then index 0 activates while
# the pinned node also keeps serving.
eval "$(extract_fn "$SCRIPT_DIR/../pihole-ha" load_master)"
eval "$(extract_fn "$SCRIPT_DIR/../pihole-ha-platform" is_valid_ip)"
log_warn() { :; }
_mc="$(mktemp)"; MASTER_CONF="$_mc"
printf 'DHCP_MASTER=10.33.47.3'      > "$_mc"   # no trailing newline
load_master
assert_eq "a pin without a trailing newline survives" "10.33.47.3" "$DHCP_MASTER"
printf 'DHCP_MASTER=10.33.47.3\n'    > "$_mc"
load_master
assert_eq "a normal pin still parses"                 "10.33.47.3" "$DHCP_MASTER"
printf 'DHCP_MASTER=auto\n'          > "$_mc"
load_master
assert_eq "auto is preserved"                         "auto"       "$DHCP_MASTER"
printf 'DHCP_MASTER=not-an-ip\n'     > "$_mc"
load_master
assert_eq "a non-IP pin falls back to auto"           "auto"       "$DHCP_MASTER"
rm -f "$_mc"

# gravity.db: an unchecked cp plus `mv -f` promoted a partial file over a
# working blocklist on a full SD card, and recorded the pull as successful.
assert_contains "the staged copy is checksummed against the manifest" "$_pullsrc2" "does not match the manifest checksum"
assert_contains "a failed copy keeps the old blocklist"               "$_pullsrc2" "could not stage gravity.db"
assert_contains "the copy is flushed before the rename"               "$_pullsrc2" "sync /etc/pihole/gravity.db.tmp"
assert_contains "a failed rename is caught"                           "$_pullsrc2" "could not replace gravity.db"
assert_contains "and any of those failures mark the run failed"       "$_pullsrc2" "APPLY_FAILED=true"

# ============================================================
echo
echo "=== gravity.db ownership: the sidecar cannot name the pihole user ==="

# `chown pihole:pihole` in the sidecar fails -- Alpine has no pihole user -- and
# the failure was swallowed by `|| true`, so the swap promoted a root-owned
# gravity.db that FTL could not open. Reproduced against a live
# pihole/pihole:latest container: "gravityDB_open() - SQL error: unable to open
# database file", then "Cannot read gravity database at /etc/pihole/gravity.db -
# file does not exist or is not readable" every second, /api/groups returning
# database_error, and the web UI showing negative counts in Group management --
# while the pull logged component=gravity status=ok.

# The class, not the one call site: nothing in the shipped scripts may chown by
# name, because the name does not exist where half of them run.
_namechown="$(grep -hnE '^[^#]*chown +[A-Za-z]' \
    "$SCRIPT_DIR/../pihole-ha-sync-pull" \
    "$SCRIPT_DIR/../pihole-ha-sync" \
    "$SCRIPT_DIR/../pihole-ha-platform" \
    "$SCRIPT_DIR/../pihole-ha" \
    "$SCRIPT_DIR/../pihole-ha-dash" \
    "$SCRIPT_DIR/../new-dhcp-device" \
    "$SCRIPT_DIR/../docker/docker-entrypoint.sh" 2>/dev/null)"
assert_eq "nothing chowns by user name" "" "$_namechown"

# notify.conf has the same problem for the same reason: it is created root-owned
# and 0640, and the DHCP hook that reads it runs as FTL's user, so a root:root
# file reads as zero settings and notifications stop without a word.
assert_eq "every notify.conf owner is set through the one helper" "3" \
    "$(grep -c 'platform_chown_notify_conf "\$_NOTIFY_CONF"' "$SCRIPT_DIR/../pihole-ha-dash")"
assert_contains "the pull sets it the same way" "$_pullsrc2" \
    "platform_chown_notify_conf /etc/pihole-ha/notify.conf"

# platform_pihole_owner, against scripted stat answers: no root needed, and
# every branch is reachable (the real files on a dev box are all one owner).
_FAKE_TOML="1000:1000"; _FAKE_GRAV="1000:1000"; _FAKE_DIR="1000:1000"
stat() {
    local v
    case "${3:-}" in
        */pihole.toml) v="$_FAKE_TOML" ;;
        */gravity.db)  v="$_FAKE_GRAV" ;;
        /etc/pihole)   v="$_FAKE_DIR"  ;;
        *) return 1 ;;
    esac
    [[ "$v" == "MISSING" ]] && return 1
    printf '%s' "$v"
}

_FAKE_TOML="1000:1000"; _FAKE_GRAV="0:0"; _FAKE_DIR="1000:1000"
assert_eq "the owner comes from pihole.toml, which FTL writes itself" \
    "1000:1000" "$(platform_pihole_owner)"

# This case IS a node broken by the old bug: gravity.db root-owned, everything
# else intact. Taking the owner from the file we are replacing would copy the
# fault forward and leave blocking off for good.
_FAKE_TOML="MISSING"; _FAKE_GRAV="0:0"; _FAKE_DIR="998:1002"
assert_eq "a root-owned gravity.db never decides the owner" \
    "998:1002" "$(platform_pihole_owner)"

# A package install and a container disagree about the uid (998 vs 1000), and a
# container started with PIHOLE_UID set agrees with neither -- so the answer is
# read off the node, never assumed.
_FAKE_TOML="998:1002"; _FAKE_GRAV="998:1002"; _FAKE_DIR="998:1002"
assert_eq "a package install's uid is honoured too" \
    "998:1002" "$(platform_pihole_owner)"

# Some builds really do run FTL as root. Refusing root would break their sync
# for no reason, so root is the last resort rather than a rejected answer.
_FAKE_TOML="0:0"; _FAKE_GRAV="0:0"; _FAKE_DIR="0:0"
assert_eq "an FTL that genuinely runs as root still gets an answer" \
    "0:0" "$(platform_pihole_owner)"

# Names are what broke this. If stat ever answers with one, it is not an owner.
_FAKE_TOML="pihole:pihole"; _FAKE_GRAV="MISSING"; _FAKE_DIR="1000:1000"
assert_eq "a non-numeric answer is not mistaken for an owner" \
    "1000:1000" "$(platform_pihole_owner)"

_FAKE_TOML="MISSING"; _FAKE_GRAV="MISSING"; _FAKE_DIR="MISSING"
assert_false "no Pi-hole config at all: no answer, so the caller refuses" \
    platform_pihole_owner

# platform_chown_checked: a chown that did nothing must not read as success.
_chownlog="$(mktemp)"
chown() { printf '%s\n' "$*" >> "$_chownlog"; return "${_FAKE_CHOWN_RC:-0}"; }
_FAKE_AFTER="1000:1000"
stat() { printf '%s' "$_FAKE_AFTER"; }

: > "$_chownlog"
assert_false "a name is refused before chown is even called" \
    platform_chown_checked "pihole:pihole" /tmp/x
assert_eq "and chown is not called with it" "" "$(cat "$_chownlog")"

: > "$_chownlog"
_FAKE_CHOWN_RC=0; _FAKE_AFTER="0:0"
assert_false "a chown that silently changed nothing fails" \
    platform_chown_checked "1000:1000" /tmp/x

_FAKE_CHOWN_RC=1; _FAKE_AFTER="1000:1000"
assert_false "a chown that errors fails" \
    platform_chown_checked "1000:1000" /tmp/x

_FAKE_CHOWN_RC=0; _FAKE_AFTER="1000:1000"
assert_true "a chown that took effect passes" \
    platform_chown_checked "1000:1000" /tmp/x

unset -f stat chown
unset _FAKE_CHOWN_RC _FAKE_AFTER _FAKE_TOML _FAKE_GRAV _FAKE_DIR
rm -f "$_chownlog"

# The install side: a blocklist FTL cannot read is worse than yesterday's.
assert_contains "the install resolves the owner numerically"        "$_pullsrc2" '_g_own="$(platform_pihole_owner)"'
assert_contains "and checks the chown instead of ignoring it"       "$_pullsrc2" 'platform_chown_checked "$_g_own" /etc/pihole/gravity.db.tmp'
assert_contains "the mode of the file being replaced is preserved"  "$_pullsrc2" "_g_mode=\"\$(stat -c '%a' /etc/pihole/gravity.db 2>/dev/null)\""
assert_contains "an unreadable blocklist is refused, not installed" "$_pullsrc2" "could not give the new blocklist the ownership FTL needs"

# A node already broken this way would wait for the next blocklist change --
# which may never come -- so the pull repairs it on sight.
_repairsrc="$(awk '/^# Repair a gravity.db that an earlier version/,/^# Check if gravity.db changed/' "$SCRIPT_DIR/../pihole-ha-sync-pull")"
assert_contains "a root-owned gravity.db is repaired on the next pull" "$_repairsrc" "event=repair component=gravity status=ok"
assert_contains "the repair is checked too"                           "$_repairsrc" 'platform_chown_checked "$_own_want" /etc/pihole/gravity.db'
assert_contains "and FTL is told to reopen it"                        "$_repairsrc" "platform_ftl_restart"
assert_contains "a repair that cannot be made is reported"            "$_repairsrc" "event=repair component=gravity status=failed"

# Adlist INSERTs ran before the wholesale gravity swap: discarded, and they
# dirtied the DB before OLD_MD5, forcing a full copy + FTL restart every cycle.
assert_contains "adlists are skipped when gravity is being replaced" "$_pullsrc2" \
    'if [[ -f "$STAGING_DIR/adlists.tsv" && ! ( "$COMP_GRAVITY" == "true" && -f "$STAGING_DIR/gravity.db" ) ]]; then'

# Settings reported status=ok even when every key failed, and recorded the hash,
# so the failure never retried.
assert_contains "a failed settings key is reported"    "$_pullsrc2" "component=settings status=partial"
assert_contains "and marks the run failed"             "$_pullsrc2" 'log_warn "event=apply component=settings key=$_skey status=failed"'
# `(( x++ ))` on an unset variable aborts under set -u -- the counter must exist.
assert_contains "the failure counter is initialised"   "$_pullsrc2" "_settings_failed=0"

# ============================================================
echo
echo "=== The VIP prompt defaults to the better setup in DHCP-HA ==="

# Without a VIP, DHCP-HA failover is only as good as each client's resolver, and
# metrics split across nodes. Requiring the operator to type "yes" made the
# recommended setup the one people skip. DNS-only stays opt-in: a VIP there is
# useless until the operator repoints their own DHCP server at it.
_ins="$(cat "$SCRIPT_DIR/../install.sh")"
# awk, not ${var%%pattern}: the block ends at an `if [[ ... ]]` line, and those
# brackets are a glob bracket expression in a parameter-expansion pattern, which
# silently cut the slice down to nothing and left every assertion below comparing
# two empty strings.
_vip_block="$(awk '/_vip_defaulted="false"$/{f=1} /if \[\[ "\$vip_choice" == "y" \]\]/{f=0} f{print}' "$SCRIPT_DIR/../install.sh")"
[[ -n "$_vip_block" ]] || { echo "  FAIL  could not extract the VIP prompt block"; (( _FAIL++ )); (( _TOTAL++ )); }

# Drive the real block with a stubbed `read`: a function of that name takes
# precedence over the builtin, so this exercises the shipped prompt logic rather
# than a copy of it.
read() { local _n="${!#}"; printf -v "$_n" '%s' "$_FAKE_IN"; }

_ask() {  # $1 = mode, $2 = what the operator typed
    _dhcp_mode="$1" _FAKE_IN="$2" vip_choice="" _vip_defaulted="false"
    eval "$_vip_block" >/dev/null 2>&1
    printf '%s/%s' "$vip_choice" "$_vip_defaulted"
}

assert_eq "DHCP-HA: pressing enter takes the VIP"      "y/true"  "$(_ask dhcp '')"
assert_eq "DHCP-HA: 'no' opts out"                     "n/false" "$(_ask dhcp 'no')"
assert_eq "DHCP-HA: 'n' opts out"                      "n/false" "$(_ask dhcp 'n')"
assert_eq "DHCP-HA: 'yes' is still yes"                "y/false" "$(_ask dhcp 'yes')"
assert_eq "DNS-only: pressing enter declines"          "n/false" "$(_ask dns '')"
assert_eq "DNS-only: 'yes' is required, and accepted"  "y/false" "$(_ask dns 'yes')"
assert_eq "DNS-only: a bare 'y' is not enough"         "n/false" "$(_ask dns 'y')"
unset -f read

assert_contains "the DHCP-HA prompt shows the new default" "$_ins" 'Enable VIP? [YES/no]'
assert_contains "the DNS-only prompt is unchanged" "$_ins" "Enable VIP? (must type 'yes')"

# Pressing enter through a prompt that defaulted to yes, then naming no address,
# is not the same mistake as asking for a VIP and leaving it blank. Only the
# second stops the install.
_vip_addr="${_ins#*Virtual IP (VIP) address (an unused address on this LAN)}"
_vip_addr="${_vip_addr%%--- 11. Summary*}"
assert_contains "a defaulted yes with no address carries on" \
    "$_vip_addr" 'continuing without a VIP'
assert_contains "an explicit yes with no address still stops" "$_vip_addr" 'exit 1'

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
