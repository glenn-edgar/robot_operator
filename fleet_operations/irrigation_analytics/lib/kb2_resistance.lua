-- kb2_resistance.lua — per-valve coil resistance trend detector.
--
-- Reads the IRRIGATION_VALVE_TEST hash from the controller, applies the
-- 2-null offset method (mean of sat_3:1 + sat_4:6), computes calc R via
-- R = 15.6 V / (I_raw - offset), classifies vs rolling-median baseline.
--
-- WSL test phase: monitor-only. No actuation. DB on WARN, Discord on
-- R_DRIFT_ALERT (sustained 3-cycle) and MASTER_RELAY_CREEP. The 5-Ω
-- step-change detector (R_STEP_NOTED) flags maintenance events for
-- the run-log; not an alert.
--
-- Calibration anchors (verified 2026-06-06 PM by meter):
--   PSU = 15.6 V                         (NOT terminal block 14.5-15 V)
--   offset = mean(I[sat_3:1], I[sat_4:6])
--   sat_1:43 = 40.0 Ω measured ~ 40.06 Ω calc → no sensor-scale correction needed
--   sat_1:44 = 23.0 Ω measured ~ 23.17 Ω calc (parallel of two ~46 Ω coils)
--   sat_1:29/30/31 all calc within 1.7 Ω of meter
--
-- Step-change observed in past valve_test history: sat_1:43 dropped from
-- ~46 Ω → ~40 Ω between cycles 15 and 16 (maintenance event in cabinet).
-- R_STEP_NOTED flag exists specifically for this signature.

local cjson = require("cjson")

local M = {}

-- =========================================================================
-- Tuneables
-- =========================================================================
-- PSU_VOLTAGE: 15.4 V — locked 2026-06-09 PM by Glenn after the two-cycle
-- avg3 calibration sweep with the modified-old-code controller. With this
-- V_PSU and the 2-null offset (~0.133 A cycle-to-cycle), R_effective
-- matches hand-meter coil readings to within ±4% on six reference valves
-- (sat_1:17, :29, :30, :31, :43, :44). Cycle-to-cycle reproducibility is
-- under 2% for nearly all valves. See effective_r_short_detection memo
-- for why we track effective R (= coil R + wire R) and not bare coil R.
M.PSU_VOLTAGE              = 15.4
M.WARN_DELTA_OHM           = 4.0    -- |Δ| > 4 → DB warn
M.ALERT_DELTA_OHM          = 8.0    -- |Δ| > 8 over 3 cycles → Discord
M.STEP_DELTA_OHM           = 5.0    -- |ΔR_prev| > 5 in one cycle → maintenance flag
M.MASTER_RELAY_CREEP_DELTA = 3.0    -- sat_1:43 upward only: R > baseline + 3 → DB warn
M.MISCAL_LOW               = 18.0
M.MISCAL_HIGH              = 80.0
M.WINDOW_N                 = 15     -- rolling-median window cap
M.ALERT_STREAK_REQUIRED    = 3      -- consecutive cycles in same direction → Discord
M.NEAR_NULL_REJECT_COUNT   = 8      -- >N near-null readings → reject cycle validity

M.NULL_VALVES = { "satellite_3:1", "satellite_4:6" }

-- Per-valve topology metadata. Anything not listed uses defaults.
-- Loaded at boot from data/kb2_topology.json — see M.load_topology().
M.TOPOLOGY = {
    ["satellite_1:43"] = {
        is_master = true,
        note = "master path, single coil ~40 Ω, drift upward = relay aging",
    },
    ["satellite_1:44"] = {
        parallel_valves = 2,
        note = "two ~46 Ω coils in parallel = 23 Ω; half-coil failure → R doubles to ~46",
    },
}

-- Coil-vs-cohort detection thresholds.
M.COIL_DRIFT_WARN_OHM  = 3.0  -- coil R deviates from branch median by > 3 Ω → DB warn
M.COIL_DRIFT_ALERT_OHM = 5.0  -- > 5 Ω AND streak ≥ 3 cycles → Discord

