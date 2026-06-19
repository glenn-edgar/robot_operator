-- tests/test_format_table.lua — format_table unit tests.
-- Run from this directory:
--   LUA_PATH="../lib/?.lua;;" luajit test_format_table.lua

local F = require("format_table")

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok  " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

local function contains(s, needle, label)
    check(s:find(needle, 1, true) ~= nil,
        string.format("%s contains %q", label, needle))
end

print("[1] both empty — '(no data)' under each header, date in title")
do
    local out = F.format_daily_report({}, {}, { report_date = "2026-05-24" })
    contains(out, "=== farm_soil daily report — 2026-05-24 ===", "header")
    contains(out, "Moisture (per-device latest):", "moisture header")
    contains(out, "ETo (CIMIS):", "eto header")
    local _, count = out:gsub("%(no data%)", "")
    check(count == 2, "exactly two '(no data)' lines, got " .. count)
end

print("[2] moisture rows render as columns")
do
    local moisture = {
        { device_id = "lacima1c", latest_value = 0.302,
          latest_ts = "2026-05-23T16:48:03.851Z", uplinks_in_window = 3 },
        { device_id = "lacima1d", latest_value = 0.155,
          latest_ts = "2026-05-23T17:00:00Z",     uplinks_in_window = 1 },
    }
    local out = F.format_daily_report(moisture, {}, { report_date = "2026-05-24" })
    contains(out, "lacima1c", "device 1")
    contains(out, "0.302",    "value 1 fmt")
    contains(out, "2026-05-23T16:48:03Z", "ts 1 subsec-trimmed")
    contains(out, "(3 uplinks)", "count 1")
    contains(out, "lacima1d", "device 2")
    contains(out, "0.155",    "value 2 fmt")
    contains(out, "2026-05-23T17:00:00Z", "ts 2 untouched")
end

print("[3] nil moisture value -> '?' placeholder")
do
    local out = F.format_daily_report(
        { { device_id = "lacima1c", latest_value = nil,
            latest_ts = "2026-05-23T16:00:00Z", uplinks_in_window = 0 } },
        {}, { report_date = "2026-05-24" })
    contains(out, "lacima1c", "device present")
    check(out:find("? ", 1, true) ~= nil, "'?' rendered for missing value")
end

print("[4] eto rows render with date + value + unit")
do
    local out = F.format_daily_report({}, {
        { date = "2026-05-23", value = 0.110, unit = "(in)" },
        { date = "2026-05-22", value = 0.087, unit = "(in)" },
    }, { report_date = "2026-05-24" })
    contains(out, "2026-05-23", "date 1")
    contains(out, "0.110 (in)", "value+unit 1")
    contains(out, "2026-05-22", "date 2")
    contains(out, "0.087 (in)", "value+unit 2")
end

print("[5] eto row with empty unit — no trailing whitespace")
do
    local out = F.format_daily_report({}, {
        { date = "2026-05-23", value = 0.110, unit = "" },
    }, { report_date = "2026-05-24" })
    -- The line should end at "0.110" with no trailing space.
    check(out:find("0.110\n", 1, true) ~= nil or out:sub(-5) == "0.110",
        "no trailing whitespace after value when unit empty")
end

print("[6] default report_date — uses today UTC")
do
    local out = F.format_daily_report({}, {})
    local today = os.date("!%Y-%m-%d")
    contains(out, today, "today's date appears in header")
end

if failures == 0 then
    print("\nALL OK")
    os.exit(0)
else
    print(string.format("\n%d FAIL", failures))
    os.exit(1)
end
