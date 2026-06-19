-- lib/clock.lua — clock readers + Pacific civil time, shared by
-- fleet_design robots.
--
-- Two clocks for two jobs:
--   now_ms()   — CLOCK_MONOTONIC, integer milliseconds. For elapsed-time
--                math (timeouts, backoff, publish cadence). Immune to
--                wall-clock jumps (NTP step, manual set, VM pause/resume).
--   wall_now() — CLOCK_REALTIME + gmtime breakout. For calendar-anchored
--                scheduling and ts fields published on the wire. Field
--                shape matches the C system's cfl_time_info_t.
--
-- Lua doubles (53-bit mantissa) hold int64 ms with no precision loss for
-- ~285k years and epoch seconds with sub-ns precision until year 2554.

local ffi = require("ffi")

-- ct_builtins cdef's these too; pcall keeps us safe in either load order.
pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } ct_log_timespec_t;")
pcall(ffi.cdef, "int clock_gettime(int clk_id, ct_log_timespec_t *tp);")

local _ts = ffi.new("ct_log_timespec_t")
local CLOCK_REALTIME  = 0
local CLOCK_MONOTONIC = 1

local M = {}

function M.now_ms()
    ffi.C.clock_gettime(CLOCK_MONOTONIC, _ts)
    return tonumber(_ts.tv_sec) * 1000
         + math.floor(tonumber(_ts.tv_nsec) / 1e6)
end

-- Returns a table with the same field shape as the C cfl_time_info_t:
--   { year, month, day, dow (Mon=0..Sun=6), doy (1-366),
--     hour, minute, second, epoch_s (fractional double) }
-- All UTC.
function M.wall_now()
    ffi.C.clock_gettime(CLOCK_REALTIME, _ts)
    local sec  = tonumber(_ts.tv_sec)
    local nsec = tonumber(_ts.tv_nsec)
    local t    = os.date("!*t", sec)
    return {
        year    = t.year,
        month   = t.month,
        day     = t.day,
        dow     = (t.wday + 5) % 7,   -- Lua wday Sun=1..Sat=7 → Mon=0..Sun=6
        doy     = t.yday,
        hour    = t.hour,
        minute  = t.min,
        second  = t.sec,
        epoch_s = sec + nsec * 1e-9,
    }
end

-- ─── US Pacific civil time ────────────────────────────────────────────
-- CIMIS (and other California data sources) report and schedule in
-- Pacific civil time — PST (UTC-8) in winter, PDT (UTC-7) in summer.
-- LuaJIT has no zoneinfo, so the DST rule is encoded here directly.
--
-- Post-2007 US rule: PDT runs from 02:00 local on the 2nd Sunday of
-- March to 02:00 local on the 1st Sunday of November.
--
-- days_from_civil / civil_from_days are Howard Hinnant's proleptic-
-- Gregorian day-count algorithms (days relative to 1970-01-01 = 0).
-- They give exact calendar math with no os.time()/local-TZ exposure.

local function idiv(a, b) return math.floor(a / b) end

-- Days since 1970-01-01 for a Gregorian Y/M/D (all integers).
function M.days_from_civil(y, m, d)
    y = y - (m <= 2 and 1 or 0)
    local era = idiv(y >= 0 and y or y - 399, 400)
    local yoe = y - era * 400
    local doy = idiv(153 * (m + (m > 2 and -3 or 9)) + 2, 5) + d - 1
    local doe = yoe * 365 + idiv(yoe, 4) - idiv(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

-- Inverse: a day count back to year, month, day.
function M.civil_from_days(z)
    z = z + 719468
    local era = idiv(z >= 0 and z or z - 146096, 146097)
    local doe = z - era * 146097
    local yoe = idiv(doe - idiv(doe, 1460) + idiv(doe, 36524)
                     - idiv(doe, 146096), 365)
    local y   = yoe + era * 400
    local doy = doe - (365 * yoe + idiv(yoe, 4) - idiv(yoe, 100))
    local mp  = idiv(5 * doy + 2, 153)
    local d   = doy - idiv(153 * mp + 2, 5) + 1
    local m   = mp < 10 and mp + 3 or mp - 9
    return y + (m <= 2 and 1 or 0), m, d
end

-- Day-of-month of the nth Sunday of (year, month). The 0=Sun weekday
-- convention follows from 1970-01-01 being a Thursday: (days + 4) % 7.
local function nth_sunday(year, month, n)
    local wd = (M.days_from_civil(year, month, 1) + 4) % 7
    return 1 + ((7 - wd) % 7) + (n - 1) * 7
end

-- UTC offset (seconds) and is_dst flag in effect at a UTC epoch, Pacific.
local function pacific_offset(epoch)
    local y = os.date("!*t", epoch).year
    -- Spring forward: 02:00 PST (= 10:00 UTC) on the 2nd Sunday of March.
    local spring = M.days_from_civil(y, 3, nth_sunday(y, 3, 2)) * 86400
                 + 10 * 3600
    -- Fall back: 02:00 PDT (= 09:00 UTC) on the 1st Sunday of November.
    local fall = M.days_from_civil(y, 11, nth_sunday(y, 11, 1)) * 86400
               + 9 * 3600
    if epoch >= spring and epoch < fall then
        return -7 * 3600, true     -- PDT
    end
    return -8 * 3600, false        -- PST
end

-- Pacific civil time at a given UTC epoch — same field shape as wall_now(),
-- plus is_dst and utc_offset_s. Exposed (not just pacific_now) so callers
-- and tests can evaluate a specific instant.
function M.pacific_at(epoch)
    local off, is_dst = pacific_offset(epoch)
    local t = os.date("!*t", epoch + off)
    return {
        year   = t.year, month = t.month,  day    = t.day,
        dow    = (t.wday + 5) % 7,          doy    = t.yday,
        hour   = t.hour, minute = t.min,    second = t.sec,
        is_dst = is_dst, utc_offset_s = off, epoch_s = epoch,
    }
end

-- Pacific civil time right now.
function M.pacific_now()
    ffi.C.clock_gettime(CLOCK_REALTIME, _ts)
    return M.pacific_at(tonumber(_ts.tv_sec))
end

-- Calendar date (YYYY-MM-DD) in Pacific civil time. `epoch` is optional —
-- it defaults to now; pass one to evaluate a specific instant.
function M.california_today(epoch)
    local p = epoch and M.pacific_at(epoch) or M.pacific_now()
    return string.format("%04d-%02d-%02d", p.year, p.month, p.day)
end

-- The Pacific calendar date one day before california_today().
function M.california_yesterday(epoch)
    local p = epoch and M.pacific_at(epoch) or M.pacific_now()
    local y, m, d = M.civil_from_days(
        M.days_from_civil(p.year, p.month, p.day) - 1)
    return string.format("%04d-%02d-%02d", y, m, d)
end

return M
