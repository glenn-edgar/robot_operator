-- lib/bad_sprinklers.lua — latched "bad solenoid" registry.
--
-- Glenn 2026-06-26: a single irrigation-current spike above the kill threshold
-- (KB1_IRR_KILL_A, default 1.5 A) is itself the verdict — the coil is arcing
-- through an intermittent short. It reseats and runs fine next time, so the
-- current looks normal afterward; the SPIKE EVENT is the evidence. So the flag
-- LATCHES: one spike => BAD, and it does NOT clear because a later run was quiet.
-- It clears ONLY when an operator logs a `replace_solenoid` / `replace_valve`
-- field action for that valve (see lib/field_log.lua).
--
-- Stored in its own sqlite file so KB1 (writer), field_log (clearer) and the
-- digest (reader) can each open it independently.

local M = {}

M.DB_PATH = "/var/fleet/kb1/bad_sprinklers.db"

function M.open(path)
    local ok, sql = pcall(require, "lsqlite3")
    if not ok then return nil, "lsqlite3 unavailable" end
    local db = sql.open(path or M.DB_PATH)
    if not db then return nil, "open failed" end
    db:exec([[
        CREATE TABLE IF NOT EXISTS bad_sprinklers (
            valve        TEXT PRIMARY KEY,   -- e.g. satellite_4:9
            first_ms     INTEGER,
            last_ms      INTEGER,
            spike_count  INTEGER DEFAULT 0,
            peak_irr     REAL,
            schedule     TEXT,
            step         INTEGER,
            cleared      INTEGER DEFAULT 0,  -- 1 once a replace action is logged
            cleared_ms   INTEGER
        );
    ]])
    return db
end

local function q(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

-- latch(db, valve, info): record/refresh a spike on `valve` and (re)mark it BAD.
--   info = { ts_ms, peak_irr, schedule, step }
function M.latch(db, valve, info)
    info = info or {}
    local ts = tonumber(info.ts_ms) or 0
    db:exec(string.format([[
        INSERT INTO bad_sprinklers(valve, first_ms, last_ms, spike_count,
                                   peak_irr, schedule, step, cleared, cleared_ms)
        VALUES(%s, %d, %d, 1, %s, %s, %d, 0, NULL)
        ON CONFLICT(valve) DO UPDATE SET
            last_ms     = %d,
            spike_count = spike_count + 1,
            peak_irr    = MAX(peak_irr, %s),
            schedule    = %s,
            step        = %d,
            cleared     = 0,            -- a new spike re-arms the flag
            cleared_ms  = NULL;
    ]], q(valve), ts, ts, tonumber(info.peak_irr) or 0,
        q(info.schedule or ""), tonumber(info.step) or 0,
        ts, tonumber(info.peak_irr) or 0, q(info.schedule or ""),
        tonumber(info.step) or 0))
end

-- clear(db, valve, ts_ms): operator replaced the solenoid → mark cleared.
-- Returns the number of rows actually cleared (0 if it wasn't flagged).
function M.clear(db, valve, ts_ms)
    db:exec(string.format(
        "UPDATE bad_sprinklers SET cleared=1, cleared_ms=%d WHERE valve=%s AND cleared=0",
        tonumber(ts_ms) or 0, q(valve)))
    return db:changes()
end

-- active(db): list of currently-BAD valves (not yet replaced).
function M.active(db)
    local out = {}
    for r in db:nrows([[SELECT valve, spike_count, peak_irr, schedule, step, last_ms
                        FROM bad_sprinklers WHERE cleared=0 ORDER BY last_ms DESC]]) do
        out[#out+1] = r
    end
    return out
end

function M.is_bad(db, valve)
    for r in db:nrows("SELECT 1 FROM bad_sprinklers WHERE valve=" .. q(valve)
                      .. " AND cleared=0 LIMIT 1") do
        return true
    end
    return false
end

return M
