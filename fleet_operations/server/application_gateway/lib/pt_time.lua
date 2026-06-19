-- pt_time.lua — DST-aware US/Pacific timestamp formatter for the dashboard.
--
-- Self-contained copy of robot_common/lib/clock.lua's Pacific logic (the
-- gateway's LUA_PATH does not include robot_common). Post-2007 US rule:
-- PDT from 02:00 local on the 2nd Sunday of March to 02:00 local on the
-- 1st Sunday of November. Replaces the dashboard's old fixed -7h hack so
-- the /irrigation/actions page shows correct PT/PDT year-round.

local M = {}

local function idiv(a, b) return math.floor(a / b) end

local function days_from_civil(y, m, d)
    y = y - (m <= 2 and 1 or 0)
    local era = idiv(y >= 0 and y or y - 399, 400)
    local yoe = y - era * 400
    local doy = idiv(153 * (m + (m > 2 and -3 or 9)) + 2, 5) + d - 1
    local doe = yoe * 365 + idiv(yoe, 4) - idiv(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

local function nth_sunday(year, month, n)
    local wd = (days_from_civil(year, month, 1) + 4) % 7
    return 1 + ((7 - wd) % 7) + (n - 1) * 7
end

-- (offset_seconds, is_dst) in effect at a UTC epoch.
local function pacific_offset(epoch)
    local y = os.date("!*t", epoch).year
    local spring = days_from_civil(y, 3, nth_sunday(y, 3, 2)) * 86400 + 10 * 3600
    local fall   = days_from_civil(y, 11, nth_sunday(y, 11, 1)) * 86400 + 9 * 3600
    if epoch >= spring and epoch < fall then return -7 * 3600, true end
    return -8 * 3600, false
end

-- Format a UTC unix-ms timestamp as Pacific "YYYY-MM-DD HH:MM:SS PDT".
function M.format_ms(ts_ms, fmt)
    local epoch = math.floor((ts_ms or 0) / 1000)
    local off, is_dst = pacific_offset(epoch)
    local tz = is_dst and "PDT" or "PST"
    return os.date(fmt or "!%Y-%m-%d %H:%M:%S", epoch + off) .. " " .. tz
end

-- Just the clock part (HH:MM:SS PDT) for compact headers.
function M.format_ms_short(ts_ms)
    return M.format_ms(ts_ms, "!%H:%M:%S")
end

return M
