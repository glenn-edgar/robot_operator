-- kb2_within_run.lua — per-minute coil R trace analysis post-STEP_COMPLETE.
--
-- KB2 extension: when an ETO bin's STEP_COMPLETE fires, fetch the run's
-- IRRIGATION_CURRENT data[] (per-minute), back-derive coil R per minute,
-- and detect within-run anomalies:
--
--   R(t) = 1 / (1/R_total(t) - 1/R_master)
--   where R_total(t) = V_PSU / (I_observed(t) - null_offset)
--   and the bin may contain multiple zones (then we get effective Σ 1/R_zone)
--
-- Detections:
--   R_HEATING_DURING_RUN   linear-fit slope of R over minutes > +0.20 Ω/min
--                          (~10 Ω rise over 50 min = thermal failure margin)
--   R_STEP_DURING_RUN      |R(t+1) - R(t)| > 5 Ω in one minute (intermittent
--                          dropout / coil arcing)
--   R_INSTABILITY           sample-to-sample MAD > 2 Ω (noisy coil)
--   R_END_HIGH              R_end - R_start > 8 Ω (significant aging
--                          signature, valve approaching failure)
--   OK                     no within-run anomaly
--
-- The 5-15 min window is excluded from slope-fit because the start of the
-- run has master+zone pressurizing (transient) and the window after 15 min
-- captures the steady-state thermal trend.

local cjson = require("cjson")
local M = {}

-- See lib/kb2_resistance.lua — V_PSU = 15.4 V locked 2026-06-09 PM after
-- the two-cycle avg3 calibration sweep.
M.PSU_VOLTAGE          = 15.4
M.R_MASTER_DEFAULT     = 40.0
M.HEATING_SLOPE_OHM_PM = 0.20      -- Ω per minute (warn)
M.STEP_DELTA_OHM       = 5.0       -- |ΔR| per minute (warn)
M.INSTABILITY_MAD_OHM  = 2.0       -- MAD over run (warn)
M.END_HIGH_DELTA_OHM   = 8.0       -- R_end - R_start (warn)
M.SLOPE_START_MIN      = 5         -- skip first 5 min (priming transient)
M.SLOPE_END_MIN        = 45        -- cap at 45 min to avoid well-drawdown tail
M.MIN_SAMPLES_FOR_FIT  = 10

-- Thermal-lift thresholds (Glenn 2026-06-09 PM). Lift = R_observed_total
-- minus cold parallel R baseline computed from KB2's per-valve R values
-- plus master. Copper coil tempco ≈ 0.39%/°C so a 4 Ω lift on a ~20 Ω
-- baseline ≈ 20% ≈ 50 °C coil temperature rise. Plausible for ~10 min run.
M.MASTER_VALVE_KEY     = "satellite_1:43"   -- always energized during runs

-- Thermal-lift EARLY-FAILURE alert (Glenn 2026-06-10): solenoids that run
-- HOT — sun exposure plus self-heating on long runs — age fast and fail
-- early. The sustained 5-15 min lift / cold-baseline fraction is the coil's
-- thermal state; as a PERCENT it adapts across bins with different parallel
-- baselines (ΔT ≈ pct / 0.0039 by the Cu tempco). Anchored, not relative to
-- a moving baseline. TUNE from field early-failure data via KB2_LIFT_ALERT_PCT.
M.LIFT_ALERT_PCT = tonumber(os.getenv("KB2_LIFT_ALERT_PCT")) or 0.30  -- >30% (~77 °C rise) → warn

-- Classify the sustained thermal lift against the cold parallel-R baseline.
-- Returns (cls, severity, pct, note) or nil if below threshold / no data.
function M.classify_thermal_lift(lift_results, R_baseline)
    if not lift_results or not R_baseline or R_baseline <= 0 then return nil end
    local lw = lift_results.lift_window
    if not lw then return nil end
    local pct = lw / R_baseline
    if pct > M.LIFT_ALERT_PCT then
        return "R_THERMAL_LIFT_HIGH", "warn", pct,
            string.format("sustained lift %.1f Ω = %.0f%% of cold baseline %.1f Ω (~%.0f °C rise) — running hot, early-failure risk",
                lw, pct * 100, R_baseline, pct / 0.0039)
    end
    return nil
end

