#!/usr/bin/lua
-- /usr/libexec/rpcd/oaf_bark
-- Pure Lua 5.1 OpenWrt rpcd ubus plugin (ZERO external Lua module dependencies!
-- Works on OpenWrt 19.07 - 25.12+, ImmortalWrt, LibWrt, LEDE, etc.)

local EVENTS_TMP_FILE = "/tmp/oaf_bark_events.json"
local STATE_TMP_FILE = "/tmp/oaf_bark_state.json"
local CONFIG_FILE = "/etc/config/oaf_bark"

-- ============================================================================
-- Minimal Pure-Lua JSON Encoder & Decoder (Zero external C module dependencies)
-- ============================================================================

local function is_array(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            return false
        end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return count > 0
end

local escape_map = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t'
}

local function escape_str(s)
    return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
        return escape_map[c] or string.format("\\u%04x", string.byte(c))
    end))
end

local function json_encode(val, empty_as_array)
    local tv = type(val)
    if val == nil then
        return "null"
    elseif tv == "boolean" then
        return val and "true" or "false"
    elseif tv == "number" then
        if val ~= val or val <= -math.huge or val >= math.huge then
            return "0"
        end
        return tostring(val)
    elseif tv == "string" then
        return '"' .. escape_str(val) .. '"'
    elseif tv == "table" then
        if next(val) == nil then
            if getmetatable(val) and getmetatable(val).__is_array or empty_as_array then
                return "[]"
            end
            return "{}"
        end
        if is_array(val) then
            local items = {}
            for i = 1, #val do
                items[i] = json_encode(val[i])
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            local items = {}
            for k, v in pairs(val) do
                if type(k) == "string" or type(k) == "number" then
                    table.insert(items, '"' .. escape_str(k) .. '":' .. json_encode(v))
                end
            end
            return "{" .. table.concat(items, ",") .. "}"
        end
    end
    return "null"
end

local function make_array(tbl)
    return setmetatable(tbl or {}, { __is_array = true })
end

