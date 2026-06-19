-- lib/coil_onset.lua — solenoid current-onset signature monitor.
--
-- Hypothesis under test (Glenn 2026-06-11): the IRRIGATION_CURRENT trace at
-- the START of a run carries a solenoid-health signature. A clog is hydraulic
-- and invisible to current; but the COIL itself shows up here. We record the
-- "early spike" (first active minute vs the settled hold) for every run, bucket
-- each valve into a distinct signature group, and accumulate history so we can
-- later correlate the signature with field-confirmed solenoid failures.
--
-- Samples are at MINUTE intervals, so the spike is the first 1-2 minutes of the
-- step sitting high before the coil settles (cold-coil thermal + mechanical
-- seating), NOT electrical inrush (which is sub-millisecond and unobservable).
--
-- IMPORTANT — current is a SUM. IRRIGATION_CURRENT is the total of every
-- solenoid energized at that instant. The master valve 1:43 is energized on
-- EVERY irrigation run (constant offset), and 1:39 (city-water dwell) plus any
-- co-fired station valves add on top. So absolute hold is NOT a per-coil number:
--   * within-run spike (first vs settled hold) — additions are on the whole run,
--     so they CANCEL; the spike is per-run-clean. Grouped here (SPIKE_*).
--   * absolute hold — only meaningful for SINGLE-station-key runs (one coil +
--     constant master), and only COHORT-RELATIVE (vs branch peers, which share
--     the same master + wiring). That cohort-low judgment is done on the
--     dashboard, not here, since it needs the whole branch at once.
--
-- Spike groups (within-run, additions cancel):
--   FLAT          no onset spike
--   SPIKE_MILD    spike 0.05-0.15 A over hold
--   SPIKE_STRONG  spike 0.15-0.30 A over hold
--   SPIKE_SEVERE  spike >= 0.30 A over hold
--
-- This module is MONITOR-ONLY. It never actuates and never alerts; it only
-- records. The call site wraps record() in pcall so a bad trace can never
-- disturb the armed KB4 detector that shares the tick.

local M = {}

-- ---- tunables (amps) -------------------------------------------------------
M.ACTIVE_A        = 0.10   -- current above this = solenoid energized
M.RAMP_MIN_A      = 0.40   -- first sample below this = energized mid-minute (ramp)
M.SPIKE_MIN_DELTA = 0.05   -- min first-vs-hold delta to count as a spike
M.SPIKE_STRONG    = 0.15
M.SPIKE_SEVERE    = 0.30
M.MIN_ACTIVE_N    = 8      -- need this many active minutes to judge onset
M.BASELINE_WIN    = 12     -- rows used for the per-valve rolling baseline

-- ---- pure analysis ---------------------------------------------------------

local function median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = t[i] end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- Spike group only — within-run, so co-energized additions (master 1:43, 1:39)
-- cancel. Absolute-hold / cohort-low judgment lives on the dashboard.
function M.group_of(hold, delta)
    if not delta then return nil end
    if delta >= M.SPIKE_SEVERE then return "SPIKE_SEVERE" end
    if delta >= M.SPIKE_STRONG then return "SPIKE_STRONG" end
    if delta >= M.SPIKE_MIN_DELTA then return "SPIKE_MILD" end
    return "FLAT"
end

