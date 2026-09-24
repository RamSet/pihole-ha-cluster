#!/bin/bash
# test-loop.sh — drives the REAL failover loop against fake system tools.
# Run: bash tests/test-loop.sh (no root needed, touches nothing outside a tmpdir)
#
# Why this exists. Every other test in tests/ extracts one function and calls it,
# which cannot reach the decisions the daemon actually makes: those live in the
# main loop, in branches that return early. Two shipped bugs hid exactly there —
# a node that reported "HA disabled" while still holding the VIP, and a
# STANDBY_ONLY release nested inside an "if DHCP is on" branch, so a node holding
# the VIP with DHCP already off kept it. Both were invisible to 300+ passing
# tests because nothing ran the loop.
#
# So: run the loop for real. Fake `ip`, `ping`, `nc`, `curl`, `pihole-FTL`,
# `systemctl` and friends as scripts on PATH, describe a world in files, run the
# daemon over it for a few cycles, then assert on the calls it made. The daemon
# source is copied and rewritten only to (a) bound the infinite loop and (b) move
# its absolute paths into the tmpdir. Nothing else is altered, and every decision
# under test is the production one.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

GW="192.168.111.1"
P1="192.168.111.201"        # primary
P2="192.168.111.205"        # this node, secondary
VIPADDR="192.168.111.200"

W=""
cleanup() { [[ -n "$W" && -d "$W" ]] && rm -rf "$W"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The fake world
# ---------------------------------------------------------------------------

# Peer state lives in one file per address: "<ping> <dns> <dhcp>". The stubs read
# it on every call, so a scenario is described in data, not in stub code.
set_peer() { printf '%s %s %s\n' "$2" "$3" "$4" > "$W/state/$1"; }

write_stubs() {
    mkdir -p "$W/bin"

    cat > "$W/bin/ip" <<'STUB'
#!/bin/bash
echo "ip $*" >> "$CALLS"
case "$*" in
    *"route get"*)      echo "1.0.0.0 via 192.168.111.1 dev eth0 src 192.168.111.205 uid 0" ;;
    "link show eth0")   exit 0 ;;
    *"link show up"*)   echo "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>" ;;
    *"addr show dev"*)
        [[ -s "$STATE/vip" ]] && echo "    inet $(cat "$STATE/vip")/32 scope global eth0"
        echo "    inet 192.168.111.205/24 brd 192.168.111.255 scope global eth0" ;;
    "addr add "*)       echo "${2%%/*}" > "$STATE/vip" ;;
    "addr del "*)       : > "$STATE/vip" ;;
esac
exit 0
STUB

    # ping/nc: the first two fields of the peer's state file. An address with no
    # state file is unreachable, which is what an absent host looks like.
    cat > "$W/bin/ping" <<'STUB'
#!/bin/bash
for a; do case "$a" in -*) ;; *) ip="$a" ;; esac; done
read -r p _ _ < "$STATE/$ip" 2>/dev/null || exit 1
[[ "$p" == "true" ]]
STUB

    cat > "$W/bin/nc" <<'STUB'
#!/bin/bash
for a; do case "$a" in -*|53) ;; *) ip="$a" ;; esac; done
[[ "$ip" == "127.0.0.1" ]] && exit 0
read -r _ d _ < "$STATE/$ip" 2>/dev/null || exit 1
[[ "$d" == "true" ]]
STUB

    # curl answers the Pi-hole API the way a passwordless v6 node does, so the
    # auth path is skipped: this harness is about failover decisions, and the
    # login flow already has its own tests.
    cat > "$W/bin/curl" <<'STUB'
