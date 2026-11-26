#!/usr/bin/lua
-- /usr/bin/oaf-barkd
-- Zero-dependency Pure Lua 5.1 Online/Offline Bark Notifier for OpenWrt + OAF 7.0+
-- Compatible with OpenWrt 19.07 - 25.12+, LibWrt, ImmortalWrt (no luci.jsonc / libuci-lua required)

local CONFIG_FILE = "/etc/config/oaf_bark"
local STATE_TMP_FILE = "/tmp/oaf_bark_state.json"
local EVENTS_TMP_FILE = "/tmp/oaf_bark_events.json"
local MAX_RECENT_EVENTS = 30

local nixio_ok, nixio = pcall(require, "nixio")
local utl_ok, utl = pcall(require, "luci.util")
local ubus_ok, ubus_mod = pcall(require, "ubus")
local ubus_conn = nil
if not (utl_ok and utl and utl.ubus) and ubus_ok and ubus_mod and ubus_mod.connect then
    ubus_conn = ubus_mod.connect()
end

-- ============================================================================
-- Pure-Lua JSON Encoder & Decoder
-- ============================================================================

local function is_array(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

local escape_map = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'
}

local function escape_str(s)
    return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
        return escape_map[c] or string.format("\\u%04x", string.byte(c))
    end))
end

local function make_array(tbl)
    return setmetatable(tbl or {}, { __is_array = true })
end

local function json_encode(val)
    local tv = type(val)
    if val == nil then return "null"
    elseif tv == "boolean" then return val and "true" or "false"
    elseif tv == "number" then
        if val ~= val or val <= -math.huge or val >= math.huge then return "0" end
        return tostring(val)
    elseif tv == "string" then return '"' .. escape_str(val) .. '"'
    elseif tv == "table" then
        if next(val) == nil then
            if getmetatable(val) and getmetatable(val).__is_array then return "[]" end
            return "{}"
        end
        if is_array(val) then
            local out = {}
            for i = 1, #val do out[i] = json_encode(val[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        else
            local out = {}
            for k, v in pairs(val) do
                if type(k) == "string" or type(k) == "number" then
                    table.insert(out, '"' .. escape_str(k) .. '":' .. json_encode(v))
                end
            end
            return "{" .. table.concat(out, ",") .. "}"
        end
    end
    return "null"
end

