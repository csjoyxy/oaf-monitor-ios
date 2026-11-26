#!/usr/bin/lua
-- /usr/libexec/rpcd/oaf_bark
-- OpenWrt rpcd ubus plugin exposing `oaf_bark` for the OAF Pulse iOS App

local jsonc = require "luci.jsonc"
local uci = require "uci"

local EVENTS_TMP_FILE = "/tmp/oaf_bark_events.json"
local STATE_TMP_FILE = "/tmp/oaf_bark_state.json"

local methods = {
    get_config = {},
    set_config = {
        enabled = 0,
        bark_server = "str",
        bark_key = "str",
        poll_interval = 0,
        offline_debounce = 0,
        watch_mode = "str",
        notify_online = 0,
        notify_offline = 0,
        include_summary = 0,
        quiet_enable = 0,
        quiet_start = "str",
        quiet_end = "str",
        watched_macs = { "str" },
        watched_macs_csv = "str"
    },
    toggle_device = {
        mac = "str",
        watch = 0
    },
    test_push = {
        bark_server = "str",
        bark_key = "str",
        mac = "str",
        device_name = "str"
    },
    clear_events = {}
}

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
    return jsonc.parse(c or "")
end

local function ensure_section(cur)
    local sec_name = nil
    cur:foreach("oaf_bark", "global", function(s)
        if not sec_name then sec_name = s[".name"] end
    end)
    if not sec_name then
        local f = io.open("/etc/config/oaf_bark", "a")
        if f then f:close() end
        cur = uci.cursor()
        sec_name = cur:add("oaf_bark", "global")
        cur:commit("oaf_bark")
    end
    return cur, sec_name
end

local function is_daemon_running()
    local rc = os.execute("pgrep -f '/usr/bin/oaf-barkd' >/dev/null 2>&1")
    return (rc == 0 or rc == true) and 1 or 0
end

local function read_uci_config()
    local cur = uci.cursor()
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
        daemon_running = is_daemon_running(),
        recent_events = read_tmp_json(EVENTS_TMP_FILE) or {},
        state = read_tmp_json(STATE_TMP_FILE) or {}
    }

    cur:foreach("oaf_bark", "global", function(s)
        cfg.enabled = tonumber(s.enabled) or 0
        cfg.bark_server = (s.bark_server and s.bark_server ~= "") and s.bark_server or "https://api.day.app"
        cfg.bark_key = s.bark_key or ""
        cfg.poll_interval = tonumber(s.poll_interval) or 15
        cfg.offline_debounce = tonumber(s.offline_debounce) or 90
        cfg.watch_mode = (s.watch_mode == "all") and "all" or "selected"
        cfg.notify_online = tonumber(s.notify_online or "1") or 1
        cfg.notify_offline = tonumber(s.notify_offline or "1") or 1
        cfg.include_summary = tonumber(s.include_summary or "1") or 1
        cfg.quiet_enable = tonumber(s.quiet_enable or "0") or 0
        cfg.quiet_start = s.quiet_start or "23:30"
        cfg.quiet_end = s.quiet_end or "07:00"

        local list = {}
        local seen = {}
        local raw = s.watched_mac
        if type(raw) == "table" then
            for _, m in ipairs(raw) do
                local nm = norm_mac(m)
                if nm ~= "" and not seen[nm] then
                    seen[nm] = true
                    table.insert(list, nm)
                end
            end
        elseif type(raw) == "string" and raw ~= "" then
            for m in string.gmatch(raw, "[^,%s]+") do
                local nm = norm_mac(m)
                if nm ~= "" and not seen[nm] then
                    seen[nm] = true
                    table.insert(list, nm)
                end
            end
        end
        cfg.watched_macs = list
    end)

    return cfg
end

local function read_stdin_args()
    local raw = io.read("*a")
    if not raw or raw == "" then return {} end
    return jsonc.parse(raw) or {}
end

local function apply_service_state(enabled)
    if tonumber(enabled) == 1 then
        os.execute("/etc/init.d/oaf-bark enable >/dev/null 2>&1")
        os.execute("/etc/init.d/oaf-bark restart >/dev/null 2>&1")
    else
        os.execute("/etc/init.d/oaf-bark stop >/dev/null 2>&1")
    end
end

if arg[1] == "list" then
    io.write(jsonc.stringify(methods))
    os.exit(0)
