-- lib/flow_deplete.lua — UNIFIED flow-depletion detector (Hunter-only).
--
-- Consolidates the two old low-flow detectors (PLC well-drawdown + Hunter clog-
-- filter) into ONE, per Glenn 2026-06-21 ("consolidate, key off the filtered
-- hunter flow rate only").
--
-- WHY HUNTER ONLY: the PLC / main_flow_meter (well source) is sand-fouled and
-- reads false-0 on well runs. The old armed PLC well-drawdown trusted it and
-- false-skipped 5 HEALTHY stations on 06-20/21 (Hunter showed 7-8 GPM delivery
-- the whole time). Physically it doesn't matter WHICH cause starves delivery — a
-- clogging filter (restriction) or a well drawing down (source dying) — the
-- SYMPTOM is the same: the Filtered Hunter (delivered flow) depletes. We act on
-- the symptom; PLC can't be trusted to name the cause.
--
-- RAMP NOTE (the 06-21 false-positive lesson): the Filtered Hunter is heavily
-- damped and ramps SLOWLY — on 3:18 it was still climbing at min 9 (5.0→6.4,
-- heading to ~8). Judging a still-rising flow against a steady baseline trips
-- prematurely. So we do NOT look at flow until the ramp is over: the steady
-- window is min 10-15 and we don't judge before JUDGE_FROM.
--
-- TWO trip paths, both Hunter-only (fire on either, once per step):
--   A. DEPLETION (the "starts to deplete" case): after the steady level is set,
--      delivery DROPS below DRAW_FRAC of it for ONSET_CONSEC minutes. Catches a
--      filter loading up / a well fading mid-run. Self-referencing — no baseline.
--   B. LOW vs clean BASELINE: the steady level sits below TRIP_FRAC of the bin's
--      known-good kb4v2 baseline. Catches a step low from the start. Needs a
--      baseline; skipped if absent.
--
-- RECOVERY ACTION (dispatched by the kb3 call site when KB3_FLOW_ARM) — Glenn
-- 2026-06-21 "i believe the filter is bad", so the recovery cleans the filter and
-- retries the step. SKIP the depleting step, then rpush the recovery. rpush ORDER
-- is the REVERSE of run order (the controller pops the queue front via rpop), so
-- push them backwards:
--   1. rpush(reinsert)     -- this step itself, re-queued to retry
--   2. rpush(CLEAN_FILTER) -- clean the (bad) filter
--   3. rpush(wait)         -- the 15-min 1:39 city wait (well rests / line settles)
-- → controller pops [wait -> CLEAN_FILTER -> reinsert]: rest, clean, re-run the step.
-- Then SKIP_STATION ends the current depleting step so the queue advances. ONE
-- clean+retry per step (anti-loop in the kb3 call site): if the reinserted step is
-- STILL low after the filter clean, it's the head/valve, not the filter — let it run.
-- BOTH trip paths (A and B) take this SAME action — one consistent recovery for
-- "low flow OR clogged filter". Monitor-only (gate off) logs what it WOULD do.

local cjson = require("cjson")

local M = {}

-- The CLEAN_FILTER queue step, byte-matched to a live IRRIGATION_PENDING entry
-- (controller wire format, captured 2026-06-21).
M.CLEAN_FILTER_JOB =
    '{"type":"CLEAN_FILTER","schedule_name":"CLEAN_FILTER","step":1,"run_time":0}'

-- ---- tunables (GPM fraction, minutes) — monitor-mode; tune from the logs. ----
M.WINDOW_FROM      = 10    -- steady-delivery window START — AFTER the slow Hunter ramp
M.WINDOW_TO        = 15    -- steady-delivery window end
M.JUDGE_FROM       = 14    -- don't judge before this minute (ramp must be over)
M.MIN_N            = 3     -- need this many steady-window samples before judging
M.TRIP_FRAC        = 0.75  -- (B) steady delivery below this fraction of clean baseline
M.DRAW_FRAC        = 0.78  -- (A) delivery below this fraction of its OWN steady = depleting
M.ONSET_CONSEC     = 2     -- (A) consecutive minutes below DRAW_FRAC before it counts
M.GUARD_REMAIN_MIN = 1     -- don't act if the step is <= this from completing

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
        steady_samples = {},    -- Hunter over min 10-15 (post-ramp)
        steady         = nil,    -- the run's settled delivery (fixed once set)
        drop_consec    = 0,      -- consecutive minutes below DRAW_FRAC*steady (path A)
        triggered      = false,  -- fired once this step
    }
