-- lib/decoder.lua — TTN SSE response + SenseCAP S2105 payload decoder.
--
-- LuaJIT port of the Python skill's decoder.py. Engine-agnostic and
-- skill-agnostic — pure parsing, no chain_tree imports, no measurement
-- naming (4108 -> "moisture" is the moisture skill's job, not the decoder's).
--
-- Public surface:
--   parse_uplinks(body)         -> list of uplink tables
--   decode_sensecap_frame(bytes)-> list of { measurement_id, value }
--
-- An uplink table:
--   { device_id, received_at, f_cnt | nil, frm_payload_b64 | nil,
--     measurements = { { measurement_id, value }, ... },
--     gateway = { gateway_id, rssi, channel_rssi, snr, frequency,
--                 spreading_factor, bandwidth, coding_rate, airtime_s,
--                 gateway_count },
--     battery_present = bool, battery_value = int | nil }
--
-- Measurement extraction prefers TTN's decoded_payload.messages (already
-- parsed by TTN's payload formatter); falls back to byte-decoding
-- frm_payload as 7-byte SenseCAP frames when no decoded_payload is present.
--
-- SenseCAP S2105 frame (per measurement, repeating):
--   0x01            channel
--   <id  LE u16>    measurement id
--   <value LE i32>  scaled by 0.001
-- = 7 bytes. Trailing bytes that don't start with 0x01 are ignored.

local cjson = require("cjson")
local bit   = require("bit")

local M = {}

local CHANNEL_BYTE = 0x01
local FRAME_LEN    = 7        -- 1 (channel) + 2 (id) + 4 (value)
local SCALE        = 0.001

-- cjson decodes JSON null to a sentinel, not Lua nil. Treat both as absent.
local JNULL = cjson.null

-- t[k], or nil when t isn't a table / the key is absent / the value is null.
local function field(t, k)
    if type(t) ~= "table" then return nil end
    local v = t[k]
    if v == nil or v == JNULL then return nil end
    return v
end

-- ---------------------------------------------------------------------------
-- base64 decode (no stdlib base64 in LuaJIT)
-- ---------------------------------------------------------------------------

local B64 = {}
do
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64[chars:sub(i, i)] = i - 1 end
end