-- Absolute high-R FAILURE-RISK ceiling (Glenn 2026-06-10). The drift +
-- cohort detectors compare to a ROLLING median, which absorbs slow
-- monotonic creep — a valve aging steadily upward re-baselines every cycle
-- and never trips, until it's too high to pull in the solenoid (the
-- sat_2:13 group field failure: rising R → valve won't operate). This
-- check is anchored to the FROZEN expected_coil_R in the topology, so creep
-- can't hide. Pull-in is really a minimum actuation current (I = V_PSU/R),
-- so a RATIO over the commissioned value adapts across branches with
-- different expected R. TUNE from the 2:13 failure (what coil R did it
-- reach when it stopped pulling in?) via KB2_FAILURE_RISK_RATIO env.
M.FAILURE_RISK_RATIO = tonumber(os.getenv("KB2_FAILURE_RISK_RATIO")) or 1.30

-- 43 driven valves (excludes the 2 nulls used for offset).
M.VALVE_LIST = {
    "satellite_1:17", "satellite_1:29", "satellite_1:30", "satellite_1:31",
    "satellite_1:32", "satellite_1:39", "satellite_1:43", "satellite_1:44",
    "satellite_2:1",  "satellite_2:2",  "satellite_2:3",  "satellite_2:4",
    "satellite_2:5",  "satellite_2:6",  "satellite_2:7",  "satellite_2:11",
    "satellite_2:13", "satellite_2:14", "satellite_2:15", "satellite_2:16",
    "satellite_2:17", "satellite_3:2",  "satellite_3:4",  "satellite_3:5",
    "satellite_3:7",  "satellite_3:11", "satellite_3:12", "satellite_3:13",
    "satellite_3:14", "satellite_3:15", "satellite_3:18", "satellite_3:19",
    "satellite_4:1",  "satellite_4:2",  "satellite_4:3",  "satellite_4:4",
    "satellite_4:7",  "satellite_4:8",  "satellite_4:9",  "satellite_4:10",
    "satellite_4:11", "satellite_4:12", "satellite_4:13",
}

-- =========================================================================
-- Math
-- =========================================================================

-- Load topology JSON at boot. Merges into M.TOPOLOGY (preserving any
-- defaults already there). Returns count loaded.
function M.load_topology(path)
    local cjson = require("cjson")
    local fh = io.open(path, "r")
    if not fh then return 0, "cannot open " .. tostring(path) end
    local raw = fh:read("*a"); fh:close()
    if not raw or raw == "" then return 0, "empty file" end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return 0, "decode failed: " .. tostring(decoded)
    end
    local valves = decoded.valves or {}
    local n = 0
    for v, t in pairs(valves) do
        M.TOPOLOGY[v] = M.TOPOLOGY[v] or {}
        for k, val in pairs(t) do M.TOPOLOGY[v][k] = val end
        n = n + 1
    end
    return n, nil
end

function M.compute_offset_2null(currents)
    -- Compute sensor offset as the mean of the two null channels'
    -- raw current readings. sat_3:1 and sat_4:6 have no coil so their
    -- raw ACS712 readings ARE the sensor offset for this cycle.
    --
    -- 2026-06-09 PM final state: controller code reverted to OLD timing +
    -- 3-sample averaging (parallel-pair valves like sat_1:44 need
    -- continuous-bus timing to latch). Controller stores RAW currents
    -- (no offset subtraction), so KB2 subtracts it here. Cycle-to-cycle
    -- offset drift is ~0.007 A (well below sensor-accuracy budget).
    --
    -- Brief detour 2026-06-09 PM: this returned 0 while the controller
    -- briefly ran the offset-subtracting NEW.py code. That's been
    -- reverted. See [[effective-r-short-detection-2026-06-09]] for the
    -- locked design.
    local n31 = currents[M.NULL_VALVES[1]]
    local n46 = currents[M.NULL_VALVES[2]]
    if not n31 or not n46 then return nil end
    return (n31 + n46) / 2.0
