-- tests/test_decoder.lua — unit tests for lib/decoder.lua.
-- Run:  LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;" luajit tests/test_decoder.lua
-- (from the farm_soil directory; LUA_CPATH points at the LuaJIT-ABI cjson.)

package.path = "/home/gedgar/motioncore-prototype/fleet_design/farm_soil/lib/?.lua;"
            .. package.path

local cjson   = require("cjson")
local decoder = require("decoder")

local fails = 0
local function check(label, got, want)
    if got == want then
        print("  ok   " .. label)
    else
        fails = fails + 1
        print(string.format("  FAIL %s — got %s want %s",
            label, tostring(got), tostring(want)))
    end
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

-- helpers ------------------------------------------------------------------
local function hex2bin(h)
    return (h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end))
end
local function le_u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end
local function le_i32(n)
    if n < 0 then n = n + 4294967296 end
    return string.char(n % 256, math.floor(n / 256) % 256,
                       math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function build_frame(ms)          -- ms = { {id=, val=}, ... }
    local out = {}
    for _, m in ipairs(ms) do
        out[#out + 1] = string.char(0x01)
        out[#out + 1] = le_u16(m.id)
        out[#out + 1] = le_i32(math.floor(m.val * 1000 + 0.5))
    end
    return table.concat(out)
end
local function sse(tbl) return "data: " .. cjson.encode(tbl) .. "\n\n" end

----------------------------------------------------------------------------
print("== decode_sensecap_frame ==")

-- 1. real frm_payload from a TTN uplink (lacima1d)
do
    local p = hex2bin("010C1012020000010610CC420000010710B4780000B06B")
    local m = decoder.decode_sensecap_frame(p)
    check("real payload: 3 measurements", #m, 3)
    check("real payload: ids",
        m[1].measurement_id .. "," .. m[2].measurement_id .. "," .. m[3].measurement_id,
        "4108,4102,4103")
    check("real payload: moisture 0.530", near(m[1].value, 0.530), true)
    check("real payload: soil_temp 17.1", near(m[2].value, 17.1), true)
    check("real payload: ec 30.9",        near(m[3].value, 30.9), true)
end

-- 2. three built measurements
do
    local m = decoder.decode_sensecap_frame(build_frame({
        { id = 4108, val = 0.234 }, { id = 4102, val = 19.5 }, { id = 4103, val = 1.234 },
    }))
    check("built: 3 measurements", #m, 3)
    check("built: values", near(m[1].value, 0.234) and near(m[2].value, 19.5)
        and near(m[3].value, 1.234), true)
end

-- 3. negative value (i32 sign)
do
    local m = decoder.decode_sensecap_frame(build_frame({ { id = 4102, val = -5.125 } }))
    check("negative temp -5.125", #m == 1 and near(m[1].value, -5.125), true)
end

-- 4. stops at the first non-0x01 start byte
do
    local good = build_frame({ { id = 4108, val = 1.0 } })
    local m = decoder.decode_sensecap_frame(good .. "\x99\0\0\0\0\0\0")
    check("stops on bad channel byte", #m == 1 and m[1].measurement_id == 4108, true)
end

----------------------------------------------------------------------------
print("== parse_uplinks ==")

-- 5. prefers decoded_payload.messages over the byte frame
do
    local body = sse({ result = {
        end_device_ids = { device_id = "lacima1d" },
        received_at = "2026-05-04T00:34:54.779712873Z",
        uplink_message = {
            f_cnt = 4115,
            frm_payload = "AQwQEgIAAAEGEMxCAAABBxC0eAAAsGs=",
            decoded_payload = { messages = {
                { measurementId = 4108, measurementValue = 0.53 },
                { measurementId = 4102, measurementValue = 17.1 },
                { measurementId = 4103, measurementValue = 30.9 },
            } },
            rx_metadata = { { gateway_ids = { gateway_id = "lacima-ranch-1" },
                              rssi = -100, snr = 7.25 } },
            settings = { frequency = "904700000",
                         data_rate = { lora = { bandwidth = 125000,
                             spreading_factor = 7, coding_rate = "4/5" } } },
            consumed_airtime = "0.082176s",
        },
    } })
    local up = decoder.parse_uplinks(body)
    check("decoded_payload: 1 uplink", #up, 1)
    if up[1] then
        local u = up[1]
        check("decoded_payload: device_id", u.device_id, "lacima1d")
        check("decoded_payload: f_cnt", u.f_cnt, 4115)
        check("decoded_payload: 3 measurements", #u.measurements, 3)
        check("decoded_payload: moisture value",
            near(u.measurements[1].value, 0.53), true)
        check("decoded_payload: gateway_id", u.gateway.gateway_id, "lacima-ranch-1")
        check("decoded_payload: rssi", u.gateway.rssi, -100)
        check("decoded_payload: airtime parsed", near(u.gateway.airtime_s, 0.082176), true)
        check("decoded_payload: spreading_factor", u.gateway.spreading_factor, 7)
    end
end

-- 6. falls back to byte decode when no decoded_payload
do
    local frm = "AQwQEgIAAAEGEMxCAAABBxC0eAAAsGs="    -- real b64 of the hex above
    local body = sse({ result = {
        end_device_ids = { device_id = "lacima1c" },
        received_at = "2026-05-04T12:00:00.000Z",
        uplink_message = {
            f_cnt = 7, frm_payload = frm,
            rx_metadata = { { gateway_ids = { gateway_id = "gw" } } },
            settings = {},
        },
    } })
    local up = decoder.parse_uplinks(body)
    check("byte fallback: 1 uplink", #up, 1)
    if up[1] then
        check("byte fallback: 3 measurements", #up[1].measurements, 3)
        check("byte fallback: ids 4108/4102/4103",
            up[1].measurements[1].measurement_id == 4108
            and up[1].measurements[2].measurement_id == 4102
            and up[1].measurements[3].measurement_id == 4103, true)
        check("byte fallback: moisture 0.530",
            near(up[1].measurements[1].value, 0.530), true)
    end
end

-- 7. battery present when the cached f_cnt matches the uplink's f_cnt
do
    local body = sse({ result = {
        end_device_ids = { device_id = "lacima1d" },
        received_at = "2026-05-05T17:34:34Z",
        uplink_message = {
            f_cnt = 4150,
            decoded_payload = { messages = {
                { measurementId = 4108, measurementValue = 0.35 } } },
            rx_metadata = { { gateway_ids = { gateway_id = "gw" }, rssi = -99 } },
            settings = {},
            last_battery_percentage = { f_cnt = 4150, value = 100 },
        },
    } })
    local up = decoder.parse_uplinks(body)
    check("battery match: present", up[1] and up[1].battery_present, true)
    check("battery match: value 100", up[1] and up[1].battery_value, 100)
end

-- 8. battery absent when the cached f_cnt differs from the uplink's
do
    local body = sse({ result = {
        end_device_ids = { device_id = "lacima1d" },
        received_at = "2026-05-05T17:34:34Z",
        uplink_message = {
            f_cnt = 4156,
            decoded_payload = { messages = {
                { measurementId = 4108, measurementValue = 0.35 } } },
            rx_metadata = { { gateway_ids = { gateway_id = "gw" }, rssi = -99 } },
            settings = {},
            last_battery_percentage = { f_cnt = 4150, value = 100 },
        },
    } })
    local up = decoder.parse_uplinks(body)
    check("battery mismatch: not present", up[1] and up[1].battery_present, false)
    check("battery mismatch: value nil", up[1] and up[1].battery_value, nil)
end

-- 9. strongest gateway picked, all counted
do
    local body = sse({ result = {
        end_device_ids = { device_id = "lacima1d" },
        received_at = "2026-05-04T00:34:54Z",
        uplink_message = {
            f_cnt = 1,
            decoded_payload = { messages = {
                { measurementId = 4108, measurementValue = 0.5 } } },
            rx_metadata = {
                { gateway_ids = { gateway_id = "gw-far" },  rssi = -110, snr = -2.0 },
                { gateway_ids = { gateway_id = "gw-near" }, rssi = -75,  snr = 9.5 },
                { gateway_ids = { gateway_id = "gw-mid" },  rssi = -95,  snr = 4.0 },
            },
            settings = {},
        },
    } })
    local up = decoder.parse_uplinks(body)
    check("strongest gateway: gw-near", up[1] and up[1].gateway.gateway_id, "gw-near")
    check("strongest gateway: rssi -75", up[1] and up[1].gateway.rssi, -75)
    check("strongest gateway: count 3", up[1] and up[1].gateway.gateway_count, 3)
end

-- 10. garbage / non-uplink lines skipped
do
    local up = decoder.parse_uplinks("garbage\n\ndata: not-json\n\ndata: {}\n")
    check("garbage lines: 0 uplinks", #up, 0)
end

----------------------------------------------------------------------------
if fails == 0 then
    print("\nALL PASS")
else
    print("\n" .. fails .. " FAILURE(S)")
    os.exit(1)
end
