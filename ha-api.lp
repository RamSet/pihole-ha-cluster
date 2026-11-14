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

local function json_error(msg)
    return '{"error":"' .. tostring(msg):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"}'
end

-- Turn curl's exit status into something an operator can act on.
--
-- Everything on this page except the status file goes through curl_local, so
-- when the :8887 API is not answering, EVERY control fails at once -- and all
-- each one used to say was "toggle failed" / "unreachable", with no hint that
-- they share a cause or what that cause is. Reported from a three-node cluster
-- where the failover toggle, the DHCP master override, the VIP toggle and the
-- sync toggles were all dead and the member list sat on "Loading..." forever.
-- curl already knows which failure it was; the fix is to stop throwing it away.
-- Why pihole-FTL could not start the helper process at all.
--
-- io.popen returns nil plus "<the whole command>: <strerror>" when fork or the
-- pipe fails -- a process limit, not a missing curl. The command carries the
-- caller's session id, so only a short, quote-free strerror tail is ever shown:
-- these messages get pasted into forum posts.
local function spawn_errtext(err)
    if type(err) ~= "string" then return nil end
    local tail = err:match(":%s*([^:]+)%s*$")
    if not tail then return nil end
    tail = tail:gsub("^%s+", ""):gsub("%s+$", "")
    if #tail == 0 or #tail > 80 then return nil end
    if tail:find("[\"'<>]") or tail:find("sid=") or tail:find("http") then return nil end
    return tail
end

local function spawn_reason(err)
    local why = spawn_errtext(err)
    return "pihole-FTL could not start curl to reach the pihole-ha API" ..
           (why and (" (" .. why .. ")") or "") ..
           ". The API itself may be fine: this is pihole-FTL unable to spawn a " ..
           "process, which usually means it is at a limit (open files, " ..
           "processes or memory)."
end

local function curl_reason(code, where, timeout)
    if code == "7" then
        return "cannot connect to the pihole-ha API on " .. where .. ". " ..
               "On a package install, pihole-ha-dash is not running. In Docker, " ..
               "the sidecar must share the Pi-hole container's network " ..
               "(network_mode: service:pihole, or pid/network on the host)."
    elseif code == "28" then
        return "the pihole-ha API on " .. where .. " did not answer within " ..
               tostring(timeout) .. "s."
    elseif code == "52" or code == "56" then
        return "the pihole-ha API on " .. where .. " accepted the connection " ..
               "and then sent nothing back -- check the sidecar's log for a " ..
               "crashed pihole-ha-dash."
    elseif code == "127" then
        return "curl is not installed where pihole-FTL runs (in Docker, that " ..
               "is inside the Pi-hole container), so this panel cannot reach " ..
               "the pihole-ha API at all."
    elseif code == "0" then
        return "the pihole-ha API on " .. where .. " answered with nothing."
    end
    return "the pihole-ha API on " .. where .. " could not be read (curl exit " ..
           tostring(code) .. ")."
end

-- One curl, carrying back either the body or the reason it failed.
--
-- The exit status comes back in the stream itself: io.popen's close() does not
-- report it portably across the Lua builds Pi-hole ships. A spawn that fails
-- outright is reported as such instead of as a missing curl -- three bare-metal
-- nodes on the forum hit that, intermittently, and the page blamed curl.
local function curl_fetch(url, timeout, where)
    local cmd = "curl -s --max-time " .. timeout .. " '" .. url ..
                "' 2>/dev/null; printf '\\n--ha-exit:%s' $?"
    local handle, perr = io.popen(cmd)
    if not handle then
        -- A spawn refused on a momentary burst of pipes or processes usually
        -- succeeds immediately after, so one retry keeps a flicker off a page
        -- that polls six endpoints every few seconds.
        handle, perr = io.popen(cmd)
    end
    if not handle then
        return nil, json_error(spawn_reason(perr))
    end
    local result = handle:read("*a") or ""
    handle:close()
    local code = result:match("%-%-ha%-exit:(%d+)%s*$")
    local body = (result:gsub("\n?%-%-ha%-exit:%d+%s*$", ""))
    if body and #body > 0 then return body end
    return nil, json_error(curl_reason(code or "?", where, timeout)), code
end

-- Nothing is listening in either place, so this is not a namespace split and
-- the only cause left is a dash that is not running.
local function unreachable_reason(host)
    return "cannot connect to the pihole-ha API, on 127.0.0.1:8887 or " ..
           host .. ":8887. pihole-ha-dash is not answering on either: on a " ..
           "package install check 'systemctl status pihole-ha-dash', in " ..
           "Docker check that the pihole-ha sidecar container is running."