#!/bin/bash
url=""
for a; do [[ "$a" == http* ]] && url="$a"; done
[[ -z "$url" ]] && exit 0
case "$url" in *pushover.net*) exit 0 ;; esac
host="${url#http://}"; host="${host%%:*}"; host="${host%%/*}"
path="${url#*://*/}"; path="/${path%%\?*}"
read -r _ _ dhcp < "$STATE/$host" 2>/dev/null || exit 7
echo "curl $path $host" >> "$CALLS"
case "$path" in
    /api/auth)                 echo '{"session":{"valid":true,"totp":false,"sid":null}}' ;;
    /api/config/dhcp/active)   echo "{\"config\":{\"dhcp\":{\"active\":${dhcp:-false}}}}" ;;
    /api/stats/summary)        echo '{"clients":{"active":2}}' ;;
    /api/dhcp/leases)          echo '{"leases":[]}' ;;
    *)                         echo '{}' ;;
esac
exit 0
STUB

    # This node's own DHCP state, and the only place it is changed.
    cat > "$W/bin/pihole-FTL" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "--config" ]]; then
    case "${2:-}" in
        dhcp.active)
            if [[ -n "${3:-}" ]]; then
                echo "pihole-FTL --config dhcp.active $3" >> "$CALLS"
                echo "$3" > "$STATE/dhcp"
            else
                cat "$STATE/dhcp" 2>/dev/null || echo false
            fi ;;
        dhcp.multiDNS) [[ -n "${3:-}" ]] || echo "false" ;;
        *)             [[ -n "${3:-}" ]] || echo "" ;;
    esac
fi
exit 0
STUB

    for _noop in systemctl logger arping sleep hostname; do
        cat > "$W/bin/$_noop" <<STUB
#!/bin/bash
echo "$_noop \$*" >> "\$CALLS"
exit 0
STUB
    done
    # hostname -I is how the daemon finds its own address; a node holding the VIP
    # reports both, in no guaranteed order. Give the VIP first on purpose: the
    # daemon has to prefer the address that is a cluster member.
    cat > "$W/bin/hostname" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "-I" ]]; then
    [[ -s "$STATE/vip" ]] && printf '%s ' "$(cat "$STATE/vip")"
    echo "192.168.111.205"
fi
exit 0
STUB
    # systemctl is-active --quiet pihole-FTL must succeed, or the loop reports
    # FTL down and never reaches a failover decision.
    cat > "$W/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
exit 0
STUB
    chmod +x "$W/bin/"*
}

# Copy the daemon and rewrite only what has to move: the unbounded loop, and the
# absolute paths it would otherwise write to on this machine.
build_daemon() {
    sed -e "s#while true; do#for _test_cycle in \$(seq \${TEST_CYCLES:-3}); do#" \
        -e "s#/usr/local/lib/pihole-ha/pihole-ha-platform#$W/pihole-ha-platform#" \
        -e "s#/etc/pihole-ha#$W/etc/pihole-ha#g" \
        -e "s#/etc/dnsmasq.d#$W/dnsmasq.d#g" \
        -e "s#/etc/resolv.conf#$W/resolv.conf#g" \
        -e "s#/run/pihole-ha#$W/run#g" \
        -e "s#/var/lib/pihole-ha#$W/var#g" \
        "$REPO/pihole-ha" > "$W/pihole-ha"
    sed -e "s#/etc/pihole-ha#$W/etc/pihole-ha#g" \
        "$REPO/pihole-ha-platform" > "$W/pihole-ha-platform"
    # A rewrite that silently misses the loop would run one cycle and pass
    # everything for the wrong reason.
    grep -q '_test_cycle' "$W/pihole-ha" || { echo "harness: loop rewrite failed" >&2; exit 1; }
}

# A scenario: nodes.conf lines in $1, then the world's state, then run.
run_loop() {
    local conf="$1" cycles="${2:-3}"
    rm -rf "$W/run" "$W/dnsmasq.d" "$W/calls.log"
    mkdir -p "$W/run" "$W/dnsmasq.d"
    : > "$W/calls.log"
    printf '%s\n' "$conf" > "$W/etc/pihole-ha/nodes.conf"
    ( cd "$W" && PATH="$W/bin:$PATH" CALLS="$W/calls.log" STATE="$W/state" \
        TEST_CYCLES="$cycles" bash "$W/pihole-ha" daemon >"$W/out.log" 2>&1 )
    return 0
}

