-- tests/test_moisture.lua — unit tests for lib/moisture.lua (the pure core:
-- record building, the ring buffer, the slot JSON). No network, no engine.
-- Run:  LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;" luajit tests/test_moisture.lua

package.path = "/home/gedgar/motioncore-prototype/fleet_design/farm_soil/lib/?.lua;"
            .. package.path

local cjson    = require("cjson")
local moisture = require("moisture")

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

-- a decoder-shaped uplink
local function uplink(received_at, f_cnt)
    return {
        device_id   = "lacima1c",
        received_at = received_at,
        f_cnt       = f_cnt,
        measurements = {
            { measurement_id = 4108, value = 0.530 },
            { measurement_id = 4102, value = 17.1  },
            { measurement_id = 4103, value = 30.9  },
        },
        gateway = {
            gateway_id = "lacima-ranch-1", gateway_count = 2,
            rssi = -100, channel_rssi = -100, snr = 7.25,
            frequency = "904700000", spreading_factor = 7,
            bandwidth = 125000, coding_rate = "4/5", airtime_s = 0.082176,
        },
        battery_present = true,
        battery_value   = 100,
    }
end

----------------------------------------------------------------------------
print("== record_from_uplink ==")
do
    local r = moisture.record_from_uplink(uplink("2026-05-12T13:00:00.000Z", 4115))
    check("received_at carried", r.received_at, "2026-05-12T13:00:00.000Z")
    check("f_cnt carried", r.f_cnt, 4115)
    check("measurement id 4108 -> moisture", near(r.measurements.moisture, 0.530), true)
    check("measurement id 4102 -> soil_temp", near(r.measurements.soil_temp, 17.1), true)
    check("measurement id 4103 -> ec", near(r.measurements.ec, 30.9), true)
    check("link gateway_id", r.link.gateway_id, "lacima-ranch-1")
    check("link rssi", r.link.rssi, -100)
    check("link battery (present)", r.link.battery, 100)
end

do  -- battery absent -> nil
    local up = uplink("2026-05-12T14:00:00.000Z", 4116)
    up.battery_present, up.battery_value = false, nil
    local r = moisture.record_from_uplink(up)
    check("link battery (absent) -> nil", r.link.battery, nil)
end

----------------------------------------------------------------------------
print("== ring_append ==")
do
    local s = moisture.new_slot("lacima1c", "zone3")
    check("append first -> true",
        moisture.ring_append(s, { received_at = "2026-05-12T10:00:00Z" }), true)
    check("append newer -> true",
        moisture.ring_append(s, { received_at = "2026-05-12T11:00:00Z" }), true)
    check("ring has 2", #s.ring, 2)
    check("append same received_at -> false",
        moisture.ring_append(s, { received_at = "2026-05-12T11:00:00Z" }), false)
    check("append older -> false",
        moisture.ring_append(s, { received_at = "2026-05-12T09:00:00Z" }), false)
    check("ring still 2 after rejects", #s.ring, 2)
end

do  -- eviction past capacity
    local s = moisture.new_slot("lacima1c", "zone3")
    for i = 1, 300 do
        local ts = string.format("2026-05-01T%02d:%02d:00.000Z",
            math.floor(i / 60), i % 60)
        moisture.ring_append(s, { received_at = ts, seq = i })
    end
    check("ring capped at 256", #s.ring, moisture.RING_CAPACITY)
    check("oldest 44 evicted (ring[1] is seq 45)", s.ring[1].seq, 45)
    check("newest is seq 300", s.ring[#s.ring].seq, 300)
end

----------------------------------------------------------------------------
print("== ring_at + reading JSON ==")
do
    local s = moisture.new_slot("lacima1c", "zone3")
    moisture.ring_append(s, moisture.record_from_uplink(uplink("2026-05-12T12:00:00Z", 1)))
    moisture.ring_append(s, moisture.record_from_uplink(uplink("2026-05-12T13:00:00Z", 2)))

    check("ring_at(0) is the newest", moisture.ring_at(s, 0).f_cnt, 2)
    check("ring_at(1) is next-newest", moisture.ring_at(s, 1).f_cnt, 1)
    check("ring_at(2) past depth -> nil", moisture.ring_at(s, 2), nil)

    local r = cjson.decode(moisture.reading_json(
        "farm_soil", "lacima01", "lacima1c", "zone3", moisture.ring_at(s, 0)))
    check("reading: schema", r.schema, "moisture.reading/1")
    check("reading: device", r.device, "lacima1c")
    check("reading: location", r.location, "zone3")
    check("reading: entry is the record", r.entry.f_cnt, 2)
    check("reading: entry moisture", near(r.entry.measurements.moisture, 0.530), true)
    check("reading: units present", r.units.moisture, "m3/m3")
end

do  -- ring_at on an empty ring -> nil
    check("ring_at empty ring -> nil",
        moisture.ring_at(moisture.new_slot("d", "l"), 0), nil)
end

----------------------------------------------------------------------------
if fails == 0 then
    print("\nALL PASS")
else
    print("\n" .. fails .. " FAILURE(S)")
    os.exit(1)
end
