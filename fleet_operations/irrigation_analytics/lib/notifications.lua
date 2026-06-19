-- notifications.lua — the robot's "past actions" log: every Discord-bound
-- message the robot emits, recorded at publish time (Glenn 2026-06-10).
--
-- Mirrors the irrigation controller's past_actions: one chronological,
-- level-colored, Pacific-timestamped stream. The application_gateway reads
-- this DB to render /irrigation/actions. Two notification tiers both land
-- here:
--   - action alerts (KB1 overcurrent, KB3 leak) → level RED (a run aborted)
--   - daily summaries (the 18:00 digest)         → level YELLOW
--
-- Single shared DB on the bind mount (/var/fleet/notify/notifications.db):
-- the robot's KBs write it; the gateway reads it. 14-day retention via
-- prune() (Glenn 2026-06-10).

local M = {}

M.RETENTION_DAYS = 14

local lsqlite3 = nil
local function ensure_lsqlite3()
    if lsqlite3 then return lsqlite3 end
    local ok, mod = pcall(require, "lsqlite3")
    if not ok then return nil, "lsqlite3 not available: " .. tostring(mod) end
    lsqlite3 = mod
    return mod
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS notifications (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms   INTEGER NOT NULL,
    level   TEXT,     -- RED (action/abort) | YELLOW (summary/warn) | GREEN (info)
    source  TEXT,     -- KB1 | KB3 | DIGEST
    kind    TEXT,     -- OVERCURRENT | LEAK | DAILY_SUMMARY
    target  TEXT,     -- valve / bin, or ''
    action  TEXT,     -- e.g. 'CLOSE_MASTER_VALVE+SKIP_STATION', or ''
    title   TEXT,     -- one-line headline
    body    TEXT      -- full message
);
CREATE INDEX IF NOT EXISTS idx_notifications_ts ON notifications(ts_ms);
]]

function M.open_db(path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(path)
    if not db then
        return nil, string.format("open %s failed: %s/%s", path, tostring(code), tostring(errmsg))
    end
    local rc = db:exec(SCHEMA)
    if rc ~= mod.OK then
        local msg = db:errmsg(); db:close()
        return nil, "schema failed: " .. tostring(msg)
    end
    return db
end

-- f: { ts_ms, level, source, kind, target, action, title, body }
function M.record(db, f)
    if not db or not f then return nil, "no db/fields" end
    local stmt = db:prepare([[
        INSERT INTO notifications(ts_ms, level, source, kind, target, action, title, body)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(f.ts_ms, f.level, f.source, f.kind,
        f.target or "", f.action or "", f.title or "", f.body or "")
    stmt:step()
    stmt:finalize()
    return true
end

-- Drop rows older than RETENTION_DAYS. Cheap; safe to call on each publish.
function M.prune(db, now_ms)
    if not db then return end
    now_ms = now_ms or (os.time() * 1000)
    local cutoff = now_ms - M.RETENTION_DAYS * 86400 * 1000
    pcall(function() db:exec(string.format(
        "DELETE FROM notifications WHERE ts_ms < %d", cutoff)) end)
end

-- Read for the dashboard. opts: { since_ms, sources (list), limit, offset }.
-- Returns rows newest-first. pcall-guarded (missing table → {}).
function M.query(db, opts)
    opts = opts or {}
    local out = {}
    if not db then return out end
    local where = {}
    if opts.since_ms then where[#where+1] = string.format("ts_ms >= %d", opts.since_ms) end
    if opts.sources and #opts.sources > 0 then
        local q = {}
        for _, s in ipairs(opts.sources) do q[#q+1] = string.format("%q", s) end
        where[#where+1] = "source IN (" .. table.concat(q, ",") .. ")"
    end
    local sql = "SELECT id, ts_ms, level, source, kind, target, action, title, body FROM notifications"
    if #where > 0 then sql = sql .. " WHERE " .. table.concat(where, " AND ") end
    sql = sql .. " ORDER BY ts_ms DESC"
    if opts.limit then sql = sql .. string.format(" LIMIT %d", opts.limit) end
    if opts.offset then sql = sql .. string.format(" OFFSET %d", opts.offset) end
    pcall(function()
        for r in db:nrows(sql) do out[#out+1] = r end
    end)
    return out
end

return M
