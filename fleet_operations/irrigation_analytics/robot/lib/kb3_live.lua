-- kb3_live.lua — per-bin live-flow detector.
--
-- Polls the controller's FILTERED_HUNTER_VALVE (the controller's own 5-tap
-- MA — see explore/in_cycle_long_run.py for the recipe we mirror in the
-- post-event analyzer).
--
-- Algorithm (sprinkler-step indexed, sliding window):
--   - The controller's popup.STEP advances by 1 each clock rollover during
--     a run (0 when idle, 1 on first tick, 2 on second, ...). We index
--     samples by that step number — one slot per step.
--   - Warmup: do nothing until step >= KB3_FIRST_EVAL_STEP (9). The first 8
--     steps are ramp-up and unreliable.
--   - From step n=9 onward: look at samples at steps [n-4, n-3, n-2, n-1, n]
--     (5-step sliding window). If ALL 5 slots are populated AND every one
--     of them has err > +baseline.kb3_threshold (HIGH only), fire.
--     KB3 IS HIGH-WATER ONLY by design — low water (blocked emitters,
--     starvation, dropout) does NOT warrant a hard-kill, only HIGH water
--     (pipe break / over-spray) does. Low-water is KB4's job.
--   - When fired and bin is kb3_eligible and not yet fired-this-run →
--     emit ONE event (hard-kill semantics, run-scoped).
--   - Bin marked fired=true; suppresses further KB3 events for this run.
--
-- Reset: arming.kb3 = { by_step = {}, last_step = 0, fired = false } on
--        each new STATION_START (handled in main.lua).
--
-- Why step-indexed (not wall-clock):
--   The previous version used a wall-clock "5 consecutive over-threshold
--   samples, reset on miss" counter with no warmup. That fired too eagerly
--   on the ramp-up edge (first sample above threshold could be transient)
--   and had no way to skip the unreliable first 8 ticks. The step-indexed
--   sliding window matches Glenn's mental model and the failure-pattern
--   observed on the 2026-06-01 4:6/4:8 incident.
--
-- Eligibility:
--   - Bin must be in baselines.json with mode == "long"
--   - Bin must have kb3_eligible == true (excludes physically noisy bins
--     whose 5×stdev > 3.0 GPM — KB4 post-event handles those)
--
-- Note: FILTERED_HUNTER_VALVE is the WHOLE-meter flow when only one
-- valve is active. For concurrent runs (e.g. sat_1:39 + sat_2:16), the
-- baseline.ref already captures the COMBINED flow because baselines.json
-- was generated from the combined-bin TIME_HISTORY. So no decomposition
-- needed — bin_key uniquely identifies the expected baseline flow.

local M = {}

local KB3_FIRST_EVAL_STEP = 9    -- start evaluating once popup.STEP reaches this
local KB3_WINDOW_N        = 5    -- need all of steps [n-4..n] over threshold to fire

-- Push one filtered-flow sample into the bin's KB3 state at sprinkler step `step`.
-- Returns:
--   { fired = bool, suppressed = bool, err = float|nil,
--     step = int, window_over_n = int, sample = float, ref = float,
--     threshold = float }
-- nil if not enough info to evaluate (eligibility miss, missing inputs, or
-- step too low for first evaluation).
--
-- baseline: the per-bin entry from baselines.json
-- kb3_state: arming.kb3 (mutated in place — { by_step={}, last_step=0, fired=false })
-- filtered_sample: tonumber(popup.FILTERED_HUNTER_VALVE)
-- step:           tonumber(popup.STEP)  -- controller's per-tick counter
function M.update(baseline, kb3_state, filtered_sample, step)
    if not baseline or baseline.mode ~= "long" then return nil end
    if not baseline.kb3_eligible then return nil end
    if not baseline.kb3_threshold or not baseline.ref then return nil end
    if not filtered_sample then return nil end
    if not kb3_state then return nil end
    if not step or step < 1 then return nil end
    step = math.floor(step)

    -- Record sample at this step. by_step is keyed by integer step number.
    kb3_state.by_step   = kb3_state.by_step or {}
    kb3_state.by_step[step] = filtered_sample
    kb3_state.last_step = math.max(kb3_state.last_step or 0, step)

    local ref    = baseline.ref
    local thresh = baseline.kb3_threshold
    local err    = filtered_sample - ref

    -- Warmup: don't even consider firing until we've reached the first
    -- evaluation step. Always return a result so cycle.kb3 logging works.
    if step < KB3_FIRST_EVAL_STEP then
        return {
            sample = filtered_sample, ref = ref, threshold = thresh, err = err,
            step = step, window_over_n = 0, fired = false, suppressed = false,
        }
    end

    -- Sliding window: [step-4, step-3, step-2, step-1, step] (5 entries).
    -- All slots must be populated AND every one over (ref + thresh).
    local over_n = 0
    local missing = false
    for s = step - (KB3_WINDOW_N - 1), step do
        local v = kb3_state.by_step[s]
        if v == nil then
            missing = true
            break
        end
        if (v - ref) > thresh then over_n = over_n + 1 end
    end

    local result = {
        sample        = filtered_sample,
        ref           = ref,
        threshold     = thresh,
        err           = err,
        step          = step,
        window_over_n = over_n,
        fired         = false,
        suppressed    = false,
    }

    if (not missing) and over_n >= KB3_WINDOW_N then
        if kb3_state.fired then
            result.suppressed = true   -- already fired this run, hard-kill is one-shot
        else
            result.fired = true
            kb3_state.fired = true
        end
    end
    return result
end

-- Construct event payload for main.lua to dispatch. Called only when
-- update() returned fired=true.
function M.event(bin_key, baseline, kb3_state, result)
    return {
        kind   = "KB3_PIPE_BREAK_HIGH",
        level  = "RED",
        action = "SKIP_STATION",
        msg    = string.format(
            "KB3 LIVE: filtered flow %.2f GPM HIGH (err +%.2f, thresh %.2f) "
                .. "vs ref %.2f at step %d, last %d steps all over on bin=%s  "
                .. ">> SKIP_STATION (pipe break / over-spray)",
            result.sample, result.err, result.threshold, result.ref,
            result.step, KB3_WINDOW_N, bin_key),
        bin_key   = bin_key,
        sample    = result.sample,
        ref       = result.ref,
        threshold = result.threshold,
        err       = result.err,
        step      = result.step,
        window_n  = KB3_WINDOW_N,
    }
end

return M