local function json_decode(str)
    if type(str) ~= "string" or str == "" then return nil end
    local pos, len = 1, #str

    local function skip_ws()
        while pos <= len do
            local b = string.byte(str, pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = string.sub(str, pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(out)
            elseif c == '\\' then
                pos = pos + 1
                local esc = string.sub(str, pos, pos)
                if esc == '"' or esc == '\\' or esc == '/' then table.insert(out, esc)
                elseif esc == 'b' then table.insert(out, '\b')
                elseif esc == 'f' then table.insert(out, '\f')
                elseif esc == 'n' then table.insert(out, '\n')
                elseif esc == 'r' then table.insert(out, '\r')
                elseif esc == 't' then table.insert(out, '\t')
                elseif esc == 'u' then
                    local code = tonumber(string.sub(str, pos + 1, pos + 4), 16) or 32
                    if code < 128 then table.insert(out, string.char(code))
                    elseif code < 2048 then
                        table.insert(out, string.char(192 + math.floor(code / 64), 128 + (code % 64)))
                    else
                        table.insert(out, string.char(224 + math.floor(code / 4096), 128 + (math.floor(code / 64) % 64), 128 + (code % 64)))
                    end
                    pos = pos + 4
                end
                pos = pos + 1
            else
                local ns = string.find(str, '["\\]', pos)
                if ns then
                    table.insert(out, string.sub(str, pos, ns - 1))
                    pos = ns
                else
                    table.insert(out, string.sub(str, pos))
                    pos = len + 1
                end
            end
        end
        return table.concat(out)
    end

    local function parse_number()
        local s, e = string.find(str, "^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if not s then return nil end
        local n = tonumber(string.sub(str, s, e))
        pos = e + 1
        return n
    end

    local function parse_array()
        pos = pos + 1
        local arr = make_array({})
        skip_ws()
        if string.sub(str, pos, pos) == ']' then pos = pos + 1; return arr end
        local idx = 1
        while pos <= len do
            skip_ws()
            arr[idx] = parse_value()
            idx = idx + 1
            skip_ws()
            local ch = string.sub(str, pos, pos)
            if ch == ',' then pos = pos + 1
            elseif ch == ']' then pos = pos + 1; return arr
            else break end
        end
        return arr
    end

    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if string.sub(str, pos, pos) == '}' then pos = pos + 1; return obj end
        while pos <= len do
            skip_ws()
            if string.sub(str, pos, pos) ~= '"' then break end
            local k = parse_string()
            skip_ws()
            if string.sub(str, pos, pos) == ':' then pos = pos + 1 end
            skip_ws()
            obj[k] = parse_value()
            skip_ws()
            local ch = string.sub(str, pos, pos)
            if ch == ',' then pos = pos + 1
            elseif ch == '}' then pos = pos + 1; return obj
            else break end
        end
        return obj
    end

    parse_value = function()
        skip_ws()
        local ch = string.sub(str, pos, pos)
        if ch == '"' then return parse_string()
        elseif ch == '{' then return parse_object()
        elseif ch == '[' then return parse_array()
        elseif ch == 't' and string.sub(str, pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif ch == 'f' and string.sub(str, pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif ch == 'n' and string.sub(str, pos, pos + 3) == "null" then pos = pos + 4; return nil
        else return parse_number() end
    end

    local ok, res = pcall(parse_value)
    return ok and res or nil
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function sleep_sec(sec)
    local s = math.max(1, math.floor(tonumber(sec) or 15))
    if nixio_ok and nixio and nixio.nanosleep then
        nixio.nanosleep(s, 0)
    else
        os.execute("sleep " .. tostring(s))
    end
end

local function norm_mac(mac)
    if not mac or type(mac) ~= "string" then return "" end
    return string.upper((mac:gsub("^%s+", ""):gsub("%s+$", "")))
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function write_tmp_json(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(json_encode(data))
    f:close()
    os.rename(tmp, path)
end

local function read_tmp_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return json_decode(c or "")
end

local function call_fwx(api_name, data_tbl)
    local req = {
        api = api_name,
        CopyRight = "www.fanchmwrt.com",
        data = data_tbl or {}
    }
    if utl_ok and utl and utl.ubus then
        return utl.ubus("fwx", "common", req)
    elseif ubus_conn then
        return ubus_conn:call("fwx", "common", req)
    else
        local payload = json_encode(req)
        local p = io.popen("ubus call fwx common " .. shell_quote(payload) .. " 2>/dev/null")
        if not p then return nil end
        local out = p:read("*a")
        p:close()
        return json_decode(out)
    end
end

local function load_config()
    local cfg = {
        enabled = 0,
        bark_server = "https://api.day.app",
        bark_key = "",
        poll_interval = 15,
        offline_debounce = 90,
        watch_mode = "selected",
        notify_online = 1,
        notify_offline = 1,
        include_summary = 1,
        quiet_enable = 0,
        quiet_start = "23:30",
        quiet_end = "07:00",
        watched_macs = {},
        ignored_ids = {},
        ignored_names = {}
    }

    local f = io.open(CONFIG_FILE, "r")
    if not f then return cfg end
    for line in f:lines() do
        local k, v = string.match(line, "^%s*option%s+([%w_]+)%s+['\"]?(.-)['\"]?%s*$")
        if k and v then
            if k == "enabled" then cfg.enabled = tonumber(v) or 0
            elseif k == "bark_server" and v ~= "" then cfg.bark_server = v:gsub("/+$", "")
            elseif k == "bark_key" then cfg.bark_key = v
            elseif k == "poll_interval" then cfg.poll_interval = math.max(10, math.min(120, tonumber(v) or 15))
            elseif k == "offline_debounce" then cfg.offline_debounce = math.max(15, math.min(600, tonumber(v) or 90))
            elseif k == "watch_mode" then cfg.watch_mode = (v == "all") and "all" or "selected"
            elseif k == "notify_online" then cfg.notify_online = tonumber(v) or 0
            elseif k == "notify_offline" then cfg.notify_offline = tonumber(v) or 0
            elseif k == "include_summary" then cfg.include_summary = tonumber(v) or 0
            elseif k == "quiet_enable" then cfg.quiet_enable = tonumber(v) or 0
            elseif k == "quiet_start" and v ~= "" then cfg.quiet_start = v
            elseif k == "quiet_end" and v ~= "" then cfg.quiet_end = v
            end
        else
            local lk, lv = string.match(line, "^%s*list%s+([%w_]+)%s+['\"]?(.-)['\"]?%s*$")
            if lk == "watched_mac" and lv then
                local nm = norm_mac(lv)
                if nm ~= "" then cfg.watched_macs[nm] = true end
            elseif (lk == "ignored_app" or lk == "disabled_rule") and lv then
                local id_s, aname = string.match(lv, "^(%d+)~(.*)$")
                if id_s and tonumber(id_s) and tonumber(id_s) > 0 then
                    cfg.ignored_ids[tonumber(id_s)] = true
                end
                if aname and aname ~= "" then
                    cfg.ignored_names[aname] = true
                end
            end
        end
    end
    f:close()
    return cfg
end

local function parse_hhmm(str)
    local h, m = string.match(str or "", "^(%d%d?):(%d%d)$")
    if not h or not m then return nil end
    return (tonumber(h) * 60) + tonumber(m)
end

local function is_in_quiet_hours(cfg)
    if cfg.quiet_enable ~= 1 then return false end
    local s_min = parse_hhmm(cfg.quiet_start)
    local e_min = parse_hhmm(cfg.quiet_end)
    if not s_min or not e_min then return false end
    local t = os.date("*t")
    local cur_min = t.hour * 60 + t.min
    if s_min <= e_min then
        return cur_min >= s_min and cur_min < e_min
    else
        return cur_min >= s_min or cur_min < e_min
    end
end

local function format_duration(seconds)
    local s = math.max(0, math.floor(tonumber(seconds) or 0))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    if h > 0 and m > 0 then return string.format("%d小时%d分", h, m)
    elseif h > 0 then return string.format("%d小时", h)
    elseif m > 0 then return string.format("%d分钟", m)
    else return string.format("%d秒", s) end
end

local function format_bytes(bytes)
    local b = tonumber(bytes) or 0
    if b <= 0 then return "0 MB" end
    if b >= 1073741824 then return string.format("%.2f GB", b / 1073741824)
    elseif b >= 1048576 then return string.format("%.1f MB", b / 1048576)
    else return string.format("%.0f KB", b / 1024) end
end

local has_curl = nil
local function detect_http_client()
    if has_curl ~= nil then return has_curl end
    local rc = os.execute("command -v curl >/dev/null 2>&1")
    has_curl = (rc == 0 or rc == true)
    return has_curl
end

local function send_bark_push(cfg, title, body, mac)
    if not cfg.bark_key or cfg.bark_key == "" then return false end
    local server = (cfg.bark_server and cfg.bark_server ~= "") and cfg.bark_server or "https://api.day.app"
    local endpoint = server:gsub("/+$", "") .. "/push"

    local payload = {
        device_key = cfg.bark_key,
        title = title,
        body = body,
        group = "OAF终端动态",
        icon = "https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent/bark-icon.png",
        level = "active"
    }
    if mac and mac ~= "" then
        payload.url = "oafpulse://device?mac=" .. mac
    end

    local body_json = json_encode(payload)
    local cmd
    if detect_http_client() then
        cmd = string.format(
            "curl -fsSL -m 8 -X POST -H 'Content-Type: application/json; charset=utf-8' -d %s %s >/dev/null 2>&1",
            shell_quote(body_json),
            shell_quote(endpoint)
        )
    else
        cmd = string.format(
            "uclient-fetch -q -T 8 --header='Content-Type: application/json; charset=utf-8' --post-data=%s -O /dev/null %s >/dev/null 2>&1",
            shell_quote(body_json),
            shell_quote(endpoint)
        )
    end
    local rc = os.execute(cmd)
    return (rc == 0 or rc == true)
end

local function build_top_apps_summary(cfg, mac)
    local resp = call_fwx("dev_visit_time", { mac = string.lower(mac) })
    if not (resp and tonumber(resp.code) == 2000 and resp.data and type(resp.data.list) == "table") then
        return nil
    end
    local list = resp.data.list
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return (tonumber(a.t) or 0) > (tonumber(b.t) or 0) end)

    local parts = {}
    for i = 1, #list do
        local item = list[i]
        local dur = tonumber(item.t) or 0
        local aid = tonumber(item.id or item.appid) or 0
        local name = item.name or ""
        local is_ignored = (aid > 0 and cfg.ignored_ids[aid]) or (name ~= "" and cfg.ignored_names[name])
        if dur >= 30 and not is_ignored then
            if name == "" then name = "App" .. tostring(aid > 0 and aid or i) end
            table.insert(parts, string.format("%s(%s)", name, format_duration(dur)))
            if #parts >= 3 then break end
        end
    end
    return (#parts > 0) and table.concat(parts, "、") or nil
end

local recent_events = read_tmp_json(EVENTS_TMP_FILE)
if type(recent_events) ~= "table" then recent_events = make_array({}) end

local function append_event(ev_type, mac, name, ip, detail, pushed)
    table.insert(recent_events, 1, {
        type = ev_type,
        mac = mac,
        name = name,
        ip = ip or "",
        detail = detail or "",
        pushed = pushed and 1 or 0,
        timestamp = os.time()
    })
    while #recent_events > MAX_RECENT_EVENTS do
        table.remove(recent_events)
    end
    setmetatable(recent_events, { __is_array = true })
    write_tmp_json(EVENTS_TMP_FILE, recent_events)
end

local function should_watch_mac(cfg, mac)
    if cfg.watch_mode == "all" then return true end
    return cfg.watched_macs[mac] == true
end

local function display_name_for(u)
    local nick = (u.nickname or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if nick ~= "" and nick ~= "--" then return nick end
    local host = (u.hostname or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if host ~= "" and host ~= "*" and host ~= "--" then return host end
    return u.mac or "未知设备"
end

local devices = {}
local seeded = false

while true do
    local cfg = load_config()

    if cfg.enabled == 1 then
        local resp = call_fwx("get_all_users", { flag = 3, page = 1, page_size = 250 })
        local list = resp and tonumber(resp.code) == 2000 and resp.data and resp.data.list
        if type(list) == "table" then
            local now = os.time()
            local state_changed = false

            for _, u in ipairs(list) do
                local mac = norm_mac(u.mac)
                if mac ~= "" then
                    local is_online = (tonumber(u.online) == 1)
                    local name = display_name_for(u)
                    local ip = (u.ip and u.ip ~= "--") and u.ip or ""
                    local active_sec = tonumber(u.today_active_time) or 0
                    local total_bytes = (tonumber(u.today_up_bytes) or 0) + (tonumber(u.today_down_bytes) or 0)

                    local st = devices[mac]
                    if not st then
                        devices[mac] = {
                            online = is_online,
                            online_since = is_online and now or nil,
                            offline_since = nil,
                            name = name,
                            ip = ip,
                            today_active_time = active_sec,
                            today_bytes = total_bytes
                        }
                        state_changed = true
                        if seeded and is_online and should_watch_mac(cfg, mac) then
                            local pushed = false
                            if cfg.notify_online == 1 and not is_in_quiet_hours(cfg) then
                                local body = (ip ~= "" and ("IP 地址：" .. ip .. "\n") or "") .. "上线时间：" .. os.date("%H:%M:%S", now)
                                pushed = send_bark_push(cfg, "🟢 " .. name .. " 已上线", body, mac)
                            end
                            append_event("online", mac, name, ip, "新连接至路由器", pushed)
                        end
                    else
                        st.name = name
                        if ip ~= "" then st.ip = ip end
                        st.today_active_time = active_sec
                        st.today_bytes = total_bytes

                        if is_online then
                            if st.offline_since ~= nil then
                                st.offline_since = nil
                            elseif not st.online then
                                st.online = true
                                st.online_since = now
                                st.offline_since = nil
                                state_changed = true

                                if seeded and should_watch_mac(cfg, mac) then
                                    local pushed = false
                                    if cfg.notify_online == 1 and not is_in_quiet_hours(cfg) then
                                        local lines = {}
                                        if st.ip ~= "" then table.insert(lines, "IP 地址：" .. st.ip) end
                                        if active_sec > 60 then table.insert(lines, "今日已活跃：" .. format_duration(active_sec)) end
                                        table.insert(lines, "上线时间：" .. os.date("%H:%M:%S", now))
                                        pushed = send_bark_push(cfg, "🟢 " .. name .. " 已上线", table.concat(lines, "\n"), mac)
                                    end
                                    append_event("online", mac, name, st.ip, "连接恢复在线", pushed)
                                end
                            end
                        else
                            if st.online then
                                if st.offline_since == nil then
                                    st.offline_since = now
                                elseif (now - st.offline_since) >= cfg.offline_debounce then
                                    local session_sec = (st.online_since and st.offline_since >= st.online_since) and (st.offline_since - st.online_since) or 0
                                    st.online = false
                                    st.offline_since = nil
                                    state_changed = true

                                    if seeded and should_watch_mac(cfg, mac) then
                                        local summary_parts = {}
                                        if session_sec > 0 then table.insert(summary_parts, "本次在线 " .. format_duration(session_sec)) end
                                        if active_sec > 0 then table.insert(summary_parts, "今日活跃 " .. format_duration(active_sec)) end
                                        if total_bytes > 1048576 then table.insert(summary_parts, "流量 " .. format_bytes(total_bytes)) end
                                        local line1 = table.concat(summary_parts, " · ")

                                        local top_apps = (cfg.include_summary == 1) and build_top_apps_summary(cfg, mac) or nil
                                        local pushed = false
                                        if cfg.notify_offline == 1 and not is_in_quiet_hours(cfg) then
                                            local lines = {}
                                            if line1 ~= "" then table.insert(lines, line1) end
                                            if top_apps then table.insert(lines, "今日常用：" .. top_apps) end
                                            table.insert(lines, "离线时间：" .. os.date("%H:%M:%S", now))
                                            pushed = send_bark_push(cfg, "🔴 " .. name .. " 已离线", table.concat(lines, "\n"), mac)
                                        end
                                        local detail = line1
                                        if top_apps then detail = (detail ~= "" and (detail .. " | ") or "") .. top_apps end
                                        append_event("offline", mac, name, st.ip, detail, pushed)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            if not seeded then
                seeded = true
                state_changed = true
            end
            if state_changed then
                local online_count, tracked_count = 0, 0
                for _, s in pairs(devices) do
                    tracked_count = tracked_count + 1
                    if s.online then online_count = online_count + 1 end
                end
                write_tmp_json(STATE_TMP_FILE, {
                    updated_at = os.time(),
                    online_count = online_count,
                    tracked_count = tracked_count,
                    enabled = cfg.enabled
                })
            end
        end
    end

    sleep_sec(cfg.poll_interval or 15)
end