calls() { cat "$W/calls.log" 2>/dev/null; }

W="$(mktemp -d)"
mkdir -p "$W/etc/pihole-ha" "$W/state" "$W/var"
write_stubs
build_daemon

_BASE_CONF="CONFIG_VERSION=1
GATEWAY=$GW
VIP=$VIPADDR
VIP_ENABLED=true
HA_NODES=$P1,$P2
PIN_DNS=false
CHECK_INTERVAL=1
ACTIVATE_AFTER=1
DEACTIVATE_AFTER=1"

# ============================================================
echo "=== Harness control: the loop can be seen taking over, and not taking over ==="

# Without these two, every assertion below could pass on a daemon that does
# nothing at all.
set_peer "$GW" true true false
set_peer "$P1" true true true          # primary healthy and serving
set_peer "$P2" true true false
: > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true" 3
assert_not_contains "standby does not take over from a healthy primary" "$(calls)" "addr add"
assert_not_contains "standby does not start DHCP under a healthy primary" \
    "$(calls)" "dhcp.active true"

set_peer "$P1" false false false       # primary gone
: > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true" 6
assert_contains "standby claims the VIP when the primary goes away" "$(calls)" "addr add $VIPADDR/32 dev eth0"
assert_contains "standby starts DHCP when the primary goes away" "$(calls)" "dhcp.active true"

# ============================================================
echo
echo "=== A node told to stand down gives the VIP and DHCP back ==="

# The shipped bug: this node holds both, the operator switches HA off, and the
# daemon reported "HA disabled" while still answering as the VIP — a duplicate
# address against a primary that is up, plus a second DHCP server.
set_peer "$P1" true true true
echo "$VIPADDR" > "$W/state/vip"; echo true > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=false
DHCP_HA=true" 2
assert_contains "HA_ENABLED=false releases the VIP"  "$(calls)" "addr del $VIPADDR/32 dev eth0"
assert_contains "HA_ENABLED=false releases DHCP"     "$(calls)" "dhcp.active false"
assert_eq       "HA_ENABLED=false ends up holding no VIP" "" "$(cat "$W/state/vip")"

# ...but the configured master keeps serving DHCP. Switching HA off is a brake on
# failover, not an instruction to take DHCP off the LAN: a standby serves it only
# as a failover artifact and hands it back, while the master carries on. The VIP
# still goes, because nothing would yield it while frozen. Here this node is
# listed first, so it IS the configured master.
echo "$VIPADDR" > "$W/state/vip"; echo true > "$W/state/dhcp"
run_loop "CONFIG_VERSION=1
GATEWAY=$GW
VIP=$VIPADDR
VIP_ENABLED=true
HA_NODES=$P2,$P1
PIN_DNS=false
CHECK_INTERVAL=1
ACTIVATE_AFTER=1
DEACTIVATE_AFTER=1
HA_ENABLED=false
DHCP_HA=true" 2
assert_contains "the configured master still releases the VIP when HA is off" \
    "$(calls)" "addr del $VIPADDR/32 dev eth0"
assert_not_contains "the configured master keeps serving DHCP when HA is off" \
    "$(calls)" "dhcp.active false"

# The second shipped bug: the release was nested inside "if DHCP is on", so a
# node holding only the VIP kept it for good.
echo "$VIPADDR" > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true
STANDBY_ONLY=true" 2
assert_contains "STANDBY_ONLY releases a VIP held with DHCP already off" \
    "$(calls)" "addr del $VIPADDR/32 dev eth0"
assert_not_contains "STANDBY_ONLY does not then re-claim it" "$(calls)" "addr add"

# Both held, STANDBY_ONLY set: both go back.
echo "$VIPADDR" > "$W/state/vip"; echo true > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true
STANDBY_ONLY=true" 2
assert_contains "STANDBY_ONLY releases DHCP"        "$(calls)" "dhcp.active false"
assert_contains "STANDBY_ONLY releases the VIP too" "$(calls)" "addr del $VIPADDR/32 dev eth0"

