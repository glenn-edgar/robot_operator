-- modes.lua — mode evaluators.
--
-- Pure functions over (state, popup, arming, past_actions_delta).
-- Returns a list of "events" — each one a table describing a detection +
-- the action that would-have-been taken. main.lua logs them and (when
-- shadow=false in future) actually triggers Discord / SKIP / CLOSE_MASTER.
--
-- Sample-0 skip is handled by the caller (main.lua tracks samples_seen
-- per arming and drops the first reading after STATION_START).
--
-- All thresholds come from thresholds.lua. We use sustained-2 (require the
-- previous sample to also trip) for warn-tier rules to filter noise.

local T = require("thresholds")
local SM = require("state_machine")

local M = {}

-- Event constructors — uniform schema.
local function event(kind, level, action, msg, extras)
    local e = { kind = kind, level = level, action = action, msg = msg }
    if extras then
        for k, v in pairs(extras) do e[k] = v end
    end
    return e
end

-- ---------------------------------------------------------------------------
-- Mode 4 (per-valve hard trip) — universal wire safety on Irrigation Current
-- ---------------------------------------------------------------------------
-- Instant (no sustained-2 — wire safety can't wait a minute).
function M.eval_mode4_irr(irr_current)
    if irr_current >= T.IRR_TRIP_A then
        return event(
            "MODE_4_PER_VALVE_TRIP", "RED", "SKIP_STATION",
            string.format("Irrigation Current %.2f A ≥ %.2f A trip",
                irr_current, T.IRR_TRIP_A),
            { irr_current = irr_current, threshold = T.IRR_TRIP_A })
    end
end

-- ---------------------------------------------------------------------------
-- EQ-warn / EQ-trip — universal wire safety on Equipment Current
-- ---------------------------------------------------------------------------
function M.eval_eq(eq_current, prev_eq_current)
    if eq_current >= T.EQ_TRIP_A then
        return event(
            "EQ_TRIP", "RED", "CLOSE_MASTER_VALVE",
            string.format("Equipment Current %.2f A ≥ %.2f A trip",
                eq_current, T.EQ_TRIP_A),
            { eq_current = eq_current, threshold = T.EQ_TRIP_A })
    end
    if eq_current >= T.EQ_WARN_A then
        if prev_eq_current and prev_eq_current >= T.EQ_WARN_A then
            return event(
                "EQ_WARN", "YELLOW", nil,
                string.format("Equipment Current %.2f A ≥ %.2f A warn (sustained)",
                    eq_current, T.EQ_WARN_A),
                { eq_current = eq_current, threshold = T.EQ_WARN_A })
        end
    end
end

-- ---------------------------------------------------------------------------
-- Mode 3 RED (shorted-sprinkler trip) — per-sample, instant.
--
-- A shorted solenoid coil draws above-baseline current immediately on
-- activation. We don't wait for the median window to fill or for the
-- warmup lag to clear — Glenn 2026-06-01: "one step sample is enough
-- for trip". Edge-triggered dispatch in main.lua section 9 handles the
-- per-bin one-shot (won't re-POST SKIP_STATION while still firing).
--
-- This sits between MODE_4_PER_VALVE_TRIP (universal 1.75 A ceiling,
-- always armed) and MODE_3_HIGH_WARN (median-based YELLOW). For a
-- 0.4 A bin with a partial short to 1.0 A, Mode 4 misses (under 1.75)
-- but Mode 3 RED (2.0×0.4 = 0.8 A threshold) catches it on the first
-- sample over.
-- ---------------------------------------------------------------------------
function M.eval_mode3_red_irr(irr_current, curve, bin_key)
    if not curve or not curve.mu or not irr_current then return nil end
    local red_th = T.mode3_high_red(curve.mu)
    if irr_current > red_th then
        return event(
            "MODE_3_HIGH_RED", "RED", "SKIP_STATION",
            string.format("Irrigation Current %.3f A > %.3f A (2.0×mu=%.3f RED, bin=%s)",
                irr_current, red_th, curve.mu, bin_key),
            { irr_current = irr_current, threshold = red_th,
              mu = curve.mu, bin_key = bin_key })
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Mode 1 (low) and Mode 3 high-warn — calibrated bin only.
-- These remain median-based YELLOW alerts (Discord ping, no SKIP):
--   - Gated off during warm-up (PLC reading lag).
--   - Gated off until the window has MEDIAN_WINDOW_N accepted samples.
--   - 15-sample median filters the 6 mA quantization noise that would
--     otherwise generate 100s of duplicate Discord pushes per run.
-- Mode 3 RED has been split out to eval_mode3_red_irr (per-sample, no
-- gates) so a shorted sprinkler trips immediately instead of waiting
-- ~15 min for the median window to fill.
-- ---------------------------------------------------------------------------
function M.eval_calibrated_modes(irr_current, irr_median, irr_window_n,
                                 curve, bin_key, in_warmup)
    local events = {}
    if not curve then return events end
    if in_warmup then return events end    -- baseline lag region — refuse to fire
    if not irr_median then return events end
    if (irr_window_n or 0) < T.MEDIAN_WINDOW_N then return events end

    local mode3_warn_th = T.mode3_high_warn(curve.mu)
    if irr_median < curve.i_low_open then
        events[#events+1] = event(
            "MODE_1_LOW", "YELLOW", nil,
            string.format("Irrigation Current med-%d %.3f A < %.3f A (bin=%s)",
                irr_window_n, irr_median, curve.i_low_open, bin_key),
            { irr_current = irr_current, irr_median = irr_median,
              window_n = irr_window_n,
              threshold = curve.i_low_open, bin_key = bin_key })
    end
    if irr_median > mode3_warn_th then
        events[#events+1] = event(
            "MODE_3_HIGH_WARN", "YELLOW", nil,
            string.format("Irrigation Current med-%d %.3f A > %.3f A (1.5×mu, bin=%s)",
                irr_window_n, irr_median, mode3_warn_th, bin_key),
            { irr_current = irr_current, irr_median = irr_median,
              window_n = irr_window_n,
              threshold = mode3_warn_th, bin_key = bin_key })
    end
    return events
end

-- ---------------------------------------------------------------------------
-- MASTER_IDLE_CHECK — master alone, no irrigation step.
-- High trip (universal wire safety) stays armed during warm-up; the
-- per-master-baseline LOW and HIGH_WARN are gated off until the current
-- reading has settled (~120 s post arming).
-- ---------------------------------------------------------------------------
function M.eval_master_idle(irr_current, irr_median, irr_window_n, in_warmup)
    local events = {}
    -- High trip first (instant, wire safety) — same Mode 4 ceiling, different action.
    -- Armed unconditionally — wire damage can't wait for warm-up or window-fill.
    if irr_current >= T.IRR_TRIP_A then
        events[#events+1] = event(
            "MASTER_HIGH_TRIP", "RED", "CLOSE_MASTER_VALVE",
            string.format("Master-idle Irrigation Current %.2f A ≥ %.2f A trip",
                irr_current, T.IRR_TRIP_A),
            { irr_current = irr_current, threshold = T.IRR_TRIP_A })
        return events
    end
    if in_warmup then return events end    -- baseline lag region — refuse to fire warns
    if not irr_median then return events end
    if (irr_window_n or 0) < T.MEDIAN_WINDOW_N then return events end

    -- Low (master coil open / wire broken) — median below threshold
    if irr_median < T.MASTER_LOW_A then
        events[#events+1] = event(
            "MASTER_IDLE_LOW", "YELLOW", nil,
            string.format("Master-idle Irrigation Current med-%d %.3f A < %.3f A (coil open?)",
                irr_window_n, irr_median, T.MASTER_LOW_A),
            { irr_current = irr_current, irr_median = irr_median,
              window_n = irr_window_n, threshold = T.MASTER_LOW_A })
    end
    -- High warn (master coil aging short) — median above threshold
    if irr_median > T.MASTER_HIGH_WARN then
        events[#events+1] = event(
            "MASTER_IDLE_HIGH_WARN", "YELLOW", nil,
            string.format("Master-idle Irrigation Current med-%d %.3f A > %.3f A (coil aging short?)",
                irr_window_n, irr_median, T.MASTER_HIGH_WARN),
            { irr_current = irr_current, irr_median = irr_median,
              window_n = irr_window_n, threshold = T.MASTER_HIGH_WARN })
    end
    return events
end

-- ---------------------------------------------------------------------------
-- evaluate — top-level dispatcher.
-- arming = { bin_key, curve_or_nil, eto_restriction_seen, samples_seen,
--            started_at_ts, irr_window, last_accepted_ts, sent_kinds }
-- last  = { irr_current, eq_current }    previous poll's reading, or nil
-- popup = current poll's reading
-- state = string (one of state_machine.states)
-- ctx   = { now_ts,
--           master_idle_armed_ts,
--           irr_median, irr_window_n   -- per-session rolling-window stats
--         }
-- ---------------------------------------------------------------------------
function M.evaluate(state, popup, arming, last, ctx)
    local events = {}
    local irr = tonumber(popup.PLC_IRRIGATION_CURRENT) or 0
    local eq  = tonumber(popup.PLC_EQUIPMENT_CURRENT)  or 0
    local prev_eq  = last and last.eq_current
    local now_ts   = ctx and ctx.now_ts
    local irr_med  = ctx and ctx.irr_median
    local irr_n    = ctx and ctx.irr_window_n

    -- SUSPENDED states gate everything
    if state == SM.states.SUSPENDED_MANUAL
       or state == SM.states.SUSPENDED_CLEAN_FILTER
       or state == SM.states.SUSPENDED_RESISTANCE then
        return events
    end

    -- EQ wire safety: always armed in non-suspended states (still per-sample)
    if state == SM.states.IDLE
       or state == SM.states.MASTER_IDLE_CHECK
       or state == SM.states.ACTIVE_RUN then
        local e = M.eval_eq(eq, prev_eq)
        if e then events[#events+1] = e end
    end

    if state == SM.states.MASTER_IDLE_CHECK then
        local mi_armed = ctx and ctx.master_idle_armed_ts
        local mi_warmup = (now_ts and mi_armed and (now_ts - mi_armed) < T.WARMUP_S) or false
        for _, e in ipairs(M.eval_master_idle(irr, irr_med, irr_n, mi_warmup)) do
            events[#events+1] = e
        end

    elseif state == SM.states.ACTIVE_RUN then
        -- Mode 4 universal trip — always armed in ACTIVE_RUN (per-sample, hard)
        local e = M.eval_mode4_irr(irr)
        if e then events[#events+1] = e end

        -- Mode 3 RED per-bin (shorted-sprinkler trip) — per-sample, no
        -- warmup, no median. Requires bin calibrated + no ETO-restriction.
        -- Sits below Mode 4 (so Mode 4 wins when both would fire); we
        -- still emit only one event per kind per poll, so duplicate
        -- MODE_3_HIGH_RED with MODE_4 is fine — they're different kinds.
        if arming and not arming.eto_restriction_seen and arming.curve then
            local red = M.eval_mode3_red_irr(irr, arming.curve, arming.bin_key)
            if red then events[#events+1] = red end
        end

        -- Mode 1 LOW + Mode 3 HIGH WARN (median-based YELLOWs) require:
        -- bin calibrated, no ETO-restriction, past warm-up, full window.
        if arming and not arming.eto_restriction_seen and arming.curve then
            local in_warmup =
                (now_ts and arming.started_at_ts
                 and (now_ts - arming.started_at_ts) < T.WARMUP_S) or false
            local cal_events = M.eval_calibrated_modes(
                irr, irr_med, irr_n, arming.curve, arming.bin_key, in_warmup)
            for _, e2 in ipairs(cal_events) do
                events[#events+1] = e2
            end
        end
    end

    return events
end

return M
