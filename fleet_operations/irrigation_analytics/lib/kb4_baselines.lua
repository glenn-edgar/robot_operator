-- lib/kb4_baselines.lua — KB4 clog/leak detector state + SQLite ops.
--
-- Responsibilities:
--   * Open / bootstrap kb4.db (runs + baselines tables)
--   * Load ETO valve set (skip ETO bins — they get a deferred ETO-path
--     handler; KB4 here is non-ETO only)
--   * Compute steady-state flow from a HUNTER_FLOW_METER series using an
--     adaptive window: median-filtered samples[1 .. min(15, len)]
--   * Classify against per-bin baseline:
--       delta > +5 GPM → LEAK   (Discord alert)
--       delta > +3 GPM → rising (DB warn)
--       delta < -3 GPM → drop   (DB warn)
--       otherwise     → OK     (update baseline median over all healthy)
--   * Idempotent insert into runs table; recompute baseline_med on OK

local cjson = require("cjson")

local M = {}

-- -----------------------------------------------------------------------
-- Bin-key canonicalization (sorted /-joined). Mirrors lib/baselines.lua's
-- gotcha — past_actions and TIME_HISTORY use different orderings.
-- -----------------------------------------------------------------------
function M.canonicalize(bin_key)
    if not bin_key or type(bin_key) ~= "string" then return bin_key end
    if not bin_key:find("/", 1, true) then return bin_key end
    local parts = {}
    for p in bin_key:gmatch("[^/]+") do parts[#parts+1] = p end
    table.sort(parts)
    return table.concat(parts, "/")
end

-- Try both alphabetical and original ordering for TH lookup.
-- Returns the matching key string or nil; caller does the actual hget.
function M.bin_key_variants(bin_key, original_io_setup)
    local variants = { M.canonicalize(bin_key) }
    if original_io_setup and original_io_setup ~= bin_key then
        variants[#variants+1] = original_io_setup
    end
    return variants
end

-- -----------------------------------------------------------------------
-- ETO valve membership
-- -----------------------------------------------------------------------
function M.load_eto_valves(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local body = f:read("*a"); f:close()
    local ok, parsed = pcall(cjson.decode, body)
    if not ok then return nil, "json decode failed" end
    local set = {}
    for _, v in ipairs(parsed.eto_valves or {}) do set[v] = true end
    return set
end

-- A bin is "non-ETO" iff NONE of its valve bits is in the ETO set.
function M.bin_is_non_eto(bin_key, eto_set)
    if not bin_key or not eto_set then return false end
    for p in bin_key:gmatch("[^/]+") do
        if eto_set[p] then return false end
    end
    return true
end

-- -----------------------------------------------------------------------
-- Adaptive steady-state window: skip sample 0 (rise), use samples
-- 1..min(15, len). 3-sample minimum to be meaningful.
-- -----------------------------------------------------------------------
local function median_filter_3(xs)
    if not xs or #xs == 0 then return {} end
    local out = {}
    for i = 1, #xs do
        local lo, hi = math.max(1, i-1), math.min(#xs, i+1)
        local s = {}
        for j = lo, hi do s[#s+1] = xs[j] end
        table.sort(s)
        out[i] = s[math.floor((#s + 1) / 2)]
    end
    return out
end

-- Non-ETO per-run metric = the LAST value of the run (Glenn 2026-06-10).
-- Short non-ETO runs (flowers/house/city_rose, 5-8 min) never reach a steady
-- 5-15 window; the end-of-run value is the best single estimate of delivered
-- flow. Returns the last non-nil sample. (ETO keeps compute_flow_window.)
function M.last_value(series)
    if not series then return nil end
    for i = #series, 1, -1 do
        if series[i] ~= nil then return series[i] end
    end
    return nil
end

function M.compute_flow_window(flow_series)
    if not flow_series or #flow_series < 3 then return nil end
    local filt = median_filter_3(flow_series)
    local start_i = 2  -- 1-indexed: skip sample 1 (= rise transient)
    local end_i = math.min(15, #filt)
    if end_i - start_i + 1 < 3 then return nil end
    local sum, n = 0, 0
    for i = start_i, end_i do sum = sum + filt[i]; n = n + 1 end
    return sum / n
end

function M.compute_total_gal(flow_series)
    if not flow_series then return 0 end
    local filt = median_filter_3(flow_series)
    local s = 0
    for i = 1, #filt do s = s + filt[i] end
    return s   -- GPM × 1 min = gallons
end

-- -----------------------------------------------------------------------
-- Classification
-- -----------------------------------------------------------------------
M.LEAK_DELTA_GPM     = 5.0       -- non-ETO leak threshold
M.WARN_DELTA_GPM     = 3.0       -- non-ETO warn (both directions)

-- ETO-specific thresholds per [[kb4-eto-spec-2026-06-05]]
M.ETO_LEAK_DELTA_GPM       = 4.0   -- ETO is more sensitive on leaks
M.ETO_WARN_DELTA_GPM       = 3.0   -- same warn band
M.ETO_BLOCK_WARN_GAL       = 30.0  -- 3 GPM × 10 min
M.ETO_BLOCK_ALERT_GAL      = 40.0  -- 4 GPM × 10 min
M.ETO_SAG_SLOPE_DELTA      = 0.1   -- GPM/min below baseline slope
M.ETO_UNSTABLE_WARN_DELTA  = 1.0   -- wiggle_mad GPM above baseline
M.ETO_UNSTABLE_ALERT_DELTA = 2.0

function M.classify(flow, baseline_med)
    if not flow or not baseline_med then return "no_baseline", 0 end
    local delta = flow - baseline_med
    -- >= so a reading exactly 5 GPM above baseline alerts (Glenn 2026-06-10:
    -- "discord alert if the end flow is 5 gpm above baseline").
    if delta >= M.LEAK_DELTA_GPM then return "LEAK", delta end
    if delta > M.WARN_DELTA_GPM then return "rising_warn", delta end
    if delta < -M.WARN_DELTA_GPM then return "drop_warn", delta end
    return "OK", delta
end

-- -----------------------------------------------------------------------
-- ETO curve metrics: linear fit + wiggle (MAD of residuals)
-- Operates on 1-indexed samples 5..15 of the median-filtered series.
-- Returns nil if input is too short for the fixed 5-15 window.
-- -----------------------------------------------------------------------
function M.compute_eto_metrics(flow_series)
    if not flow_series or #flow_series < 15 then return nil end
    local filt = median_filter_3(flow_series)
    -- Lua 1-indexed: samples 5..15 are indices 6..15 (skip 0-indexed 0..4 = 1..5)
    -- Actually: sample 0 = filt[1] (rise), samples 5..14 = filt[6]..filt[15].
    local wf, wt = {}, {}
    for i = 6, 15 do
        wf[#wf+1] = filt[i]
        wt[#wt+1] = i - 1   -- minute index 5..14
    end
    -- Linear least-squares
    local n = #wt
    local sum_x, sum_y = 0, 0
    for i = 1, n do sum_x = sum_x + wt[i]; sum_y = sum_y + wf[i] end
    local mx, my = sum_x / n, sum_y / n
    local num, den = 0, 0
    for i = 1, n do
        local dx = wt[i] - mx
        num = num + dx * (wf[i] - my)
        den = den + dx * dx
    end
    local slope = (den > 0) and (num / den) or 0
    local intercept = my - slope * mx
    -- Residual MAD = wiggle
    local abs_resid = {}
    for i = 1, n do
        abs_resid[i] = math.abs(wf[i] - (slope * wt[i] + intercept))
    end
    table.sort(abs_resid)
    local wiggle_mad = abs_resid[math.floor(n / 2) + 1]
    -- Gallons in window = sum of 10 GPM samples × 1 min each
    local gallons = 0
    for i = 1, n do gallons = gallons + wf[i] end
    -- Mean flow over window (also same as average of wf)
    local flow_mean = sum_y / n
    return {
        flow_5_15  = flow_mean,
        gallons_5_15 = gallons,
        slope      = slope,
        intercept  = intercept,
        wiggle_mad = wiggle_mad,
    }
end

-- Classify ETO gallon shortfall (Activity 3 — blocked sprinkler).
function M.classify_eto_gallons(gallons, baseline_gallons)
    if not gallons or not baseline_gallons then return "no_baseline", 0 end
    local delta = gallons - baseline_gallons
    if delta < -M.ETO_BLOCK_ALERT_GAL then return "BLOCKED_ALERT", delta end
    if delta < -M.ETO_BLOCK_WARN_GAL  then return "BLOCKED_WARN",  delta end
    return "OK", delta
end

-- Classify ETO GPM curve (Activity 4 — leak / sag / wiggle).
-- Returns a single class string (highest-severity wins) and a table of
-- per-signal deltas for the record.
function M.classify_eto_gpm(metrics, bl)
    if not metrics or not bl then return "no_baseline", {} end
    local d_intercept = metrics.intercept - (bl.intercept_med or 0)
    local d_slope     = metrics.slope     - (bl.slope_med or 0)
    local d_wiggle    = metrics.wiggle_mad - (bl.wiggle_med or 0)
    local deltas = {
        d_intercept = d_intercept,
        d_slope     = d_slope,
        d_wiggle    = d_wiggle,
    }
    -- Severity order: Discord-tier > DB-warn-tier
    if d_intercept > M.ETO_LEAK_DELTA_GPM    then return "LEAK_ALERT", deltas end
    if d_wiggle    > M.ETO_UNSTABLE_ALERT_DELTA then return "WELL_UNSTABLE_ALERT", deltas end
    if d_intercept > M.ETO_WARN_DELTA_GPM    then return "LEAK_WARN", deltas end
    if d_wiggle    > M.ETO_UNSTABLE_WARN_DELTA then return "WELL_UNSTABLE_WARN", deltas end
    if d_slope < -M.ETO_SAG_SLOPE_DELTA      then return "SAG_WARN", deltas end
    return "OK", deltas
end

-- -----------------------------------------------------------------------
-- SQLite open + schema migration
-- -----------------------------------------------------------------------
local lsqlite3 = nil
local function ensure_lsqlite3()
    if lsqlite3 then return lsqlite3 end
    local ok, mod = pcall(require, "lsqlite3")
    if not ok then return nil, "lsqlite3 not available: " .. tostring(mod) end
    lsqlite3 = mod
    return mod
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms       INTEGER NOT NULL,
    sid         TEXT,
    bin         TEXT NOT NULL,
    schedule    TEXT,
    step        INTEGER,
    run_time_m  INTEGER,
    flow_5_15   REAL,
    curr_5_15   REAL,
    total_gal   REAL,
    baseline_used REAL,
    delta       REAL,
    cls         TEXT,
    UNIQUE(sid, bin)
);

CREATE INDEX IF NOT EXISTS idx_runs_bin ON runs(bin);
CREATE INDEX IF NOT EXISTS idx_runs_cls ON runs(cls);
CREATE INDEX IF NOT EXISTS idx_runs_ts  ON runs(ts_ms);

CREATE TABLE IF NOT EXISTS baselines (
    bin         TEXT PRIMARY KEY,
    flow_med    REAL,
    flow_mad    REAL,
    curr_med    REAL,
    leak_thr    REAL,
    warn_up     REAL,
    warn_down   REAL,
    n_healthy   INTEGER DEFAULT 0,
    last_updated_ms INTEGER,
    phantom     INTEGER DEFAULT 0,
    note        TEXT
);

-- ETO bin runs — separate table per kb4-eto-spec-2026-06-05.
-- Each STEP_COMPLETE on an ETO bin produces ONE row with two
-- independent classifications (cls_gallons + cls_gpm).
CREATE TABLE IF NOT EXISTS runs_eto (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms INTEGER NOT NULL,
    sid TEXT,
    bin TEXT NOT NULL,
    schedule TEXT,
    step INTEGER,
    run_time_m INTEGER,
    flow_5_15 REAL,
    gallons_5_15 REAL,
    slope REAL,
    intercept REAL,
    wiggle_mad REAL,
    curr_5_15 REAL,
    cls_gallons TEXT,
    cls_gpm TEXT,
    delta_gallons REAL,
    delta_intercept REAL,
    delta_slope REAL,
    delta_wiggle REAL,
    UNIQUE(sid, bin)
);
CREATE INDEX IF NOT EXISTS idx_runs_eto_bin ON runs_eto(bin);
CREATE INDEX IF NOT EXISTS idx_runs_eto_ts  ON runs_eto(ts_ms);
CREATE INDEX IF NOT EXISTS idx_runs_eto_cls ON runs_eto(cls_gallons, cls_gpm);

CREATE TABLE IF NOT EXISTS baselines_eto (
    bin TEXT PRIMARY KEY,
    flow_5_15_med REAL,
    gallons_5_15_med REAL,
    slope_med REAL,
    intercept_med REAL,
    wiggle_med REAL,
    curr_med REAL,
    n_healthy INTEGER DEFAULT 0,
    last_updated_ms INTEGER,
    elevated INTEGER DEFAULT 0,
    note TEXT
);
]]

function M.open_db(path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(path)
    if not db then return nil, ("open %s failed: %s/%s"):format(path, tostring(code), tostring(errmsg)) end
    local rc = db:exec(SCHEMA)
    if rc ~= mod.OK then
        local msg = db:errmsg()
        db:close()
        return nil, "schema migration failed: " .. tostring(msg)
    end
    return db
end

-- -----------------------------------------------------------------------
-- Seed baselines from JSON if the table is empty.
-- -----------------------------------------------------------------------
function M.seed_baselines_if_empty(db, seed_path, now_ms)
    local count = 0
    for r in db:nrows("SELECT COUNT(1) AS n FROM baselines") do count = r.n end
    if count > 0 then return 0 end
    local f, err = io.open(seed_path, "r")
    if not f then return 0, "seed open failed: " .. tostring(err) end
    local body = f:read("*a"); f:close()
    local ok, parsed = pcall(cjson.decode, body)
    if not ok then return 0, "seed json decode failed" end
    local stmt = db:prepare([[
        INSERT OR REPLACE INTO baselines
          (bin, flow_med, flow_mad, curr_med, leak_thr, warn_up, warn_down,
           n_healthy, last_updated_ms, phantom, note)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    local n = 0
    for bin, bl in pairs(parsed) do
        stmt:bind_values(
            bin,
            bl.flow_med or 0,
            bl.flow_mad or 0,
            bl.curr_med or 0,
            bl.leak_threshold or (bl.flow_med and bl.flow_med + 5 or 5),
            bl.warn_up or (bl.flow_med and bl.flow_med + 3 or 3),
            bl.warn_down or (bl.flow_med and bl.flow_med - 3 or -3),
            bl.n_kept or 0,
            now_ms,
            (bl.phantom or bl.below_meter_floor) and 1 or 0,
            bl.note or ""
        )
        stmt:step()
        stmt:reset()
        n = n + 1
    end
    stmt:finalize()
    return n
end

function M.get_baseline(db, bin)
    for r in db:nrows(string.format(
        "SELECT * FROM baselines WHERE bin = %q", bin)) do
        return r
    end
    return nil
end

-- ETO baseline ops (separate from non-ETO).
function M.seed_baselines_eto_if_empty(db, seed_path, now_ms)
    local count = 0
    for r in db:nrows("SELECT COUNT(1) AS n FROM baselines_eto") do count = r.n end
    if count > 0 then return 0 end
    local f, err = io.open(seed_path, "r")
    if not f then return 0, "ETO seed open failed: " .. tostring(err) end
    local body = f:read("*a"); f:close()
    local ok, parsed = pcall(cjson.decode, body)
    if not ok then return 0, "ETO seed decode failed" end
    local stmt = db:prepare([[
        INSERT OR REPLACE INTO baselines_eto
          (bin, flow_5_15_med, gallons_5_15_med, slope_med, intercept_med,
           wiggle_med, curr_med, n_healthy, last_updated_ms, elevated, note)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    local n = 0
    local ELEVATED = {
        ["satellite_4:9"]=true, ["satellite_4:10"]=true,
        ["satellite_4:11"]=true, ["satellite_3:2/satellite_4:12"]=true,
    }
    for bin, bl in pairs(parsed) do
        stmt:bind_values(
            bin,
            bl.flow_5_15_med or 0,
            bl.gallons_5_15_med or 0,
            bl.slope_med or 0,
            bl.intercept_med or 0,
            bl.wiggle_med or 0,
            bl.curr_med or 0,
            bl.n_healthy or 0,
            now_ms,
            ELEVATED[bin] and 1 or 0,
            bl.note or ""
        )
        stmt:step(); stmt:reset()
        n = n + 1
    end
    stmt:finalize()
    return n
end

function M.get_baseline_eto(db, bin)
    for r in db:nrows(string.format(
        "SELECT * FROM baselines_eto WHERE bin = %q", bin)) do
        return r
    end
    return nil
end

function M.insert_run_eto(db, rec)
    local stmt = db:prepare([[
        INSERT OR IGNORE INTO runs_eto
          (ts_ms, sid, bin, schedule, step, run_time_m,
           flow_5_15, gallons_5_15, slope, intercept, wiggle_mad, curr_5_15,
           cls_gallons, cls_gpm, delta_gallons, delta_intercept, delta_slope, delta_wiggle)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_values(
        rec.ts_ms, rec.sid, rec.bin, rec.schedule or "",
        rec.step or 0, rec.run_time_m or 0,
        rec.flow_5_15, rec.gallons_5_15, rec.slope, rec.intercept,
        rec.wiggle_mad, rec.curr_5_15 or 0,
        rec.cls_gallons or "no_baseline", rec.cls_gpm or "no_baseline",
        rec.delta_gallons or 0, rec.delta_intercept or 0,
        rec.delta_slope or 0, rec.delta_wiggle or 0
    )
    local rc = stmt:step()
    stmt:finalize()
    return rc
end

-- Recompute ETO baseline medians over rows where BOTH gallon-side AND
-- gpm-side were OK (== healthy run, no partial outlier).
function M.update_baseline_eto_running_median(db, bin, now_ms)
    local rows = {}
    for r in db:nrows(string.format([[
        SELECT flow_5_15, gallons_5_15, slope, intercept, wiggle_mad, curr_5_15
        FROM runs_eto
        WHERE bin = %q AND cls_gallons = 'OK' AND cls_gpm = 'OK'
    ]], bin)) do
        rows[#rows+1] = r
    end
    if #rows < 3 then return nil end
    local function med(field)
        local xs = {}
        for _, r in ipairs(rows) do xs[#xs+1] = r[field] end
        table.sort(xs)
        return xs[math.floor(#xs / 2) + 1]
    end
    db:exec(string.format([[
        UPDATE baselines_eto
        SET flow_5_15_med = %f, gallons_5_15_med = %f,
            slope_med = %f, intercept_med = %f, wiggle_med = %f,
            curr_med = %f, n_healthy = %d, last_updated_ms = %d
        WHERE bin = %q
    ]], med("flow_5_15"), med("gallons_5_15"), med("slope"),
        med("intercept"), med("wiggle_mad"), med("curr_5_15"),
        #rows, now_ms, bin))
    return med("gallons_5_15")
end

-- Append a run, idempotent on (sid, bin).
function M.insert_run(db, rec)
    local stmt = db:prepare([[
        INSERT OR IGNORE INTO runs
          (ts_ms, sid, bin, schedule, step, run_time_m,
           flow_5_15, curr_5_15, total_gal, baseline_used, delta, cls)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_values(
        rec.ts_ms, rec.sid, rec.bin, rec.schedule or "",
        rec.step or 0, rec.run_time_m or 0,
        rec.flow_5_15, rec.curr_5_15, rec.total_gal,
        rec.baseline_used, rec.delta, rec.cls
    )
    local rc = stmt:step()
    stmt:finalize()
    return rc
end

-- Recompute median over all OK rows for this bin and persist to baselines.
-- O(n) load + sort but n is small (1 row per run; thousands max over years).
function M.update_baseline_running_median(db, bin, now_ms)
    local flows, currs = {}, {}
    for r in db:nrows(string.format(
        "SELECT flow_5_15, curr_5_15 FROM runs WHERE bin = %q AND cls = 'OK' ORDER BY flow_5_15",
        bin)) do
        flows[#flows+1] = r.flow_5_15
        currs[#currs+1] = r.curr_5_15
    end
    if #flows < 3 then return nil end  -- need minimum sample
    table.sort(flows); table.sort(currs)
    local mid = math.floor(#flows / 2) + 1
    local flow_med = flows[mid]
    local curr_med = currs[math.floor(#currs / 2) + 1]
    local devs = {}
    for _, f in ipairs(flows) do devs[#devs+1] = math.abs(f - flow_med) end
    table.sort(devs)
    local flow_mad = devs[math.floor(#devs / 2) + 1]
    db:exec(string.format([[
        UPDATE baselines
        SET flow_med = %f, flow_mad = %f, curr_med = %f,
            leak_thr = %f, warn_up = %f, warn_down = %f,
            n_healthy = %d, last_updated_ms = %d
        WHERE bin = %q
    ]],
        flow_med, flow_mad, curr_med,
        flow_med + M.LEAK_DELTA_GPM,
        flow_med + M.WARN_DELTA_GPM,
        flow_med - M.WARN_DELTA_GPM,
        #flows, now_ms, bin))
    return flow_med
end

return M
