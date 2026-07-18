<? --[[
*  Pi-hole HA Cluster — Native Web UI
*  Integrated into Pi-hole's AdminLTE interface
*  Polls the pihole-ha-dash API on port 8887
--]]

mg.include('scripts/lua/header_authenticated.lp','r')

-- HTML-escape untrusted config values before rendering into the page.
local function esc(s)
    if s == nil then return "" end
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;"
    }))
end

-- Installed version, read server-side so the badge always shows it even if the
-- async update-check can't reach the API (e.g. during an update/restart).
local ha_version = "unknown"
local vf = io.open("/usr/local/share/pihole-ha/VERSION", "r")
if vf then
    local v = vf:read("*l"); vf:close()
    if v then ha_version = v:gsub("%s+", "") end
end

-- Read nodes.conf for dynamic node list
local ha_nodes, ha_gateway, ha_vip = {}, "", ""
local ha_vip_enabled = true
local ncf = io.open("/etc/pihole-ha/nodes.conf", "r")
if ncf then
    for line in ncf:lines() do
        local k, v = line:match("^([%w_]+)=(.*)")
        if k == "GATEWAY" then ha_gateway = v
        elseif k == "VIP" then ha_vip = v
        elseif k == "VIP_ENABLED" then ha_vip_enabled = (v == "true")
        elseif k == "HA_NODES" then
            for entry in v:gmatch("[^,]+") do
                local ip = entry:match("^([^:]+)")
                table.insert(ha_nodes, ip or entry)
            end
        end
    end
    ncf:close()
end
if #ha_nodes == 0 then ha_nodes = {} end
local ha_roles = {"PRIMARY", "SECONDARY", "TERTIARY"}
local ha_role_short = {"P1", "P2", "P3"}
local node_count = #ha_nodes
for i = 4, node_count do
    ha_roles[i] = "NODE" .. i
    ha_role_short[i] = "P" .. i
end

-- Read Pushover notify config server-side for initial state
local po_enabled = false
local po_has_user, po_has_token = false, false
local po_title = "pihole-ha"
local dhcp_notify_enabled = true
local dhcp_notify_ignored_macs = ""
local dhcp_notify_ignored_hosts = ""
local nf = io.open("/etc/pihole-ha/notify.conf", "r")
if nf then
    for line in nf:lines() do
        local k, v = line:match("^([%w_]+)=(.*)")
        if k == "PO_ENABLED" then po_enabled = (v == "true")
        elseif k == "PO_USER" then po_has_user = (v ~= nil and v ~= "")
        elseif k == "PO_TOKEN" then po_has_token = (v ~= nil and v ~= "")
        elseif k == "PO_TITLE" then po_title = v or "pihole-ha"
        elseif k == "DHCP_NOTIFY_ENABLED" then dhcp_notify_enabled = (v ~= "false")
        elseif k == "DHCP_NOTIFY_IGNORED_MACS" then dhcp_notify_ignored_macs = v or ""
        elseif k == "DHCP_NOTIFY_IGNORED_HOSTS" then dhcp_notify_ignored_hosts = v or ""
        end
    end
    nf:close()
end
-- Convert comma-separated lists to newline-separated for textarea display
local dhcp_ignored_textarea = dhcp_notify_ignored_macs:gsub(",", "\n")
local dhcp_ignored_hosts_textarea = dhcp_notify_ignored_hosts:gsub(",", "\n")

-- Read sync config server-side for initial checkbox state
local sync_enabled, sync_gravity, sync_dhcp, sync_dns = true, true, true, true
local sync_settings = true
local sync_primary = ha_nodes[1]
local sync_interval = 15
local sf = io.open("/etc/pihole-ha/sync.conf", "r")
if sf then
    for line in sf:lines() do
        local k, v = line:match("^([%w_]+)=(.*)")
        if k == "SYNC_ENABLED" then sync_enabled = (v == "true")
        elseif k == "SYNC_GRAVITY" then sync_gravity = (v == "true")
        elseif k == "SYNC_DHCP" then sync_dhcp = (v == "true")
        elseif k == "SYNC_DNS" then sync_dns = (v == "true")
        elseif k == "SYNC_SETTINGS" then sync_settings = (v == "true")
        elseif k == "SYNC_PRIMARY" then sync_primary = v
        elseif k == "SYNC_INTERVAL" then sync_interval = tonumber(v) or 15
        end
    end
    sf:close()