end

-- Derive the operative calibration for this cycle. Returns a table:
--   { v_psu = number, offset = number, source = string,
--     controller_offset = number_or_nil, controller_v_psu_spread = number_or_nil }
--
-- Two sources, tried in order:
--   1. "controller": popup_data has v_psu + sensor_offset published by the
--      controller's rewritten valve_resistance_check_py3.py (2026-06-09).
--      The valve_test currents are ALREADY offset-corrected by the
--      controller, so our subtraction offset = 0. v_psu is the measured
--      PSU voltage for this cycle.
--   2. "legacy_2null": no v_psu in popup → fall back to the 2-null
--      heuristic + hardcoded PSU_VOLTAGE. This is the path that runs
--      against the unmodified controller.
--
-- popup_data may be nil (popup fetch failed) — silently falls back.
function M.derive_calibration(popup_data, currents)
    if popup_data then
        local v_psu = tonumber(popup_data.v_psu)
        local ctrl_offset = tonumber(popup_data.sensor_offset)
        if v_psu and v_psu > 10 and v_psu < 25 and ctrl_offset ~= nil then
            return {
                v_psu                  = v_psu,
                offset                 = 0,  -- controller already subtracted
                source                 = "controller",
                controller_offset      = ctrl_offset,
                controller_v_psu_spread = tonumber(popup_data.v_psu_spread),
                controller_cohort_n    = tonumber(popup_data.v_psu_cohort_n),
            }
        end
    end
    -- Legacy fallback
    return {
        v_psu  = M.PSU_VOLTAGE,
        offset = M.compute_offset_2null(currents) or 0,
        source = "legacy_2null",
    }
end

-- Compute R given a current reading and a calibration object. Single
-- entry-point used by both KB2_TICK and KB2_WR_TICK so the source
-- transition is in one place.
function M.compute_R_calibrated(I_raw, calibration)
    if not I_raw or not calibration then return nil end
    local I_net = I_raw - (calibration.offset or 0)
    if I_net <= 0 then return nil end
    return calibration.v_psu / I_net
end

-- Legacy two-arg signature preserved for any callers that pass a raw
-- offset (no callers left after the controller upgrade, but defensive).
function M.compute_R(I_raw, offset)
    if not I_raw or not offset then return nil end
    local Inet = I_raw - offset
    if Inet <= 0 then return nil end
    return M.PSU_VOLTAGE / Inet
end

function M.median(values)
    if not values or #values == 0 then return nil end
    local sorted = {}
    for i, v in ipairs(values) do sorted[i] = v end
    table.sort(sorted)
    local n = #sorted
    if n % 2 == 1 then return sorted[math.floor((n+1)/2)] end
    return (sorted[n/2] + sorted[n/2+1]) / 2.0
end

function M.mad(values, med)
    if not values or #values == 0 then return nil end
    med = med or M.median(values)
    local devs = {}
    for i, v in ipairs(values) do devs[i] = math.abs(v - med) end
    return M.median(devs)
end