-- =========================================================================
-- Per-minute R back-derivation
-- =========================================================================
--
-- bin_valves: list of "satellite_X:Y" in the bin
-- kb2_R:      KB2 baselines (for computing parallel master + other zone coils)
-- For SINGLE-zone bins: R_zone(t) = 1 / (1/R_total(t) - 1/R_master)
-- For MULTI-coil bins (dual, redundant, city-mixed): we can only estimate
--   one aggregate "effective zone R" since we don't have per-coil current.
--   Track this aggregate; the bin baseline absorbs the multi-coil reality.

function M.compute_R_per_minute(I_data, null_offset, R_master, n_zone_coils)
    if not I_data or #I_data == 0 then return nil end
    R_master = R_master or M.R_MASTER_DEFAULT
    n_zone_coils = n_zone_coils or 1
    local out = {}
    for i, I_obs in ipairs(I_data) do
        local I_real = I_obs - (null_offset or 0)
        if I_real > 0.05 then
            local R_total = M.PSU_VOLTAGE / I_real
            -- 1/R_total = 1/R_master + (n_zone)/R_zone_effective
            -- → R_zone_effective = n_zone / (1/R_total - 1/R_master)
            local inv = 1.0/R_total - 1.0/R_master
            if inv > 0 then
                out[i] = n_zone_coils / inv
            else
                out[i] = nil
            end
        else
            out[i] = nil
        end
    end
    return out
end

-- =========================================================================
-- Thermal-lift functions (Glenn 2026-06-09 PM)
-- =========================================================================
-- Compute the cold-baseline parallel resistance for a bin during a run.
-- Master is ALWAYS in parallel during normal runs (we confirmed this
-- against sat_4:4 TIME_HISTORY — V_PSU / I matched the parallel of all
-- energized coils + master within 2% in the 5-15 minute window).
--
-- R_per_valve: { [valve_key] = R_cold_ohm, ... }  — from KB2's baselines_kb2
-- valves     : list of "satellite_X:Y" strings from this bin's io_setup
-- R_master   : master valve cold R (sat_1:43 from KB2)
--
-- Returns parallel R, or nil if any required baseline is missing.
function M.compute_parallel_baseline(R_per_valve, valves, R_master)
    if not R_per_valve or not valves or #valves == 0 then return nil end
    R_master = R_master or M.R_MASTER_DEFAULT
    local inv_sum = 1.0 / R_master  -- master always in parallel during runs
    for _, v in ipairs(valves) do
        if v ~= M.MASTER_VALVE_KEY then  -- avoid double-counting if io_setup includes master
            local R = R_per_valve[v]
            if not R or R <= 0 then
                return nil, "missing cold R for " .. v
            end
            inv_sum = inv_sum + 1.0 / R
        end
    end
    return 1.0 / inv_sum
end

-- Per-minute thermal lift = R_observed(t) - R_baseline_parallel.
-- I_data is RAW IRRIGATION_CURRENT (the controller never subtracts offset
-- from runtime samples — confirmed 2026-06-09 PM). null_offset comes from
-- KB2's 2-null computation on the latest valve_test cycle.
--
-- Returns: { thermal_lift = [Ω per minute], R_observed = [Ω per minute],
--            R_baseline = N, n_valid = N }
function M.compute_thermal_lift(I_data, null_offset, R_baseline)
    if not I_data or #I_data == 0 then return nil end
    if not R_baseline or R_baseline <= 0 then return nil end
    local R_obs, lifts = {}, {}
    local n_valid = 0
    for i, I_obs in ipairs(I_data) do
        local I_real = (I_obs or 0) - (null_offset or 0)
        if I_real > 0.05 then
            local R = M.PSU_VOLTAGE / I_real
            R_obs[i] = R
            lifts[i] = R - R_baseline
            n_valid = n_valid + 1
        else
            R_obs[i] = nil
            lifts[i] = nil
        end
    end
    return {
        thermal_lift = lifts,
        R_observed   = R_obs,
        R_baseline   = R_baseline,
        n_valid      = n_valid,
    }
end

