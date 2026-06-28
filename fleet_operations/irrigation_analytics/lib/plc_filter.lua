-- lib/plc_filter.lua — PLC-source FILTER-LOAD detector (Glenn 2026-06-26 plan).
--
-- The PLC-source complement to the Hunter-only flow_deplete. It catches the
-- case where the FILTER (or the well/main line) loads up so the SOURCE flow
-- itself collapses — proven 2026-06-26: on a real filter-load the PLC
-- (main_flow_meter, well source, UPSTREAM of the filter) and the FILTERED
-- HUNTER (delivery, downstream) fell TOGETHER, city_rose 13 → 0.7 GPM on BOTH;
-- a CLEAN_FILTER then restored both to ~8-9 GPM on the next schedule. So:
--   PLC + Hunter fall in LOCKSTEP  → LINE/FILTER restriction → CLEAN_FILTER helps.
--   Hunter falls while PLC HOLDS   → per-valve clog (flow_deplete's job, not ours).
--   PLC false-0 while Hunter HOLDS → sand-fouled meter dropout → IGNORE (do NOT fire).
--
-- The last case is why this detector must NEVER fire on PLC alone: the
-- main_flow_meter is sand-fouled and reads false-0 on well runs (the reason the
-- old armed PLC well-drawdown was retired into the Hunter-only flow_deplete,
-- see [[irrigation-production-state]]). The HUNTER CROSS-CHECK is mandatory —
-- we only trip when delivery is ALSO depressed, which a sand-foul dropout is not.
--
-- SCOPE (set by the kb5 call site, not here): city-water valves OR non-ETO
-- valves — i.e. everything the Hunter flow_deplete does NOT actuate on (it covers
-- ETO-non-city). gate-in = is_city OR not is_eto_bin.
--
-- Filter load is a BIG, sustained drop (13 → 0.7), so a ~0.5 fraction of the
-- run's own early-run steady, held for several consecutive minutes, is a clear
-- and noise-robust signal. All self-referencing — no clean baseline needed.
--
-- Returns the onset minute (first minute of the sustained drop streak) so the
-- kb5 call site can rpush exactly the run_time the valve was still owed
-- (run_time − onset), reusing flow_deplete.reinsert_job. RECOVERY (when armed,
-- dispatched by the call site): wait(1:39) + CLEAN_FILTER + rpush(remainder) + SKIP.
--
-- Monitor-only by default (the call site's KB5_FILTER_ARM gate) — observe() just
-- reports what it WOULD do; it actuates nothing.

local M = {}

-- ---- tunables (GPM fraction, minutes) — monitor-mode; tune from the logs. ----
M.WINDOW_FROM    = 5     -- early-run steady window START (PLC ramps fast; this is post-onset)
M.WINDOW_TO      = 12    -- early-run steady window end
M.JUDGE_FROM     = 12    -- don't judge before this minute (steady must be established)
M.MIN_N          = 3     -- need this many steady-window samples before judging
M.PLC_DROP_FRAC  = 0.50  -- PLC below this fraction of its OWN steady = source collapsing
M.HUN_DROP_FRAC  = 0.70  -- Hunter ALSO below this fraction of its steady = lockstep (cross-check)
M.ONSET_CONSEC   = 3     -- consecutive minutes BOTH below before it counts (vs sand-foul transient)
M.GUARD_REMAIN_MIN = 1   -- don't act if the step is <= this from completing

local function median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = t[i] end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- Fresh per-station state. Call on STATION_START.
function M.new_station()
    return {
        plc_samples = {},     -- PLC over the early steady window
        hun_samples = {},     -- Hunter over the early steady window (cross-check)
        plc_steady  = nil,    -- the run's settled source level (fixed once set)
        hun_steady  = nil,    -- the run's settled delivery level (fixed once set)
        drop_consec = 0,      -- consecutive minutes BOTH PLC and Hunter depressed
        onset_min   = nil,    -- elapsed minute the current drop streak began
        triggered   = false,  -- fired once this step
    }
end

-- observe(state, plc, hunter, elapsed, opts) — call once per NEW minute.
--   plc     = popup.PLC_FLOW_METER (GPM, well source, upstream of the filter)
--   hunter  = popup.FILTERED_HUNTER_VALVE (GPM, delivered, downstream)
--   elapsed = popup.ELASPED_TIME (minutes into the step)
--   opts    = { run_time = step minutes }
-- Returns { would_trigger, below, reason, plc_steady, hun_steady, plc_ratio,
--           hun_ratio, onset_min, guard_ok }.
function M.observe(state, plc, hunter, elapsed, opts)
    opts = opts or {}
    local out = { would_trigger = false, below = false }
    if not plc or not hunter or not elapsed then out.reason = "no_data"; return out end

    -- collect the early steady window for BOTH meters
    if elapsed >= M.WINDOW_FROM and elapsed <= M.WINDOW_TO then
        state.plc_samples[#state.plc_samples + 1] = plc
        state.hun_samples[#state.hun_samples + 1] = hunter
    end
    -- fix the run's steady source + delivery once we have enough early samples
    if not state.plc_steady and elapsed >= M.JUDGE_FROM
       and #state.plc_samples >= M.MIN_N then
        state.plc_steady = median(state.plc_samples)
        state.hun_steady = median(state.hun_samples)
    end
    out.plc_steady = state.plc_steady
    out.hun_steady = state.hun_steady
    if not state.plc_steady then out.reason = "warmup/collecting"; return out end

    -- A meaningful PLC steady is required: a city bin that ran entirely on city
    -- water never draws the well, so its PLC steady is ~0 and there is nothing to
    -- "collapse" — correctly inert (PLC_DROP_FRAC * ~0 ≈ 0, never crossed).
    if state.plc_steady <= 1 then out.reason = "no_source_draw"; return out end

    out.plc_ratio = plc / state.plc_steady
    if state.hun_steady and state.hun_steady > 1 then
        out.hun_ratio = hunter / state.hun_steady
    end

    -- BOTH must be depressed in the SAME minute (lockstep) — PLC source AND Hunter
    -- delivery. PLC-only = sand-foul dropout (ignore); Hunter-only = per-valve clog
    -- (flow_deplete's job). Record onset_min = first minute of the streak so the
    -- retry re-runs from when delivery started degrading.
    local plc_lo = plc < M.PLC_DROP_FRAC * state.plc_steady
    local hun_lo = (out.hun_ratio ~= nil) and (hunter < M.HUN_DROP_FRAC * state.hun_steady)
                   or false
    if plc_lo and hun_lo then
        if state.drop_consec == 0 then state.onset_min = elapsed end
        state.drop_consec = state.drop_consec + 1
    else
        state.drop_consec = 0
    end

    if state.drop_consec < M.ONSET_CONSEC then out.reason = "ok"; return out end

    out.below  = true
    out.reason = "filter-load(plc+hunter lockstep drop)"

    local remain = opts.run_time and (opts.run_time - elapsed) or 99
    out.guard_ok = remain > M.GUARD_REMAIN_MIN
    if state.triggered then out.reason = out.reason .. "/already"; return out end
    if not out.guard_ok then out.reason = out.reason .. "/guard"; return out end

    state.triggered   = true
    out.would_trigger = true
    out.onset_min     = state.onset_min or elapsed
    return out
end

return M