end

-- Read DHCP master override config
-- Read HA enabled state
local ha_enabled = true
local haf = io.open("/etc/pihole-ha/nodes.conf", "r")
if haf then
    for line in haf:lines() do
        local k, v = line:match("^([%w_]+)=(.*)")
        if k == "HA_ENABLED" then ha_enabled = (v == "true") end
    end
    haf:close()
end

local dhcp_master = "auto"
local mf = io.open("/etc/pihole-ha/master.conf", "r")
if mf then
    for line in mf:lines() do
        local k, v = line:match("^([%w_]+)=(.*)")
        if k == "DHCP_MASTER" then dhcp_master = v end
    end
    mf:close()
end

-- Column class based on node count
local col_class = node_count == 2 and "col-lg-6 col-md-6" or "col-lg-4 col-md-4"
?>

<style>
.ha-toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 22px;
    vertical-align: middle;
    cursor: pointer;
    user-select: none;
}
.ha-toggle-track {
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    background-color: #555;
    transition: .3s;
    border-radius: 22px;
}
.ha-toggle-track:before {
    content: "";
    position: absolute;
    height: 16px;
    width: 16px;
    left: 3px;
    bottom: 3px;
    background-color: #aaa;
    transition: .3s;
    border-radius: 50%;
}
.ha-toggle.on .ha-toggle-track {
    background-color: #00a65a;
}
.ha-toggle.on .ha-toggle-track:before {
    transform: translateX(22px);
    background-color: #fff;
}
.ha-toggle.disabled {
    opacity: 0.4;
    cursor: not-allowed;
    pointer-events: none;
}
.ha-sync-row td {
    vertical-align: middle !important;
}
.ha-sync-row.disabled {
    opacity: 0.4;
    pointer-events: none;
}
.ha-promote-group {
    display: inline-flex;
    gap: 0;
}
.ha-promote-group .btn {
    border-radius: 0;
    min-width: 90px;
}
.ha-promote-group .btn:first-child {
    border-radius: 3px 0 0 3px;
}
.ha-promote-group .btn:last-child {
    border-radius: 0 3px 3px 0;
}
.ha-promote-group .btn.btn-success {
    cursor: default;
    pointer-events: none;
}
/* Ignored host in the static-host picker: red + bold in every theme.
   Override text-muted on the name so the color actually shows. */
.dhcp-pick-row.ignored,
.dhcp-pick-row.ignored code,
.dhcp-pick-row.ignored .text-muted {
    color: #e74c3c !important;
    font-weight: bold;
}
</style>

<!-- Error callout (hidden by default) -->
<div class="callout callout-danger" id="ha-error" style="display:none">
    <h4><i class="fa fa-exclamation-triangle"></i> Connection Error</h4>
    <p>Cannot reach the local HA service on port 8887. Is <code>pihole-ha-dash</code> running?</p>
</div>

<!-- HA Disabled Banner -->
<div class="callout callout-danger" id="ha-disabled-banner" style="<? if ha_enabled then ?>display:none<? end ?>">
    <h4><i class="fa fa-power-off"></i> HA Failover Disabled</h4>
    <p>All DHCP failover, health checks, and VIP management are paused across all nodes.
    <button class="btn btn-sm btn-success ha-re-enable-btn" style="margin-left:10px"><i class="fa fa-play"></i> Re-enable HA</button></p>
</div>

<!-- Info bar -->
<div class="row">
    <div class="col-md-12" style="margin-bottom:10px">
        <span id="gw-status"></span>
        <span id="ha-equilibrium" style="margin-left:10px;font-size:12px"></span>
        <span class="pull-right text-muted" id="ha-timestamp"></span>
    </div>
