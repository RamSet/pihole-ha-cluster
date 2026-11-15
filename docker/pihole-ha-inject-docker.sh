#!/bin/bash
# Injects pihole-ha web UI files into Pi-hole admin panel
# Runs inside the pihole container before start.sh
# Source files appear in /pihole-ha-src/ from the sidecar container

SRCDIR="/pihole-ha-src"
WEBDIR="/var/www/html/admin"
SIDEBAR="$WEBDIR/scripts/lua/sidebar.lp"

inject_ha() {
    # Wait for source files from sidecar (it stages them on startup)
    local waited=0
    while [[ ! -f "$SRCDIR/ha.lp" ]] && (( waited < 60 )); do
        sleep 1
        (( waited++ ))
    done

    if [[ ! -f "$SRCDIR/ha.lp" ]]; then
        echo "pihole-ha-inject: source files not found after 60s — skipping"
        return
    fi

    # Wait for web directory (FTL creates it)
    waited=0
    while [[ ! -d "$WEBDIR/scripts/js" ]] && (( waited < 60 )); do
        sleep 1
        (( waited++ ))
    done

    if [[ ! -d "$WEBDIR/scripts/js" ]]; then
        echo "pihole-ha-inject: web directory not ready — skipping"
        return
    fi

    # Copy page files
    cp "$SRCDIR/ha.lp" "$WEBDIR/ha.lp"
    cp "$SRCDIR/ha-api.lp" "$WEBDIR/ha-api.lp"
    cp "$SRCDIR/ha.js" "$WEBDIR/scripts/js/ha.js"
    # Same path the bare-metal install uses, because ha.lp reads it from there.
    if [[ -f "$SRCDIR/VERSION" ]]; then
        mkdir -p /usr/local/share/pihole-ha
        cp "$SRCDIR/VERSION" /usr/local/share/pihole-ha/VERSION
    fi
    echo "pihole-ha-inject: copied ha.lp, ha-api.lp, ha.js"

    # Patch sidebar if not already done
    if [[ ! -f "$SIDEBAR" ]]; then
        echo "pihole-ha-inject: sidebar.lp not found — skipping patch"
        return
    fi

    if grep -q 'HA Cluster' "$SIDEBAR"; then
        echo "pihole-ha-inject: sidebar already patched"
        return
    fi

    # Add 'ha' to the Tools treeview so parent menu opens
    sed -i "s/'network'})/'network', 'ha'})/" "$SIDEBAR"

    # Insert HA menu entry before "Update Gravity" using sed
    sed -i '/<!-- Update Gravity -->/i\                        <!-- HA Cluster -->\n                        <li<? if scriptname == '"'"'ha'"'"' then ?> class="active"<? end ?>>\n                            <a href="<?=webhome?>ha">\n                                <i class="fa fa-fw menu-icon fa-server"><\/i> <span>HA Cluster<\/span>\n                            <\/a>\n                        <\/li>' "$SIDEBAR"

    echo "pihole-ha-inject: sidebar patched — HA Cluster menu added"
}

# Under DHCP failover, DHCP settings must not live in this container's environment.
#
# FTLCONF_dhcp_* is the natural way to configure DHCP in a compose file, and
# under pihole-ha it is a trap, because the sidecar drives DHCP with its own
# pihole-FTL process, which has none of those variables. Measured on FTL v6.8:
#
#   FTLCONF_dhcp_active=true     the sidecar's "--config dhcp.active false"
#       writes the file, prints false and exits 0, while the server in this
#       container -- where the key is forced -- goes on answering: the port-67
#       listener was still up 12s after a "successful" stand-down. Set on every
#       node, that is every node serving DHCP with pihole-ha reporting one.
#   FTLCONF_dhcp_start/end/router   the sidecar's "--config dhcp.active true"
#       fails with "DHCP start address is not valid", because the range exists
#       only in this container's environment. That node can never take over.
#
# The sidecar cannot read this environment (another container's process), so
# this wrapper, which runs here before FTL, is the only place to act. The switch
# itself is pihole-ha's to throw, so it is dropped. Everything else is moved
# into pihole.toml, where both containers see the same value; the compose file
# stays the source of truth because this runs on every start. DNS-only installs
# do not manage DHCP and are left exactly as configured.
_ha_conf="${PIHOLE_HA_NODES_CONF:-/etc/pihole-ha/nodes.conf}"
_ha_conf_val() { sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$_ha_conf" 2>/dev/null | tail -1; }
if [[ -r "$_ha_conf" && "$(_ha_conf_val DHCP_HA)" == "true" && "$(_ha_conf_val HA_ENABLED)" != "false" ]]; then
    while IFS= read -r _ha_var; do
        [[ -n "$_ha_var" ]] || continue
        _ha_val="${!_ha_var}"
        _ha_key="${_ha_var#*_}"; _ha_key="dhcp.${_ha_key#*_}"
        unset "$_ha_var"
        if [[ "${_ha_key,,}" == "dhcp.active" ]]; then
            echo "pihole-ha-inject: ignoring ${_ha_var}=${_ha_val} — with DHCP failover on, pihole-ha switches DHCP itself, and a forced value would leave this node serving (or silent) whatever the cluster decided; remove it from the compose file"
        elif pihole-FTL --config "$_ha_key" "$_ha_val" >/dev/null 2>&1; then
            echo "pihole-ha-inject: moved ${_ha_var} into pihole.toml as ${_ha_key} so the pihole-ha sidecar sees it too"
        else
            # Not a key this FTL accepts from the command line (a list, or a
            # misspelling): put it back rather than lose the setting.
            export "$_ha_var=$_ha_val"
            echo "pihole-ha-inject: could not move ${_ha_var} into pihole.toml — leaving it in the environment, where the pihole-ha sidecar cannot see it"
        fi
    done < <(compgen -e | grep -i '^FTLCONF_dhcp_')
fi

# Run injection in background so Pi-hole starts immediately
inject_ha &

# Hand off to THIS image's entrypoint, not a hardcoded one.
#
# The stock image starts at start.sh, but a combined image starts at its own
# script -- mpgirro/pihole-unbound's /custom-entrypoint.sh launches unbound and
# then Pi-hole. Running start.sh there skips unbound entirely, and since such a
# setup points dns.upstreams at 127.0.0.1#5335, the node comes up answering
# nothing. Set PIHOLE_HA_ENTRYPOINT in the pihole container to whatever the
# image's own entrypoint is; the two fallbacks below just save you doing that
# for the images we know about.
_real_entrypoint="${PIHOLE_HA_ENTRYPOINT:-}"
if [[ -z "$_real_entrypoint" ]]; then
    if [[ -x /custom-entrypoint.sh ]]; then
        _real_entrypoint=/custom-entrypoint.sh
    else
        _real_entrypoint=start.sh
    fi
fi
echo "pihole-ha-inject: handing off to $_real_entrypoint"
exec "$_real_entrypoint" "$@"