function M.push_ring(ring, value, cap)
    ring[#ring+1] = value
    while #ring > cap do table.remove(ring, 1) end
    return ring
end

-- =========================================================================
-- Branch / cohort math (the "wire R per branch" decomposition)
-- =========================================================================
--
-- Given:
--   R_table     = { ["satellite_X:Y"] = R_calc this cycle, ... }
--   topology    = M.TOPOLOGY (with branch + expected_coil_R per valve)
--
-- Per branch:
--   wire_R = median over branch members of (R_calc - expected_coil_R)
--
-- Then per valve:
--   coil_R         = R_calc - wire_R[branch]
--   branch_median  = median coil_R over branch members
--   cohort_dev     = coil_R - branch_median
--
-- Null channels (is_null) and master (is_master) are EXCLUDED from cohort
-- median calculations — their R doesn't represent the branch's standard
-- coil. They still get coil_R computed, just don't contribute to the median.

-- Returns { branch_name = wire_R }, list of branches seen.
function M.compute_wire_R_per_branch(R_table)
    local by_branch = {}  -- branch -> list of (R - expected_coil_R)
    for valve, R in pairs(R_table) do
        local topo = M.TOPOLOGY[valve]
        if topo and topo.branch and topo.expected_coil_R then
            -- Skip nulls and master + parallel/special for wire R derivation —
            -- their expected_coil_R isn't the branch standard
            if not topo.is_null and not topo.is_master
               and not topo.parallel_valves then
                by_branch[topo.branch] = by_branch[topo.branch] or {}
                table.insert(by_branch[topo.branch], R - topo.expected_coil_R)
            end
        end
    end
    local out = {}
    for branch, deltas in pairs(by_branch) do
        out[branch] = M.median(deltas)
    end
    return out
end

-- Returns coil_R for valve given the branch's wire R.
function M.compute_coil_R(valve, R_total, wire_R_table)
    local topo = M.TOPOLOGY[valve]
    if not topo or not topo.branch then return R_total end
    local wire_R = wire_R_table[topo.branch] or 0
    return R_total - wire_R
end

-- Per-branch median COIL R (post-wire-subtraction). Skips nulls/master.
-- Returns { branch = median_coil_R }
function M.compute_branch_median_coil(coil_R_table)
    local by_branch = {}
    for valve, coil_R in pairs(coil_R_table) do
        local topo = M.TOPOLOGY[valve]
        if topo and topo.branch
           and not topo.is_null and not topo.is_master
           and not topo.parallel_valves then
            by_branch[topo.branch] = by_branch[topo.branch] or {}
            table.insert(by_branch[topo.branch], coil_R)
        end
    end
    local out = {}
    for branch, list in pairs(by_branch) do
        out[branch] = M.median(list)
    end
    return out
end

-- Classify a valve's coil R against its branch cohort.
-- Direction-aware cohort class name (Glenn 2026-06-10 effective-R model).
-- A member ABOVE its branch peers (d>0) is drifting UP = wear/aging;
-- a member BELOW its peers (d<0) is the SHORT direction (that valve's
-- coil insulation / terminal junction breaking down). Same magnitudes,
-- opposite sign — see [[effective-r-short-detection-2026-06-09]].
local function coil_class_for(d, level)
    local kind = (d < 0) and "SHORT" or "DRIFT"
    if level == "alert" then return "COIL_" .. kind .. "_ALERT_CANDIDATE" end
    return "COIL_" .. kind .. "_WARN"
end

-- Returns (coil_cls, severity, deviation, note).
-- coil_cls: COIL_OK | COIL_DRIFT_WARN | COIL_DRIFT_ALERT_CANDIDATE (above peers)
--                   | COIL_SHORT_WARN | COIL_SHORT_ALERT_CANDIDATE (below peers)
function M.classify_coil_vs_cohort(valve, coil_R, branch_median)
    if not coil_R or not branch_median then
        return "COIL_OK", "ok", 0, nil
    end
    local topo = M.TOPOLOGY[valve]
    -- Master / null / parallel: skip cohort comparison; use absolute expected
    if topo and (topo.is_master or topo.is_null or topo.parallel_valves) then
        local expected = (topo and topo.expected_coil_R) or coil_R
        local d = coil_R - expected
        if math.abs(d) > M.COIL_DRIFT_ALERT_OHM then
            return coil_class_for(d, "alert"), "alert", d,
                string.format("special-role coil_R %+.1f Ω vs expected", d)
        elseif math.abs(d) > M.COIL_DRIFT_WARN_OHM then
            return coil_class_for(d, "warn"), "warn", d,
                string.format("special-role coil_R %+.1f Ω vs expected", d)
        end
        return "COIL_OK", "ok", d, nil
    end
    -- Standard valves: compare to branch median
    local d = coil_R - branch_median
    if math.abs(d) > M.COIL_DRIFT_ALERT_OHM then
        return coil_class_for(d, "alert"), "alert", d,
            string.format("coil_R %+.1f Ω vs branch median %.1f", d, branch_median)
    elseif math.abs(d) > M.COIL_DRIFT_WARN_OHM then
        return coil_class_for(d, "warn"), "warn", d,
            string.format("coil_R %+.1f Ω vs branch median %.1f", d, branch_median)
    end
    return "COIL_OK", "ok", d, nil
end

-- Absolute high-R failure-risk vs the FROZEN commissioned expected_coil_R.
-- Independent of the rolling baseline (which absorbs slow creep) and of the
-- per-cycle cohort median (blind to whole-branch aging). Returns
-- (cls, severity, delta_over_expected, note) or nil when no expected_coil_R
-- is known for the valve. Catches the sat_2:13 rising-R-to-non-operation mode.
function M.classify_failure_risk(valve, coil_R)
    if not coil_R then return nil end
    local topo = M.TOPOLOGY[valve]
    local exp = topo and topo.expected_coil_R
    if not exp or exp <= 0 then return nil end
    if coil_R > exp * M.FAILURE_RISK_RATIO then
        return "R_HIGH_FAILURE_RISK", "alert", coil_R - exp,
            string.format("coil_R=%.1f Ω > %.0f%% of commissioned %.1f Ω — rising toward non-operation (won't pull in)",
                coil_R, M.FAILURE_RISK_RATIO * 100, exp)
    end
    return nil
end

-- =========================================================================
-- Classification
-- =========================================================================
--
-- Returns (cls, severity, delta_baseline, delta_step, note).
--
-- Effective-R direction model (Glenn 2026-06-10, see
-- [[effective-r-short-detection-2026-06-09]]): effective R = R_coil + R_wire.
-- INCREASING R = wear / coil aging / relay creep (R_DRIFT_*, R_STEP_NOTED,
-- MASTER_RELAY_CREEP). DECREASING R = SHORT signature — insulation
-- breakdown / developing wire-to-wire bridge / moisture intrusion
-- (R_SHORT_*). The two families share magnitudes (WARN=4, ALERT=8,
-- STEP=5 Ω); only the sign differs.
--
-- cls strings:
--   OK | POSSIBLE_CHIP_MISCAL | no_reading
--   up:   R_DRIFT_WARN | R_DRIFT_ALERT_CANDIDATE | R_STEP_NOTED | MASTER_RELAY_CREEP
--   down: R_SHORT_WARN | R_SHORT_ALERT_CANDIDATE | R_SHORT_STEP
--
-- R_{DRIFT,SHORT}_ALERT_CANDIDATE is a single-cycle observation. The
-- KB2_TICK caller bumps a streak counter; once 3 consecutive cycles in the
-- same direction land, it promotes to R_DRIFT_ALERT / R_SHORT_ALERT + Discord.

function M.classify(R_calc, baseline_med, prev_R, bin_key)
    if not R_calc then
        return "no_reading", "info", nil, nil, "I_net <= 0"
    end
    if R_calc < M.MISCAL_LOW or R_calc > M.MISCAL_HIGH then
        return "POSSIBLE_CHIP_MISCAL", "info", nil, nil,
            string.format("R=%.1f outside [%.0f..%.0f]", R_calc, M.MISCAL_LOW, M.MISCAL_HIGH)
    end

    local delta_step = prev_R and (R_calc - prev_R) or nil

    -- Abrupt single-cycle step vs the immediate prior cycle. Direction is
    -- the diagnosis: UP = maintenance swap / wear (info, folds into baseline
    -- downstream); DOWN = SUDDEN-SHORT signature (bare wire to ground, splice
    -- failure) — flag loudly to verify, and do NOT fold into baseline (a
    -- maintenance swap to a lower-R coil is handled by a post-maintenance
    -- baseline reset, so we don't risk masking a real short).
    if delta_step and math.abs(delta_step) > M.STEP_DELTA_OHM then
        local d_base = baseline_med and (R_calc - baseline_med) or nil
        if delta_step < 0 then
            return "R_SHORT_STEP", "warn", d_base, delta_step,
                string.format("ΔR_prev=%+.1f Ω in one cycle (SUDDEN-SHORT direction — verify; or maintenance swap)",
                    delta_step)
        end
        return "R_STEP_NOTED", "info", d_base, delta_step,
            string.format("ΔR_prev=%+.1f Ω in one cycle (likely maintenance/wear)", delta_step)
    end

    if not baseline_med then
        return "OK", "ok", nil, delta_step, "seeding baseline"
    end

    local d = R_calc - baseline_med

    -- sat_1:43 master path: only upward drift is alarming (relay aging).
    local topo = M.TOPOLOGY[bin_key]
    if topo and topo.is_master and d > M.MASTER_RELAY_CREEP_DELTA then
        return "MASTER_RELAY_CREEP", "warn", d, delta_step,
            string.format("master R %+.1f Ω vs baseline %.1f", d, baseline_med)
    end

    -- Direction-aware drift vs baseline. d<0 (effective R falling) = short.
    if math.abs(d) > M.ALERT_DELTA_OHM then
        if d < 0 then
            return "R_SHORT_ALERT_CANDIDATE", "alert", d, delta_step,
                string.format("Δ=%.1f Ω (effective R falling > %.1f — developing SHORT, pending 3-cycle confirm)",
                    d, M.ALERT_DELTA_OHM)
        end
        return "R_DRIFT_ALERT_CANDIDATE", "alert", d, delta_step,
            string.format("Δ=+%.1f Ω > %.1f (upward drift, pending 3-cycle confirm)",
                d, M.ALERT_DELTA_OHM)
    end
    if math.abs(d) > M.WARN_DELTA_OHM then
        if d < 0 then
            return "R_SHORT_WARN", "warn", d, delta_step,
                string.format("Δ=%.1f Ω (short direction) > %.1f", d, M.WARN_DELTA_OHM)
        end
        return "R_DRIFT_WARN", "warn", d, delta_step,
            string.format("Δ=+%.1f Ω (wear direction) > %.1f", d, M.WARN_DELTA_OHM)
    end

    return "OK", "ok", d, delta_step, nil
end

-- =========================================================================
-- SQLite open + schema
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
CREATE TABLE IF NOT EXISTS runs_kb2 (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms               INTEGER NOT NULL,
    cycle_id            INTEGER,
    valve               TEXT NOT NULL,
    I_raw               REAL,
    offset_used         REAL,
    R_calc              REAL,
    baseline_used       REAL,
    prev_R              REAL,
    delta_baseline      REAL,
    delta_step          REAL,
    cls                 TEXT,
    severity            TEXT,
    note                TEXT,
    -- cohort analysis columns (added 2026-06-08)
    branch              TEXT,
    wire_R_branch       REAL,
    coil_R              REAL,
    branch_median_coil  REAL,
    cohort_deviation    REAL,
    coil_cls            TEXT,
    UNIQUE(cycle_id, valve)
);
CREATE INDEX IF NOT EXISTS idx_runs_kb2_valve ON runs_kb2(valve);
CREATE INDEX IF NOT EXISTS idx_runs_kb2_ts    ON runs_kb2(ts_ms);
CREATE INDEX IF NOT EXISTS idx_runs_kb2_cls   ON runs_kb2(cls);

CREATE TABLE IF NOT EXISTS baselines_kb2 (
    valve            TEXT PRIMARY KEY,
    R_med            REAL,
    R_mad            REAL,
    n_healthy        INTEGER DEFAULT 0,
    last_updated_ms  INTEGER,
    last_R           REAL,
    window_json      TEXT,
    topology         TEXT,
    note             TEXT
);

CREATE TABLE IF NOT EXISTS alert_state_kb2 (
    valve                  TEXT PRIMARY KEY,
    drift_streak           INTEGER DEFAULT 0,
    last_streak_direction  TEXT,
    last_alert_ts_ms       INTEGER
);

CREATE TABLE IF NOT EXISTS cycle_state_kb2 (
    k     TEXT PRIMARY KEY,
    v     TEXT
);
]]