-- Summarise a thermal-lift series into headline metrics.
-- window_start_min / window_end_min: clean steady-state window (default 5..15)
function M.analyze_thermal_lift(lift_series, window_start_min, window_end_min)
    if not lift_series or not lift_series.thermal_lift then return nil end
    window_start_min = window_start_min or 5
    window_end_min   = window_end_min   or 15
    local lifts = lift_series.thermal_lift
    local n = #lifts
    -- Index = minute (lifts[1] = minute 1 of run = step 1)
    local window_vals = {}
    for i = window_start_min, math.min(window_end_min, n) do
        if lifts[i] then window_vals[#window_vals+1] = lifts[i] end
    end
    local function mean(t)
        if not t or #t == 0 then return nil end
        local s = 0
        for _, v in ipairs(t) do s = s + v end
        return s / #t
    end
    local function max(t)
        if not t or #t == 0 then return nil end
        local m = t[1]
        for _, v in ipairs(t) do if v > m then m = v end end
        return m
    end
    -- Trailing-edge lift (end of run)
    local end_lifts = {}
    for i = math.max(1, n-2), n do
        if lifts[i] then end_lifts[#end_lifts+1] = lifts[i] end
    end
    return {
        lift_start      = lifts[1],         -- min 1 (will include line-recharge transient)
        lift_window     = mean(window_vals), -- mean over 5-15 min steady-state
        lift_window_max = max(window_vals),
        lift_end        = mean(end_lifts),   -- mean over last 3 min
        lift_max        = max(lifts),
        n_window        = #window_vals,
    }
end

-- Calibrated variant: takes a KB2 calibration object instead of separate
-- null_offset + hardcoded PSU. When the controller publishes v_psu +
-- sensor_offset (post-2026-06-09 rewrite), this uses them; otherwise
-- the caller passes a legacy_2null calibration built from kb2_resistance's
-- DB cache + M.PSU_VOLTAGE.
--
-- NOTE: IRRIGATION_CURRENT.data[] in TIME_HISTORY is collected during
-- normal runs (not valve_test), so it is RAW regardless of whether the
-- controller upgrade has shipped. The calibration object provides the
-- offset to subtract here in either mode:
--   - "controller" mode: offset = controller_offset (the value the
--     controller measured at sensor null this cycle)
--   - "legacy_2null" mode: offset = 2-null heuristic from valve_test
function M.compute_R_per_minute_calibrated(I_data, calibration, R_master, n_zone_coils)
    if not I_data or #I_data == 0 then return nil end
    if not calibration then return nil end
    R_master = R_master or M.R_MASTER_DEFAULT
    n_zone_coils = n_zone_coils or 1
    local v_psu = calibration.v_psu or M.PSU_VOLTAGE
    -- For TIME_HISTORY we always need to subtract a sensor offset because
    -- IRRIGATION_CURRENT is raw. In controller mode, prefer the published
    -- controller_offset; in legacy mode, the 2-null offset is in
    -- calibration.offset.
    local null_offset
    if calibration.source == "controller" then
        null_offset = calibration.controller_offset or 0
    else
        null_offset = calibration.offset or 0
    end
    local out = {}
    for i, I_obs in ipairs(I_data) do
        local I_real = I_obs - null_offset
        if I_real > 0.05 then
            local R_total = v_psu / I_real
            local inv = 1.0/R_total - 1.0/R_master
            if inv > 0 then
                out[i] = n_zone_coils / inv
            else
                out[i] = nil
            end
        else
            out[i] = nil
        end
    end
    return out
end

-- =========================================================================
-- Stats
-- =========================================================================

local function median(values)
    if not values or #values == 0 then return nil end
    local t = {}
    for _, v in ipairs(values) do t[#t+1] = v end
    table.sort(t)
    local n = #t
    if n % 2 == 1 then return t[math.floor((n+1)/2)] end
    return (t[n/2] + t[n/2+1]) / 2
end

local function mad(values, med)
    if not values or #values == 0 then return nil end
    med = med or median(values)
    local devs = {}
    for _, v in ipairs(values) do devs[#devs+1] = math.abs(v - med) end
    return median(devs)
end

local function linfit_slope(values, start_idx, end_idx)
    -- linear fit over values[start_idx..end_idx]; returns slope (per index)
    local pts = {}
    for i = start_idx, end_idx do
        if values[i] then pts[#pts+1] = { i, values[i] } end
    end
    local n = #pts
    if n < 2 then return 0, 0 end
    local sx, sy = 0, 0
    for _, p in ipairs(pts) do sx = sx + p[1]; sy = sy + p[2] end
    local xm, ym = sx/n, sy/n
    local num, den = 0, 0
    for _, p in ipairs(pts) do
        num = num + (p[1] - xm) * (p[2] - ym)
        den = den + (p[1] - xm)^2
    end
    if den == 0 then return 0, ym end
    local slope = num / den
    local icpt  = ym - slope * xm
    return slope, icpt
end

-- Short-segment boxcar average (Glenn 2026-06-11): per-minute samples are
-- noisy; replace each minute with the mean of a w-wide centered window to get
-- the "true average" before fitting drift. Edge-clamped. Used for slope / start
-- / end / peak; raw values are kept for step + instability detection (smoothing
-- would erase a real one-minute intermittent dropout).
local function boxcar(values, w)
    local n = #values
    if n == 0 then return {} end
    local half = math.floor((w or 3) / 2)
    local out = {}
    for i = 1, n do
        local s, c = 0, 0
        for j = math.max(1, i - half), math.min(n, i + half) do
            s = s + values[j]; c = c + 1
        end
        out[i] = s / c
    end
    return out
end

-- =========================================================================
-- Classify
-- =========================================================================
-- Returns table with all detection results + selected cls + Discord-worthy flag.
function M.analyze_run(R_series)
    local clean = {}
    for _, v in ipairs(R_series or {}) do
        if v and v > 10 and v < 200 then clean[#clean+1] = v end
    end
    if #clean < M.MIN_SAMPLES_FOR_FIT then
        return { cls = "TOO_FEW_SAMPLES", n = #clean }
    end
    local n = #clean

    -- Segment-averaged trace for drift / start / end / peak (denoise).
    local smooth = boxcar(clean, 3)

    -- Slope fit over min 5..45 (steady-state window) on the smoothed trace
    local start_i = math.min(M.SLOPE_START_MIN + 1, n)
    local end_i = math.min(M.SLOPE_END_MIN, n)
    local slope, icpt = linfit_slope(smooth, start_i, end_i)

    -- Peak in the 1-5 min interval: the segment-averaged current PEAK = R
    -- MINIMUM in the early window (R = V/I). Track it + how far it sits below
    -- the steady-state R, a per-run early-transient signature.
    local peak_1_5_r, peak_1_5_min
    do
        local lim = math.min(5, n)
        for i = 1, lim do
            if smooth[i] and (not peak_1_5_r or smooth[i] < peak_1_5_r) then
                peak_1_5_r = smooth[i]; peak_1_5_min = i
            end
        end
    end

    -- Step detect — max |R(t+1) - R(t)| in run
    local max_step = 0
    local max_step_i = nil
    for i = 2, n do
        if clean[i] and clean[i-1] then
            local d = math.abs(clean[i] - clean[i-1])
            if d > max_step then max_step = d; max_step_i = i end
        end
    end

    -- MAD-based instability
    local med = median(clean)
    local m = mad(clean, med) or 0

    -- End-vs-start (on the smoothed trace)
    local n_window = math.min(5, n)
    local sum_start = 0
    for i = 1, n_window do sum_start = sum_start + smooth[i] end
    local sum_end = 0
    for i = n - n_window + 1, n do sum_end = sum_end + smooth[i] end
    local R_start = sum_start / n_window
    local R_end   = sum_end / n_window
    local end_delta = R_end - R_start
    local peak_1_5_dev = peak_1_5_r and (R_end - peak_1_5_r) or nil

    -- Priority classification (most-severe first)
    local cls = "OK"
    local note = nil
    local severity = "ok"
    if max_step > M.STEP_DELTA_OHM then
        cls = "R_STEP_DURING_RUN"; severity = "alert"
        note = string.format("ΔR=%.1f Ω jump at minute %d (intermittent dropout?)",
            max_step, max_step_i or 0)
    elseif slope > M.HEATING_SLOPE_OHM_PM then
        cls = "R_HEATING_DURING_RUN"; severity = "warn"
        note = string.format("R slope=%+.2f Ω/min (thermal aging — failure margin)",
            slope)
    elseif end_delta > M.END_HIGH_DELTA_OHM then
        cls = "R_END_HIGH"; severity = "warn"
        note = string.format("R_end %.1f − R_start %.1f = %+.1f Ω (significant aging)",
            R_end, R_start, end_delta)
    elseif m > M.INSTABILITY_MAD_OHM then
        cls = "R_INSTABILITY"; severity = "warn"
        note = string.format("MAD=%.1f Ω over run (noisy coil)", m)
    end

    return {
        cls = cls, severity = severity, note = note,
        n = n,
        R_med = med, R_mad = m,
        R_start = R_start, R_end = R_end, end_delta = end_delta,
        slope_ohm_per_min = slope, intercept = icpt,
        max_step_ohm = max_step, max_step_minute = max_step_i,
        peak_1_5_r = peak_1_5_r, peak_1_5_minute = peak_1_5_min,
        peak_1_5_dev = peak_1_5_dev,
    }
end

-- =========================================================================
-- SQLite
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
CREATE TABLE IF NOT EXISTS runs_kb2_within (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms           INTEGER NOT NULL,
    sid             TEXT,
    bin             TEXT NOT NULL,
    step            INTEGER,
    schedule        TEXT,
    run_time_m      INTEGER,
    n_samples       INTEGER,
    null_offset     REAL,
    R_master        REAL,
    R_start         REAL,
    R_end           REAL,
    end_delta       REAL,
    R_med           REAL,
    R_mad           REAL,
    slope_ohm_pm    REAL,
    intercept_ohm   REAL,
    max_step_ohm    REAL,
    max_step_minute INTEGER,
    cls             TEXT,
    severity        TEXT,
    note            TEXT,
    -- Thermal-lift fields (Glenn 2026-06-09 PM).
    -- R_baseline_par = cold parallel R from KB2 baselines (all bin valves
    -- + master). lift_window = mean over step 5-15. lift_end = mean over
    -- last 3 min. Positive lift = coil warming. Negative lift = parallel
    -- load not accounted for (e.g. bin 3 sat_4:4/sat_1:39 anomaly).
    R_baseline_par  REAL,
    lift_window     REAL,
    lift_end        REAL,
    lift_max        REAL,
    -- 1-5 min current peak (Glenn 2026-06-11): segment-averaged early-window
    -- R minimum (= current peak) + how far below the run end it sits.
    peak_1_5_r      REAL,
    peak_1_5_dev    REAL,
    UNIQUE(sid, bin)
);
CREATE INDEX IF NOT EXISTS idx_runs_kb2_within_bin ON runs_kb2_within(bin);
CREATE INDEX IF NOT EXISTS idx_runs_kb2_within_ts  ON runs_kb2_within(ts_ms);
CREATE INDEX IF NOT EXISTS idx_runs_kb2_within_cls ON runs_kb2_within(cls);
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
    -- Additive migration for existing DBs (ALTER errors harmlessly if the
    -- column already exists; ignore the rc). NOTE: every column the INSERT in
    -- insert_run references MUST be ALTER-migrated here — CREATE TABLE IF NOT
    -- EXISTS is a no-op on a pre-existing table, so a column added only to the
    -- SCHEMA literal is invisible to an old DB and the prepared INSERT then
    -- fails silently (no row stored). This bit us 2026-06-09→06-12: the
    -- thermal-lift columns were added to SCHEMA + the INSERT but had no ALTER,
    -- so within-run persistence was dead for 3 days while still logging.
    db:exec("ALTER TABLE runs_kb2_within ADD COLUMN R_baseline_par REAL")
    db:exec("ALTER TABLE runs_kb2_within ADD COLUMN lift_window REAL")
    db:exec("ALTER TABLE runs_kb2_within ADD COLUMN lift_end REAL")
    db:exec("ALTER TABLE runs_kb2_within ADD COLUMN lift_max REAL")
    db:exec("ALTER TABLE runs_kb2_within ADD COLUMN peak_1_5_r REAL")
    db:exec("ALTER TABLE runs_kb2_within ADD COLUMN peak_1_5_dev REAL")
    return db
end

function M.insert_run(db, fields)
    local stmt = db:prepare([[
        INSERT OR IGNORE INTO runs_kb2_within(
            ts_ms, sid, bin, step, schedule, run_time_m,
            n_samples, null_offset, R_master,
            R_start, R_end, end_delta,
            R_med, R_mad, slope_ohm_pm, intercept_ohm,
            max_step_ohm, max_step_minute,
            cls, severity, note,
            R_baseline_par, lift_window, lift_end, lift_max,
            peak_1_5_r, peak_1_5_dev)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(
        fields.ts_ms, fields.sid, fields.bin, fields.step, fields.schedule, fields.run_time_m,
        fields.n_samples, fields.null_offset, fields.R_master,
        fields.R_start, fields.R_end, fields.end_delta,
        fields.R_med, fields.R_mad, fields.slope_ohm_pm, fields.intercept_ohm,
        fields.max_step_ohm, fields.max_step_minute,
        fields.cls, fields.severity, fields.note,
        fields.R_baseline_par, fields.lift_window, fields.lift_end, fields.lift_max,
        fields.peak_1_5_r, fields.peak_1_5_dev)
    stmt:step()
    stmt:finalize()
    return true
end

-- Load all per-valve cold R values from kb2_resistance's DB. Read-only,
-- snapshot at boot. Returns { [valve_key] = R_med_ohm, ... }.
function M.load_all_cold_R(kb2_db_path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(kb2_db_path)
    if not db then
        return nil, string.format("open %s failed: %s/%s",
            kb2_db_path, tostring(code), tostring(errmsg))
    end
    local out = {}
    local stmt = db:prepare("SELECT valve, R_med FROM baselines_kb2 WHERE R_med IS NOT NULL")
    if not stmt then
        local m = db:errmsg(); db:close()
        return nil, "select R_med failed: " .. tostring(m)
    end
    for row in stmt:nrows() do
        out[row.valve] = row.R_med
    end
    stmt:finalize()
    db:close()
    return out
end

-- Load most-recent 2-null offset from kb2_resistance's DB. The runs_kb2
-- table stores offset_used per valve per cycle; we pick the latest cycle's
-- value (it's the same across all valves in a cycle).
function M.load_kb2_offset(kb2_db_path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(kb2_db_path)
    if not db then
        return nil, string.format("open %s failed: %s/%s",
            kb2_db_path, tostring(code), tostring(errmsg))
    end
    local stmt = db:prepare(
        "SELECT offset_used FROM runs_kb2 WHERE offset_used IS NOT NULL ORDER BY ts_ms DESC LIMIT 1")
    if not stmt then
        local m = db:errmsg(); db:close()
        return nil, "select offset failed: " .. tostring(m)
    end
    local offset = nil
    for row in stmt:nrows() do offset = row.offset_used; break end
    stmt:finalize()
    db:close()
    return offset
end

-- Load master valve cold R from KB2 baselines.
function M.load_master_R(kb2_db_path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(kb2_db_path)
    if not db then return nil, err end
    local stmt = db:prepare("SELECT R_med FROM baselines_kb2 WHERE valve = ?")
    if not stmt then db:close(); return nil, "prepare failed" end
    stmt:bind_values(M.MASTER_VALVE_KEY)
    local R = nil
    for row in stmt:nrows() do R = row.R_med; break end
    stmt:finalize()
    db:close()
    return R
end

-- Persistence gate for the noisy R_STEP_DURING_RUN detector.
-- The within-run R = V/(I_obs − offset) division is unstable at the low coil
-- currents here (single-sample ACS712, no per-channel cal), so one jittery
-- current minute can trip a >5 Ω step on almost any bin — it fired fleet-wide
-- (16/20 bins) 2026-06-16, the signature of measurement noise, not 16 faults.
-- Return the cls of the most-recent PRIOR run for this bin (excluding the
-- just-inserted current run by sid). The caller requires it to also be
-- R_STEP_DURING_RUN before alerting — random jitter won't repeat on the same
-- bin run-over-run, a real intermittent dropout will. Mirrors kb2_resistance's
-- prev_cycle_alert_kinds 2-consecutive gate.
function M.prev_run_cls(db, bin, exclude_sid)
    if not db or not bin then return nil end
    local sql = string.format(
        "SELECT cls FROM runs_kb2_within WHERE bin=%q AND sid <> %q " ..
        "ORDER BY ts_ms DESC LIMIT 1", bin, tostring(exclude_sid or ""))
    local cls = nil
    for r in db:nrows(sql) do cls = r.cls; break end
    return cls
end

return M