# STANDBY_ONLY has to win against the state that would otherwise make this node
# take over: it is the brake an operator reaches for while a cluster is fighting.
set_peer "$P1" false false false
: > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true
STANDBY_ONLY=true" 6
assert_not_contains "STANDBY_ONLY never claims the VIP, even with the primary down" \
    "$(calls)" "addr add"
assert_not_contains "STANDBY_ONLY never starts DHCP, even with the primary down" \
    "$(calls)" "dhcp.active true"

# ============================================================
echo
echo "=== DNS-only: the VIP still moves, DHCP is never touched ==="

# DHCP belongs to another server here. The bug was that STANDBY_ONLY was read
# below the branch that returns for DNS-only nodes, so the flag did nothing.
#
# The primary has to be DOWN for this to test anything: against a healthy primary
# a DNS-only node releases the VIP anyway, by yielding, and the assertion passes
# on code that ignores the flag completely. It did, until this line was changed.
set_peer "$P1" false false false
echo "$VIPADDR" > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=false
STANDBY_ONLY=true" 3
assert_contains "DNS-only STANDBY_ONLY releases the VIP it would otherwise keep" \
    "$(calls)" "addr del $VIPADDR/32 dev eth0"
assert_not_contains "DNS-only STANDBY_ONLY does not re-claim it" "$(calls)" "addr add"
assert_not_contains "DNS-only never writes DHCP state"   "$(calls)" "dhcp.active true"
assert_not_contains "DNS-only never writes DHCP state (off either)" \
    "$(calls)" "dhcp.active false"

# And with HA off, same thing: hand the address back.
echo "$VIPADDR" > "$W/state/vip"
run_loop "$_BASE_CONF
HA_ENABLED=false
DHCP_HA=false" 2
assert_contains "DNS-only HA_ENABLED=false releases the VIP" "$(calls)" "addr del $VIPADDR/32 dev eth0"

# Control for this mode: a DNS-only node with the primary's DNS down does claim.
set_peer "$P1" true false false
: > "$W/state/vip"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=false" 6
assert_contains "DNS-only claims the VIP when the primary's DNS dies" \
    "$(calls)" "addr add $VIPADDR/32 dev eth0"
assert_not_contains "DNS-only claim still does not touch DHCP" "$(calls)" "dhcp.active true"

# ============================================================
echo
echo "=== A node that cannot answer DNS itself must not serve DHCP or hold the VIP ==="

# should_i_hold_vip has carried this precondition all along; the DHCP path did
# not. A node whose own FTL is up but not answering on :53 would keep DHCP and
# the VIP while a healthy peer also took them, and neither side yielded.
set_peer "$GW" true true false
set_peer "$P1" false false false      # nobody else to serve
set_peer "$P2" true false false       # this node: pingable, DNS dead
: > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true" 6
assert_not_contains "a node with dead DNS does not claim the VIP, even alone" \
    "$(calls)" "addr add"
assert_not_contains "a node with dead DNS does not start DHCP, even alone" \
    "$(calls)" "dhcp.active true"

# And it gives back what it is already holding, rather than serving a network it
# cannot resolve for.
set_peer "$P1" true true true          # a healthy peer is serving
echo "$VIPADDR" > "$W/state/vip"; echo true > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true" 4
assert_contains "a node with dead DNS yields DHCP" "$(calls)" "dhcp.active false"
assert_contains "a node with dead DNS yields the VIP" "$(calls)" "addr del $VIPADDR/32 dev eth0"

# Control: the same node, DNS restored, does serve when it is the only one left.
set_peer "$P1" false false false
set_peer "$P2" true true false
: > "$W/state/vip"; echo false > "$W/state/dhcp"
run_loop "$_BASE_CONF
HA_ENABLED=true
DHCP_HA=true" 6
assert_contains "the same node serves once its own DNS answers again" \
    "$(calls)" "addr add $VIPADDR/32 dev eth0"

# ============================================================
echo
test_summary
exit $?