-- Extract the onset signature from a raw IRRIGATION_CURRENT minute-series.
-- Returns {first, hold, delta, ratio, group, n_active} or nil if too short.
function M.extract(curr_series)
    if type(curr_series) ~= "table" then return nil end
    -- numeric copy
    local a = {}
    for _, x in ipairs(curr_series) do
        a[#a + 1] = tonumber(x) or 0
    end
    -- trim leading/trailing inactive (valve off)
    local i, j = 1, #a
    while i <= #a and a[i] < M.ACTIVE_A do i = i + 1 end
    while j >= i and a[j] < M.ACTIVE_A do j = j - 1 end
    local n = j - i + 1
    if n < M.MIN_ACTIVE_N then return nil end

    local act = {}
    for k = i, j do act[#act + 1] = a[k] end

    -- 1-2 min spike vs END of run (Glenn 2026-06-11): for the short non-ETO
    -- runs the only observable is the early transient compared to the run end,
    -- segment-averaged. `first` = mean of the first 2 active minutes (skipping a
    -- ramp-start partial sample); `endseg` = mean of the last 2 active minutes.
    local s1 = (act[1] < M.RAMP_MIN_A and act[2]) and 2 or 1
    local first
    if act[s1 + 1] then first = (act[s1] + act[s1 + 1]) / 2 else first = act[s1] end
    local endseg = (n >= 2) and ((act[n] + act[n - 1]) / 2) or act[n]

    -- settled hold = median of the back ~2/3 of the run (kept for the per-coil
    -- least-squares decomposition, which wants a robust steady-state current).
    local start = math.max(3, math.floor(n / 3))
    local tail = {}
    for k = start, n do tail[#tail + 1] = act[k] end
    local hold = median(tail)
    if not hold or hold < 0.05 then return nil end

    -- spike is now first-2-min vs end-of-run
    local delta = first - endseg
    return {
        first = first, hold = hold, endseg = endseg, delta = delta,
        ratio = endseg > 0.05 and (first / endseg) or 1, n_active = n,
        group = M.group_of(hold, delta),
    }
end

-- ---- persistence -----------------------------------------------------------

function M.ensure_schema(db)
    db:exec([[
    CREATE TABLE IF NOT EXISTS coil_onset (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_ms       INTEGER NOT NULL,
        sid         TEXT,
        valve       TEXT NOT NULL,
        n_active    INTEGER,
        first_a     REAL,
        hold_a      REAL,
        spike_delta REAL,
        spike_ratio REAL,
        sig_group   TEXT,
        step        INTEGER,
        schedule    TEXT,
        UNIQUE(sid, valve)
    );
    CREATE INDEX IF NOT EXISTS idx_coil_onset_valve ON coil_onset(valve, ts_ms);
    CREATE TABLE IF NOT EXISTS coil_onset_baseline (
        valve           TEXT PRIMARY KEY,
        n               INTEGER DEFAULT 0,
        first_med       REAL,
        hold_med        REAL,
        spike_delta_med REAL,
        sig_group       TEXT,
        last_ms         INTEGER
    );
    CREATE TABLE IF NOT EXISTS watch_list (
        valve    TEXT PRIMARY KEY,
        reason   TEXT,
        source   TEXT,
        added_ms INTEGER
    );
    ]])
    -- Additive migration for pre-existing DBs — REAL Lua, OUTSIDE the SQL string
    -- (cycle context for the per-coil decomposition monitor: group runs into cycles
    -- by schedule + step-reset). Every column the INSERT names must be ALTER'd here
    -- or the prepared INSERT fails silently on an old DB (the kb2_wr lesson).
    pcall(function() db:exec("ALTER TABLE coil_onset ADD COLUMN step INTEGER") end)
    pcall(function() db:exec("ALTER TABLE coil_onset ADD COLUMN schedule TEXT") end)
end

-- Recompute the rolling per-valve baseline from the most recent BASELINE_WIN
-- rows, and re-bucket the valve from those medians (a stable signature group).
function M.update_baseline(db, valve)
    local firsts, holds, deltas = {}, {}, {}
    local sql = string.format(
        "SELECT first_a, hold_a, spike_delta FROM coil_onset " ..
        "WHERE valve=%q ORDER BY ts_ms DESC LIMIT %d", valve, M.BASELINE_WIN)
    for r in db:nrows(sql) do
        firsts[#firsts + 1] = r.first_a
        holds[#holds + 1]   = r.hold_a
        deltas[#deltas + 1] = r.spike_delta
    end
    if #holds == 0 then return end
    local fm, hm, dm = median(firsts), median(holds), median(deltas)
    local grp = M.group_of(hm, dm)
    local stmt = db:prepare([[
        INSERT INTO coil_onset_baseline
            (valve, n, first_med, hold_med, spike_delta_med, sig_group, last_ms)
        VALUES (?,?,?,?,?,?, (SELECT MAX(ts_ms) FROM coil_onset WHERE valve=?))
        ON CONFLICT(valve) DO UPDATE SET
            n=excluded.n, first_med=excluded.first_med, hold_med=excluded.hold_med,
            spike_delta_med=excluded.spike_delta_med, sig_group=excluded.sig_group,
            last_ms=excluded.last_ms ]])
    if not stmt then return end
    stmt:bind_values(valve, #holds, fm, hm, dm, grp, valve)
    stmt:step(); stmt:finalize()
end

-- Record one run's onset for a valve. Returns the signature table or nil.
-- Safe to call with composite bins (the page filters to single valves).
-- step/schedule (optional) tag the run with its cycle context so the per-coil
-- decomposition monitor can group runs into actual irrigation cycles (a cycle =
-- contiguous runs of one schedule; boundary = schedule change or step reset).
function M.record(db, valve, ts_ms, sid, curr_series, step, schedule)
    if not db or not valve or valve == "" then return nil end
    local sig = M.extract(curr_series)
    if not sig then return nil end
    local stmt = db:prepare([[
        INSERT OR IGNORE INTO coil_onset
            (ts_ms, sid, valve, n_active, first_a, hold_a, spike_delta, spike_ratio, sig_group, step, schedule)
        VALUES (?,?,?,?,?,?,?,?,?,?,?) ]])
    if not stmt then return nil end
    stmt:bind_values(ts_ms, sid or "", valve, sig.n_active,
        sig.first, sig.hold, sig.delta, sig.ratio, sig.group,
        tonumber(step), schedule)
    stmt:step(); stmt:finalize()
    M.update_baseline(db, valve)
    return sig
end

return M
