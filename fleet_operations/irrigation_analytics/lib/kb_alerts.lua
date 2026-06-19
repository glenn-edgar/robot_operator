-- kb_alerts.lua — durable per-cycle alert record for the daily digest.
--
-- Two-tier notification model (Glenn 2026-06-10): KB1/KB3 push immediate
-- action alerts; KB2/KB4 are diagnostics that roll up into ONE 18:00-Pacific
-- digest. The promotion logic (3-cycle confirm, joint cohort+baseline, etc.)
-- lives in the KB handlers and is NOT recoverable from the raw per-cycle
-- runs_* rows. So each KB, at the moment it WOULD have pushed Discord,
-- instead records the confirmed alert line here. The digest aggregates
-- these over the last 24 h — exactly what the old per-event Discord would
-- have said, only batched and noise-free (candidates never get recorded).
--
-- The table lives inside each KB's existing DB (no new connection); the
-- digest reads kb_alerts from each KB DB it knows about.

local M = {}

M.SCHEMA = [[
CREATE TABLE IF NOT EXISTS kb_alerts (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms     INTEGER NOT NULL,
    source    TEXT,     -- 'kb2' | 'kb2_wr' | 'kb4'
    kind      TEXT,     -- failure_risk|short|drift|creep|step|thermal|heating|clog
    severity  TEXT,     -- 'alert' | 'warn'
    target    TEXT,     -- valve or bin key
    summary   TEXT
);
CREATE INDEX IF NOT EXISTS idx_kb_alerts_ts ON kb_alerts(ts_ms);
]]

-- Idempotent — safe to call every boot on an already-open KB DB.
function M.ensure_schema(db)
    if not db then return nil, "no db" end
    local rc = db:exec(M.SCHEMA)
    return rc
end

-- Record one confirmed alert line. fields:
--   ts_ms, source, kind, severity, target, summary
function M.record(db, f)
    if not db or not f then return nil, "no db/fields" end
    local stmt = db:prepare([[
        INSERT INTO kb_alerts(ts_ms, source, kind, severity, target, summary)
        VALUES(?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(f.ts_ms, f.source, f.kind, f.severity, f.target, f.summary)
    stmt:step()
    stmt:finalize()
    return true
end

-- Return all alert rows since since_ms, oldest-first. Caller may pass a DB
-- that has no kb_alerts table yet (returns {} — pcall-guarded).
function M.query_since(db, since_ms)
    local out = {}
    if not db then return out end
    local ok = pcall(function()
        for r in db:nrows(string.format(
                "SELECT ts_ms, source, kind, severity, target, summary "
                .. "FROM kb_alerts WHERE ts_ms >= %d ORDER BY ts_ms", since_ms)) do
            out[#out+1] = r
        end
    end)
    if not ok then return {} end
    return out
end

return M