end

-- The address this node's own :8887 API answers on, when loopback is not it.
--
-- This page runs inside pihole-FTL; the API runs in the pihole-ha sidecar. The
-- shipped compose puts both on the host network, so one loopback serves both --
-- but a Pi-hole container on a bridge network has a loopback of its own with
-- nothing on it, and then every control on the page fails with "cannot connect"
-- while curl on the host answers fine (reported from a three-node cluster on
-- bridge networking; reproduced in a bridge container: loopback gives curl exit
-- 7, the host's own LAN address answers). What the two always share is
-- /run/pihole-ha, and the sidecar's status file there names an address that
-- does work, since the dash binds 0.0.0.0. Only IPv4 is matched, which is all
-- nodes.conf accepts, and the pattern admits nothing but digits and dots, so
-- the value is safe to interpolate into the shell'd curl URL.
local function node_api_host()
    local content = read_file("/run/pihole-ha/status.json")
    if not content then return nil end
    local node = content:match('"node"%s*:%s*{(.-)}')
    if not node then return nil end
    local ip = node:match('"ip"%s*:%s*"(%d+%.%d+%.%d+%.%d+)"')
    if not ip or ip == "127.0.0.1" then return nil end
    return ip
end

-- Returns the response body, or nil plus a JSON error naming the cause.
local function curl_local(endpoint, timeout)
    -- Forward the caller's session so the :8887 backend authorizes writes on
    -- password-protected Pi-holes. Harmless on endpoints that don't require it.
    local sid = get_sid()
    if sid then
        local sep = endpoint:find("?", 1, true) and "&" or "?"
        endpoint = endpoint .. sep .. "sid=" .. url_encode(sid)
    end
    timeout = timeout or 4
    local body, err, code = curl_fetch("http://127.0.0.1:8887" .. endpoint,
                                       timeout, "127.0.0.1:8887")
    if body then return body end
    -- Only a refused connection is retried elsewhere: a timeout or a dropped
    -- connection means something IS listening on loopback, and asking a second
    -- address about a dash that is mid-crash would only mislabel the fault.
    if code ~= "7" then return nil, err end
    local host = node_api_host()
    if not host then return nil, err end
    local body2, err2, code2 = curl_fetch("http://" .. host .. ":8887" .. endpoint,
                                          timeout, host .. ":8887")
    if body2 then return body2 end
    if code2 == "7" then return nil, json_error(unreachable_reason(host)) end
    return nil, err2
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
    if not primary or #primary == 0 then
        return nil, json_error("no sync primary is configured on this node.")
    end
    return curl_fetch("http://" .. primary .. ":8887/api/sync/manifest", 4,
                      primary .. ":8887")
end

local action = get_param("action") or ""

if action == "status" then
    -- Read status file directly (fast, no HTTP call needed)
    local content = read_file("/run/pihole-ha/status.json")
    mg.write(content or err or '{"error":"no status file"}')

elseif action == "version" then
    local content, err = curl_local("/api/version")
    mg.write(content or err or '{"local":"unknown","latest":"","update_available":false}')

elseif action == "sync-config" then
    -- Proxy to local dash API (handles config parsing)
    local content, err = curl_local("/api/sync/config")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "sync-manifest" then
    -- Always fetch from sync primary since only it builds payloads
    local content, err = curl_primary_manifest()
    mg.write(content or err or '{"error":"no manifest"}')

elseif action == "toggle" then
    local key = get_param("key") or ""
    -- Validate key is alphanumeric only
    if key:match("^%a+$") then
        local content, err = curl_local("/api/sync/toggle/" .. key)
        mg.write(content or err or '{"error":"toggle failed"}')
    else
        mg.write('{"error":"invalid key"}')
    end

elseif action == "sync-now" then
    local content, err = curl_local("/api/sync/now")
    mg.write(content or err or '{"error":"sync failed"}')

elseif action == "set-interval" then
    local minutes = get_param("minutes") or ""
    if minutes:match("^%d+$") then
        local content, err = curl_local("/api/sync/interval?minutes=" .. minutes)
        mg.write(content or err or '{"error":"interval set failed"}')
    else
        mg.write('{"error":"invalid interval"}')
    end

elseif action == "notify-config" then
    local content, err = curl_local("/api/notify/config")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "notify-toggle" then
    local content, err = curl_local("/api/notify/toggle")
    mg.write(content or err or '{"error":"toggle failed"}')

elseif action == "notify-save" then
    local enabled = get_param("enabled") or "false"
    local user = get_param("user") or ""
    local token = get_param("token") or ""
    local title = get_param("title") or "pihole-ha"
    local dhcp_enabled = get_param("dhcp_enabled") or "true"
    local dhcp_macs = get_param("dhcp_macs") or ""
    local dhcp_hosts = get_param("dhcp_hosts") or ""
    local content, err = curl_local("/api/notify/save?enabled=" .. url_encode(enabled) .. "&user=" .. url_encode(user) .. "&token=" .. url_encode(token) .. "&title=" .. url_encode(title) .. "&dhcp_enabled=" .. url_encode(dhcp_enabled) .. "&dhcp_macs=" .. url_encode(dhcp_macs) .. "&dhcp_hosts=" .. url_encode(dhcp_hosts))
    mg.write(content or err or '{"error":"save failed"}')

elseif action == "notify-dhcp-hosts" then
    local content, err = curl_local("/api/dhcp/hosts")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "notify-test" then
    local content, err = curl_local("/api/notify/test")
    mg.write(content or err or '{"error":"test failed"}')

elseif action == "master-config" then
    local content, err = curl_local("/api/dhcp/master-config")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "set-master" then
    local ip = get_param("ip") or ""
    if ip == "auto" or ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local content, err = curl_local("/api/dhcp/master?ip=" .. ip)
        mg.write(content or err or '{"error":"set-master failed"}')
    else
        mg.write('{"error":"invalid value"}')
    end

elseif action == "ha-config" then
    local content, err = curl_local("/api/ha/config")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "ha-toggle" then
    local content, err = curl_local("/api/ha/toggle")
    mg.write(content or err or '{"error":"toggle failed"}')

elseif action == "priority-config" then
    local content, err = curl_local("/api/priority/config")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "set-priority" then
    local nodes = get_param("nodes") or ""
    -- Validate: only digits, dots, and commas
    if nodes:match("^[%d%.,]+$") then
        local content, err = curl_local("/api/priority/set?nodes=" .. nodes)
        mg.write(content or err or '{"error":"set-priority failed"}')
    else
        mg.write('{"error":"invalid node list"}')
    end

elseif action == "vip-config" then
    local content, err = curl_local("/api/vip/config")
    mg.write(content or err or '{"error":"unreachable"}')

elseif action == "vip-toggle" then
    local content, err = curl_local("/api/vip/toggle")
    mg.write(content or err or '{"error":"toggle failed"}')

elseif action == "leave" then
    local ip = get_param("ip") or ""
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        -- Rewrites config and restarts the daemon on every member; 4s is tight.
        local content, err = curl_local("/api/nodes/leave?node=" .. ip, 15)
        mg.write(content or err or '{"error":"leave failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

elseif action == "join" then
    local ip = get_param("ip") or ""
    -- Accepts IP or IP:PORT (Pi-hole web port of the joining node).
    if ip:match("^%d+%.%d+%.%d+%.%d+$") or ip:match("^%d+%.%d+%.%d+%.%d+:%d+$") then
        local content, err = curl_local("/api/nodes/join?node=" .. ip, 15)
        mg.write(content or err or '{"error":"join failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

elseif action == "promote" then
    local ip = get_param("ip") or ""
    -- Validate IP format (digits and dots only)
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local content, err = curl_local("/api/sync/promote?ip=" .. ip)
        mg.write(content or err or '{"error":"promote failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

elseif action == "set-auth" then
    local ip = get_param("ip") or ""
    local password = get_param("password") or ""
    -- Validate IP format (digits and dots only)
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        -- 10s, not the 4s default. Timeouts here must INCREASE outward:
        -- _validate_sid (5s) < this (10s) < the browser's ajax (15s). If an outer
        -- budget is the smaller one it fires first, and the specific reason the
        -- inner layer worked out is thrown away in favour of a bare timeout.
        local content, err = curl_local("/api/auth/set?ip=" .. url_encode(ip) .. "&password=" .. url_encode(password), 10)
        mg.write(content or err or '{"error":"auth save failed"}')
    else
        mg.write('{"error":"invalid IP"}')
    end

else
    mg.write('{"error":"unknown action"}')
end
?>
