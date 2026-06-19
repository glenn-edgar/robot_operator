-- kb4_v2.lua — flow-baseline KB4 v2 (Glenn 2026-06-09 spec, simplified).
--
-- COLLECTION ONLY. Per Glenn 2026-06-09 PM: "for eto valve we just
-- collect base lines — kb3 should prevent well depletion". KB3's
-- in-flight leak detection is the protection mechanism that keeps the
-- well intact and prevents the cascading baseline-poisoning we observed
-- (sat_3:5 leak → sat_2:14 well-depleted run inheriting bad data).
--
-- KB4 v2 therefore does NO alerting and NO classification beyond a
-- descriptive tag. It only builds per-bin references over time:
--
--   - base_flow_gpm    = median(window mean PLC over 5-15 min)
--   - base_gallons_5_15 = median(integrated gallons over 5-15 min)
--   - base_end_flow_gpm = median(last 3 min mean PLC)  [non-ETO only]
--
-- Rolling window: last 7 runs per bin. With median-of-7 even a single
-- poisoned sample (e.g. one leak run that slipped past KB3, or one
-- well-recovery run) gets median-filtered out within a few cycles. No
-- guards needed because nothing acts on the baseline yet.
--
-- City vs non-city ETO bins are naturally separated because the bin_key
-- includes sat_1:39 in city bins — same algorithm, distinct rows.
--
-- Window choice rationale: 5-15 min skips sprinkler-line recharge (the
-- same physical phenomenon KB3's warmup gates) and gives 10 minutes of
-- clean signal for runs scheduled ≥16 minutes. Shorter runs are skipped
-- (run_time_min < 16 yields no row).
--
-- Future: when a meaningful threshold IS chosen (after the post-repair
-- sprinkler-check field cycle gives Glenn calibrated drift bounds), a
-- separate detector module can subscribe to this baseline and alert.
-- Keeping collection and alerting decoupled was the lesson from
-- KB3-curve's 2026-06-08 failure.
--
-- Coexists with kb4_clog (cohort starvation / clog fingerprints).

local M = {}

-- =========================================================================
-- Tuneables
-- =========================================================================
M.WINDOW_START_MIN  = 5     -- first usable minute (post line-recharge)
M.WINDOW_END_MIN    = 15    -- last minute of the window
M.MIN_RUN_DURATION  = 16    -- skip runs shorter than this many minutes
M.NON_ETO_END_WIN   = 3     -- last N minutes for non-ETO end-of-run flow
M.ROLLING_N         = 7     -- rolling window depth for baseline median

-- Blocked-sprinkler alert (Glenn 2026-06-10): a clog reduces delivered flow,
-- so the 5-15 min window mean falls below the bin's baseline. Fire when flow
-- is BLOCKED_FLOW_DELTA below base, OR gallons below BLOCKED_GALLONS_FRAC of
-- base. ETO bins with a mature baseline only (>= BLOCKED_MIN_N runs).
-- Non-actuating — records to kb_alerts for the 18:00 digest.
M.BLOCKED_FLOW_DELTA   = tonumber(os.getenv("KB4_BLOCKED_FLOW_DELTA")) or 3.0
M.BLOCKED_GALLONS_FRAC = tonumber(os.getenv("KB4_BLOCKED_GALLONS_FRAC")) or 0.75
M.BLOCKED_MIN_N        = 3

-- ETO + city membership mirrors KB3 (lib/kb3_sustained.lua). Could share
-- via a robot_common helper later; duplicating for now keeps the modules
-- decoupled.
M.ETO_PINS = {
    satellite_2 = { [13]=true, [14]=true, [15]=true, [16]=true },
    satellite_3 = { [1]=true, [2]=true, [5]=true, [13]=true, [14]=true,
                    [15]=true, [18]=true },
    satellite_4 = { [1]=true, [3]=true, [4]=true, [6]=true, [7]=true,
                    [9]=true, [10]=true, [11]=true, [12]=true },
}
M.CITY_VALVE = { remote = "satellite_1", bit = 39 }

function M.is_eto_bin(io_setup)
    if type(io_setup) ~= "table" then return false end
    for _, group in ipairs(io_setup) do
        if type(group) == "table" then
            local sat = group.remote
            for _, bit in ipairs(group.bits or {}) do
                if M.ETO_PINS[sat] and M.ETO_PINS[sat][tonumber(bit)] then
                    return true
                end
            end
        end
    end
    return false
end

function M.is_city_bin(io_setup)
    if type(io_setup) ~= "table" then return false end
    for _, group in ipairs(io_setup) do
        if type(group) == "table" and group.remote == M.CITY_VALVE.remote then
            for _, bit in ipairs(group.bits or {}) do
                if tonumber(bit) == M.CITY_VALVE.bit then return true end
            end
        end
    end
    return false
end

function M.bin_key(io_setup)
    local parts = {}
    for _, group in ipairs(io_setup or {}) do
        if type(group) == "table" then
            local sat = group.remote or "?"
            for _, bit in ipairs(group.bits or {}) do
                parts[#parts+1] = sat .. ":" .. tostring(bit)
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, "/")
end

-- =========================================================================
-- Window math
-- =========================================================================
--
-- plc_samples: list of { sid_ms = INT, main_flow_meter = REAL } sorted by
--              sid_ms, covering [run_start_ms, run_end_ms].
-- run_start_ms / run_end_ms: STATION_START / STEP_COMPLETE stream IDs (ms)
--
-- Returns: { win_flow_gpm, win_gallons, n_samples, end_flow_gpm, end_n }
--   win_flow_gpm  → mean PLC over [start + WINDOW_START_MIN*60s,
--                                  start + WINDOW_END_MIN*60s]
--   win_gallons   → integrated gallons over the same window (trapezoid via
--                    dt-weighted sum: gpm × dt_seconds / 60)
--   end_flow_gpm  → mean PLC over [end - NON_ETO_END_WIN*60s, end]
--                    (used for non-ETO only; populated regardless)
--   nil if run too short or no samples.
function M.compute_window_stats(plc_samples, run_start_ms, run_end_ms)
    if not plc_samples or #plc_samples == 0 then return nil end
    if not run_start_ms or not run_end_ms then return nil end
    local run_min = (run_end_ms - run_start_ms) / 60000.0
    if run_min < M.MIN_RUN_DURATION then
        return nil, "run too short: " .. string.format("%.1f", run_min) .. " min"
    end

    local win_start_ms = run_start_ms + M.WINDOW_START_MIN * 60000
    local win_end_ms   = run_start_ms + M.WINDOW_END_MIN   * 60000
    local end_start_ms = run_end_ms   - M.NON_ETO_END_WIN  * 60000

    local win_samples, end_samples = {}, {}
    for _, s in ipairs(plc_samples) do
        local plc = s.main_flow_meter
        if plc then
            if s.sid_ms >= win_start_ms and s.sid_ms <= win_end_ms then
                win_samples[#win_samples+1] = s
            end
            if s.sid_ms >= end_start_ms and s.sid_ms <= run_end_ms then
                end_samples[#end_samples+1] = s
            end
        end
    end

    if #win_samples == 0 then return nil, "no PLC samples in 5-15 window" end

    -- Mean PLC over window
    local sum = 0
    for _, s in ipairs(win_samples) do sum = sum + s.main_flow_meter end
    local win_flow_gpm = sum / #win_samples

    -- Mean HUNTER (FILTERED_HUNTER_VALVE) over the same 5-15 window. This is
    -- the expected-flow baseline KB3 trips against (expected + 4 GPM, the
    -- relative leak/break trip — Glenn 2026-06-10). Same samples; the Hunter
    -- field rides along in plc_xrange. nil if no Hunter samples present.
    local hsum, hn = 0, 0
    for _, s in ipairs(win_samples) do
        local h = s.FILTERED_HUNTER_VALVE
        if h then hsum = hsum + h; hn = hn + 1 end
    end
    local win_hunter_gpm = hn > 0 and (hsum / hn) or nil

    -- Integrated gallons via dt-weighted sum. For each sample at t, use the
    -- interval to next sample (dt seconds). Clamp last sample's dt to the
    -- window-end boundary so we don't over-count outside the window.
    local win_gallons = 0
    for i, s in ipairs(win_samples) do
        local t_next
        if i < #win_samples then
            t_next = win_samples[i+1].sid_ms
        else
            t_next = math.min(s.sid_ms + 60000, win_end_ms)  -- assume 60s if last
        end
        local dt_s = (t_next - s.sid_ms) / 1000.0
        if dt_s > 0 then
            win_gallons = win_gallons + (s.main_flow_meter * dt_s / 60.0)
        end
    end

    -- End-of-run mean (non-ETO)
    local end_flow_gpm = nil
    if #end_samples > 0 then
        local esum = 0
        for _, s in ipairs(end_samples) do esum = esum + s.main_flow_meter end
        end_flow_gpm = esum / #end_samples
    end

    return {
        win_flow_gpm   = win_flow_gpm,
        win_hunter_gpm = win_hunter_gpm,
        win_gallons    = win_gallons,
        n_samples      = #win_samples,
        end_flow_gpm   = end_flow_gpm,
        end_n          = #end_samples,
    }
end

-- =========================================================================
-- Tagging (no classification — collection only per Glenn 2026-06-09 PM)
-- =========================================================================
-- Returns (tag, delta_or_nil, note).
--   tag = "COLLECTED" (with a baseline to compute delta against)
--       | "FIRST"     (first run for this bin — seeding only)
--       | "NON_ETO"   (no ETO membership; non-ETO end-of-run path)
-- delta is informational only — KB4 v2 takes no action on it. A future
-- separate alerter module can read runs_kb4v2 rows and threshold delta.
function M.tag_run(bin_type, observed, baseline)
    if not observed then return "skip", nil, nil end
    if bin_type ~= "eto" then
        return "NON_ETO", nil,
               "non-eto end-of-run collected (no threshold yet)"
    end
    if not baseline or not baseline.base_flow_gpm then
        return "FIRST", nil, "first run for this bin — seeding baseline"
    end
    local delta = observed.win_flow_gpm - baseline.base_flow_gpm
    return "COLLECTED", delta, nil
end

-- Blocked-sprinkler check (the PLC gallons-curve alerter). Returns
-- (is_blocked, note). ETO bins with a mature baseline only.
function M.classify_blocked(observed, baseline)
    if not observed or not baseline then return false end
    if (baseline.n_clean_runs or 0) < M.BLOCKED_MIN_N then return false end
    local bf = baseline.base_flow_gpm
    local bg = baseline.base_gallons_5_15
    if not bf then return false end
    local wf = observed.win_flow_gpm or 0
    local wg = observed.win_gallons or 0
    local flow_blocked = wf < (bf - M.BLOCKED_FLOW_DELTA)
    local gal_blocked  = bg and bg > 0 and (wg < bg * M.BLOCKED_GALLONS_FRAC)
    if flow_blocked or gal_blocked then
        return true, string.format(
            "BLOCKED: flow %.1f vs base %.1f (Δ%+.1f), gallons %.0f vs base %.0f (%.0f%%)",
            wf, bf, wf - bf, wg, bg or 0, (bg and bg > 0) and (wg / bg * 100) or 0)
    end
    return false
end

-- =========================================================================
-- Ring + median
-- =========================================================================
function M.push_ring(ring, v, max_n)
    if not v then return ring end
    ring[#ring+1] = v
    while #ring > max_n do table.remove(ring, 1) end
    return ring
end

function M.median(values)
    if not values or #values == 0 then return nil end
    local sorted = {}
    for i, x in ipairs(values) do sorted[i] = x end
    table.sort(sorted)
    local n = #sorted
    if n % 2 == 1 then return sorted[math.floor((n+1)/2)] end
    return (sorted[n/2] + sorted[n/2+1]) / 2.0
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

-- Rings stored as JSON arrays in TEXT columns. Avoids a wide-row design
-- and keeps schema stable as ROLLING_N might evolve.
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS baselines_kb4v2 (
    bin                TEXT PRIMARY KEY,
    is_city            INTEGER DEFAULT 0,
    is_eto             INTEGER DEFAULT 0,
    base_flow_gpm      REAL,
    base_gallons_5_15  REAL,
    base_end_flow_gpm  REAL,
    n_clean_runs       INTEGER DEFAULT 0,
    ring_flow_json     TEXT,
    ring_gal_json      TEXT,
    ring_end_json      TEXT,
    last_updated_ms    INTEGER
);

CREATE TABLE IF NOT EXISTS runs_kb4v2 (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms             INTEGER NOT NULL,
    bin               TEXT,
    is_eto            INTEGER DEFAULT 0,
    is_city           INTEGER DEFAULT 0,
    sid               TEXT,
    schedule          TEXT,
    step              INTEGER,
    run_time_min      INTEGER,
    n_samples         INTEGER,
    win_flow_gpm      REAL,
    win_hunter_gpm    REAL,
    win_gallons       REAL,
    end_flow_gpm      REAL,
    base_flow_used    REAL,
    leak_delta        REAL,
    cls               TEXT,
    note              TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_kb4v2_bin ON runs_kb4v2(bin);
CREATE INDEX IF NOT EXISTS idx_runs_kb4v2_ts  ON runs_kb4v2(ts_ms);
CREATE INDEX IF NOT EXISTS idx_runs_kb4v2_cls ON runs_kb4v2(cls);
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
    -- Additive migration for DBs created before the Hunter baseline (2026-06-10).
    -- Errors on duplicate column = already present = the safe outcome.
    pcall(function() db:exec("ALTER TABLE runs_kb4v2 ADD COLUMN win_hunter_gpm REAL") end)
    return db
end

-- KB3's relative leak/break baseline: median of the last N per-run Hunter
-- window-means (mean Hunter over 5-15 min) for a bin. KB4 v2 collects these
-- per run; KB3 reads them and trips at (median + 4 GPM). Returns
-- (median_or_nil, n_clean) — KB3 arms the relative trip only when n_clean >= 3.
-- Median over N is robust to a stray high/low run; the maturity gate guards
-- the seeding period. (A *persistently* leaking bin bakes its leak into the
-- baseline — the absolute 14 GPM trip remains the backstop for that.)
function M.load_hunter_baseline(db, bin, n)
    if not db or not bin then return nil, 0 end
    local vals = {}
    pcall(function()
        for r in db:nrows(string.format(
                "SELECT win_hunter_gpm AS v FROM runs_kb4v2 "
                .. "WHERE bin = %q AND win_hunter_gpm IS NOT NULL "
                .. "ORDER BY ts_ms DESC LIMIT %d", bin, n or 7)) do
            vals[#vals+1] = r.v
        end
    end)
    if #vals == 0 then return nil, 0 end
    table.sort(vals)
    local mid = math.floor((#vals + 1) / 2)
    local median = (#vals % 2 == 1) and vals[mid]
        or (vals[#vals / 2] + vals[#vals / 2 + 1]) / 2.0
    return median, #vals
end

local cjson_ok, cjson = pcall(require, "cjson")
local function encode_ring(r) if cjson_ok then return cjson.encode(r or {}) end return "[]" end
local function decode_ring(s)
    if not s or s == "" or not cjson_ok then return {} end
    local ok, dec = pcall(cjson.decode, s)
    if ok and type(dec) == "table" then return dec end
    return {}
end

function M.load_baseline(db, bin)
    local stmt = db:prepare([[
        SELECT bin, is_city, is_eto, base_flow_gpm, base_gallons_5_15,
               base_end_flow_gpm, n_clean_runs,
               ring_flow_json, ring_gal_json, ring_end_json, last_updated_ms
        FROM baselines_kb4v2 WHERE bin = ?
    ]])
    if not stmt then return nil end
    stmt:bind_values(bin)
    local row = nil
    for r in stmt:nrows() do row = r; break end
    stmt:finalize()
    if not row then return nil end
    return {
        bin                = row.bin,
        is_city            = (row.is_city == 1),
        is_eto             = (row.is_eto == 1),
        base_flow_gpm      = row.base_flow_gpm,
        base_gallons_5_15  = row.base_gallons_5_15,
        base_end_flow_gpm  = row.base_end_flow_gpm,
        n_clean_runs       = row.n_clean_runs or 0,
        ring_flow          = decode_ring(row.ring_flow_json),
        ring_gal           = decode_ring(row.ring_gal_json),
        ring_end           = decode_ring(row.ring_end_json),
        last_updated_ms    = row.last_updated_ms,
    }
end

function M.upsert_baseline(db, bin, fields)
    local stmt = db:prepare([[
        INSERT INTO baselines_kb4v2(
            bin, is_city, is_eto,
            base_flow_gpm, base_gallons_5_15, base_end_flow_gpm,
            n_clean_runs,
            ring_flow_json, ring_gal_json, ring_end_json,
            last_updated_ms)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bin) DO UPDATE SET
            is_city           = excluded.is_city,
            is_eto            = excluded.is_eto,
            base_flow_gpm     = excluded.base_flow_gpm,
            base_gallons_5_15 = excluded.base_gallons_5_15,
            base_end_flow_gpm = excluded.base_end_flow_gpm,
            n_clean_runs      = excluded.n_clean_runs,
            ring_flow_json    = excluded.ring_flow_json,
            ring_gal_json     = excluded.ring_gal_json,
            ring_end_json     = excluded.ring_end_json,
            last_updated_ms   = excluded.last_updated_ms
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(bin,
        fields.is_city and 1 or 0,
        fields.is_eto  and 1 or 0,
        fields.base_flow_gpm, fields.base_gallons_5_15,
        fields.base_end_flow_gpm,
        fields.n_clean_runs or 0,
        encode_ring(fields.ring_flow),
        encode_ring(fields.ring_gal),
        encode_ring(fields.ring_end),
        fields.last_updated_ms)
    stmt:step()
    stmt:finalize()
    return true
end

function M.insert_run(db, fields)
    local stmt = db:prepare([[
        INSERT INTO runs_kb4v2(
            ts_ms, bin, is_eto, is_city, sid, schedule, step, run_time_min,
            n_samples, win_flow_gpm, win_hunter_gpm, win_gallons, end_flow_gpm,
            base_flow_used, leak_delta, cls, note)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(fields.ts_ms, fields.bin,
        fields.is_eto and 1 or 0,
        fields.is_city and 1 or 0,
        fields.sid, fields.schedule, fields.step, fields.run_time_min,
        fields.n_samples,
        fields.win_flow_gpm, fields.win_hunter_gpm, fields.win_gallons, fields.end_flow_gpm,
        fields.base_flow_used, fields.leak_delta,
        fields.cls, fields.note)
    stmt:step()
    stmt:finalize()
    return true
end

return M
