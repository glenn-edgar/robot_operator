-- robot_common/lib/format_table.lua — fixed-width report formatter.
--
-- Port of robot_person/robots/farm_soil/format.py. Pure Lua, engine-free —
-- unit-testable without booting the chain_tree. The farm_soil daily-digest
-- leaf calls format_daily_report(moisture_rows, eto_rows, opts) and
-- publishes the returned string as the digest body; downstream
-- (notification_service) POSTs it to Discord verbatim.
--
-- Row shapes (mirror the Python):
--   moisture_rows: one entry per device, fields:
--     device_id          string
--     latest_value       number | nil
--     latest_ts          string ISO-8601 ("YYYY-MM-DDTHH:MM:SSZ" or with subseconds)
--     uplinks_in_window  number
--   eto_rows: one entry per day, most-recent first, fields:
--     date               string ISO-8601
--     value              number | nil
--     unit               string
--
-- An empty list renders as "(no data)" — surface the gap rather than
-- producing a misleadingly-short message.

local M = {}

local MOISTURE_HEADER = "Moisture (per-device latest):"
local ETO_HEADER      = "ETo (CIMIS):"

-- "2026-05-05T16:48:03.851Z" -> "2026-05-05T16:48:03Z" (drop subseconds).
local function short_time(ts)
    if type(ts) ~= "string" or ts == "" then return "?" end
    local dot = ts:find(".", 1, true)
    if dot then return ts:sub(1, dot - 1) .. "Z" end
    return ts
end

local function fmt_num(value, prec)
    if value == nil then return "?" end
    return string.format("%0." .. prec .. "f", value)
end

local function pad_right(s, width)
    s = tostring(s)
    if #s >= width then return s end
    return s .. string.rep(" ", width - #s)
end

local function pad_left(s, width)
    s = tostring(s)
    if #s >= width then return s end
    return string.rep(" ", width - #s) .. s
end

-- Build the daily-report string.
-- opts.report_date — ISO date stamp printed in the header (default: today UTC).
function M.format_daily_report(moisture_rows, eto_rows, opts)
    opts = opts or {}
    local today = opts.report_date or os.date("!%Y-%m-%d")
    local lines = {
        "=== farm_soil daily report — " .. today .. " ===",
        "",
        MOISTURE_HEADER,
    }

    if not moisture_rows or #moisture_rows == 0 then
        lines[#lines + 1] = "  (no data)"
    else
        for _, row in ipairs(moisture_rows) do
            local device = row.device_id or "?"
            local value  = fmt_num(row.latest_value, 3)
            local ts     = row.latest_ts and short_time(row.latest_ts) or "?"
            local count  = row.uplinks_in_window or 0
            lines[#lines + 1] = string.format(
                "  %s %s  ts=%s  (%d uplinks)",
                pad_right(device, 10), pad_left(value, 6), ts, count)
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ETO_HEADER

    if not eto_rows or #eto_rows == 0 then
        lines[#lines + 1] = "  (no data)"
    else
        for _, row in ipairs(eto_rows) do
            local date  = row.date or "?"
            local value = fmt_num(row.value, 3)
            local unit  = row.unit or ""
            local line  = string.format("  %s  %s %s",
                date, pad_left(value, 6), unit)
            -- Strip trailing space when unit is empty (matches Python rstrip).
            line = line:gsub("%s+$", "")
            lines[#lines + 1] = line
        end
    end

    return table.concat(lines, "\n")
end

return M
