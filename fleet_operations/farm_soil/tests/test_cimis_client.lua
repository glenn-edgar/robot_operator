-- tests/test_cimis_client.lua — unit tests for lib/cimis_client.lua.
-- Covers URL building and the fetch error path against a refused port.
-- The success path + WAF detection are exercised live in slice D.
-- Run:  luajit farm_soil/tests/test_cimis_client.lua

package.path = "/home/gedgar/motioncore-prototype/fleet_design/farm_soil/lib/?.lua;"
            .. package.path

local cimis = require("cimis_client")

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

print("== request_url ==")
do
    local c = cimis.new{ app_key = "SECRET_APPKEY_VALUE" }
    local url = c:request_url("237", "day-asce-eto", "2026-05-15", "2026-05-22")
    check("base preserved",
        url:sub(1, #"https://et.water.ca.gov/api/data?"),
        "https://et.water.ca.gov/api/data?")
    check("appKey carried (by API design)",
        url:find("appKey=SECRET_APPKEY_VALUE", 1, true) ~= nil, true)
    check("targets carried",
        url:find("targets=237", 1, true) ~= nil, true)
    check("dataItems carried",
        url:find("dataItems=day-asce-eto", 1, true) ~= nil, true)
    check("startDate carried",
        url:find("startDate=2026-05-15", 1, true) ~= nil, true)
    check("endDate carried",
        url:find("endDate=2026-05-22", 1, true) ~= nil, true)
    check("unitOfMeasure defaults to E",
        url:find("unitOfMeasure=E", 1, true) ~= nil, true)
end

print("== request_url — multi-target zip CSV ==")
do
    local c = cimis.new{ app_key = "K" }
    local url = c:request_url("92562,92563", "day-asce-eto",
                              "2026-05-15", "2026-05-22")
    check("CSV preserved as-is",
        url:find("targets=92562,92563", 1, true) ~= nil, true)
end

print("== request_url — explicit units arg ==")
do
    local c = cimis.new{ app_key = "K" }
    local url = c:request_url("237", "day-asce-eto", "2026-05-15", "2026-05-22", "M")
    check("metric units passed through",
        url:find("unitOfMeasure=M", 1, true) ~= nil, true)
end

print("== fetch — error path (port 1 refused) ==")
do
    -- curl reports http_code 000 against a refused port; fetch must return
    -- cleanly without raising.
    local c = cimis.new{
        app_key = "SECRET_APPKEY_VALUE",
        api_base = "http://127.0.0.1:1/",
        timeout_s = 3,
    }
    local body, ok, err = c:fetch("237", "day-asce-eto", "2026-05-15", "2026-05-22")
    check("refused: ok = false",   ok,   false)
    check("refused: body empty",   body, "")
    check("refused: err non-empty",
        type(err) == "string" and #err > 0, true)
end

print("")
if fails == 0 then
    print("test_cimis_client: ALL PASS")
    os.exit(0)
else
    print("test_cimis_client: " .. fails .. " FAIL")
    os.exit(1)
end