local function json_decode(str)
    if type(str) ~= "string" then return nil end
    local pos = 1
    local len = #str

    local function skip_ws()
        while pos <= len do
            local b = string.byte(str, pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1 -- skip '"'
        local out = {}
        while pos <= len do
            local c = string.sub(str, pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == '\\' then
                pos = pos + 1
                local esc = string.sub(str, pos, pos)
                if esc == '"' or esc == '\\' or esc == '/' then
                    table.insert(out, esc)
                elseif esc == 'b' then table.insert(out, '\b')
                elseif esc == 'f' then table.insert(out, '\f')
                elseif esc == 'n' then table.insert(out, '\n')
                elseif esc == 'r' then table.insert(out, '\r')
                elseif esc == 't' then table.insert(out, '\t')
                elseif esc == 'u' then
                    local hex = string.sub(str, pos + 1, pos + 4)
                    local code = tonumber(hex, 16) or 32
                    if code < 128 then
                        table.insert(out, string.char(code))
                    elseif code < 2048 then
                        table.insert(out, string.char(192 + math.floor(code / 64), 128 + (code % 64)))
                    else
                        table.insert(out, string.char(
                            224 + math.floor(code / 4096),
                            128 + (math.floor(code / 64) % 64),
                            128 + (code % 64)
                        ))
                    end
                    pos = pos + 4
                end
                pos = pos + 1
            else
                local next_special = string.find(str, '["\\]', pos)
                if next_special then
                    table.insert(out, string.sub(str, pos, next_special - 1))
                    pos = next_special
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
        local num = tonumber(string.sub(str, s, e))
        pos = e + 1
        return num
    end

    local function parse_array()
        pos = pos + 1 -- skip '['
        local arr = make_array({})
        skip_ws()
        if string.sub(str, pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        local idx = 1
        while pos <= len do
            skip_ws()
            arr[idx] = parse_value()
            idx = idx + 1
            skip_ws()
            local ch = string.sub(str, pos, pos)
            if ch == ',' then
                pos = pos + 1
            elseif ch == ']' then
                pos = pos + 1
                return arr
            else
                break
            end
        end
        return arr
    end

    local function parse_object()
        pos = pos + 1 -- skip '{'
        local obj = {}
        skip_ws()
        if string.sub(str, pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while pos <= len do
            skip_ws()
            if string.sub(str, pos, pos) ~= '"' then break end
            local key = parse_string()
            skip_ws()
            if string.sub(str, pos, pos) == ':' then pos = pos + 1 end
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            local ch = string.sub(str, pos, pos)
            if ch == ',' then
                pos = pos + 1
            elseif ch == '}' then
                pos = pos + 1
                return obj
            else
                break
            end
        end
        return obj
    end

    parse_value = function()
        skip_ws()
        local ch = string.sub(str, pos, pos)
        if ch == '"' then return parse_string()
        elseif ch == '{' then return parse_object()
        elseif ch == '[' then return parse_array()
        elseif ch == 't' and string.sub(str, pos, pos + 3) == "true" then
            pos = pos + 4; return true
        elseif ch == 'f' and string.sub(str, pos, pos + 4) == "false" then
            pos = pos + 5; return false
        elseif ch == 'n' and string.sub(str, pos, pos + 3) == "null" then
            pos = pos + 4; return nil
        else
            return parse_number()
        end
    end

    local ok, res = pcall(parse_value)
    if ok then return res end
    return nil
end

-- ============================================================================
-- Pure-Lua UCI File Reader & Writer for /etc/config/oaf_bark (Zero dependencies)
-- ============================================================================

local function norm_mac(mac)
    if not mac or type(mac) ~= "string" then return "" end
    return string.upper((mac:gsub("^%s+", ""):gsub("%s+$", "")))
end

local function shell_quote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function read_tmp_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return json_decode(c or "")
end

local function is_daemon_running()
    local p = io.popen("ps w 2>/dev/null || ps 2>/dev/null")
    if not p then return 0 end
    local out = p:read("*a") or ""
    p:close()
    if string.find(out, "/usr/bin/oaf%-barkd") then
        return 1
    end
    return 0
end

local function read_config_file()
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
        watched_macs = make_array({}),
        daemon_running = is_daemon_running(),
        recent_events = make_array(read_tmp_json(EVENTS_TMP_FILE) or {}),
        state = read_tmp_json(STATE_TMP_FILE) or {}
    }

    local f = io.open(CONFIG_FILE, "r")
    if not f then return cfg end
    local mac_seen = {}
    for line in f:lines() do
        local k, v = string.match(line, "^%s*option%s+([%w_]+)%s+['\"]?(.-)['\"]?%s*$")
        if k and v then
            if k == "enabled" then cfg.enabled = tonumber(v) or 0
            elseif k == "bark_server" and v ~= "" then cfg.bark_server = v
            elseif k == "bark_key" then cfg.bark_key = v
            elseif k == "poll_interval" then cfg.poll_interval = tonumber(v) or 15
            elseif k == "offline_debounce" then cfg.offline_debounce = tonumber(v) or 90
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
                if nm ~= "" and not mac_seen[nm] then
                    mac_seen[nm] = true
                    table.insert(cfg.watched_macs, nm)
                end
            end
        end
    end
    f:close()
    return cfg
end

local function sanitize_uci_val(v)
    return tostring(v or ""):gsub("['\r\n]", "")
end

local function write_config_file(cfg)
    local lines = {
        "config global 'main'",
        string.format("\toption enabled '%d'", tonumber(cfg.enabled) == 1 and 1 or 0),
        string.format("\toption bark_server '%s'", sanitize_uci_val(cfg.bark_server ~= "" and cfg.bark_server or "https://api.day.app")),
        string.format("\toption bark_key '%s'", sanitize_uci_val(cfg.bark_key)),
        string.format("\toption poll_interval '%d'", math.max(10, math.min(120, tonumber(cfg.poll_interval) or 15))),
        string.format("\toption offline_debounce '%d'", math.max(15, math.min(600, tonumber(cfg.offline_debounce) or 90))),
        string.format("\toption watch_mode '%s'", (cfg.watch_mode == "all") and "all" or "selected"),
        string.format("\toption notify_online '%d'", tonumber(cfg.notify_online) == 1 and 1 or 0),
        string.format("\toption notify_offline '%d'", tonumber(cfg.notify_offline) == 1 and 1 or 0),
        string.format("\toption include_summary '%d'", tonumber(cfg.include_summary) == 1 and 1 or 0),
        string.format("\toption quiet_enable '%d'", tonumber(cfg.quiet_enable) == 1 and 1 or 0),
        string.format("\toption quiet_start '%s'", sanitize_uci_val(cfg.quiet_start ~= "" and cfg.quiet_start or "23:30")),
        string.format("\toption quiet_end '%s'", sanitize_uci_val(cfg.quiet_end ~= "" and cfg.quiet_end or "07:00"))
    }
    if type(cfg.watched_macs) == "table" then
        local seen = {}
        for _, m in ipairs(cfg.watched_macs) do
            local nm = norm_mac(m)
            if nm ~= "" and not seen[nm] then
                seen[nm] = true
                table.insert(lines, string.format("\tlist watched_mac '%s'", sanitize_uci_val(nm)))
            end
        end
    end
    local tmp = CONFIG_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
        os.rename(tmp, CONFIG_FILE)
    end
end

local function apply_service_state(enabled)
    if tonumber(enabled) == 1 then
        os.execute("/etc/init.d/oaf-bark enable >/dev/null 2>&1")
        os.execute("/etc/init.d/oaf-bark restart >/dev/null 2>&1")
    else
        os.execute("/etc/init.d/oaf-bark stop >/dev/null 2>&1")
    end
end

-- ============================================================================
-- rpcd Method Signatures & Dispatch
-- ============================================================================

local methods = {
    get_config = {},
    set_config = {
        enabled = 32,
        bark_server = "str",
        bark_key = "str",
        poll_interval = 32,
        offline_debounce = 32,
        watch_mode = "str",
        notify_online = 32,
        notify_offline = 32,
        include_summary = 32,
        quiet_enable = 32,
        quiet_start = "str",
        quiet_end = "str",
        watched_macs_csv = "str"
    },
    toggle_device = {
        mac = "str",
        watch = 32
    },
    test_push = {
        bark_server = "str",
        bark_key = "str",
        mac = "str",
        device_name = "str"
    },
    clear_events = {}
}

if arg[1] == "list" then
    io.write(json_encode(methods))
    os.exit(0)
elseif arg[1] == "call" then
    local method = arg[2]
    local raw = io.read("*a")
    local req = (raw and raw ~= "") and (json_decode(raw) or {}) or {}

    if method == "get_config" then
        io.write(json_encode({ code = 0, data = read_config_file() }))
        os.exit(0)

    elseif method == "set_config" then
        local cur = read_config_file()
        if req.enabled ~= nil then cur.enabled = tonumber(req.enabled) or 0 end
        if req.bark_server ~= nil then cur.bark_server = tostring(req.bark_server):gsub("/+$", "") end
        if req.bark_key ~= nil then cur.bark_key = tostring(req.bark_key) end
        if req.poll_interval ~= nil then cur.poll_interval = tonumber(req.poll_interval) or 15 end
        if req.offline_debounce ~= nil then cur.offline_debounce = tonumber(req.offline_debounce) or 90 end
        if req.watch_mode ~= nil then cur.watch_mode = (req.watch_mode == "all") and "all" or "selected" end
        if req.notify_online ~= nil then cur.notify_online = tonumber(req.notify_online) or 0 end
        if req.notify_offline ~= nil then cur.notify_offline = tonumber(req.notify_offline) or 0 end
        if req.include_summary ~= nil then cur.include_summary = tonumber(req.include_summary) or 0 end
        if req.quiet_enable ~= nil then cur.quiet_enable = tonumber(req.quiet_enable) or 0 end
        if req.quiet_start ~= nil then cur.quiet_start = tostring(req.quiet_start) end
        if req.quiet_end ~= nil then cur.quiet_end = tostring(req.quiet_end) end

        if type(req.watched_macs_csv) == "string" then
            local clean = make_array({})
            local seen = {}
            for m in string.gmatch(req.watched_macs_csv, "[^,%s]+") do
                local nm = norm_mac(m)
                if nm ~= "" and not seen[nm] then
                    seen[nm] = true
                    table.insert(clean, nm)
                end
            end
            cur.watched_macs = clean
        end

        write_config_file(cur)
        apply_service_state(cur.enabled)
        local refreshed = read_config_file()
        io.write(json_encode({ code = 0, data = refreshed }))
        os.exit(0)

    elseif method == "toggle_device" then
        local target_mac = norm_mac(req.mac)
        local watch = tonumber(req.watch) or 0
        if target_mac == "" then
            io.write(json_encode({ code = 1, message = "invalid mac" }))
            os.exit(0)
        end
        local cur = read_config_file()
        local clean = make_array({})
        local seen = {}
        for _, m in ipairs(cur.watched_macs or {}) do
            local nm = norm_mac(m)
            if nm ~= "" and nm ~= target_mac and not seen[nm] then
                seen[nm] = true
                table.insert(clean, nm)
            end
        end
        if watch == 1 then
            table.insert(clean, target_mac)
        end
        cur.watched_macs = clean
        write_config_file(cur)
        io.write(json_encode({ code = 0, data = read_config_file() }))
        os.exit(0)

    elseif method == "test_push" then
        local current = read_config_file()
        local server = (req.bark_server and req.bark_server ~= "") and req.bark_server or current.bark_server
        local key = (req.bark_key and req.bark_key ~= "") and req.bark_key or current.bark_key
        if not key or key == "" then
            io.write(json_encode({ code = 1, message = "请先填写 Bark Key" }))
            os.exit(0)
        end
        local endpoint = tostring(server):gsub("/+$", "") .. "/push"
        local mac = norm_mac(req.mac)
        local dev_name = (req.device_name and req.device_name ~= "") and req.device_name or "测试终端"
        local payload = {
            device_key = key,
            title = "🔔 OAF Pulse 测试通知",
            body = string.format("路由器连接正常 (%s)\n点击此通知可直接打开 %s 详情页", os.date("%H:%M:%S"), dev_name),
            group = "OAF终端动态",
            icon = "https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent/bark-icon.png",
            level = "active",
            url = (mac ~= "") and ("oafpulse://device?mac=" .. mac) or "oafpulse://home"
        }

        local body_json = json_encode(payload)
        local has_curl_rc = os.execute("command -v curl >/dev/null 2>&1")
        local has_curl = (has_curl_rc == 0 or has_curl_rc == true)
        local cmd
        if has_curl then
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
        if rc == 0 or rc == true then
            io.write(json_encode({ code = 0, message = "测试推送已送达 Bark 服务器" }))
        else
            io.write(json_encode({ code = 2, message = "路由器访问 Bark 服务器失败，请检查 Bark Key 或路由器外网网络" }))
        end
        os.exit(0)

    elseif method == "clear_events" then
        os.remove(EVENTS_TMP_FILE)
        io.write(json_encode({ code = 0 }))
        os.exit(0)
    end
end

io.write(json_encode({ code = -1, message = "unknown method" }))