-- Additive ALTER for existing DBs: each column added in a separate pcall'd
-- ALTER TABLE so re-runs are idempotent (SQLite errors on duplicate column,
-- which is the safe outcome — we just continue).
local function ensure_cohort_columns(db)
    local cols = {
        { "branch",             "TEXT" },
        { "wire_R_branch",      "REAL" },
        { "coil_R",             "REAL" },
        { "branch_median_coil", "REAL" },
        { "cohort_deviation",   "REAL" },
        { "coil_cls",           "TEXT" },
    }
    for _, c in ipairs(cols) do
        local sql = string.format(
            "ALTER TABLE runs_kb2 ADD COLUMN %s %s", c[1], c[2])
        pcall(function() db:exec(sql) end)
    end
end

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
    ensure_cohort_columns(db)
    return db
end

-- =========================================================================
-- Baseline IO
-- =========================================================================

function M.load_baseline(db, valve)
    for r in db:nrows(string.format(
            "SELECT R_med, R_mad, n_healthy, last_R, window_json FROM baselines_kb2 WHERE valve=%q",
            valve)) do
        local ring = {}
        if r.window_json and r.window_json ~= "" then
            local ok, decoded = pcall(cjson.decode, r.window_json)
            if ok and type(decoded) == "table" then ring = decoded end
        end
        return {
            R_med     = r.R_med,
            R_mad     = r.R_mad,
            n_healthy = r.n_healthy or 0,
            last_R    = r.last_R,
            ring      = ring,
        }
    end
    return nil
