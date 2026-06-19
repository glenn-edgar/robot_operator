-- tests/test_format.lua — offline unit tests for rancho_format.
-- Run:
--   LUA_PATH="../lib/?.lua;;" luajit test_format.lua

local F = require("rancho_format")

local failures = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end
local function contains(s, needle, label)
    check(s:find(needle, 1, true) ~= nil,
        string.format("%s contains %q", label, needle))
end

print("[1] full day with hourly rows + total")
do
    local out = F.format_daily_report({
        AccountNumber = "3047791",
        Date = "2026-05-23T00:00:00",
        DayOfWeek = 6,
        Usage = {
            { ReadTime = "2026-05-23T01:00:00", GPH = 0,   GPM = 0, HCF = 0.0 },
            { ReadTime = "2026-05-23T02:00:00", GPH = 7,   GPM = 0, HCF = 0.0 },
            { ReadTime = "2026-05-23T03:00:00", GPH = 135, GPM = 2, HCF = 0.0 },
        },
        TotalGallons = 1234.0,
        TotalHCF     = 8.5,
    }, "2026-05-23")
    contains(out, "rancho_water daily report — 2026-05-23", "header")
    contains(out, "Hourly usage", "table header")
    contains(out, "hour    GPH    GPM     HCF", "column header includes HCF")
    contains(out, "01:00", "hour row 01")
    contains(out, "02:00", "hour row 02")
    contains(out, "03:00", "hour row 03")
    contains(out, "  135", "GPH 135 right-aligned (int)")
    contains(out, "    2", "GPM 2 right-aligned (int)")
    contains(out, " 0.180", "HCF for 135 GPH = 0.180 (135/748.052)")
    contains(out, " 0.009", "HCF for 7 GPH = 0.009")
    contains(out, " 0.000", "HCF for 0 GPH = 0.000")
    contains(out, "Total: 1234 gal (8.50 HCF)", "total formatted")
end

print("[2] empty Usage -> '(no data)'")
do
    local out = F.format_daily_report({
        Usage = {}, TotalGallons = 0, TotalHCF = 0,
    }, "2026-05-23")
    contains(out, "(no data)", "(no data) marker")
    contains(out, "Total: 0 gal (0.00 HCF)", "zero total still rendered")
end

print("[3] malformed ReadTime -> '??:??' placeholder, no crash")
do
    local out = F.format_daily_report({
        Usage = { { ReadTime = "garbage", GPH = 10, GPM = 1, HCF = 0 } },
        TotalGallons = 10, TotalHCF = 0,
    }, "2026-05-23")
    contains(out, "??:??", "malformed hour rendered as ??:??")
    contains(out, "   10", "GPH still printed")
end

print("[4] missing totals -> safe rendering")
do
    local out = F.format_daily_report({
        Usage = {}, TotalGallons = nil, TotalHCF = nil,
    }, "2026-05-23")
    contains(out, "no total reported", "missing-totals fallback line")
end

print("[5] nil data -> safe rendering (no crash)")
do
    local out = F.format_daily_report(nil, "2026-05-23")
    contains(out, "rancho_water daily report — 2026-05-23", "header still rendered")
    contains(out, "(no data)", "(no data) marker")
end

if failures == 0 then print("\nALL OK"); os.exit(0)
else print(string.format("\n%d FAIL", failures)); os.exit(1) end
