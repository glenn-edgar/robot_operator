-- lib/well_drawdown.lua — well-flow monitor: WELL-DRAWDOWN + INTERNAL-LEAK (MONITOR-ONLY).
--
-- Runs in PARALLEL with KB3's sustained-leak check, reading the same live per-minute
-- meters KB3 already fetches:
--   PLC    = popup.PLC_FLOW_METER     = WELL SOURCE  (raw, leads)
--   HUNTER = FILTERED_HUNTER_VALVE    = DOWNSTREAM   (filtered, lags)
--
-- TWO detectors (Glenn 2026-06-14, [[irrigation-leak-well-model-2026-06-14]]):
--
-- 1. INTERNAL LEAK = PLC >> HUNTER (water lost BETWEEN the meters) = supply-line break
--    controller->zone. Over-draws the WELL + starves the zone. It is ALSO the EARLY
--    well-drawdown warning — the over-draw is the precursor to depletion (4:9 on 06-14:
--    div +5 at 18:26, before 18:43; the plateau-drop detector missed it). Healthy div
--    ~ +1 GPM (calibration offset). Self-referencing (run's own early div) + absolute.
--
-- 2. WELL DRAWDOWN = PLC falling below its own in-run plateau / the cycle's demonstrated
--    capacity. Catches the well running low ("don't wait for zero, too late then").
--    RETUNED 2026-06-14 from the 4:9 MISS: tighter frac (4:9 bottomed 0.71, just above the
--    old 0.70 floor -> 0 hits), fire on ONSET (2 consecutive) not only the 3-of-4 window
--    (short runs + sawtooth recoveries dodged it), and flag HUNTER-also-dropping = severe
--    (downstream actually starving — the real arming discriminator).
--
-- Root cause of a drawdown is EITHER an internal leak (over-draw) OR a scheduling gap
-- (a high-draw bank with no 1:39 recharge after it -> well starts the next step depleted).
-- BOTH are remedied by the SAME action this would take: rpush the 15-min 1:39 `wait`
-- recharge. MONITOR-ONLY: logs what it WOULD do; pushes nothing, skips nothing. The KB3
-- call site pcall-isolates it so a bad tick can't disturb the armed leak detector.

local M = {}

-- ---- tunables (GPM, minutes) — NOT load-bearing in monitor mode; set from logs. ----
M.WARMUP_MIN        = 5      -- ignore the fill ramp (HUNTER lags PLC here = benign)
M.PLATEAU_FROM      = 5      -- establish PLC plateau + div_ref + hun_ref over min 5..12
M.PLATEAU_TO        = 12
M.PLATEAU_MIN_N     = 3
-- well drawdown
M.DRAW_FRAC         = 0.78   -- PLC below this fraction of plateau = drawdown (was 0.70)
M.FLOOR_FRAC        = 0.50   -- PLC below this fraction of cycle capacity = floor
M.ONSET_CONSEC      = 2      -- fire on this many CONSECUTIVE below (catches onset/short runs)
M.WINDOW            = 4      -- ...OR this windowed...
M.WINDOW_HITS       = 3      -- ...many of WINDOW below (catches the sawtooth) — first wins
M.HUN_DROP          = 1.5    -- HUNTER this far below its ref = downstream starving = SEVERE
M.GUARD_REMAIN_MIN  = 1      -- don't act if the step is <= this from completing
-- internal leak (PLC - HUNTER = loss between meters)
M.IL_DIV_DELTA      = 3.0    -- div this far above the run's own early ref = internal leak
M.IL_DIV_ABS        = 3.5    -- ...or absolute div this high (covers leak-from-run-start)
M.IL_SUSTAIN        = 2      -- consecutive minutes post-warmup before flagging

-- The exact recovery step we WOULD rpush (byte-matched to a live IRRIGATION_PENDING job;
-- satellite_1:39 = city water, no well draw, 15 min — this IS the missing recharge period).
M.WAIT_JOB = '{"type":"IRRIGATION_STEP","schedule_name":"wait","step":0,' ..
    '"io_setup":[{"remote":"satellite_1","bits":[39]}],"run_time":15,' ..
    '"elasped_time":0,"eto_enable":false,"eto_list":null,"eto_flag":false}'

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
        plateau_samples = {}, plateau = nil,
        div_samples     = {}, div_ref = nil,
        hun_samples     = {}, hun_ref = nil,
        recent          = {},          -- ring of last WINDOW drawdown below-flags
        below_consec    = 0,
        triggered       = false,       -- well-drawdown fired (once/station)
        il_consec       = 0,
        il_fired        = false,       -- internal-leak fired (once/station)
    }
