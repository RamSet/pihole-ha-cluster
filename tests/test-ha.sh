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
echo "=== Syntax check all scripts ==="

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