</div>

<!-- Row 1: Cluster Overview (dynamic node cards) -->
<div class="row">
<? for i, node_ip in ipairs(ha_nodes) do
    local idx = i - 1
    local role = ha_roles[i] or ("NODE" .. i)
    local short = ha_role_short[i] or ("P" .. i)
?>
    <div class="<?=col_class?> col-sm-6">
        <div class="small-box bg-aqua no-user-select" id="node-box-<?=idx?>">
            <div class="inner">
                <p><?=role?> (<?=short?>)</p>
                <h3 id="node-status-<?=idx?>">---</h3>
                <p id="node-stats-<?=idx?>" style="margin:0;font-size:13px">&nbsp;</p>
            </div>
            <div class="icon">
                <i class="fas fa-server"></i>
            </div>
            <a href="http://<?=node_ip?>:8887" target="_blank" class="small-box-footer" id="node-footer-<?=idx?>">
                <?=node_ip?> <i class="fa fa-arrow-circle-right"></i>
            </a>
        </div>
    </div>
<? end ?>
</div>

<!-- Row 1a: HA Failover Toggle -->
<div class="row">
    <div class="col-md-12">
        <div class="box box-danger" id="ha-panel">
            <div class="box-header with-border">
                <h3 class="box-title"><i class="fa fa-power-off"></i> HA Failover</h3>
                <div class="box-tools pull-right">
                    <span class="label label-default" id="ha-status">
                        <? if ha_enabled then ?>Active<? else ?>DISABLED<? end ?>
                    </span>
                </div>
            </div>
            <div class="box-body">
                <p class="text-muted" style="margin:0 0 12px;font-size:12px;line-height:1.5">
                    Controls the entire HA system. When enabled, nodes continuously monitor each other and automatically
                    fail over DHCP if the active server goes down. When disabled, all failover logic, health checks,
                    and VIP management stop across every node &mdash; DHCP stays wherever it currently is.
                </p>
                <table class="table">
                    <tbody>
                        <tr class="ha-sync-row">
                            <td style="width:60px">
                                <div class="ha-toggle<? if ha_enabled then ?> on<? end ?>" id="toggle-ha">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                <strong>HA Enabled</strong><br>
                                <small class="text-muted">Master kill-switch &mdash; applies to all nodes immediately</small>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>
</div>

<!-- Row 1b: DHCP Master Override -->
<div class="row">
    <div class="col-md-12">
        <div class="box box-success" id="master-panel">
            <div class="box-header with-border">
                <h3 class="box-title">DHCP Master</h3>
                <div class="box-tools pull-right">
                    <span class="label label-default" id="master-status">
                        <? if dhcp_master == "auto" then ?>
                            Automatic
                        <? else ?>
                            Manual: <?=dhcp_master?>
                        <? end ?>
                    </span>
                </div>
            </div>
            <div class="box-body">
                <p class="text-muted" style="margin:0 0 12px;font-size:12px;line-height:1.5">
                    Controls which node runs the DHCP server. In <strong>Auto</strong> mode, the highest-priority
                    healthy node takes over automatically. Pin a specific node to force it as master regardless
                    of priority &mdash; useful during maintenance or testing. The override propagates to all nodes instantly.
                </p>
                <table class="table" id="master-toggles">
                    <tbody>
                        <tr class="ha-sync-row">
                            <td>
                                <strong>DHCP Master Override</strong>
                                <small class="text-muted" style="margin-left:6px">Force a specific node as DHCP master, or use automatic priority-based failover</small>
                                <div style="margin-top:8px" id="master-group">
                                    <div class="ha-promote-group">
                                        <button class="btn btn-sm <?= dhcp_master == 'auto' and 'btn-success' or 'btn-default' ?>"
                                            id="master-auto">Auto</button>
<? for i, node_ip in ipairs(ha_nodes) do
    local role = ha_roles[i] or ("NODE" .. i)
    local ip_id = node_ip:gsub("%.", "_")
    local btn_class = (dhcp_master == node_ip) and "btn-success" or "btn-default"
