#!/usr/bin/lua
-- oaf-barkd.lua
-- Ultra-lightweight OpenAppFilter (OAF 7.0+) Online/Offline Bark Notifier
-- Designed for low-spec OpenWrt routers:
--   * Single resident Lua process (~900 KB RAM, < 0.01% CPU)
--   * In-process ubus calls via luci.util / libubus-lua (zero subshell forks when idle)
--   * Zero flash writes during operation (runtime state kept in RAM / /tmp tmpfs)
--   * Anti-flap offline debounce to prevent iPhone Wi-Fi power-save false alarms

local jsonc_ok, jsonc = pcall(require, "luci.jsonc")
local utl_ok, utl = pcall(require, "luci.util")
local uci_ok, uci = pcall(require, "uci")
local nixio_ok, nixio = pcall(require, "nixio")

local CONFIG_FILE = "/etc/config/oaf_bark"
local STATE_TMP_FILE = "/tmp/oaf_bark_state.json"
local EVENTS_TMP_FILE = "/tmp/oaf_bark_events.json"
local PID_FILE = "/var/run/oaf-barkd.pid"
local MAX_RECENT_EVENTS = 30

-- Write PID to /var/run (tmpfs)
do
    local pid = nixio_ok and nixio.getpid and nixio.getpid() or nil
    if pid then
        local f = io.open(PID_FILE, "w")
        if f then
            f:write(tostring(pid) .. "\n")
            f:close()
        end
    end
end

local function sleep_sec(sec)
    local s = tonumber(sec) or 15
    if s < 1 then s = 1 end
    if nixio_ok and nixio.nanosleep then
        nixio.nanosleep(math.floor(s), 0)
    else
        os.execute("sleep " .. tostring(math.floor(s)))
    end
end

local function json_stringify(obj)
    if jsonc_ok and jsonc and jsonc.stringify then
        return jsonc.stringify(obj)
    end
    return "{}"
end

local function json_parse(str)
    if not str or str == "" then return nil end
    if jsonc_ok and jsonc and jsonc.parse then
        return jsonc.parse(str)
    end
    return nil
end

local function file_mtime(path)
    if nixio_ok and nixio.fs and nixio.fs.stat then
        local st = nixio.fs.stat(path)
        return st and st.mtime or 0
    end
    local f = io.open(path, "r")
    if f then f:close(); return 1 end
    return 0
end

