-- lib/plc_filter.lua — PLC-meter SAND-FOUL detector (Glenn 2026-06-28 rule).
--
-- THE RULE (Glenn): "key off the PLC — if it drops AND the smooth (filtered)
-- Hunter is still flowing, do the cleaning operation."
--
-- PHYSICS / WHY THIS WORKS:
--   The PLC meter (main_flow_meter) sits UPSTREAM of the filter = the well source.
--   The smooth/filtered Hunter (FILTERED_HUNTER_VALVE) sits DOWNSTREAM of the
--   filter = water actually DELIVERED. In a healthy system the two are in SERIES,
--   so they read roughly the same flow.
--   Therefore: PLC LOW while Hunter STILL FLOWS is physically impossible from a
--   real hydraulic event (a true flow loss — dying well, clogged line — would
--   starve DELIVERY too, dropping Hunter). The only thing that makes the upstream
--   meter read ~0 while the downstream meter proves water is moving is the PLC
--   meter / its sensing port being SAND-FOULED (the chronic main_flow_meter
--   false-0, observed reading ~0 for HOURS on 2026-06-28 while Hunter delivered
--   5-7 GPM). The fix for that is to FLUSH it: CLEAN_FILTER.
--
--   The complementary case — PLC low AND Hunter ALSO low (both fall together) —
--   is a REAL delivery loss and is already the Hunter-only flow_deplete's job
--   (KB3_FLOW_ARM: clean + retry + skip). KB5 does NOT handle that; KB5's unique
--   value is exactly the case flow_deplete is blind to: Hunter fine, PLC fouled.
--
-- SCOPE (enforced by the kb5 call site): NON-CITY bins only. On a city bin the
-- well legitimately may not draw (city water carries the load) → PLC low + Hunter
-- flowing would be city water, NOT a fouled meter. On a non-city bin the well is
-- the only source, so Hunter flow PROVES the well is flowing and a low PLC = a
-- meter/filter fault.
--
-- RECOVERY (when armed, dispatched by the call site, Glenn 2026-06-29): a 15-min
-- 1:39 wait/recharge FIRST, THEN ONE CLEAN_FILTER (controller pops [wait -> clean]),
-- run next. NO skip and NO re-run — the station is delivering correctly; only the
-- meter is fouled, so we must not interrupt a healthy watering step. Rate-gated to
-- one clean per 90 min (the cooldown lives in the call site / kb5_meta).
--
-- Monitor-only by default (the call site's KB5_FILTER_ARM gate) — observe() just
-- reports what it WOULD do; it actuates nothing.

local M = {}

-- ---- tunables (GPM, minutes) — tune from the logs. ----
-- "PLC drops" = the upstream meter reads below this absolute floor. Absolute (not
-- a fraction of its own steady) because the fouling is often present from the
-- START of a run — there is no healthy steady to drop FROM (PLC read ~0 for hours
-- on 06-28). A healthy well run pulls well above this (Hunter ~6 ⇒ PLC ~6+).
M.PLC_LOW_GPM   = 3.0
-- "smooth Hunter still flows" = real delivery downstream. Above this = the well IS
-- flowing (so a low PLC cannot be a real flow loss — it's the meter).
M.HUN_FLOW_GPM  = 4.0
-- Don't judge before the slow filtered-Hunter ramp settles (flow_deplete RAMP
-- NOTE: Hunter still climbing at min 9). Before this, Hunter < HUN_FLOW_GPM anyway.
M.JUDGE_FROM    = 6
-- Sustained: the PLC-low / Hunter-flowing divergence must hold this many
-- consecutive minutes (rejects a single-sample meter glitch).
M.ONSET_CONSEC  = 3
M.GUARD_REMAIN_MIN = 1   -- don't bother if the step is <= this from completing

-- Fresh per-station state. Call on STATION_START.
function M.new_station()
    return {
        drop_consec = 0,      -- consecutive minutes of PLC-low / Hunter-flowing
        onset_min   = nil,    -- elapsed minute the current divergence streak began
        triggered   = false,  -- fired once this step
    }
end

-- observe(state, plc, hunter, elapsed, opts) — call once per NEW minute.
--   plc     = popup.PLC_FLOW_METER (GPM, well source, UPSTREAM of the filter)
--   hunter  = popup.FILTERED_HUNTER_VALVE (GPM, delivered, DOWNSTREAM = "smooth hunter")
--   elapsed = popup.ELASPED_TIME (minutes into the step)
--   opts    = { run_time = step minutes }
-- Returns { would_trigger, below, reason, plc, hunter, guard_ok }.
function M.observe(state, plc, hunter, elapsed, opts)
    opts = opts or {}
    local out = { would_trigger = false, below = false, plc = plc, hunter = hunter }
    if not plc or not hunter or not elapsed then out.reason = "no_data"; return out end

    -- Wait out the line-recharge ramp; Hunter hasn't reached delivery yet.
    if elapsed < M.JUDGE_FROM then out.reason = "warmup/ramp"; return out end

    -- THE RULE: PLC dropped (upstream reads low) AND smooth Hunter still flows
    -- (downstream proves the well is delivering) → the PLC meter/filter is fouled.
    local plc_dropped    = plc < M.PLC_LOW_GPM
    local hunter_flowing = hunter >= M.HUN_FLOW_GPM
    if plc_dropped and hunter_flowing then
        if state.drop_consec == 0 then state.onset_min = elapsed end
        state.drop_consec = state.drop_consec + 1
    else
        state.drop_consec = 0
    end

    if state.drop_consec < M.ONSET_CONSEC then out.reason = "ok"; return out end

    out.below  = true
    out.reason = "plc-foul(plc low, smooth hunter still flowing)"

    local remain = opts.run_time and (opts.run_time - elapsed) or 99
    out.guard_ok = remain > M.GUARD_REMAIN_MIN
    if state.triggered then out.reason = out.reason .. "/already"; return out end
    if not out.guard_ok then out.reason = out.reason .. "/guard"; return out end

    state.triggered   = true
    out.would_trigger = true
    return out
end

return M