end

-- observe(state, hunter, elapsed, opts) — call once per NEW minute.
--   hunter  = popup.FILTERED_HUNTER_VALVE (GPM, delivered)
--   elapsed = popup.ELASPED_TIME (minutes into the step)
--   opts    = { baseline_gpm = bin clean Hunter baseline (optional), run_time = step minutes }
-- Returns { would_trigger, below, reason, hun_med (=steady), steady, baseline, ratio, guard_ok }.
function M.observe(state, hunter, elapsed, opts)
    opts = opts or {}
    local out = { would_trigger = false, below = false }
    if not hunter or not elapsed then out.reason = "no_data"; return out end
    local base = opts.baseline_gpm

    -- collect ONLY the post-ramp steady window
    if elapsed >= M.WINDOW_FROM and elapsed <= M.WINDOW_TO then
        state.steady_samples[#state.steady_samples + 1] = hunter
    end
    -- fix the run's steady delivery once the ramp is over and we have enough samples
    if not state.steady and elapsed >= M.JUDGE_FROM and #state.steady_samples >= M.MIN_N then
        state.steady = median(state.steady_samples)
    end
    out.steady   = state.steady
    out.baseline = base
    if not state.steady then out.reason = "warmup/collecting"; return out end
    out.hun_med = state.steady
    if base and base > 1 then out.ratio = state.steady / base end

    -- PATH A — depletion vs the run's OWN steady level (self-referencing)
    local deplete = false
    if hunter < M.DRAW_FRAC * state.steady then
        state.drop_consec = state.drop_consec + 1
    else
        state.drop_consec = 0
    end
    if state.drop_consec >= M.ONSET_CONSEC then deplete = true end
    -- PATH B — low vs the bin's known-good baseline
    local low_base = (out.ratio ~= nil and out.ratio < M.TRIP_FRAC)

    if not (deplete or low_base) then out.reason = "ok"; return out end

    out.below  = true
    out.reason = deplete and "deplete(drop-from-steady)" or "low_vs_baseline"

    local remain = opts.run_time and (opts.run_time - elapsed) or 99
    out.guard_ok = remain > M.GUARD_REMAIN_MIN
    if state.triggered then out.reason = out.reason .. "/already"; return out end
    if not out.guard_ok then out.reason = out.reason .. "/guard"; return out end

    state.triggered   = true
    out.would_trigger = true
    return out
end

-- reinsert_job(opts) — the byte-matched IRRIGATION_STEP JSON for re-queuing the
-- depleting step (full re-run after the clean+wait). Verified against a live
-- IRRIGATION_PENDING entry 2026-06-21:
--   {"type":"IRRIGATION_STEP","schedule_name":"house","step":4,
--    "io_setup":[{"remote":"satellite_2","bits":[6]}],"run_time":5,
--    "elasped_time":0,"eto_enable":false,"eto_list":null,"eto_flag":false}
-- "elasped_time" is misspelled ON PURPOSE (the controller's wire key).
-- eto_* = FALSE on purpose (Glenn 2026-06-24): the CALLER passes the REMAINING
-- time (scheduled run_time − minutes already run) as opts.run_time, so the retry
-- delivers exactly the water the skipped run missed. eto_flag MUST stay false or
-- the controller re-resolves run_time at pop-to-run and overrides our remainder
-- (and the eto_flag:true attempt didn't work anyway — a front-pushed job carries no
-- eto_list, so the controller neither corrected run_time nor credited the deficit).
-- JSON key order inside io_setup is irrelevant to the parser.
--   opts = { schedule, step, io_setup (lua array), run_time = REMAINING minutes }
function M.reinsert_job(opts)
    opts = opts or {}
    local io_json = cjson.encode(opts.io_setup or {})
    return string.format(
        '{"type":"IRRIGATION_STEP","schedule_name":"%s","step":%d,"io_setup":%s,' ..
        '"run_time":%d,"elasped_time":0,"eto_enable":false,"eto_list":null,"eto_flag":false}',
        tostring(opts.schedule or ""), tonumber(opts.step) or 0, io_json,
        tonumber(opts.run_time) or 0)
end

return M
