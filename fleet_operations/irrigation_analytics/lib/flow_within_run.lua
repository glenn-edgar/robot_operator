-- lib/flow_within_run.lua — within-run flow time-bin monitor (MONITOR-ONLY).
--
-- Built 2026-06-12 from the clog-detection analysis (Glenn). The key findings
-- this records the raw material for:
--
--   1. STEADY 5-15 LEVEL. The minutes-5..15 window is early in a run, before
--      well drawdown, so the supply is stable there. A blocked sprinkler head
--      removes ~14.5 gph = 2.42 gal from this 10-min window. So a sustained,
--      bin-specific drop in steady_5_15 (beyond ~2 heads, neighbour-normalised)
--      is the developing-clog signature.
--
--   2. WITHIN-RUN FLATNESS. Comparing the steady time bins (min 5-15 / 15-25 /
--      25-35) OF THE SAME RUN to each other cancels the run-to-run supply
--      pressure offset (pressure is shared within a run). The scatter across
--      those bins is the pressure-CANCELLED noise floor — ~0.8 gal on a clean
--      bin (2:16, 4:3) vs >2 gal on a supply-limited bin (4:9). This is the
--      per-bin "can flow even police this zone?" regime flag.
--
--   3. END-OF-RUN DROOP. Late bins (last ~10 active min) vs the 5-15 level.
--      A systematic late-run flow loss on a long run is WELL DRAWDOWN, not a
--      clog — it must be kept SEPARATE from the steady-level clog signal so it
--      doesn't masquerade as one. It is also a useful well-capacity gauge.
--
-- DELIBERATELY write-only of RAW per-run metrics. The neighbour-normalisation
-- (this bin's 5-15 vs its cohort median the same night, to cancel common-mode
-- supply) and the multi-run decline/trend detection are done at READ time
-- (dashboard / offline analysis), so we can refine the thresholds over the
-- weeks of accumulation this needs WITHOUT a redeploy. No alerts, no actuation.
--
-- Samples are per-minute. ETO runs are long (~59 min) so there are plenty of
-- time bins; non-ETO runs (5-8 min) are too short and are NOT recorded here.
--
-- Call site wraps record() in pcall so a bad trace can never disturb the armed
-- KB4 detector that shares the tick (same isolation as lib/coil_onset).

local M = {}

-- ---- tunables --------------------------------------------------------------
M.ACTIVE_GPM   = 2.0    -- flow above this = valve energised / flowing
M.MIN_SAMPLES  = 15     -- need a full 5-15 window + margin to judge
M.END_WIN      = 10     -- last N active minutes = the end-of-run window
M.BASELINE_WIN = 14     -- rows used for the per-valve rolling baseline

-- minute m (0-indexed run minute) maps to filt[m+1]; sample 0 = filt[1] is the
-- rise transient. Steady bins are the well-stable early portion (Glenn).
M.STEADY_BINS  = { {5, 15}, {15, 25}, {25, 35} }

-- ---- pure helpers ----------------------------------------------------------

local function median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = t[i] end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- median-of-3 smoothing (matches kb4_baselines de-spike behaviour).
local function median3(s)
    local n = #s
    if n < 3 then return s end
    local out = {}
    out[1] = s[1]; out[n] = s[n]
    for i = 2, n - 1 do
        local a, b, c = s[i - 1], s[i], s[i + 1]
        out[i] = math.max(math.min(a, b), math.min(math.max(a, b), c))
    end
    return out
end

-- mean of filt over run-minutes [a, b) (0-indexed minutes -> filt[a+1 .. b]).
local function bin_mean(filt, a, b)
    local n = #filt
    local lo, hi = a + 1, math.min(b, n)
    if hi - lo + 1 < 3 then return nil end
    local s, c = 0, 0
    for i = lo, hi do s = s + filt[i]; c = c + 1 end
    return s / c
end