?>
                                        <button class="btn btn-sm <?=btn_class?>"
                                            id="master-<?=ip_id?>">.<?=node_ip:match("[^.]+$")?> (<?=role?>)</button>
<? end ?>
                                    </div>
                                    <span id="master-result" style="margin-left:10px"></span>
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>
</div>

<!-- Row 1b2: Priority Order -->
<div class="row">
    <div class="col-md-12">
        <div class="box box-success" id="priority-panel">
            <div class="box-header with-border">
                <h3 class="box-title">Priority Order</h3>
                <div class="box-tools pull-right">
                    <span class="label label-default" id="priority-status">Loading</span>
                </div>
            </div>
            <div class="box-body">
                <p class="text-muted" style="margin:0 0 12px;font-size:12px;line-height:1.5">
                    Sets the failover order. When the active DHCP master goes down, the next node in this list
                    takes over. Drag nodes up or down to change the sequence. Changes propagate to all nodes
                    immediately so every node agrees on who takes over next.
                </p>
                <strong>Failover Priority</strong>
                <small class="text-muted" style="margin-left:6px">Reorder nodes to change failover sequence &mdash; propagates to all nodes</small>
                <div style="margin-top:10px" id="priority-rows">Loading...</div>
                <span id="priority-result" style="margin-left:10px"></span>
            </div>
        </div>
    </div>
</div>

<!-- Row 1c: VIP Toggle -->
<div class="row">
    <div class="col-md-12">
        <div class="box box-info" id="vip-panel">
            <div class="box-header with-border">
                <h3 class="box-title">Virtual IP (VIP)</h3>
                <div class="box-tools pull-right">
                    <span class="label label-default" id="vip-status">
                        <? if ha_vip_enabled then ?>Enabled<? else ?>Disabled<? end ?>
                    </span>
                </div>
            </div>
            <div class="box-body">
                <p class="text-muted" style="margin:0 0 12px;font-size:12px;line-height:1.5">
                    A floating IP address (the VIP) that orbits the active DHCP node - it follows whichever node is active. When enabled, clients get the VIP
                    as their DNS server instead of individual node IPs. This means failover is seamless &mdash;
                    clients never need to update their DNS settings. The VIP is added and removed automatically
                    via gratuitous ARP when the active node changes.
                </p>
                <table class="table" id="vip-toggles">
                    <tbody>
                        <tr class="ha-sync-row">
                            <td style="width:60px">
                                <div class="ha-toggle<? if ha_vip_enabled then ?> on<? end ?>" id="toggle-vip">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                <strong>VIP Enabled</strong><br>
                                <small class="text-muted">Floating IP added as first DNS server in DHCP leases &mdash; follows the active DHCP node</small>
                            </td>
                        </tr>
                    </tbody>
                </table>
                <div id="vip-details" style="padding:0 10px<? if not ha_vip_enabled then ?>;display:none<? end ?>">
                    <p style="margin:4px 0"><strong>VIP Address:</strong> <?=ha_vip?></p>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- Row 2: Health Check Details (dynamic) -->
<div class="row" style="margin-bottom:0">
    <div class="col-md-12">
        <p class="text-muted" style="margin:0 0 8px 4px;font-size:12px;line-height:1.5">
            Each node runs periodic health checks against every other node. A node is considered healthy when
            its Pi-hole DNS service and the HA daemon are both responding. If a node fails consecutive checks,
            it becomes ineligible for DHCP failover until it recovers.
        </p>
    </div>
</div>
<div class="row">
<? for i, node_ip in ipairs(ha_nodes) do
    local idx = i - 1
    local role = ha_roles[i] or ("NODE" .. i)
?>
    <div class="<?=col_class?> col-sm-6">
        <div class="box box-default" id="health-box-<?=idx?>">
            <div class="box-header with-border">
                <h3 class="box-title"><?=role?> &mdash; <?=node_ip?></h3>
            </div>
            <div class="box-body no-padding">
                <table class="table table-striped table-bordered">
                    <thead>
                        <tr>
                            <th>Check</th>
                            <th>Status</th>
                        </tr>
                    </thead>
                    <tbody id="health-body-<?=idx?>">
                        <tr><td colspan="2" class="text-center text-muted">Loading...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>
