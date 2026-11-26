#!/usr/bin/lua
-- /usr/bin/oaf-feature-tool
-- Pure Lua 5.1 OAF 7.0+ feature.bin Inspector, Surgical Rule Disabler & Restorer
-- Bit-exact implementation of OpenAppFilter fwx_feature.c (XTEA-CTR + CRC32, 32-bit safe for Lua 5.1 double)

local FEATURE_BIN_PATH = "/etc/fwxd/feature.bin"
local FEATURE_ORIG_BACKUP = "/etc/fwxd/feature.bin.oafpulse.orig"
local FEATURE_CANDIDATE_PATH = "/tmp/feature.bin"
local DISABLED_PREFIX = "#OAFPULSE_DISABLED#"

-- ============================================================================
-- Fast 32-Bit Unsigned Bitwise Operations for Pure Lua 5.1 (Exact in 53-bit double)
-- ============================================================================

local MOD32 = 4294967296

-- 256x256 byte XOR lookup table (65536 entries, built once in ~4ms, makes 32-bit XOR 4 table lookups!)
local xor_byte = {}
for a = 0, 255 do
    local row = a * 256
    for b = 0, 255 do
        local res = 0
        local bit_val = 1
        local x, y = a, b
        while x > 0 or y > 0 do
            local rx = x % 2
            local ry = y % 2
            if rx ~= ry then res = res + bit_val end
            x = (x - rx) / 2
            y = (y - ry) / 2
            bit_val = bit_val * 2
        end
        xor_byte[row + b] = res
    end
end

local floor = math.floor

local function bxor32(a, b)
    local a0 = a % 256; a = (a - a0) / 256
    local a1 = a % 256; a = (a - a1) / 256
    local a2 = a % 256; local a3 = (a - a2) / 256

    local b0 = b % 256; b = (b - b0) / 256
    local b1 = b % 256; b = (b - b1) / 256
    local b2 = b % 256; local b3 = (b - b2) / 256

    return xor_byte[a0 * 256 + b0]
         + xor_byte[a1 * 256 + b1] * 256
         + xor_byte[a2 * 256 + b2] * 65536
         + xor_byte[a3 * 256 + b3] * 16777216
end

local pow2 = {}
for i = 0, 32 do pow2[i] = 2 ^ i end

local function lshift32(a, n)
    return (a * pow2[n]) % MOD32
end

local function rshift32(a, n)
    return floor(a / pow2[n])
end

-- CRC32 lookup table
local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if c % 2 == 1 then
            c = bxor32(floor(c / 2), 0xedb88320)
        else
            c = floor(c / 2)
        end
    end
    crc_table[i] = c
end

local function calc_crc32(s)
    local crc = 0xffffffff
    local len = #s
    for i = 1, len do
        local b = string.byte(s, i)
        local idx = xor_byte[(crc % 256) * 256 + b]
        crc = bxor32(floor(crc / 256), crc_table[idx])
    end
    return bxor32(crc, 0xffffffff)
end

-- XTEA-CTR key from OpenAppFilter fwx_feature.c
local KEY0 = 0x8f4c29a1
local KEY1 = 0x73b6d502
local KEY2 = 0xc14e87f3
local KEY3 = 0x2ad95b60
local KEYS = { [0] = KEY0, [1] = KEY1, [2] = KEY2, [3] = KEY3 }
local DELTA = 0x9e3779b9

local function get_le16(s, idx)
    local b0, b1 = string.byte(s, idx, idx + 1)
    return b0 + b1 * 256
end

local function get_le32(s, idx)
    local b0, b1, b2, b3 = string.byte(s, idx, idx + 3)
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

local function put_le16(v)
    local b0 = v % 256; v = (v - b0) / 256
    local b1 = v % 256
    return string.char(b0, b1)
end

local function put_le32(v)
    local b0 = v % 256; v = (v - b0) / 256
    local b1 = v % 256; v = (v - b1) / 256
    local b2 = v % 256; v = (v - b2) / 256
    local b3 = v % 256
    return string.char(b0, b1, b2, b3)
end