-- Extract the within-run flow signature from a raw HUNTER_FLOW_METER series.
-- Returns { steady_5_15, flatness, end_droop, n_active } in GALLONS, or nil.
function M.extract(flow_series)
    if type(flow_series) ~= "table" or #flow_series < M.MIN_SAMPLES then
        return nil
    end
    local filt = median3(flow_series)
    local n = #filt

    -- steady time bins -> means; need at least 2 present to judge flatness
    local steady = {}
    for _, ab in ipairs(M.STEADY_BINS) do
        steady[#steady + 1] = bin_mean(filt, ab[1], ab[2])
    end
    local present = {}
    for _, v in ipairs(steady) do if v then present[#present + 1] = v end end
    if #present < 2 then return nil end

    local early = steady[1] or present[1]            -- the 5-15 level (GPM)
    if not early or early < 0.5 then return nil end

    -- within-run flatness = SD across present steady bins, in gallons (×10 min)
    local mean = 0
    for _, v in ipairs(present) do mean = mean + v end
    mean = mean / #present
    local var = 0
    for _, v in ipairs(present) do var = var + (v - mean) * (v - mean) end
    local flatness = math.sqrt(var / #present) * 10

    -- end-of-run window = last END_WIN active minutes
    local je = n
    while je >= 1 and filt[je] < M.ACTIVE_GPM do je = je - 1 end
    local end_droop
    if je >= 1 then
        local lo = math.max(1, je - (M.END_WIN - 1))
        local es, ec = 0, 0
        for i = lo, je do es = es + filt[i]; ec = ec + 1 end
        if ec >= 3 then end_droop = (es / ec - early) * 10 end   -- gallons; <0 = droop
    end

    local n_active = 0
    for i = 1, n do if filt[i] >= M.ACTIVE_GPM then n_active = n_active + 1 end end

    return {
        steady_5_15 = early * 10,    -- gallons in the 5-15 window
        flatness    = flatness,      -- gallons; small = clean/pressure-stable bin
        end_droop   = end_droop,     -- gallons; negative = well drawdown late-run
        n_active    = n_active,
    }
end

-- ---- persistence -----------------------------------------------------------

function M.ensure_schema(db)
    db:exec([[
    CREATE TABLE IF NOT EXISTS flow_within (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_ms       INTEGER NOT NULL,
        sid         TEXT,
        valve       TEXT NOT NULL,
        n_active    INTEGER,
        steady_5_15 REAL,
        flatness    REAL,
        end_droop   REAL,
        UNIQUE(sid, valve)
    );
    CREATE INDEX IF NOT EXISTS idx_flow_within_valve ON flow_within(valve, ts_ms);
    CREATE TABLE IF NOT EXISTS flow_within_baseline (
        valve            TEXT PRIMARY KEY,
        n                INTEGER DEFAULT 0,
        steady_5_15_med  REAL,
        flatness_med     REAL,
        end_droop_med    REAL,
        last_ms          INTEGER
    );
    ]])
end

-- Recompute the rolling per-valve baseline (medians over BASELINE_WIN rows).
function M.update_baseline(db, valve)
    local sv, fl, ed = {}, {}, {}
    local sql = string.format(
        "SELECT steady_5_15, flatness, end_droop FROM flow_within " ..
        "WHERE valve=%q ORDER BY ts_ms DESC LIMIT %d", valve, M.BASELINE_WIN)
    for r in db:nrows(sql) do
        sv[#sv + 1] = r.steady_5_15
        fl[#fl + 1] = r.flatness
        if r.end_droop ~= nil then ed[#ed + 1] = r.end_droop end
    end
    if #sv == 0 then return end
    local stmt = db:prepare([[
        INSERT INTO flow_within_baseline
            (valve, n, steady_5_15_med, flatness_med, end_droop_med, last_ms)
        VALUES (?,?,?,?,?, (SELECT MAX(ts_ms) FROM flow_within WHERE valve=?))
        ON CONFLICT(valve) DO UPDATE SET
            n=excluded.n, steady_5_15_med=excluded.steady_5_15_med,
            flatness_med=excluded.flatness_med, end_droop_med=excluded.end_droop_med,
            last_ms=excluded.last_ms ]])
    if not stmt then return end
    stmt:bind_values(valve, #sv, median(sv), median(fl),
        (#ed > 0) and median(ed) or nil, valve)
    stmt:step(); stmt:finalize()
end

-- Record one ETO run's within-run flow signature. Returns the sig table or nil.
function M.record(db, valve, ts_ms, sid, flow_series)
    if not db or not valve or valve == "" then return nil end
    local sig = M.extract(flow_series)
    if not sig then return nil end
    local stmt = db:prepare([[
        INSERT OR IGNORE INTO flow_within
            (ts_ms, sid, valve, n_active, steady_5_15, flatness, end_droop)
        VALUES (?,?,?,?,?,?,?) ]])
    if not stmt then return nil end
    stmt:bind_values(ts_ms, sid or "", valve, sig.n_active,
        sig.steady_5_15, sig.flatness, sig.end_droop)
    stmt:step(); stmt:finalize()
    M.update_baseline(db, valve)
    return sig
end

return M