<? end ?>
</div>

<!-- Row 3: Config Sync Panel -->
<div class="row">
    <div class="col-md-12">
        <div class="box box-primary" id="sync-panel">
            <div class="box-header with-border">
                <h3 class="box-title">Config Sync</h3>
                <div class="box-tools pull-right">
                    <span class="label" id="sync-entangled" style="display:none"></span>
                    <span class="label label-default" id="sync-ts">&mdash;</span>
                </div>
            </div>
            <div class="box-body">
                <p class="text-muted" style="margin:0 0 12px;font-size:12px;line-height:1.5">
                    Keeps all Pi-hole nodes in sync. The <strong>Sync Primary</strong> builds a config payload every 15 minutes.
                    Standby nodes pull that payload and apply it automatically.
                    Use <strong>Sync Now</strong> to push changes immediately without waiting for the next cycle.
                    Toggle individual components below to control what gets synced.
                </p>
                <table class="table" id="sync-toggles">
                    <tbody>
                        <tr class="ha-sync-row">
                            <td colspan="2">
                                <strong>Sync Primary</strong>
                                <small class="text-muted" style="margin-left:6px">Node that builds and distributes config payloads</small>
                                <div style="margin-top:8px" id="promote-group">
                                    <div class="ha-promote-group">
<? for i, node_ip in ipairs(ha_nodes) do
    local role = ha_roles[i] or ("NODE" .. i)
    local ip_id = node_ip:gsub("%.", "_")
    local btn_class = (sync_primary == node_ip) and "btn-success" or "btn-default"
?>
                                        <button class="btn btn-sm <?=btn_class?>"
                                            id="promote-<?=ip_id?>">.<?=node_ip:match("[^.]+$")?> (<?=role?>)</button>
<? end ?>
                                    </div>
                                    <span id="promote-result" style="margin-left:10px"></span>
                                </div>
                            </td>
                        </tr>
                        <tr class="ha-sync-row">
                            <td style="width:60px">
                                <div class="ha-toggle<? if sync_enabled then ?> on<? end ?>" id="toggle-enabled">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                <strong>Sync Enabled</strong><br>
                                <small class="text-muted">Master toggle &mdash; when off, no config is built or pulled on any node</small>
                            </td>
                        </tr>
                        <tr class="ha-sync-row ha-sync-component">
                            <td>
                                <div class="ha-toggle<? if sync_gravity then ?> on<? end ?><? if not sync_enabled then ?> disabled<? end ?>" id="toggle-gravity">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                Gravity Database<br>
                                <small class="text-muted">Blocklists, allow/deny lists, regex filters, groups, and clients</small>
                            </td>
                        </tr>
                        <tr class="ha-sync-row ha-sync-component">
                            <td>
                                <div class="ha-toggle<? if sync_dhcp then ?> on<? end ?><? if not sync_enabled then ?> disabled<? end ?>" id="toggle-dhcp">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                DHCP Static Leases<br>
                                <small class="text-muted">MAC-to-IP reservations so devices always get the same address</small>
                            </td>
                        </tr>
                        <tr class="ha-sync-row ha-sync-component">
                            <td>
                                <div class="ha-toggle<? if sync_dns then ?> on<? end ?><? if not sync_enabled then ?> disabled<? end ?>" id="toggle-dns">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                Custom DNS Records<br>
                                <small class="text-muted">Local DNS entries (A/AAAA/CNAME) from Pi-hole's custom.list</small>
                            </td>
                        </tr>
                        <tr class="ha-sync-row ha-sync-component">
                            <td>
                                <div class="ha-toggle<? if sync_settings then ?> on<? end ?><? if not sync_enabled then ?> disabled<? end ?>" id="toggle-settings">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                FTL Settings<br>
                                <small class="text-muted">Blocking mode, rate limits, cache size, DNSSEC, upstream DNS, dnsmasq lines</small>
                            </td>
                        </tr>
                    </tbody>
                </table>
                <div style="padding:10px 10px 0">
                    <button class="btn btn-primary" id="sync-now-btn"<? if not sync_enabled then ?> disabled<? end ?>>
                        <i class="fa fa-sync"></i> Sync Now
                    </button>
                    <span id="sync-result" style="margin-left:10px"></span>
                    <br><small class="text-muted" style="display:inline-block;margin-top:6px">Triggers the primary to build a fresh payload. Standbys will pull it on their next cycle or immediately on restart.</small>
                </div>
                <div style="padding:10px 10px 0">
                    <label style="font-weight:600;margin-right:8px">Sync Interval</label>
                    <select class="form-control input-sm" id="sync-interval" style="width:auto;display:inline-block">
                        <option value="1"<? if sync_interval == 1 then ?> selected<? end ?>>1 min</option>
                        <option value="5"<? if sync_interval == 5 then ?> selected<? end ?>>5 min</option>
                        <option value="10"<? if sync_interval == 10 then ?> selected<? end ?>>10 min</option>
                        <option value="15"<? if sync_interval == 15 then ?> selected<? end ?>>15 min</option>
                        <option value="30"<? if sync_interval == 30 then ?> selected<? end ?>>30 min</option>
                        <option value="60"<? if sync_interval == 60 then ?> selected<? end ?>>60 min</option>
                    </select>
                    <span id="interval-result" style="margin-left:10px"></span>
                    <br><small class="text-muted" style="display:inline-block;margin-top:4px">How often the primary builds and standbys pull config payloads. Applies to all nodes.</small>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- Row 4: Pushover Notifications Panel -->
