-- lib/clog_filter.lua — clogged-filter monitor (MONITOR-ONLY).
--
-- Runs in PARALLEL with KB3's leak + well-drawdown checks, off the SAME live
-- per-minute meters the KB3 tick already fetches. Mirrors well_drawdown.lua:
-- the kb3 call site pcall-isolates it so a fault here can NEVER disturb the
-- armed leak path.
--
-- SENSOR = FILTERED_HUNTER_VALVE (delivered flow, downstream of the filter).
-- A clogged well/main filter starves DELIVERY: the Filtered Hunter sags below
-- the bin's clean baseline while the well source is still fine. We deliberately
-- do NOT use PLC / main_flow_meter here — it is sand-fouled and reads false-0 on
-- well runs (state.md 2026-06-19), so any PLC or PLC-Hunter-divergence rule would
-- false-fire. Hunter-vs-baseline is the sole discriminator.
--
-- Validated against the 06-19/06-20 MANUAL clean-filter events (the operator
-- cleared the schedule, ran `clean filter`, re-queued): the same valves recovered
-- right after each clean — 4:10 5.0->7.7 GPM, 4:11 4.2->7.4 GPM (baseline 9.69 /
-- 5.79). Healthy steps deliver 0.85-0.92x baseline; clog candidates fall to
-- 0.50-0.78x. TRIP_FRAC sits between.
--
-- The recovery action this WOULD take (the clean-filter routine, wired later):
-- SKIP the current step, then rpush IN REVERSE so the controller queue (rpop =
-- front) pops them in order [wait 1:39 15m -> CLEAN_FILTER -> reinsert this step].
-- ONCE PER STEP: a real filter clog recovers after one clean; if the reinserted
-- step is STILL low, it is the head/valve (not the filter) — do not re-clean.
--
-- MONITOR-ONLY: observe() decides what it WOULD do; it pushes nothing and skips
-- nothing. is_city steps are EXCLUDED at the call site (a pure 1:39 recharge/flush
-- delivers ~0 Hunter and would false-trip).

local M = {}

-- ---- tunables (GPM fraction, minutes) — monitor-mode; tune from the logs. ----
M.WINDOW_FROM      = 5     -- steady-delivery window start (matches kb4v2 win_hunter)
M.WINDOW_TO        = 15    -- steady-delivery window end
M.JUDGE_FROM       = 9     -- don't judge before this minute: Filtered Hunter LAGS
                           -- (filtered), so an early median understates real delivery
M.MIN_N            = 4     -- need this many in-window samples before judging
M.TRIP_FRAC        = 0.75  -- Hunter median below this fraction of clean baseline =
                           -- clog candidate (healthy 0.85-0.92x; clog 0.50-0.78x)
M.GUARD_REMAIN_MIN = 1     -- don't act if the step is <= this from completing

-- Fresh per-station state. Call on STATION_START.
function M.new_station()
    return { samples = {}, triggered = false }
end

-- observe(state, hunter, elapsed, opts) — call once per NEW minute.
--   hunter  = popup.FILTERED_HUNTER_VALVE (GPM, delivered)
--   elapsed = popup.ELASPED_TIME (minutes into the step)
--   opts    = { baseline_gpm = bin clean Hunter baseline, run_time = step minutes }
-- Returns { would_trigger, below, hun_med, baseline, ratio, n, guard_ok, reason }.
function M.observe(state, hunter, elapsed, opts)
    opts = opts or {}
    local out = { would_trigger = false, below = false }
    local base = opts.baseline_gpm
    if not base or base <= 1 then out.reason = "no_baseline"; return out end
    if not hunter or not elapsed then out.reason = "no_data"; return out end

    if elapsed >= M.WINDOW_FROM and elapsed <= M.WINDOW_TO then
        state.samples[#state.samples + 1] = hunter
    end
    out.baseline = base
    local n = #state.samples
    out.n = n
    if n < M.MIN_N or elapsed < M.JUDGE_FROM then
        out.reason = "collecting"; return out
    end

    local c = {}
    for i = 1, n do c[i] = state.samples[i] end
    table.sort(c)
    local med = (n % 2 == 1) and c[(n + 1) / 2] or (c[n / 2] + c[n / 2 + 1]) / 2
    out.hun_med = med
    out.ratio   = med / base

    if out.ratio >= M.TRIP_FRAC then out.reason = "ok"; return out end

    -- below the trip fraction
    out.below = true
    local remain = opts.run_time and (opts.run_time - elapsed) or 99
    out.guard_ok = remain > M.GUARD_REMAIN_MIN
    if state.triggered then out.reason = "already_triggered"; return out end
    if not out.guard_ok then out.reason = "guard_blocked"; return out end

    state.triggered    = true
    out.would_trigger  = true
    out.reason         = "hunter_below_frac"
    return out
end

return M