local function b64decode(s)
    local out, acc, nbits = {}, 0, 0
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "=" then break end
        local v = B64[c]
        if v then
            acc = bit.bor(bit.lshift(acc, 6), v)
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                out[#out + 1] = string.char(bit.band(bit.rshift(acc, nbits), 0xFF))
                acc = bit.band(acc, bit.lshift(1, nbits) - 1)
            end
        end
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- SenseCAP byte-frame decode
-- ---------------------------------------------------------------------------

-- Decode 7-byte frames from `payload` (a byte string). Stops at the first
-- frame whose start byte isn't 0x01 — trailing battery/CRC bytes are ignored.
local function decode_sensecap_frame(payload)
    local out = {}
    local off = 1                                  -- 1-indexed
    while off + FRAME_LEN - 1 <= #payload do
        if payload:byte(off) ~= CHANNEL_BYTE then break end
        local b1, b2 = payload:byte(off + 1), payload:byte(off + 2)
        local mid = b1 + b2 * 256                  -- u16 LE
        local v0, v1, v2, v3 = payload:byte(off + 3), payload:byte(off + 4),
                               payload:byte(off + 5), payload:byte(off + 6)
        local raw = v0 + v1 * 256 + v2 * 65536 + v3 * 16777216   -- u32 LE
        if raw >= 2147483648 then raw = raw - 4294967296 end     -- -> i32
        out[#out + 1] = { measurement_id = mid, value = raw * SCALE }
        off = off + FRAME_LEN
    end
    return out
end
M.decode_sensecap_frame = decode_sensecap_frame

-- ---------------------------------------------------------------------------
-- TTN uplink_message extraction
-- ---------------------------------------------------------------------------

-- Prefer decoded_payload.messages; fall back to byte-decoding frm_payload.
local function measurements_from_msg(msg)
    local decoded  = field(msg, "decoded_payload")
    local messages = decoded and field(decoded, "messages")
    if type(messages) == "table" and #messages > 0 then
        local out = {}
        for _, m in ipairs(messages) do
            if type(m) == "table" then
                local mid, val = m.measurementId, m.measurementValue
                if type(mid) == "number" and type(val) == "number" then
                    out[#out + 1] = { measurement_id = mid, value = val }
                end
            end
        end
        if #out > 0 then return out end
    end
    local frm = field(msg, "frm_payload")
    if type(frm) == "string" and #frm > 0 then
        local ok, res = pcall(function()
            return decode_sensecap_frame(b64decode(frm))
        end)
        if ok then return res end
    end
    return {}
end

-- Battery counts as "present in this uplink" only when the cached
-- last_battery_percentage entry's f_cnt matches the uplink's own f_cnt —
-- TTN attaches the last-known battery to every uplink regardless.
local function battery_from_msg(msg, uplink_f_cnt)
    local batt = field(msg, "last_battery_percentage")
    if type(batt) ~= "table" then return false, nil end
    local bf = batt.f_cnt
    if not (type(uplink_f_cnt) == "number" and type(bf) == "number"
            and bf == uplink_f_cnt) then
        return false, nil
    end
    local v = batt.value
    if type(v) == "number" then return true, math.floor(v + 0.5) end
    return true, nil                               -- present but no numeric value
end

-- Pick the strongest gateway (highest RSSI) and count all that received it.
local function gateway_from_msg(msg)
    local rx = field(msg, "rx_metadata")
    local rx_list = {}
    if type(rx) == "table" then
        for _, r in ipairs(rx) do
            if type(r) == "table" then rx_list[#rx_list + 1] = r end
        end
    end
    local strongest, best = nil, -math.huge
    for _, r in ipairs(rx_list) do
        local rssi = r.rssi
        local s = (type(rssi) == "number") and rssi or -math.huge
        if s >= best then best, strongest = s, r end
    end
    strongest = strongest or {}

    local settings  = field(msg, "settings") or {}
    local data_rate = field(settings, "data_rate") or {}
    local lora      = field(data_rate, "lora") or {}

    local airtime, airtime_s = field(msg, "consumed_airtime"), nil
    if type(airtime) == "string" and airtime:sub(-1) == "s" then
        airtime_s = tonumber(airtime:sub(1, -2))
    end

    local gw_ids = field(strongest, "gateway_ids") or {}
    return {
        gateway_id       = field(gw_ids, "gateway_id"),
        rssi             = field(strongest, "rssi"),
        channel_rssi     = field(strongest, "channel_rssi"),
        snr              = field(strongest, "snr"),
        frequency        = field(settings, "frequency"),
        spreading_factor = field(lora, "spreading_factor"),
        bandwidth        = field(lora, "bandwidth"),
        coding_rate      = field(lora, "coding_rate"),
        airtime_s        = airtime_s,
        gateway_count    = #rx_list,
    }
end

local function uplink_from_result(result)
    local eds         = field(result, "end_device_ids") or {}
    local device_id   = field(eds, "device_id")
    local received_at = field(result, "received_at")
    if not device_id or not received_at then return nil end

    local msg   = field(result, "uplink_message") or {}
    local f_cnt = msg.f_cnt
    if type(f_cnt) ~= "number" then f_cnt = nil end
    local bat_present, bat_value = battery_from_msg(msg, f_cnt)

    return {
        device_id       = device_id,
        received_at     = received_at,
        f_cnt           = f_cnt,
        frm_payload_b64 = field(msg, "frm_payload"),
        measurements    = measurements_from_msg(msg),
        gateway         = gateway_from_msg(msg),
        battery_present = bat_present,
        battery_value   = bat_value,
    }
end

-- ---------------------------------------------------------------------------
-- TTN storage response parsing
-- ---------------------------------------------------------------------------

-- Parse a TTN storage response body into a list of uplink tables. Tolerates
-- SSE `data: ` prefixes, blank lines, the `{"result": {...}}` wrapper, and
-- non-JSON noise lines.
function M.parse_uplinks(body)
    local out = {}
    for raw in (body or ""):gmatch("[^\r\n]+") do
        local line = raw:match("^%s*(.-)%s*$")           -- trim
        if line:sub(1, 5) == "data:" then
            line = line:sub(6):match("^%s*(.-)%s*$")
        end
        local c = line:sub(1, 1)
        if c == "{" or c == "[" then
            local ok, obj = pcall(cjson.decode, line)
            if ok and type(obj) == "table" then
                local result = obj.result
                if result == nil or result == JNULL then result = obj end
                if type(result) == "table" then
                    local up = uplink_from_result(result)
                    if up then out[#out + 1] = up end
                end
            end
        end
    end
    return out
end

return M
