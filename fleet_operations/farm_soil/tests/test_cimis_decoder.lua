-- tests/test_cimis_decoder.lua — unit tests for lib/cimis_decoder.lua.
-- No network — synthetic JSON, mirrors skills/cimis/tests/test_decoder.py.
-- Run:  LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;" \
--         luajit farm_soil/tests/test_cimis_decoder.lua

package.path = "/home/gedgar/motioncore-prototype/fleet_design/farm_soil/lib/?.lua;"
            .. package.path

local cjson   = require("cjson")
local decoder = require("cimis_decoder")

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

local function station_response(station, date, eto)
    return cjson.encode({
        Data = { Providers = { {
            Name = "cimis", Type = "station",
            Records = { {
                Date = date, Station = station, Julian = "124",
                Standard = "english", ZipCodes = "92590", Scope = "daily",
                DayAsceEto   = { Value = eto,    Qc = "Y", Unit = "Inches" },
                DayAirTmpMax = { Value = "78.4", Qc = "Y", Unit = "Fahrenheit" },
            } }
        } } }
    })
end

local function spatial_response(lat, lng, date, eto)
    return cjson.encode({
        Data = { Providers = { {
            Name = "cimis", Type = "spatial",
            Records = { {
                Date = date,
                Coordinates = { Latitude = lat, Longitude = lng },
                DayAsceEto  = { Value = eto, Qc = "Y", Unit = "Inches" },
            } }
        } } }
    })
end

print("== station extract ==")
do
    local out = decoder.parse_response(station_response("237", "2026-05-04", "0.20"))
    local by_item = {}
    for _, r in ipairs(out) do by_item[r.item] = r end
    check("two items emitted",      #out, 2)
    check("DayAsceEto present",     by_item.DayAsceEto ~= nil, true)
    check("DayAirTmpMax present",   by_item.DayAirTmpMax ~= nil, true)
    local eto = by_item.DayAsceEto
    check("target_kind",            eto.target_kind, "station")
    check("target",                 eto.target, "237")
    check("date",                   eto.date, "2026-05-04")
    check("value ≈ 0.20",           near(eto.value, 0.20), true)
    check("unit",                   eto.unit, "Inches")
    check("qc",                     eto.qc, "Y")
end

print("== spatial (coord) extract ==")
do
    local out = decoder.parse_response(
        spatial_response("33.5785", "-117.2994", "2026-05-04", "0.18"))
    check("one record",             #out, 1)
    local r = out[1]
    check("target_kind",            r.target_kind, "spatial")
    check("target = 'lat,lng'",     r.target, "33.5785,-117.2994")
    check("date",                   r.date, "2026-05-04")
    check("item",                   r.item, "DayAsceEto")
    check("value ≈ 0.18",           near(r.value, 0.18), true)
end

print("== spatial (zip) extract ==")
do
    local body = cjson.encode({
        Data = { Providers = { {
            Name = "cimis", Type = "spatial",
            Records = { {
                Date = "2026-04-28", Julian = "118",
                Standard = "english", ZipCodes = "92590", Scope = "daily",
                DayAsceEto = { Value = "0.17", Qc = " ", Unit = "(in)" },
            } }
        } } }
    })
    local out = decoder.parse_response(body)
    check("one record",             #out, 1)
    check("target_kind",            out[1].target_kind, "spatial")
    check("target = zip",           out[1].target, "92590")
    check("value ≈ 0.17",           near(out[1].value, 0.17), true)
end

print("== mixed providers ==")
do
    local body = cjson.encode({
        Data = { Providers = {
            {
                Name = "cimis", Type = "station",
                Records = { { Date = "2026-05-04", Station = "237",
                    DayAsceEto = { Value = "0.20", Qc = "Y", Unit = "Inches" } } },
            },
            {
                Name = "cimis", Type = "spatial",
                Records = { { Date = "2026-05-04",
                    Coordinates = { Latitude = "33.5785", Longitude = "-117.2994" },
                    DayAsceEto = { Value = "0.18", Qc = "Y", Unit = "Inches" } } },
            },
        } }
    })
    local out = decoder.parse_response(body)
    local kinds = {}
    for _, r in ipairs(out) do kinds[r.target_kind] = true end
    check("station provider seen",  kinds.station, true)
    check("spatial provider seen",  kinds.spatial, true)
end

print("== malformed input ==")
check("'not json'  -> {}", #decoder.parse_response("not json"), 0)
check("''          -> {}", #decoder.parse_response(""), 0)
check("nil         -> {}", #decoder.parse_response(nil), 0)

print("== missing fields skip records ==")
do
    local body = cjson.encode({
        Data = { Providers = { {
            Name = "cimis", Type = "station",
            Records = {
                { Date = "2026-05-04" },                       -- no Station -> drop
                { Station = "237" },                            -- no Date    -> drop
                { Date = "2026-05-04", Station = "237",
                  DayAsceEto = { Value = "", Qc = "M", Unit = "Inches" } },
            }
        } } }
    })
    local out = decoder.parse_response(body)
    check("only third record yields a row", #out, 1)
    check("blank value -> nil",            out[1].value, nil)
    check("qc preserved",                  out[1].qc, "M")
end

print("")
if fails == 0 then
    print("test_cimis_decoder: ALL PASS")
    os.exit(0)
else
    print("test_cimis_decoder: " .. fails .. " FAIL")
    os.exit(1)
end