<div class="row">
    <div class="col-md-12">
        <div class="box box-warning" id="notify-panel">
            <div class="box-header with-border">
                <h3 class="box-title"><i class="fa fa-bell"></i> Pushover Notifications</h3>
                <div class="box-tools pull-right">
                    <span class="label label-default" id="notify-status">
                        <? if po_enabled and po_has_user and po_has_token then ?>
                            <i class="fa fa-check"></i> Active
                        <? elseif po_enabled then ?>
                            <i class="fa fa-exclamation-triangle"></i> Incomplete
                        <? else ?>
                            Disabled
                        <? end ?>
                    </span>
                </div>
            </div>
            <div class="box-body">
                <p class="text-muted" style="margin:0 0 12px;font-size:12px;line-height:1.5">
                    Get push notifications on your phone when something happens in the cluster &mdash; DHCP failovers,
                    nodes going down or coming back up, and VIP changes. Requires a free
                    <a href="https://pushover.net" target="_blank">Pushover</a> account and app. Enter your user key
                    and API token below, then use <strong>Send Test</strong> to verify delivery.
                </p>
                <table class="table" id="notify-toggles">
                    <tbody>
                        <tr class="ha-sync-row">
                            <td style="width:60px">
                                <div class="ha-toggle<? if po_enabled then ?> on<? end ?>" id="toggle-notify">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                <strong>HA Event Notifications</strong><br>
                                <small class="text-muted">Send alerts on DHCP failover events via Pushover</small>
                            </td>
                        </tr>
                        <tr class="ha-sync-row">
                            <td style="width:60px">
                                <div class="ha-toggle<? if dhcp_notify_enabled then ?> on<? end ?>" id="toggle-dhcp-notify">
                                    <div class="ha-toggle-track"></div>
                                </div>
                            </td>
                            <td>
                                <strong>New Device Notifications</strong><br>
                                <small class="text-muted">Send a notification when a new device gets a DHCP lease</small>
                            </td>
                        </tr>
                    </tbody>
                </table>
                <div id="dhcp-notify-fields" style="padding:0 10px 10px<? if not dhcp_notify_enabled then ?>;display:none<? end ?>">
                    <div class="form-group" style="margin-top:10px;margin-bottom:6px">
                        <label>Ignored MAC Addresses</label>
                        <textarea class="form-control input-sm" id="dhcp-ignored-macs" rows="4"
                            style="max-width:420px;font-family:monospace;font-size:12px"
                            placeholder="One MAC per line, e.g.&#10;aa:bb:cc:dd:ee:ff"><?=dhcp_ignored_textarea?></textarea>
                        <small class="text-muted">Devices that will never trigger a notification. One MAC address per line.</small>
                    </div>
                    <div class="form-group" style="margin-bottom:10px">
                        <label>Pick from static hosts</label>
                        <div id="dhcp-host-picker" style="max-width:420px;max-height:160px;overflow-y:auto;border:1px solid rgba(128,128,128,0.3);border-radius:4px;padding:6px 8px">
                            <small class="text-muted"><i class="fa fa-spinner fa-spin"></i> Loading...</small>
                        </div>
                        <small class="text-muted">Click a host to add it to the ignored list. <strong style="color:#e74c3c">Bold red</strong> = already ignored.</small>
                    </div>
                    <div class="form-group" style="margin-bottom:10px">
                        <label>Ignored Hostnames</label>
                        <textarea class="form-control input-sm" id="dhcp-ignored-hosts" rows="4"
                            style="max-width:420px;font-family:monospace;font-size:12px"
                            placeholder="One hostname per line, e.g.&#10;chromecast&#10;esp32-sensor"><?=dhcp_ignored_hosts_textarea?></textarea>
                        <small class="text-muted">Devices whose hostname matches (case-insensitive) will never trigger a notification. One hostname per line.</small>
                    </div>
                </div>
                <div id="notify-fields" style="padding:0 10px<? if not po_enabled then ?>;display:none<? end ?>">
                    <div class="form-group" style="margin-top:10px">
                        <label>User Key</label>
                        <input type="password" class="form-control input-sm" id="notify-user"
                            placeholder="Pushover user key" style="max-width:350px"
                            value="<? if po_has_user then ?>********<? end ?>">
                        <small class="text-muted">From <a href="https://pushover.net" target="_blank">pushover.net</a> dashboard</small>
                    </div>
                    <div class="form-group">
                        <label>API Token</label>
                        <input type="password" class="form-control input-sm" id="notify-token"
                            placeholder="Application API token" style="max-width:350px"
                            value="<? if po_has_token then ?>********<? end ?>">
                        <small class="text-muted">Create an application at pushover.net</small>
                    </div>
                    <div class="form-group">
                        <label>Title</label>
                        <input type="text" class="form-control input-sm" id="notify-title"
                            placeholder="pihole-ha" style="max-width:350px"
                            value="<?=esc(po_title)?>">
                        <small class="text-muted">Notification title (default: pihole-ha)</small>
                    </div>
                    <button class="btn btn-primary btn-sm" id="notify-save-btn">
                        <i class="fa fa-save"></i> Save
                    </button>
                    <button class="btn btn-default btn-sm" id="notify-test-btn" style="margin-left:6px">
                        <i class="fa fa-paper-plane"></i> Send Test
                    </button>
                    <span id="notify-result" style="margin-left:10px"></span>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- Version / update indicator (populated by ha.js from /api/version) -->
<div id="ha-version" style="text-align:center;color:#999;font-size:12px;margin:10px 0 4px">
    Pi-hole HA <span id="ha-version-local">v<?=ha_version?></span><span id="ha-version-update"></span>
</div>

<div id="ha-config" style="display:none"
    data-nodes='[<? for i, node_ip in ipairs(ha_nodes) do local role = ha_roles[i] or ("NODE" .. i) local sep = (i < node_count) and "," or "" ?>{"ip":"<?=node_ip?>","role":"<?=role?>","priority":<?=i?>}<?=sep?><? end ?>]'
    data-gateway="<?=ha_gateway?>"
    data-master="<?=dhcp_master?>">
</div>
<script src="<?=pihole.fileversion('scripts/js/ha.js')?>"></script>

<? mg.include('scripts/lua/footer.lp','r')?>
