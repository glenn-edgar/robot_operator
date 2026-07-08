-- lib/flow_step.lua — flow STEP-CHANGE leak-watch (Glenn 2026-07-08).
--
-- Catches a SMALL, SUSTAINED developing leak that the gross-leak trips miss: a bin whose
-- per-run delivery steps UP and STAYS up. The 4:4/1:39 case (07-08): delivery stepped from
-- ~10 to ~12.3 around 07-05 and held for 4 runs (+2.2). That is well under the absolute
-- 14 GPM trip AND under +5 over its (creeping) baseline, so KB3's per-minute leak detector
-- never fired — Glenn caught it by eyeballing the run-to-run TREND. This detects the trend:
-- the recent runs' median sits >= STEP_GPM above the prior runs' median.
--
-- ALERT-ONLY (no actuation, unlike the gross-leak SKIP). A step-up CAN be a leak, but it can
-- also be benign (a repair, a pressure/seasonal change, or a clog RECOVERY returning toward
-- normal), so it warns and lets the operator judge — it must not auto-skip a healthy station.
-- Per-run (compares completed-run history at STATION_START), not per-minute.

local M = {}

-- ---- tunables (GPM, run counts) ----
M.RECENT_N  = 3      -- most-recent completed runs = "now"
M.PRIOR_N   = 4      -- the runs before those = "before"
M.STEP_GPM  = 1.5    -- recent median must exceed prior median by at least this
M.MIN_LEVEL = 5.0    -- ignore low-flow bins (recent median must be at least this to matter)

local function median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = t[i] end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end

-- detect(series) — series = per-run win_hunter values, NEWEST FIRST
-- (from KB4V2.load_hunter_series). Returns
--   { stepped_up, recent_med, prior_med, delta_gpm, reason }.
function M.detect(series)
    local out = { stepped_up = false }
    series = series or {}
    if #series < M.RECENT_N + M.PRIOR_N then out.reason = "too_few_runs"; return out end
    local recent, prior = {}, {}
    for i = 1, M.RECENT_N do recent[i] = series[i] end
    for i = 1, M.PRIOR_N do prior[i] = series[M.RECENT_N + i] end
    local rm, pm = median(recent), median(prior)
    out.recent_med, out.prior_med, out.delta_gpm = rm, pm, rm - pm
    if rm < M.MIN_LEVEL then out.reason = "low_flow_bin"; return out end
    -- require a real, SUSTAINED step: recent median >= prior median + STEP, AND EVERY recent
    -- run above the prior median (a plateau, not one high sample or a noisy wobble).
    local all_above = true
    for i = 1, M.RECENT_N do if series[i] <= pm then all_above = false; break end end
    if out.delta_gpm >= M.STEP_GPM and all_above then
        out.stepped_up = true
        out.reason = "flow_step_up"
    else
        out.reason = "no_step"
    end
    return out
end

return M
