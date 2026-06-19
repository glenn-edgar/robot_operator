-- tests/test_clock.lua — unit tests for lib/clock.lua's Pacific civil-time
-- rule (DST boundaries, california_today/yesterday) and the Hinnant day
-- arithmetic. No network, no engine.
-- Run:  luajit robot_common/tests/test_clock.lua

package.path = "/home/gedgar/motioncore-prototype/fleet_design/robot_common/lib/?.lua;"
            .. package.path

local clock = require("clock")

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

-- A UTC epoch from Y/M/D H:M:S, built via clock's own day count — no
-- os.time() so the test is immune to the host's local TZ.
local function utc(y, mo, d, h, mi, s)
    return clock.days_from_civil(y, mo, d) * 86400
         + (h or 0) * 3600 + (mi or 0) * 60 + (s or 0)
end

print("day-count anchors")
check("1970-01-01 = day 0",        clock.days_from_civil(1970, 1, 1), 0)
check("2000-01-01 = day 10957",    clock.days_from_civil(2000, 1, 1), 10957)
do
    local y, m, d = clock.civil_from_days(0)
    check("civil_from_days(0) y", y, 1970)
    check("civil_from_days(0) m", m, 1)
    check("civil_from_days(0) d", d, 1)
end
do
    local y, m, d = clock.civil_from_days(clock.days_from_civil(2026, 5, 22))
    check("round-trip 2026-05-22 y", y, 2026)
    check("round-trip 2026-05-22 m", m, 5)
    check("round-trip 2026-05-22 d", d, 22)
end

print("PST winter — 2026-01-15 12:00 Pacific (= 20:00 UTC)")
do
    local p = clock.pacific_at(utc(2026, 1, 15, 20, 0, 0))
    check("hour",   p.hour, 12)
    check("day",    p.day, 15)
    check("is_dst", p.is_dst, false)
    check("offset", p.utc_offset_s, -8 * 3600)
end

print("PDT summer — 2026-07-15 12:00 Pacific (= 19:00 UTC)")
do
    local p = clock.pacific_at(utc(2026, 7, 15, 19, 0, 0))
    check("hour",   p.hour, 12)
    check("day",    p.day, 15)
    check("is_dst", p.is_dst, true)
    check("offset", p.utc_offset_s, -7 * 3600)
end

print("spring-forward boundary — 2026-03-08 02:00 PST -> 03:00 PDT")
do
    local before = clock.pacific_at(utc(2026, 3, 8, 9, 59, 0))   -- 09:59 UTC
    check("before: hour",   before.hour, 1)        -- 01:59 PST
    check("before: is_dst", before.is_dst, false)
    local after  = clock.pacific_at(utc(2026, 3, 8, 10, 0, 0))   -- 10:00 UTC
    check("after: hour",    after.hour, 3)         -- 03:00 PDT (02:00 skipped)
    check("after: is_dst",  after.is_dst, true)
end

print("fall-back boundary — 2026-11-01 02:00 PDT -> 01:00 PST")
do
    local before = clock.pacific_at(utc(2026, 11, 1, 8, 59, 0))  -- 08:59 UTC
    check("before: hour",   before.hour, 1)        -- 01:59 PDT
    check("before: is_dst", before.is_dst, true)
    local after  = clock.pacific_at(utc(2026, 11, 1, 9, 0, 0))   -- 09:00 UTC
    check("after: hour",    after.hour, 1)         -- 01:00 PST (repeated hour)
    check("after: is_dst",  after.is_dst, false)
end

print("california_today / california_yesterday")
-- mid-window:   2026-03-09 00:30 PDT (PDT in effect) = 07:30 UTC
check("today (mid-window)",
      clock.california_today(utc(2026, 3, 9, 7, 30)),     "2026-03-09")
check("yesterday (mid-window)",
      clock.california_yesterday(utc(2026, 3, 9, 7, 30)), "2026-03-08")
-- month boundary: 2026-04-01 00:10 PDT = 07:10 UTC -> yesterday 2026-03-31
check("yesterday across month",
      clock.california_yesterday(utc(2026, 4, 1, 7, 10)), "2026-03-31")
-- year boundary:  2026-01-01 00:10 PST = 08:10 UTC -> yesterday 2025-12-31
check("yesterday across year",
      clock.california_yesterday(utc(2026, 1, 1, 8, 10)), "2025-12-31")
-- late evening: 2026-05-21 23:00 PDT = 2026-05-22 06:00 UTC. The Pacific
-- date is still the 21st though UTC has rolled. Captures the CIMIS need
-- for civil time: "yesterday" in California is not "yesterday in UTC".
check("today lags UTC in the evening",
      clock.california_today(utc(2026, 5, 22, 6, 0)),     "2026-05-21")

print("")
if fails == 0 then
    print("test_clock: ALL PASS")
    os.exit(0)
else
    print("test_clock: " .. fails .. " FAIL")
    os.exit(1)
end
