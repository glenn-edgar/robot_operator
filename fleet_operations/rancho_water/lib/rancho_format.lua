-- lib/rancho_format.lua — formatter for the Rancho daily usage digest.
--
-- Engine-free, unit-testable. Consumes the decoded JSON from
-- rancho_portal:fetch_day and returns a fixed-width body string suitable
-- for the digest channel (Discord message body, well under 2000 chars).
--
-- Input shape (verified live 2026-05-24 against /api/usage/get/):
--   {
--     AccountNumber = "3047791",
--     Date          = "2026-05-23T00:00:00",
--     DayOfWeek     = 6,
--     Usage         = { { ReadTime="...T01:00:00", GPH=0,   GPM=0,   HCF=0 },
--                       { ReadTime="...T02:00:00", GPH=7,   GPM=0,   HCF=0 },
--                       ... },
--     TotalGallons  = 1234.0,
--     TotalHCF      = 8.5,
--     ...
--   }
--
-- The robot picked "no alerts, just data": we render the hourly table and
-- the day total; we DO NOT condition on LeakDetected/ExceededFlowThreshold
-- (those flags are still in the raw JSON for persistence to capture).

local M = {}

-- Hundred Cubic Feet -> gallons. 1 HCF == 748.052 US gallons exactly
-- (https://www.usbr.gov/lc/region/g4000/wtrweights.pdf). Rancho's API
-- ships per-hour HCF as INT only — 135 GPH (=0.18 HCF) rounds to 0.0 in
-- their response. We compute the real fractional HCF from GPH ourselves
-- so the column has meaningful values at low flow rates; the daily
-- TotalHCF still comes from the API (it's the billing-authoritative value).
M.HCF_TO_GAL = 748.052

local function fmt_int(value)
    if value == nil then return "?" end
    return string.format("%d", math.floor(value + 0.5))
end

local function fmt_num(value, prec)
    if value == nil then return "?" end
    return string.format("%0." .. prec .. "f", value)
end

local function pad_left(s, w)
    s = tostring(s)
    if #s >= w then return s end
    return string.rep(" ", w - #s) .. s
end

-- "2026-05-23T03:00:00" -> "03:00".  Returns "??:??" on malformed input
-- rather than throwing — a misshapen hour entry should not kill the digest.
local function hour_of(read_time)
    if type(read_time) ~= "string" then return "??:??" end
    local h, m = read_time:match("T(%d%d):(%d%d):")
    if not h then return "??:??" end
    return h .. ":" .. m
end

-- The whole report body.  date_iso ("YYYY-MM-DD") used in the header so
-- the reader knows which day's data this is.
function M.format_daily_report(data, date_iso)
    data = data or {}
    local lines = {
        "=== rancho_water daily report — " .. (date_iso or "?") .. " ===",
        "",
    }

    -- Hourly table. HCF computed from GPH (the API per-hour HCF is INT
    -- and reads 0.0 for any sub-748-gph hour, which on this meter is
    -- almost every hour).
    lines[#lines + 1] = "Hourly usage:"
    local usage = data.Usage
    if type(usage) ~= "table" or #usage == 0 then
        lines[#lines + 1] = "  (no data)"
    else
        lines[#lines + 1] = "  hour    GPH    GPM     HCF"
        for _, row in ipairs(usage) do
            local hcf = row.GPH and (row.GPH / M.HCF_TO_GAL) or nil
            lines[#lines + 1] = string.format(
                "  %s  %s  %s  %s",
                hour_of(row.ReadTime),
                pad_left(fmt_int(row.GPH), 5),
                pad_left(fmt_int(row.GPM), 5),
                pad_left(fmt_num(hcf, 3), 6))
        end
    end

    lines[#lines + 1] = ""

    -- Daily summary.
    local total_gal = data.TotalGallons
    local total_hcf = data.TotalHCF
    if total_gal ~= nil or total_hcf ~= nil then
        lines[#lines + 1] = string.format(
            "Total: %s gal (%s HCF)",
            fmt_int(total_gal), fmt_num(total_hcf, 2))
    else
        lines[#lines + 1] = "Total: (no total reported)"
    end

    return table.concat(lines, "\n")
end

return M
