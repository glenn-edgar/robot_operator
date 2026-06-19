-- kb1_overcurrent.lua — simple absolute-threshold overcurrent detector.
--
-- Design philosophy (Glenn 2026-06-09): KB1 stays independent of every
-- other detector. No KB2 baseline lookups, no expected_I math, no null
-- offset. Just two raw popup fields against fixed thresholds.
--
-- On either threshold cross:
--   1. Dispatch CLOSE_MASTER_VALVE  (water off first)
--   2. Dispatch SKIP_STATION         (advance past bad station)
--   3. Push Discord
--   4. Write row to runs_kb1
--   5. Edge-trigger: don't re-fire until current drops below threshold
--
-- Sources (both populated correctly in popup, no SSH-style fetch needed):
--   popup.PLC_IRRIGATION_CURRENT  — irrigation valve rail (sprinkler coils)
--   popup.PLC_EQUIPMENT_CURRENT   — equipment rail (master + others)
--
-- Thresholds chosen 2026-06-09 with headroom over normal operating peaks
-- observed across all bin types (single, dual, redundant, city-mixed):
--   IRR_KILL = 1.8 A   (max observed peak ~1.20 A, 50% headroom)
--   EQ_KILL  = 1.2 A   (max observed peak ~0.66 A, 80% headroom)
--
-- Future overcurrent rules can be ADDED to this KB but the absolute-
-- threshold path stays untouched as the always-on safety net.

local M = {}

-- =========================================================================
-- Thresholds (overridable via env in class_spec.kb1_overcurrent)
-- =========================================================================
M.IRR_KILL_A = 1.8   -- irrigation rail
-- Equipment rail raised 1.2→1.8 A (Glenn 2026-06-15): still wiring-safe. The
-- equipment-current reading carries a quasi-periodic ~0.4 A excursion that is
-- NOT a real load (constant load, only relays switch; uniform across all
-- satellites/relay counts). The 732s sit on a separate 5 V step-down rail and
-- the ADC is on yet another supply, so the swing is measurement/step-down noise.
-- 1.2 risked a false EQ kill on that artifact; 1.8 clears it. See the EQ sampler.
M.EQ_KILL_A  = tonumber(os.getenv("KB1_EQ_KILL_A")) or 1.8   -- equipment rail

-- =========================================================================
-- Classify
-- =========================================================================
--
-- Returns (cls, severity, excess, note).
--   cls:      OK | KB1_IRR_KILL | KB1_EQ_KILL
--   excess:   amps above the threshold that fired
function M.classify(irr_I, eq_I)
    if irr_I and irr_I > M.IRR_KILL_A then
        return "KB1_IRR_KILL", "critical", irr_I - M.IRR_KILL_A,
            string.format("IRR=%.2f A > %.1f A absolute threshold", irr_I, M.IRR_KILL_A)
    end
    if eq_I and eq_I > M.EQ_KILL_A then
        return "KB1_EQ_KILL", "critical", eq_I - M.EQ_KILL_A,
            string.format("EQ=%.2f A > %.1f A absolute threshold", eq_I, M.EQ_KILL_A)
    end
    return "OK", "ok", 0, nil
end

-- =========================================================================
-- SQLite (tracks every fire — diagnostic + audit)
-- =========================================================================
local lsqlite3 = nil
local function ensure_lsqlite3()
    if lsqlite3 then return lsqlite3 end
    local ok, mod = pcall(require, "lsqlite3")
    if not ok then return nil, "lsqlite3 not available: " .. tostring(mod) end
    lsqlite3 = mod
    return mod
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS runs_kb1 (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms           INTEGER NOT NULL,
    bin             TEXT,
    step            INTEGER,
    schedule        TEXT,
    irr_I           REAL,
    eq_I            REAL,
    cls             TEXT,
    severity        TEXT,
    excess          REAL,
    note            TEXT,
    actions_sent    TEXT,
    armed           INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_runs_kb1_ts ON runs_kb1(ts_ms);
CREATE INDEX IF NOT EXISTS idx_runs_kb1_cls ON runs_kb1(cls);
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

function M.insert_run(db, fields)
    local stmt = db:prepare([[
        INSERT INTO runs_kb1(
            ts_ms, bin, step, schedule,
            irr_I, eq_I, cls, severity, excess, note,
            actions_sent, armed)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(fields.ts_ms, fields.bin, fields.step, fields.schedule,
        fields.irr_I, fields.eq_I, fields.cls, fields.severity,
        fields.excess, fields.note,
        fields.actions_sent or "", fields.armed and 1 or 0)
    stmt:step()
    stmt:finalize()
    return true
end

return M
