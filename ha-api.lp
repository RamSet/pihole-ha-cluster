<?
-- ha-api.lp — Same-origin API proxy for Pi-hole HA page
-- Reads local files and proxies to :8887 API to avoid cross-origin/mixed-content issues


local function url_decode(s)
    if s == nil then return nil end
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

-- Percent-encode a value for safe interpolation into the shell'd curl URL in
-- curl_local(). This neutralizes shell metacharacters (' ; $ ` & ...) AND is the
-- correct URL wire format, so the value arrives intact at the :8887 backend.
local function url_encode(s)
    if s == nil then return "" end
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function get_param(name)
    local qs = mg.request_info.query_string or ""
    for k, v in qs:gmatch("([^&=]+)=([^&]*)") do
        if k == name then return url_decode(v) end
    end
    return nil
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- The caller's Pi-hole session id. This page is already auth-gated by Pi-hole
-- (an unauthenticated request is redirected to the login page and never reaches
-- this code), so whatever we find here belongs to a logged-in admin. The :8887
-- backend independently re-validates it against the local Pi-hole before it will
-- perform any write, so we must forward it. The browser sends it as the HttpOnly
-- "sid" cookie; some clients use the X-FTL-SID header or a sid query param.
local function get_sid()
    local ri = mg.request_info or {}
    local h = ri.http_headers or {}
    local sid = h["X-FTL-SID"] or h["X-Ftl-Sid"] or h["x-ftl-sid"]
    if sid and #sid > 0 then return sid end
    local cookie = h["Cookie"] or h["cookie"]
    if cookie then
        local c = cookie:match("sid=([^;]+)")
        if c and #c > 0 then return c end
    end
    local q = get_param("sid")
    if q and #q > 0 then return q end
    return nil
end

local function curl_local(endpoint)
    -- Forward the caller's session so the :8887 backend authorizes writes on
    -- password-protected Pi-holes. Harmless on endpoints that don't require it.
    local sid = get_sid()
    if sid then
        local sep = endpoint:find("?", 1, true) and "&" or "?"
        endpoint = endpoint .. sep .. "sid=" .. url_encode(sid)
    end
    local handle = io.popen("curl -s --max-time 4 'http://127.0.0.1:8887" .. endpoint .. "' 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()
    if result and #result > 0 then return result end
    return nil
end

local function read_nodes_conf()
    local nodes = {}
    local f = io.open("/etc/pihole-ha/nodes.conf", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^([%w_]+)=(.*)")
            if k == "HA_NODES" then
                for entry in v:gmatch("[^,]+") do
                    local ip = entry:match("^([^:]+)")
                    table.insert(nodes, ip or entry)
                end
            end
        end
        f:close()
    end
    if #nodes == 0 then nodes = {} end
    return nodes
end

local function read_sync_primary()
    local nodes = read_nodes_conf()
    local primary = nodes[1]
    local f = io.open("/etc/pihole-ha/sync.conf", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^([%w_]+)=(.*)")
            if k == "SYNC_PRIMARY" then primary = v end
        end
        f:close()
    end
    return primary
end

local function curl_primary_manifest()
    local primary = read_sync_primary()
    local handle = io.popen("curl -s --max-time 4 http://" .. primary .. ":8887/api/sync/manifest 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()
    if result and #result > 0 then return result end
    return nil
end

local action = get_param("action") or ""

if action == "status" then
    -- Read status file directly (fast, no HTTP call needed)
    local content = read_file("/run/pihole-ha/status.json")
    mg.write(content or '{"error":"no status file"}')

elseif action == "sync-config" then
    -- Proxy to local dash API (handles config parsing)
    local content = curl_local("/api/sync/config")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "sync-manifest" then
    -- Always fetch from sync primary since only it builds payloads
    local content = curl_primary_manifest()
    mg.write(content or '{"error":"no manifest"}')

elseif action == "toggle" then
    local key = get_param("key") or ""
    -- Validate key is alphanumeric only
    if key:match("^%a+$") then
        local content = curl_local("/api/sync/toggle/" .. key)
        mg.write(content or '{"error":"toggle failed"}')
    else
        mg.write('{"error":"invalid key"}')
    end

elseif action == "sync-now" then
    local content = curl_local("/api/sync/now")
    mg.write(content or '{"error":"sync failed"}')

elseif action == "set-interval" then
    local minutes = get_param("minutes") or ""
    if minutes:match("^%d+$") then
        local content = curl_local("/api/sync/interval?minutes=" .. minutes)
        mg.write(content or '{"error":"interval set failed"}')
    else
        mg.write('{"error":"invalid interval"}')
    end

elseif action == "notify-config" then
    local content = curl_local("/api/notify/config")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "notify-toggle" then
    local content = curl_local("/api/notify/toggle")
    mg.write(content or '{"error":"toggle failed"}')

elseif action == "notify-save" then
    local enabled = get_param("enabled") or "false"
    local user = get_param("user") or ""
    local token = get_param("token") or ""
    local title = get_param("title") or "pihole-ha"
    local dhcp_enabled = get_param("dhcp_enabled") or "true"
    local dhcp_macs = get_param("dhcp_macs") or ""
    local content = curl_local("/api/notify/save?enabled=" .. url_encode(enabled) .. "&user=" .. url_encode(user) .. "&token=" .. url_encode(token) .. "&title=" .. url_encode(title) .. "&dhcp_enabled=" .. url_encode(dhcp_enabled) .. "&dhcp_macs=" .. url_encode(dhcp_macs))
    mg.write(content or '{"error":"save failed"}')

elseif action == "notify-dhcp-hosts" then
    local content = curl_local("/api/dhcp/hosts")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "notify-test" then
    local content = curl_local("/api/notify/test")
    mg.write(content or '{"error":"test failed"}')

elseif action == "master-config" then
    local content = curl_local("/api/dhcp/master-config")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "set-master" then
    local ip = get_param("ip") or ""
    if ip == "auto" or ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local content = curl_local("/api/dhcp/master?ip=" .. ip)
        mg.write(content or '{"error":"set-master failed"}')
    else
        mg.write('{"error":"invalid value"}')
    end

elseif action == "ha-config" then
    local content = curl_local("/api/ha/config")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "ha-toggle" then
    local content = curl_local("/api/ha/toggle")
    mg.write(content or '{"error":"toggle failed"}')

elseif action == "priority-config" then
    local content = curl_local("/api/priority/config")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "set-priority" then
    local nodes = get_param("nodes") or ""
    -- Validate: only digits, dots, and commas
    if nodes:match("^[%d%.,]+$") then
        local content = curl_local("/api/priority/set?nodes=" .. nodes)
        mg.write(content or '{"error":"set-priority failed"}')
    else
        mg.write('{"error":"invalid node list"}')
    end

elseif action == "vip-config" then
    local content = curl_local("/api/vip/config")
    mg.write(content or '{"error":"unreachable"}')

elseif action == "vip-toggle" then
    local content = curl_local("/api/vip/toggle")
    mg.write(content or '{"error":"toggle failed"}')

elseif action == "leave" then
    local ip = get_param("ip") or ""
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local content = curl_local("/api/nodes/leave?node=" .. ip)
        mg.write(content or '{"error":"leave failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

elseif action == "promote" then
    local ip = get_param("ip") or ""
    -- Validate IP format (digits and dots only)
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local content = curl_local("/api/sync/promote?ip=" .. ip)
        mg.write(content or '{"error":"promote failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

elseif action == "set-auth" then
    local ip = get_param("ip") or ""
    local password = get_param("password") or ""
    -- Validate IP format (digits and dots only)
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local content = curl_local("/api/auth/set?ip=" .. url_encode(ip) .. "&password=" .. url_encode(password))
        mg.write(content or '{"error":"auth save failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

else
    mg.write('{"error":"unknown action"}')
end
?>