local function xtea_ctr_crypt(data_str, nonce_lo, nonce_hi)
    local len = #data_str
    local out = {}
    local out_idx = 1
    local c_lo = nonce_lo
    local c_hi = nonce_hi
    local char = string.char
    local byte = string.byte

    local offset = 1
    while offset <= len do
        local v0 = c_lo
        local v1 = c_hi
        local sum = 0

        for _ = 1, 32 do
            local t1 = bxor32(lshift32(v1, 4), rshift32(v1, 5))
            t1 = (t1 + v1) % MOD32
            local k1 = (sum + KEYS[sum % 4]) % MOD32
            v0 = (v0 + bxor32(t1, k1)) % MOD32

            sum = (sum + DELTA) % MOD32

            local t2 = bxor32(lshift32(v0, 4), rshift32(v0, 5))
            t2 = (t2 + v0) % MOD32
            local k2 = (sum + KEYS[rshift32(sum, 11) % 4]) % MOD32
            v1 = (v1 + bxor32(t2, k2)) % MOD32
        end

        local s0 = v0 % 256; v0 = (v0 - s0) / 256
        local s1 = v0 % 256; v0 = (v0 - s1) / 256
        local s2 = v0 % 256; local s3 = (v0 - s2) / 256

        local s4 = v1 % 256; v1 = (v1 - s4) / 256
        local s5 = v1 % 256; v1 = (v1 - s5) / 256
        local s6 = v1 % 256; local s7 = (v1 - s6) / 256

        local rem = len - offset + 1
        if rem >= 8 then
            local d0, d1, d2, d3, d4, d5, d6, d7 = byte(data_str, offset, offset + 7)
            out[out_idx] = char(
                xor_byte[d0 * 256 + s0],
                xor_byte[d1 * 256 + s1],
                xor_byte[d2 * 256 + s2],
                xor_byte[d3 * 256 + s3],
                xor_byte[d4 * 256 + s4],
                xor_byte[d5 * 256 + s5],
                xor_byte[d6 * 256 + s6],
                xor_byte[d7 * 256 + s7]
            )
            out_idx = out_idx + 1
            offset = offset + 8
        else
            local ks = { s0, s1, s2, s3, s4, s5, s6, s7 }
            local tail = {}
            for i = 1, rem do
                local db = byte(data_str, offset + i - 1)
                tail[i] = char(xor_byte[db * 256 + ks[i]])
            end
            out[out_idx] = table.concat(tail)
            out_idx = out_idx + 1
            offset = offset + rem
        end

        c_lo = c_lo + 1
        if c_lo >= MOD32 then
            c_lo = 0
            c_hi = (c_hi + 1) % MOD32
        end
    end

    return table.concat(out)
end

local function decrypt_feature_file(path)
    local f = io.open(path, "rb")
    if not f then return nil, "无法读取特征库文件: " .. tostring(path) end
    local raw = f:read("*a")
    f:close()

    if not raw or #raw < 24 then
        return nil, "特征库文件长度异常"
    end
    if string.sub(raw, 1, 4) ~= "FWXB" then
        return nil, "特征库文件魔数不匹配 (非 FWXB 格式)"
    end
    local ver = string.byte(raw, 5)
    local alg = string.byte(raw, 6)
    local hdr_sz = get_le16(raw, 7)
    if ver ~= 1 or alg ~= 1 or hdr_sz ~= 24 then
        return nil, "特征库头部版本不支持"
    end

    local plain_len = get_le32(raw, 9)
    local expected_crc = get_le32(raw, 13)
    local nonce_lo = get_le32(raw, 17)
    local nonce_hi = get_le32(raw, 21)

    if plain_len == 0 or #raw ~= (24 + plain_len) then
        return nil, "特征库数据长度校验不通过"
    end

    local cipher = string.sub(raw, 25)
    local plain = xtea_ctr_crypt(cipher, nonce_lo, nonce_hi)
    local actual_crc = calc_crc32(plain)
    if actual_crc ~= expected_crc then
        return nil, string.format("特征库 CRC32 校验失败 (got %08x, expected %08x)", actual_crc, expected_crc)
    end

    return {
        plain = plain,
        nonce_lo = nonce_lo,
        nonce_hi = nonce_hi
    }, nil
end

