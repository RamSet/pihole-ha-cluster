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

# Run injection in background so Pi-hole starts immediately
inject_ha &

# Hand off to the real pihole entrypoint
exec start.sh "$@"
