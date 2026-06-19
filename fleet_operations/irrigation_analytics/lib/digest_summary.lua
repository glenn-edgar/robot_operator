-- digest_summary.lua — builds the daily KB2/KB4 operator digest body.
--
-- Two-tier notification model (Glenn 2026-06-10):
--   - KB1 / KB3 = action alerts → immediate per-event Discord (run aborted).
--   - KB2 / KB4 = diagnostics → ONE daily summary at 18:00 Pacific that tells
--     the operator "N things need review" and links to the dashboard. Detail
--     lives in the DB / website, never in Discord.
--
-- Source = the kb_alerts table (see lib/kb_alerts.lua). Each KB records its
-- CONFIRMED alert lines there at the moment it would have pushed Discord, so
-- the digest contains exactly those — no per-cycle candidate noise. We read
-- kb_alerts from each KB DB and aggregate the last WINDOW_S by display group.
--
-- Returns (body, counts):
--   body   = Discord-ready summary string, or nil when nothing is flagged
--            (caller suppresses empty digests — the point is attention).
--   counts = { failure_risk, short, thermal, wear, clog } distinct targets.

local kb_alerts = require("kb_alerts")

local M = {}

local lsqlite3 = nil
local function ensure_lsqlite3()
    if lsqlite3 then return lsqlite3 end
    local ok, mod = pcall(require, "lsqlite3")
    if not ok then return nil end
    lsqlite3 = mod
    return mod
end

-- Open a KB DB for reading. Absent file → nil (that KB hasn't run yet); we
-- must not create an empty DB, so check existence first. Container runs as
-- root and we only SELECT, so a plain 1-arg open is fine.
local function open_ro(path)
    local mod = ensure_lsqlite3()
    if not mod or not path then return nil end
    local fh = io.open(path, "r")
    if not fh then return nil end
    fh:close()
    return mod.open(path)
end

-- kind → display group. Anything unknown falls into "wear".
local GROUP_OF = {
    failure_risk = "failure_risk",
    short        = "short",
    thermal      = "thermal",
    heating      = "thermal",
    drift        = "wear",
    creep        = "wear",
    step         = "wear",
    clog         = "clog",
}

local function brief(set, max)
    max = max or 6
    local list = {}
    for k in pairs(set) do list[#list+1] = k end
    table.sort(list)
    if #list == 0 then return "" end
    if #list <= max then return " (" .. table.concat(list, ", ") .. ")" end
    local head = {}
    for i = 1, max do head[i] = list[i] end
    return string.format(" (%s +%d more)", table.concat(head, ", "), #list - max)
end

-- opts: kb_db_paths = { "/var/fleet/kb2/kb2.db", "/var/fleet/kb2_wr/kb2_wr.db", ... }
--       now_ms, window_s, report_date, dashboard_url
function M.build_summary(opts)
    opts = opts or {}
    local now_ms   = opts.now_ms or (os.time() * 1000)
    local since_ms = now_ms - (opts.window_s or 86400) * 1000

    -- Distinct targets per display group (a valve flagged twice = one entry).
    local groups = { failure_risk = {}, short = {}, thermal = {}, wear = {}, clog = {} }
    for _, path in ipairs(opts.kb_db_paths or {}) do
        local db = open_ro(path)
        if db then
            for _, row in ipairs(kb_alerts.query_since(db, since_ms)) do
                local g = GROUP_OF[row.kind] or "wear"
                groups[g][tostring(row.target or "?")] = true
            end
            db:close()
        end
    end

    local function n(g)
        local c = 0; for _ in pairs(groups[g]) do c = c + 1 end; return c
    end
    local counts = {
        failure_risk = n("failure_risk"), short = n("short"),
        thermal = n("thermal"), wear = n("wear"), clog = n("clog"),
    }

    -- Suppress when nothing needs review — the digest exists to get attention.
    if counts.failure_risk == 0 and counts.short == 0 and counts.thermal == 0
       and counts.wear == 0 and counts.clog == 0 then
        return nil, counts
    end

    local lines = { "🔧 Irrigation daily review — " .. tostring(opts.report_date or "") }
    if counts.failure_risk > 0 then
        lines[#lines+1] = string.format(
            "⚠️ rising-R FAILURE risk: %d valve(s)%s — may stop operating",
            counts.failure_risk, brief(groups.failure_risk))
    end
    if counts.short > 0 then
        lines[#lines+1] = string.format(
            "🔻 short candidates: %d valve(s)%s — effective R falling",
            counts.short, brief(groups.short))
    end
    if counts.thermal > 0 then
        lines[#lines+1] = string.format(
            "🌡️ ran hot: %d bin(s)%s — early-failure watch",
            counts.thermal, brief(groups.thermal))
    end
    if counts.wear > 0 then
        lines[#lines+1] = string.format(
            "🔺 upward drift / wear: %d valve(s)%s", counts.wear, brief(groups.wear))
    end
    if counts.clog > 0 then
        lines[#lines+1] = string.format(
            "🚱 blocked / clog: %d bin(s)%s", counts.clog, brief(groups.clog))
    end
    lines[#lines+1] = ""
    lines[#lines+1] = "→ Review details: " .. (opts.dashboard_url or "(dashboard URL unset)")

    return table.concat(lines, "\n"), counts
end

return M