elseif arg[1] == "call" then
    local method = arg[2]
    local req = read_stdin_args()

    if method == "get_config" then
        io.write(jsonc.stringify({ code = 0, data = read_uci_config() }))
        os.exit(0)

    elseif method == "set_config" then
        local cur = uci.cursor()
        local sec
        cur, sec = ensure_section(cur)

        if req.enabled ~= nil then cur:set("oaf_bark", sec, "enabled", tostring(tonumber(req.enabled) or 0)) end
        if req.bark_server ~= nil then cur:set("oaf_bark", sec, "bark_server", tostring(req.bark_server):gsub("/+$", "")) end
        if req.bark_key ~= nil then cur:set("oaf_bark", sec, "bark_key", tostring(req.bark_key)) end
        if req.poll_interval ~= nil then
            local p = math.max(10, math.min(120, tonumber(req.poll_interval) or 15))
            cur:set("oaf_bark", sec, "poll_interval", tostring(p))
        end
        if req.offline_debounce ~= nil then
            local d = math.max(15, math.min(600, tonumber(req.offline_debounce) or 90))
            cur:set("oaf_bark", sec, "offline_debounce", tostring(d))
        end
        if req.watch_mode ~= nil then
            cur:set("oaf_bark", sec, "watch_mode", (req.watch_mode == "all") and "all" or "selected")
        end
        if req.notify_online ~= nil then cur:set("oaf_bark", sec, "notify_online", tostring(tonumber(req.notify_online) or 0)) end
        if req.notify_offline ~= nil then cur:set("oaf_bark", sec, "notify_offline", tostring(tonumber(req.notify_offline) or 0)) end
        if req.include_summary ~= nil then cur:set("oaf_bark", sec, "include_summary", tostring(tonumber(req.include_summary) or 0)) end
        if req.quiet_enable ~= nil then cur:set("oaf_bark", sec, "quiet_enable", tostring(tonumber(req.quiet_enable) or 0)) end
        if req.quiet_start ~= nil then cur:set("oaf_bark", sec, "quiet_start", tostring(req.quiet_start)) end
        if req.quiet_end ~= nil then cur:set("oaf_bark", sec, "quiet_end", tostring(req.quiet_end)) end

        if type(req.watched_macs_csv) == "string" then
            local clean = {}
            local seen = {}
            for m in string.gmatch(req.watched_macs_csv, "[^,%s]+") do
                local nm = norm_mac(m)
                if nm ~= "" and not seen[nm] then
                    seen[nm] = true
                    table.insert(clean, nm)
                end
            end
            if #clean > 0 then
                cur:set_list("oaf_bark", sec, "watched_mac", clean)
            else
                cur:delete("oaf_bark", sec, "watched_mac")
            end
        elseif type(req.watched_macs) == "table" then
            local clean = {}
            local seen = {}
            for _, m in ipairs(req.watched_macs) do
                local nm = norm_mac(m)
                if nm ~= "" and not seen[nm] then
                    seen[nm] = true
                    table.insert(clean, nm)
                end
            end
            if #clean > 0 then
                cur:set_list("oaf_bark", sec, "watched_mac", clean)
            else
                cur:delete("oaf_bark", sec, "watched_mac")
            end
        end

        cur:commit("oaf_bark")
        local updated = read_uci_config()
        apply_service_state(updated.enabled)
        updated.daemon_running = is_daemon_running()
        io.write(jsonc.stringify({ code = 0, data = updated }))
        os.exit(0)

    elseif method == "toggle_device" then
        local target_mac = norm_mac(req.mac)
        local watch = tonumber(req.watch) or 0
        if target_mac == "" then
            io.write(jsonc.stringify({ code = 1, message = "invalid mac" }))
            os.exit(0)
        end

        local cur = uci.cursor()
        local sec
        cur, sec = ensure_section(cur)
        local current = read_uci_config()
        local clean = {}
        local seen = {}
        for _, m in ipairs(current.watched_macs or {}) do
            local nm = norm_mac(m)
            if nm ~= "" and nm ~= target_mac and not seen[nm] then
                seen[nm] = true
                table.insert(clean, nm)
            end
        end
        if watch == 1 then
            table.insert(clean, target_mac)
        end
        if #clean > 0 then
            cur:set_list("oaf_bark", sec, "watched_mac", clean)
        else
            cur:delete("oaf_bark", sec, "watched_mac")
        end
        cur:commit("oaf_bark")
        io.write(jsonc.stringify({ code = 0, data = read_uci_config() }))
        os.exit(0)

    elseif method == "test_push" then
        local current = read_uci_config()
        local server = (req.bark_server and req.bark_server ~= "") and req.bark_server or current.bark_server
        local key = (req.bark_key and req.bark_key ~= "") and req.bark_key or current.bark_key
        if not key or key == "" then
            io.write(jsonc.stringify({ code = 1, message = "请先填写 Bark Key" }))
            os.exit(0)
        end
        local endpoint = tostring(server):gsub("/+$", "") .. "/push"
        local mac = norm_mac(req.mac)
        local dev_name = req.device_name or "测试终端"
        local payload = {
            device_key = key,
            title = "🔔 OAF Pulse 测试通知",
            body = string.format("路由器连接正常 (%s)\n点击此通知可直接打开 %s 详情页", os.date("%H:%M:%S"), dev_name),
            group = "OAF终端动态",
            icon = "https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent/bark-icon.png",
            level = "active"
        }
        if mac ~= "" then
            payload.url = "oafpulse://device?mac=" .. mac
        else
            payload.url = "oafpulse://home"
        end

        local body_json = jsonc.stringify(payload)
        local has_curl = (os.execute("command -v curl >/dev/null 2>&1") == 0 or os.execute("command -v curl >/dev/null 2>&1") == true)
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
            io.write(jsonc.stringify({ code = 0, message = "测试推送已送达 Bark 服务器" }))
        else
            io.write(jsonc.stringify({ code = 2, message = "路由器访问 Bark 服务器失败，请检查 Bark Key 或路由器外网 DNS/HTTPS 证书环境" }))
        end
        os.exit(0)

    elseif method == "clear_events" then
        os.remove(EVENTS_TMP_FILE)
        io.write(jsonc.stringify({ code = 0 }))
        os.exit(0)
    end
end

io.write(jsonc.stringify({ code = -1, message = "unknown method" }))