local function write_tmp_json(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(json_stringify(data))
    f:close()
    os.rename(tmp, path)
end

local function read_tmp_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return json_parse(content)
end

-- Normalize MAC to uppercase XX:XX:XX:XX:XX:XX
local function norm_mac(mac)
    if not mac or type(mac) ~= "string" then return "" end
    return string.upper((mac:gsub("^%s+", ""):gsub("%s+$", "")))
end

-- Call ubus in-process without forking when luci.util is available
local ubus_conn = nil
if not (utl_ok and utl and utl.ubus) then
    local ubus_mod_ok, ubus_mod = pcall(require, "ubus")
    if ubus_mod_ok and ubus_mod then
        ubus_conn = ubus_mod.connect()
    end
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
        local payload = json_stringify(req):gsub("'", "'\\''")
        local p = io.popen("ubus call fwx common '" .. payload .. "' 2>/dev/null")
        if not p then return nil end
        local out = p:read("*a")
        p:close()
        return json_parse(out)
    end
end

-- Load configuration from UCI (/etc/config/oaf_bark)
local function load_config()
    local cfg = {
        enabled = 0,
        bark_server = "https://api.day.app",
        bark_key = "",
        poll_interval = 15,
        offline_debounce = 90,
        watch_mode = "selected", -- "selected" or "all"
        notify_online = 1,
        notify_offline = 1,
        include_summary = 1,
        quiet_enable = 0,
        quiet_start = "23:30",
        quiet_end = "07:00",
        watched_macs = {}
    }

    if not uci_ok then return cfg end
    local cur = uci.cursor()
    cur:foreach("oaf_bark", "global", function(s)
        cfg.enabled = tonumber(s.enabled) or cfg.enabled
        if s.bark_server and s.bark_server ~= "" then
            cfg.bark_server = s.bark_server:gsub("/+$", "")
        end
        cfg.bark_key = s.bark_key or ""
        cfg.poll_interval = math.max(10, math.min(120, tonumber(s.poll_interval) or 15))
        cfg.offline_debounce = math.max(15, math.min(600, tonumber(s.offline_debounce) or 90))
        cfg.watch_mode = (s.watch_mode == "all") and "all" or "selected"
        cfg.notify_online = tonumber(s.notify_online or "1") or 1
        cfg.notify_offline = tonumber(s.notify_offline or "1") or 1
        cfg.include_summary = tonumber(s.include_summary or "1") or 1
        cfg.quiet_enable = tonumber(s.quiet_enable or "0") or 0
        cfg.quiet_start = s.quiet_start or "23:30"
        cfg.quiet_end = s.quiet_end or "07:00"

        local macs = s.watched_mac
        if type(macs) == "table" then
            for _, m in ipairs(macs) do
                local nm = norm_mac(m)
                if nm ~= "" then cfg.watched_macs[nm] = true end
            end
        elseif type(macs) == "string" and macs ~= "" then
            for m in string.gmatch(macs, "[^,%s]+") do
                local nm = norm_mac(m)
                if nm ~= "" then cfg.watched_macs[nm] = true end
            end
        end
    end)
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
    if h > 0 and m > 0 then
        return string.format("%d小时%d分", h, m)
    elseif h > 0 then
        return string.format("%d小时", h)
    elseif m > 0 then
        return string.format("%d分钟", m)
    else
        return string.format("%d秒", s)
    end
end

local function format_bytes(bytes)
    local b = tonumber(bytes) or 0
    if b <= 0 then return "0 MB" end
    if b >= 1073741824 then
        return string.format("%.2f GB", b / 1073741824)
    elseif b >= 1048576 then
        return string.format("%.1f MB", b / 1048576)
    else
        return string.format("%.0f KB", b / 1024)
    end
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local has_curl = nil
local function detect_http_client()
    if has_curl ~= nil then return has_curl end
    local rc = os.execute("command -v curl >/dev/null 2>&1")
    has_curl = (rc == 0 or rc == true)
    return has_curl
end

-- Send push to Bark server (only invoked on actual state transitions!)
local function send_bark_push(cfg, title, body, mac)
    if not cfg.bark_key or cfg.bark_key == "" then
        return false, "missing bark_key"
    end
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

    local body_json = json_stringify(payload)
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
    local ok = (rc == 0 or rc == true)
    return ok, ok and "ok" or "push command failed"
end

-- Query top 3 apps used today for offline summary
local function build_top_apps_summary(mac)
    local resp = call_fwx("dev_visit_time", { mac = mac })
    if not (resp and tonumber(resp.code) == 2000 and resp.data and type(resp.data.list) == "table") then
        return nil
    end
    local list = resp.data.list
    if #list == 0 then return nil end

    table.sort(list, function(a, b)
        return (tonumber(a.t) or 0) > (tonumber(b.t) or 0)
    end)

    local parts = {}
    local limit = math.min(3, #list)
    for i = 1, limit do
        local item = list[i]
        local dur = tonumber(item.t) or 0
        if dur >= 30 then
            local name = item.name
            if not name or name == "" then
                name = "App" .. tostring(item.id or item.appid or i)
            end
            table.insert(parts, string.format("%s(%s)", name, format_duration(dur)))
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "、")
end

-- Record recent events in RAM (/tmp/oaf_bark_events.json) for iOS App viewing
local recent_events = read_tmp_json(EVENTS_TMP_FILE)
if type(recent_events) ~= "table" then
    recent_events = {}
end

local function append_event(ev_type, mac, name, ip, detail, pushed)
    table.insert(recent_events, 1, {
        type = ev_type, -- "online" or "offline"
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
    write_tmp_json(EVENTS_TMP_FILE, recent_events)
end

local function should_watch_mac(cfg, mac)
    if cfg.watch_mode == "all" then
        return true
    end
    return cfg.watched_macs[mac] == true
end

local function display_name_for(u)
    local nick = (u.nickname or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if nick ~= "" and nick ~= "--" then return nick end
    local host = (u.hostname or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if host ~= "" and host ~= "*" and host ~= "--" then return host end
    return u.mac or "未知设备"
end

-- Runtime in-memory device table:
-- devices[mac] = {
--   online = true/false,
--   online_since = ts,
--   offline_since = nil or ts,
--   name = "...",
--   ip = "...",
--   today_active_time = 0,
--   today_bytes = 0
-- }
local devices = {}
local seeded = false
local last_cfg_mtime = -1
local cfg = load_config()

local function export_state_snapshot()
    local online_count = 0
    local tracked_count = 0
    for _, st in pairs(devices) do
        tracked_count = tracked_count + 1
        if st.online then online_count = online_count + 1 end
    end
    write_tmp_json(STATE_TMP_FILE, {
        updated_at = os.time(),
        online_count = online_count,
        tracked_count = tracked_count,
        enabled = cfg.enabled
    })
end

-- Main ultra-lightweight loop
while true do
    local mtime = file_mtime(CONFIG_FILE)
    if mtime ~= last_cfg_mtime then
        cfg = load_config()
        last_cfg_mtime = mtime
    end

    if cfg.enabled == 1 then
        local resp = call_fwx("get_all_users", { flag = 3, page = 1, page_size = 250 })
        local list = resp and tonumber(resp.code) == 2000 and resp.data and resp.data.list
        if type(list) == "table" then
            local now = os.time()
            local seen_in_poll = {}
            local state_changed = false

            for _, u in ipairs(list) do
                local mac = norm_mac(u.mac)
                if mac ~= "" then
                    seen_in_poll[mac] = true
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
                        -- Notify only if baseline was already seeded (a brand-new device joined!)
                        if seeded and is_online and should_watch_mac(cfg, mac) then
                            local pushed = false
                            if cfg.notify_online == 1 and not is_in_quiet_hours(cfg) then
                                local title = "🟢 " .. name .. " 已上线"
                                local body_lines = {}
                                if ip ~= "" then
                                    table.insert(body_lines, "IP 地址：" .. ip)
                                end
                                table.insert(body_lines, "上线时间：" .. os.date("%H:%M:%S", now))
                                pushed = send_bark_push(cfg, title, table.concat(body_lines, "\n"), mac)
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
                                -- Device reconnected within anti-flap debounce window: cancel pending offline!
                                st.offline_since = nil
                            elseif not st.online then
                                -- Genuine offline -> online transition
                                st.online = true
                                st.online_since = now
                                st.offline_since = nil
                                state_changed = true

                                if seeded and should_watch_mac(cfg, mac) then
                                    local pushed = false
                                    if cfg.notify_online == 1 and not is_in_quiet_hours(cfg) then
                                        local title = "🟢 " .. name .. " 已上线"
                                        local body_lines = {}
                                        if st.ip ~= "" then
                                            table.insert(body_lines, "IP 地址：" .. st.ip)
                                        end
                                        if active_sec > 60 then
                                            table.insert(body_lines, "今日已活跃：" .. format_duration(active_sec))
                                        end
                                        table.insert(body_lines, "上线时间：" .. os.date("%H:%M:%S", now))
                                        pushed = send_bark_push(cfg, title, table.concat(body_lines, "\n"), mac)
                                    end
                                    append_event("online", mac, name, st.ip, "连接恢复在线", pushed)
                                end
                            end
                        else
                            -- Reported offline in current poll
                            if st.online then
                                if st.offline_since == nil then
                                    st.offline_since = now
                                elseif (now - st.offline_since) >= cfg.offline_debounce then
                                    -- Confirmed offline after debounce grace period!
                                    local session_sec = 0
                                    if st.online_since and st.offline_since >= st.online_since then
                                        session_sec = st.offline_since - st.online_since
                                    end
                                    st.online = false
                                    st.offline_since = nil
                                    state_changed = true

                                    if seeded and should_watch_mac(cfg, mac) then
                                        local summary_parts = {}
                                        if session_sec > 0 then
                                            table.insert(summary_parts, "本次在线 " .. format_duration(session_sec))
                                        end
                                        if active_sec > 0 then
                                            table.insert(summary_parts, "今日活跃 " .. format_duration(active_sec))
                                        end
                                        if total_bytes > 1048576 then
                                            table.insert(summary_parts, "流量 " .. format_bytes(total_bytes))
                                        end
                                        local line1 = table.concat(summary_parts, " · ")

                                        local top_apps = nil
                                        if cfg.include_summary == 1 then
                                            top_apps = build_top_apps_summary(mac)
                                        end

                                        local pushed = false
                                        if cfg.notify_offline == 1 and not is_in_quiet_hours(cfg) then
                                            local title = "🔴 " .. name .. " 已离线"
                                            local body_lines = {}
                                            if line1 ~= "" then table.insert(body_lines, line1) end
                                            if top_apps then
                                                table.insert(body_lines, "今日常用：" .. top_apps)
                                            end
                                            table.insert(body_lines, "离线时间：" .. os.date("%H:%M:%S", now))
                                            pushed = send_bark_push(cfg, title, table.concat(body_lines, "\n"), mac)
                                        end
                                        local detail = line1
                                        if top_apps then
                                            detail = (detail ~= "" and (detail .. " | ") or "") .. top_apps
                                        end
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
                export_state_snapshot()
            end
        end
    end

    sleep_sec(cfg.poll_interval or 15)
end