local function encrypt_feature_data(plain, nonce_lo, nonce_hi)
    if not nonce_lo or not nonce_hi then
        local ur = io.open("/dev/urandom", "rb")
        if ur then
            local nb = ur:read(8)
            ur:close()
            if nb and #nb == 8 then
                nonce_lo = get_le32(nb, 1)
                nonce_hi = get_le32(nb, 5)
            end
        end
        nonce_lo = nonce_lo or os.time()
        nonce_hi = nonce_hi or 0x12345678
    end

    local crc = calc_crc32(plain)
    local cipher = xtea_ctr_crypt(plain, nonce_lo, nonce_hi)
    local header = "FWXB"
        .. string.char(1, 1)
        .. put_le16(24)
        .. put_le32(#plain)
        .. put_le32(crc)
        .. put_le32(nonce_lo)
        .. put_le32(nonce_hi)
    return header .. cipher
end

-- ============================================================================
-- Feature Rule Analysis & Surgical Modification
-- ============================================================================

local function analyze_rule_risk(rule_body)
    if not rule_body or rule_body == "" then
        return "未找到特征规则内容"
    end
    local reasons = {}
    -- Check for portless pure byte-offset rules like `udp;;;;;00:28|01:28` or `tcp;;;;;00:33|1:66`
    if string.find(rule_body, "[tu][dc]p;;;;;[%x:|]+") then
        table.insert(reasons, "存在「不限端口、不限域名」的纯字节偏移特征，看直播/刷视频的高并发包极易随机撞上产生误报")
    end
    if string.find(rule_body, "00:33|0?1:66") then
        table.insert(reasons, "使用了腾讯 GCloud 通用协议头 (0x33 0x66)，微信/腾讯系 SDK/同门流量容易串台")
    end
    if string.find(rule_body, "liveplay") or string.find(rule_body, "myqcloud") or string.find(rule_body, "qq%.com") then
        table.insert(reasons, "包含云直播/腾讯公共域名关键词，刷直播间或短视频 CDN 时容易误触发")
    end
    if #reasons == 0 then
        return "常规协议/域名特征；若确认手机未安装该应用，可直接将其标记误报或从特征库禁用"
    end
    return table.concat(reasons, "；")
end

local function parse_rule_line(raw_line)
    local is_disabled = false
    local clean = raw_line:gsub("\r$", "")
    if string.sub(clean, 1, #DISABLED_PREFIX) == DISABLED_PREFIX then
        is_disabled = true
        clean = string.sub(clean, #DISABLED_PREFIX + 1)
    end
    local id_str, sep, name, body = string.match(clean, "^%s*(%d+)([~%s]+)([^:%[]-)%s*:%s*(%b[])")
    if not id_str then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local joiner = string.find(sep, "~") and "~" or " "
    return {
        app_id = tonumber(id_str),
        app_name = name,
        rule_body = body,
        is_disabled = is_disabled,
        full_rule = string.format("%s%s%s:%s", id_str, joiner, name, body)
    }
end

local function copy_file_bin(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local d = fi:read("*a")
    fi:close()
    local fo = io.open(dst .. ".tmp", "wb")
    if not fo then return false end
    fo:write(d)
    fo:close()
    os.rename(dst .. ".tmp", dst)
    return true
end

local function apply_candidate_and_reload(enc_bytes)
    local fo = io.open(FEATURE_CANDIDATE_PATH .. ".tmp", "wb")
    if not fo then return false, "无法写入 /tmp/feature.bin" end
    fo:write(enc_bytes)
    fo:close()
    os.rename(FEATURE_CANDIDATE_PATH .. ".tmp", FEATURE_CANDIDATE_PATH)

    -- Trigger oafd zero-downtime hot reload via SIGUSR1 (defined in OpenAppFilter main.c!)
    local rc = os.execute("killall -USR1 oafd >/dev/null 2>&1")
    if rc ~= 0 and rc ~= true then
        os.execute("cp -f " .. FEATURE_CANDIDATE_PATH .. " " .. FEATURE_BIN_PATH .. " && /etc/init.d/appfilter restart >/dev/null 2>&1")
    else
        -- Wait briefly for oafd SIGUSR1 handler to move /tmp/feature.bin -> /etc/fwxd/feature.bin
        os.execute("sleep 1")
    end
    return true, "ok"
end

-- Expose module table when loaded via dofile(), or CLI for self-test
local M = {}

function M.inspect(target_id, target_name, bin_path)
    local path = bin_path or FEATURE_BIN_PATH
    local res, err = decrypt_feature_file(path)
    if not res then return nil, err end

    local version = ""
    local matched = nil
    for line in string.gmatch(res.plain .. "\n", "(.-)\n") do
        local v = string.match(line, "^#version%s+(%S+)")
        if v then version = v end

        local parsed = parse_rule_line(line)
        if parsed then
            if (target_id and target_id > 0 and parsed.app_id == target_id) or
               (target_name and target_name ~= "" and parsed.app_name == target_name) then
                matched = parsed
                break
            end
        end
    end

    if not matched then
        return {
            found = 0,
            version = version,
            app_id = target_id or 0,
            app_name = target_name or "",
            raw_rule = "",
            is_disabled = 0,
            risk_hint = "在当前特征库中未检索到该 ID 的独立条目"
        }, nil
    end

    return {
        found = 1,
        version = version,
        app_id = matched.app_id,
        app_name = matched.app_name,
        raw_rule = matched.full_rule,
        rule_body = matched.rule_body,
        is_disabled = matched.is_disabled and 1 or 0,
        risk_hint = analyze_rule_risk(matched.rule_body)
    }, nil
end

function M.list_disabled(bin_path)
    local path = bin_path or FEATURE_BIN_PATH
    local res = decrypt_feature_file(path)
    if not res then return {} end
    local list = {}
    for line in string.gmatch(res.plain .. "\n", "(.-)\n") do
        if string.sub(line, 1, #DISABLED_PREFIX) == DISABLED_PREFIX then
            local parsed = parse_rule_line(line)
            if parsed then
                table.insert(list, {
                    id = parsed.app_id,
                    name = parsed.app_name,
                    rule = parsed.rule_body
                })
            end
        end
    end
    return list
end

function M.set_rule_disabled(target_id, target_name, disable_flag, bin_path)
    local path = bin_path or FEATURE_BIN_PATH
    local res, err = decrypt_feature_file(path)
    if not res then return false, err end

    -- Keep pristine backup before very first edit
    if path == FEATURE_BIN_PATH then
        local bf = io.open(FEATURE_ORIG_BACKUP, "rb")
        if bf then
            bf:close()
        else
            copy_file_bin(FEATURE_BIN_PATH, FEATURE_ORIG_BACKUP)
        end
    end

    local lines = {}
    local changed = false
    local matched_name = target_name or ""
    local matched_id = target_id or 0

    for line in string.gmatch(res.plain .. "\n", "(.-)\n") do
        local parsed = parse_rule_line(line)
        if parsed and ((matched_id > 0 and parsed.app_id == matched_id) or (matched_name ~= "" and parsed.app_name == matched_name)) then
            matched_id = parsed.app_id
            matched_name = parsed.app_name
            local clean_line = line:gsub("\r$", "")
            if string.sub(clean_line, 1, #DISABLED_PREFIX) == DISABLED_PREFIX then
                clean_line = string.sub(clean_line, #DISABLED_PREFIX + 1)
            end
            if disable_flag then
                table.insert(lines, DISABLED_PREFIX .. clean_line)
            else
                table.insert(lines, clean_line)
            end
            changed = true
        else
            table.insert(lines, (line:gsub("\r$", "")))
        end
    end

    -- Remove trailing extra empty line added by `.. "\n"` if original didn't end with double newline
    if #lines > 0 and lines[#lines] == "" and string.sub(res.plain, -1) ~= "\n" then
        table.remove(lines)
    end

    if not changed then
        return false, "未在特征库中找到该应用规则"
    end

    local new_plain = table.concat(lines, "\n")
    local enc = encrypt_feature_data(new_plain, res.nonce_lo, res.nonce_hi)

    if path ~= FEATURE_BIN_PATH then
        local fo = io.open(path, "wb")
        if not fo then return false, "write failed" end
        fo:write(enc)
        fo:close()
        return true, matched_name
    end

    local ok, apply_err = apply_candidate_and_reload(enc)
    if not ok then return false, apply_err end
    return true, matched_name
end

function M.restore_all_orig()
    local bf = io.open(FEATURE_ORIG_BACKUP, "rb")
    if not bf then
        return false, "尚未修改过原厂特征库，无需还原"
    end
    local orig_bytes = bf:read("*a")
    bf:close()
    return apply_candidate_and_reload(orig_bytes)
end

-- Self-test CLI entrypoint: lua oaf-feature-tool.lua selftest <feature.bin>
if arg and arg[1] == "selftest" and arg[2] then
    local t0 = os.clock()
    local f = io.open(arg[2], "rb")
    local orig_raw = f:read("*a")
    f:close()

    local dec, err = decrypt_feature_file(arg[2])
    assert(dec, "Decrypt failed: " .. tostring(err))
    local re_enc = encrypt_feature_data(dec.plain, dec.nonce_lo, dec.nonce_hi)
    assert(re_enc == orig_raw, "Round-trip encryption byte mismatch!")
    local elapsed_ms = math.floor((os.clock() - t0) * 1000)
    print(string.format("SELFTEST_OK plain_bytes=%d elapsed_ms=%d", #dec.plain, elapsed_ms))
    os.exit(0)
end

return M