end

function M.upsert_baseline(db, valve, R_med, R_mad, n_healthy, last_R, ring, now_ms)
    local topo = M.TOPOLOGY[valve]
    local topo_str = topo and cjson.encode(topo) or ""
    local note = topo and topo.note or ""
    local ring_json = cjson.encode(ring or {})

    local stmt = db:prepare([[
        INSERT INTO baselines_kb2(valve, R_med, R_mad, n_healthy, last_updated_ms, last_R, window_json, topology, note)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(valve) DO UPDATE SET
            R_med=excluded.R_med, R_mad=excluded.R_mad,
            n_healthy=excluded.n_healthy, last_updated_ms=excluded.last_updated_ms,
            last_R=excluded.last_R, window_json=excluded.window_json,
            topology=excluded.topology, note=excluded.note
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(valve, R_med or 0, R_mad or 0, n_healthy or 0,
                     now_ms, last_R or 0, ring_json, topo_str, note)
    stmt:step()
    stmt:finalize()
    return true
end

function M.insert_run(db, valve, fields)
    local stmt = db:prepare([[
        INSERT OR IGNORE INTO runs_kb2(
            ts_ms, cycle_id, valve, I_raw, offset_used,
            R_calc, baseline_used, prev_R, delta_baseline, delta_step,
            cls, severity, note,
            branch, wire_R_branch, coil_R,
            branch_median_coil, cohort_deviation, coil_cls)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(fields.ts_ms, fields.cycle_id, valve,
        fields.I_raw, fields.offset_used,
        fields.R_calc, fields.baseline_used, fields.prev_R,
        fields.delta_baseline, fields.delta_step,
        fields.cls, fields.severity, fields.note,
        fields.branch, fields.wire_R_branch, fields.coil_R,
        fields.branch_median_coil, fields.cohort_deviation, fields.coil_cls)
    stmt:step()
    stmt:finalize()
    return true
end

-- Alert-streak helpers: track consecutive cycles in same direction.
function M.load_alert_state(db, valve)
    for r in db:nrows(string.format(
            "SELECT drift_streak, last_streak_direction FROM alert_state_kb2 WHERE valve=%q",
            valve)) do
        return { streak = r.drift_streak or 0, dir = r.last_streak_direction }
    end
    return { streak = 0, dir = nil }
end

function M.upsert_alert_state(db, valve, streak, dir, last_alert_ts_ms)
    local stmt = db:prepare([[
        INSERT INTO alert_state_kb2(valve, drift_streak, last_streak_direction, last_alert_ts_ms)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(valve) DO UPDATE SET
            drift_streak=excluded.drift_streak,
            last_streak_direction=excluded.last_streak_direction,
            last_alert_ts_ms=COALESCE(excluded.last_alert_ts_ms, alert_state_kb2.last_alert_ts_ms)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(valve, streak or 0, dir, last_alert_ts_ms)
    stmt:step()
    stmt:finalize()
    return true
end

-- Cycle-state KV (last-seen probe value for new-cycle detection).
function M.cycle_state_get(db, key)
    for r in db:nrows(string.format("SELECT v FROM cycle_state_kb2 WHERE k=%q", key)) do
        return r.v
    end
    return nil
end

function M.cycle_state_set(db, key, value)
    local stmt = db:prepare([[
        INSERT INTO cycle_state_kb2(k, v) VALUES(?, ?)
        ON CONFLICT(k) DO UPDATE SET v=excluded.v
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(key, tostring(value))
    stmt:step()
    stmt:finalize()
    return true
end

-- Reset step-detection prev_R (baselines_kb2.last_R) when the running image tag
-- changes — i.e. on a deploy / calibration transition (Glenn 2026-06-10).
-- Without this, the first cycle after a deploy compares new-calibration R
-- against the previous image's stale prev_R and fires a FALSE R_SHORT_STEP
-- epidemic across whole branches (observed on the Pi 0.4->0.19 swap: sat_2:1-7
-- all "stepped" -5..-9 Ω at one timestamp). Only last_R is cleared — the
-- rolling R_med baseline is robust and stays. Auto-detected via IMAGE_TAG so no
-- manual version bumping. Returns (did_reset, previous_tag).
function M.reset_prev_r_on_new_image(db, image_tag)
    if not db or not image_tag or image_tag == "" then return false end
    local stored = M.cycle_state_get(db, "image_tag")
    if stored == image_tag then return false, stored end
    db:exec("UPDATE baselines_kb2 SET last_R = NULL")
    M.cycle_state_set(db, "image_tag", image_tag)
    return true, stored
end

-- Persistence gate. The per-cycle valve_test current is noisy enough that a
-- single cycle's cohort outlier flips drift<->short<->step cycle-to-cycle
-- (verified 2026-06-11: the same valve alerted drift, then step, then short on
-- one afternoon). A real fault keeps the SAME direction every cycle. So before
-- a cohort short/drift (or failure_risk) is allowed to alert, the immediately
-- prior cycle's row for that valve must already point the same way. Returns a
-- set like { short=true } / { drift=true } / { failure_risk=true } for the most
-- recent PRIOR cycle, or {} if none / it was OK.
function M.prev_cycle_alert_kinds(db, valve, before_ts_ms)
    local kinds = {}
    if not db or not valve or not before_ts_ms then return kinds end
    local sql = string.format(
        "SELECT coil_cls, cls, coil_R FROM runs_kb2 WHERE valve=%q AND ts_ms < %d " ..
        "ORDER BY ts_ms DESC LIMIT 1", valve, before_ts_ms)
    for r in db:nrows(sql) do
        local cc = r.coil_cls or ""
        local cl = r.cls or ""
        if cc:find("SHORT") then kinds.short = true end
        if cc:find("DRIFT") then kinds.drift = true end
        -- failure_risk isn't stored in cls; recompute from the prior coil_R
        -- against the frozen commissioned reference.
        if cl:find("FAILURE_RISK") then kinds.failure_risk = true end
        if r.coil_R and M.classify_failure_risk then
            local frc = M.classify_failure_risk(valve, r.coil_R)
            if frc then kinds.failure_risk = true end
        end
    end
    return kinds
end

return M
