-- lib/kb5_filter.lua — SQLite layer for the KB5 PLC filter-load detector.
--
-- Three tables:
--   evals_kb5    per-minute trace (every minute-transition tick on an armed bin)
--   runs_kb5     fires (one row per filter-load trip; armed=0 in monitor mode)
--   kb5_meta     key/val store — persists `last_fire_ms` so the 90-minute global
--                rate gate survives a container restart (Glenn 2026-06-26: the
--                filter clean is a GLOBAL action, fire no more than once / 90 min).
--
-- Detection + recovery decisions live in the kb5 call site / lib/plc_filter.lua;
-- this module is storage only. Mirrors lib/kb3_sustained.lua's db pattern.

local M = {}

local lsqlite3 = nil
local function ensure_lsqlite3()
    if lsqlite3 then return lsqlite3 end
    local ok, mod = pcall(require, "lsqlite3")
    if not ok then return nil, "lsqlite3 not available: " .. tostring(mod) end
    lsqlite3 = mod
    return mod
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS evals_kb5 (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms         INTEGER NOT NULL,
    bin           TEXT,
    is_city       INTEGER DEFAULT 0,
    is_eto        INTEGER DEFAULT 0,
    schedule      TEXT,
    station_step  INTEGER,
    elapsed_min   INTEGER,
    plc_gpm       REAL,
    hunter_gpm    REAL,
    plc_steady    REAL,
    hun_steady    REAL,
    plc_ratio     REAL,
    hun_ratio     REAL,
    drop_consec   INTEGER,
    below         INTEGER,
    fired         INTEGER,
    reason        TEXT
);
CREATE INDEX IF NOT EXISTS idx_evals_kb5_bin   ON evals_kb5(bin);
CREATE INDEX IF NOT EXISTS idx_evals_kb5_ts    ON evals_kb5(ts_ms);
CREATE INDEX IF NOT EXISTS idx_evals_kb5_fired ON evals_kb5(fired);

CREATE TABLE IF NOT EXISTS runs_kb5 (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms         INTEGER NOT NULL,
    bin           TEXT,
    is_city       INTEGER DEFAULT 0,
    is_eto        INTEGER DEFAULT 0,
    schedule      TEXT,
    station_step  INTEGER,
    elapsed_min   INTEGER,
    plc_gpm       REAL,
    hunter_gpm    REAL,
    plc_steady    REAL,
    hun_steady    REAL,
    onset_min     INTEGER,
    reinsert_rt   INTEGER,
    run_time      INTEGER,
    cooldown_block INTEGER DEFAULT 0,
    actions_sent  TEXT,
    armed         INTEGER DEFAULT 0,
    note          TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_kb5_ts ON runs_kb5(ts_ms);

CREATE TABLE IF NOT EXISTS kb5_meta (
    key TEXT PRIMARY KEY,
    val INTEGER
);
]]

function M.open_db(path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(path)
    if not db then
        return nil, string.format("open %s failed: %s/%s",
            path, tostring(code), tostring(errmsg))
    end
    local rc = db:exec(SCHEMA)
    if rc ~= mod.OK then
        local msg = db:errmsg()
        db:close()
        return nil, "schema migration failed: " .. tostring(msg)
    end
    return db
end

-- 90-min rate gate persistence. last_fire_ms is the ms timestamp of the last
-- ARMED actuation (monitor-only would-fires do NOT consume the cooldown, so the
-- full event stream stays visible during validation).
function M.get_last_fire_ms(db)
    local v = nil
    for row in db:nrows("SELECT val FROM kb5_meta WHERE key='last_fire_ms'") do
        v = tonumber(row.val)
    end
    return v
end

function M.set_last_fire_ms(db, ts_ms)
    -- INSERT OR REPLACE (key is PRIMARY KEY) = upsert, works on all SQLite versions.
    local stmt = db:prepare(
        "INSERT OR REPLACE INTO kb5_meta(key,val) VALUES('last_fire_ms',?)")
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(tonumber(ts_ms) or 0)
    stmt:step()
    stmt:finalize()
    return true
end

function M.insert_eval(db, f)
    local stmt = db:prepare([[
        INSERT INTO evals_kb5(
            ts_ms, bin, is_city, is_eto, schedule, station_step, elapsed_min,
            plc_gpm, hunter_gpm, plc_steady, hun_steady, plc_ratio, hun_ratio,
            drop_consec, below, fired, reason)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(f.ts_ms, f.bin,
        f.is_city and 1 or 0, f.is_eto and 1 or 0,
        f.schedule, f.station_step, f.elapsed_min,
        f.plc_gpm, f.hunter_gpm, f.plc_steady, f.hun_steady,
        f.plc_ratio, f.hun_ratio, f.drop_consec or 0,
        f.below and 1 or 0, f.fired and 1 or 0, f.reason)
    stmt:step()
    stmt:finalize()
    return true
end

function M.insert_fire(db, f)
    local stmt = db:prepare([[
        INSERT INTO runs_kb5(
            ts_ms, bin, is_city, is_eto, schedule, station_step, elapsed_min,
            plc_gpm, hunter_gpm, plc_steady, hun_steady, onset_min, reinsert_rt,
            run_time, cooldown_block, actions_sent, armed, note)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(f.ts_ms, f.bin,
        f.is_city and 1 or 0, f.is_eto and 1 or 0,
        f.schedule, f.station_step, f.elapsed_min,
        f.plc_gpm, f.hunter_gpm, f.plc_steady, f.hun_steady,
        f.onset_min, f.reinsert_rt, f.run_time,
        f.cooldown_block and 1 or 0,
        f.actions_sent or "", f.armed and 1 or 0, f.note)
    stmt:step()
    stmt:finalize()
    return true
end

return M