end

-- One per-minute observation. Returns a result table for the caller to log:
--   well drawdown: { phase, plateau, plc, frac, below, below_consec, hits, severe,
--                    would_trigger, guard_ok, reason }
--   internal leak: { internal_leak, div, div_ref }
-- phase in {no_plc, warmup, building, monitor}
function M.observe(state, plc, hunter, elapsed, opts)
    opts = opts or {}
    local out = { phase = "monitor", plc = plc, hunter = hunter }
    plc = tonumber(plc); hunter = tonumber(hunter); elapsed = tonumber(elapsed)
    if not plc or not elapsed then out.phase = "no_plc"; return out end
    if elapsed < M.WARMUP_MIN then out.phase = "warmup"; return out end

    -- establish/refine references over the early steady window
    if elapsed >= M.PLATEAU_FROM and elapsed <= M.PLATEAU_TO then
        state.plateau_samples[#state.plateau_samples + 1] = plc
        if hunter then
            state.hun_samples[#state.hun_samples + 1] = hunter
            state.div_samples[#state.div_samples + 1] = plc - hunter
        end
        if #state.plateau_samples >= M.PLATEAU_MIN_N then
            state.plateau = median(state.plateau_samples)
            state.div_ref = (#state.div_samples > 0) and median(state.div_samples) or nil
            state.hun_ref = (#state.hun_samples > 0) and median(state.hun_samples) or nil
        end
    end
    if not state.plateau then out.phase = "building"; return out end
    out.plateau = state.plateau

    -- ===== INTERNAL LEAK (PLC - HUNTER divergence) =====
    if hunter then
        local div = plc - hunter
        out.div = div
        local is_il = false
        if state.div_ref and (div - state.div_ref) >= M.IL_DIV_DELTA then is_il = true end
        if div >= M.IL_DIV_ABS then is_il = true end
        if is_il then state.il_consec = state.il_consec + 1 else state.il_consec = 0 end
        if state.il_consec >= M.IL_SUSTAIN and not state.il_fired then
            state.il_fired = true
            out.internal_leak = true
            out.div_ref = state.div_ref
        end
    end

    -- ===== WELL DRAWDOWN (retuned) =====
    local draw  = plc < M.DRAW_FRAC * state.plateau
    local cap   = tonumber(opts.cycle_capacity)
    local floor = cap and plc < M.FLOOR_FRAC * cap or false
    local below = draw or floor
    out.frac  = plc / state.plateau
    out.below = below

    if below then state.below_consec = state.below_consec + 1 else state.below_consec = 0 end
    out.below_consec = state.below_consec
    local r = state.recent
    r[#r + 1] = below and 1 or 0
    while #r > M.WINDOW do table.remove(r, 1) end
    local hits = 0
    for _, v in ipairs(r) do hits = hits + v end
    out.hits = hits

    -- downstream severity: is HUNTER (filtered) also dropping = zone actually starving
    local severe = false
    if hunter and state.hun_ref and (state.hun_ref - hunter) >= M.HUN_DROP then severe = true end
    out.severe = severe

    local run_time = tonumber(opts.run_time)
    out.guard_ok = (not run_time) or (run_time - elapsed > M.GUARD_REMAIN_MIN)

    if not state.triggered and out.guard_ok
       and (state.below_consec >= M.ONSET_CONSEC or hits >= M.WINDOW_HITS) then
        state.triggered = true
        out.would_trigger = true
        out.reason = (floor and "floor(cycle-cap)")
            or (severe and "drawdown+downstream-starving")
            or "plateau-drop"
    end
    return out
end

return M
