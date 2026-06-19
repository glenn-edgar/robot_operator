-- kb4_post.lua — STEP_COMPLETE post-event analyzer.
--
-- Phase 1 jobs:
--  (a) LONG (ETO) bins — silently update the rolling baseline curve
--      with the just-completed run's body_mean (MA5 + mean over t in [5, n-2)).
--      No anomaly detection yet — that's phase 2 (small pipe break + blocked
--      sprinklers for ETO bins).
--
--  (b) SHORT (non-ETO) bins — compute last_sample, score vs baseline ref,
--      fire YELLOW Discord event if |last - ref| > max(2 * ref_mad, 2.0 GPM).
--      Direction-aware kinds (KB4_SHORT_LOW = blocked emitters candidate,
--      KB4_SHORT_HIGH = over-spray / pipe break candidate).
--      Edge-triggered cooldown lives in main.lua (kb4_cond_state).
--
-- Both modes update the bin's rolling-5 window subject to the
-- "population-10" rule:
--    n_runs_total < 10  → update ALWAYS (still bootstrapping baseline)
--    n_runs_total >= 10 → update only on STABLE runs (skip flagged ones,
--                          so chronic faults don't poison the baseline)
--
-- Update writes back to baselines.json atomically (temp + rename). Robot
-- becomes the writer here, not just a reader — keep the schema additive
-- (only window/ref/ref_mad/n_runs_total/n_window/updated_at touched).
-- kb3_stdev/threshold/eligible are stable, recomputed only by
-- generate_curves.py periodic rebuilds.

local cjson = require("cjson")
local Baselines = require("baselines")

local M = {}

local FLOW_SKIP        = 5
local TAIL_SKIP        = 2
local MA_TAPS          = 5
local MIN_BODY_FLOW    = 5
local WINDOW_N         = 5
local POP_GATE         = 10
local SHORT_FLOOR_GPM  = 2.0
local SHORT_K_MAD      = 2.0

-- 5-tap causal MA matching controller's FILTERED_HUNTER_VALVE recipe.
local function ma5(samples)
    local out = {}
    local n = #samples
    for t = 1, n do
        if t < MA_TAPS then
            out[t] = nil
        else
            local s = 0
            for k = t - MA_TAPS + 1, t do s = s + samples[k] end
            out[t] = s / MA_TAPS
        end
    end
    return out
end

-- Long-bin reducer: mean over MA5(samples)[5+1 : n-2]
-- (Lua arrays are 1-indexed; Python's t in [5, n-2) maps to t in [6, n-2] here.)
local function reduce_long(samples)
    local n = #samples
    if n < FLOW_SKIP + TAIL_SKIP + MIN_BODY_FLOW then return nil end
    local filt = ma5(samples)
    local sum, cnt = 0, 0
    -- Python [5, n-2) = indices 5..n-3 → Lua 6..n-2
    for t = FLOW_SKIP + 1, n - TAIL_SKIP do
        local v = filt[t]
        if v then sum = sum + v; cnt = cnt + 1 end
    end
    if cnt < MIN_BODY_FLOW then return nil end
    return sum / cnt
end

local function reduce_short(samples)
    if #samples < 1 then return nil end
    return samples[#samples]
end

local function median(xs)
    if #xs == 0 then return nil end
    local s = {}
    for i = 1, #xs do s[i] = xs[i] end
    table.sort(s)
    local m = #s
    if m % 2 == 1 then return s[math.floor((m + 1) / 2)] end
    return (s[math.floor(m / 2)] + s[math.floor(m / 2) + 1]) / 2
end

local function mad(xs, med)
    if #xs == 0 then return nil end
    med = med or median(xs)
    local devs = {}
    for i, x in ipairs(xs) do devs[i] = math.abs(x - med) end
    return median(devs)
end

-- Update the in-memory baselines table for a bin with a new reduction.
-- Returns updated entry, and a bool indicating whether the window was
-- actually modified (false = pop-10 rule skipped).
local function update_window(baseline_entry, new_value, flagged)
    if not baseline_entry then return nil, false end
    local n_runs_total = (baseline_entry.n_runs_total or 0) + 1
    baseline_entry.n_runs_total = n_runs_total
    local skip_window = (n_runs_total >= POP_GATE) and flagged
    if not skip_window then
        local w = baseline_entry.window or {}
        w[#w+1] = new_value
        while #w > WINDOW_N do table.remove(w, 1) end
        baseline_entry.window = w
        local m = median(w)
        baseline_entry.ref = m
        baseline_entry.ref_mad = mad(w, m)
        baseline_entry.n_window = #w
    end
    return baseline_entry, not skip_window
end

-- Write baselines.json atomically. Caller passes the parsed root table
-- (with version/schema/bins/...) — we re-serialize and replace.
local function atomic_write(path, root)
    root.generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ") .. "  (incr by robot)"
    local raw = cjson.encode(root)
    local tmp = path .. ".tmp"
    local fh, oerr = io.open(tmp, "w")
    if not fh then return false, "open tmp: " .. tostring(oerr) end
    fh:write(raw); fh:close()
    local ok, rerr = os.rename(tmp, path)
    if not ok then return false, "rename: " .. tostring(rerr) end
    return true
end

-- Determine flag for short-bin reduction. Returns:
--   flag (string) one of "KB4_SHORT_LOW", "KB4_SHORT_HIGH", or nil
--   delta (number), threshold (number)
local function score_short(last_sample, baseline_entry)
    if not baseline_entry or not baseline_entry.ref then return nil end
    local ref = baseline_entry.ref
    local ref_mad = baseline_entry.ref_mad or 0
    local thresh = math.max(SHORT_K_MAD * ref_mad, SHORT_FLOOR_GPM)
    local delta = last_sample - ref
    local abs_delta = delta >= 0 and delta or -delta
    if abs_delta > thresh then
        if delta < 0 then
            return "KB4_SHORT_LOW", delta, thresh
        else
            return "KB4_SHORT_HIGH", delta, thresh
        end
    end
    return nil, delta, thresh
end

local function cond_key(bin_key, kind) return bin_key .. ":" .. kind end

-- Edge-triggered Discord decision for short bins.
-- Updates kb4_cond_state in place. Returns event (table) or nil.
--   kind nil (within band): transitions ALL tracked kinds for this bin to "ok"
--     (silent clear of any prior fault state)
--   kind set: if state was not "fired" → fire event, set "fired"
--             if state was "fired" → suppress (still in fault), no event
local function decide_edge(bin_key, result, kb4_cond_state)
    if not kb4_cond_state then return nil end
    if result.kind == nil then
        -- This run is within band; clear all fault state for this bin.
        local prefix = bin_key .. ":"
        for k, st in pairs(kb4_cond_state) do
            if st == "fired" and k:sub(1, #prefix) == prefix then
                kb4_cond_state[k] = "ok"
            end
        end
        return nil
    end
    -- Flagged run: edge-trigger
    local ck = cond_key(bin_key, result.kind)
    if kb4_cond_state[ck] == "fired" then
        return nil   -- still in fault, suppress
    end
    kb4_cond_state[ck] = "fired"
    local sign = result.delta >= 0 and "+" or ""
    return {
        kind  = result.kind,
        level = "YELLOW",
        action = nil,
        msg = string.format(
            "KB4 short bin %s: last=%.2f GPM vs ref=%.2f (Δ%s%.2f, thresh=%.2f)  [%s]",
            bin_key, result.last, result.ref, sign, result.delta, result.threshold,
            result.kind == "KB4_SHORT_LOW" and "blocked-sprinkler candidate"
                                            or "over-spray / pipe-break candidate"),
        bin_key      = bin_key,
        last         = result.last,
        ref          = result.ref,
        delta        = result.delta,
        threshold    = result.threshold,
        n_runs_total = result.n_runs_total,
    }
end

-- Main dispatcher. Updates baselines + kb4_cond_state in place.
-- Returns (result, event, err):
--   result: {mode, reduction, updated, kind, delta, threshold, ...}
--   event: Discord event table or nil (already edge-trigger filtered)
--   err: string or nil
function M.process(bin_key, baselines_root, flow_data, kb4_cond_state)
    if not baselines_root or not baselines_root.bins then
        return nil, nil, "baselines_root missing"
    end
    -- Canonicalize: past_actions and time_history disagree on valve ordering
    -- in compound keys; baselines table is canonical-keyed on load.
    bin_key = Baselines.canonicalize_key(bin_key)
    local entry = baselines_root.bins[bin_key]
    if not entry then
        return nil, nil, "bin not in baselines: " .. bin_key
    end
    local result = { bin_key = bin_key, mode = entry.mode }

    if entry.mode == "long" then
        local body_mean = reduce_long(flow_data)
        if not body_mean then
            return { bin_key = bin_key, mode = "long", reason = "too few samples",
                     n = #flow_data }, nil
        end
        result.reduction = body_mean
        -- For long bins, no flagging in phase 1 — always update.
        local _, updated = update_window(entry, body_mean, false)
        result.updated = updated
        result.new_ref = entry.ref
        result.new_ref_mad = entry.ref_mad
        result.n_runs_total = entry.n_runs_total
        return result, nil

    elseif entry.mode == "short" then
        local last = reduce_short(flow_data)
        if not last then
            return { bin_key = bin_key, mode = "short", reason = "empty flow_data" }, nil
        end
        result.last = last
        result.ref  = entry.ref
        local kind, delta, thresh = score_short(last, entry)
        result.kind, result.delta, result.threshold = kind, delta, thresh
        local flagged = (kind ~= nil)
        local _, updated = update_window(entry, last, flagged)
        result.updated = updated
        result.new_ref = entry.ref
        result.new_ref_mad = entry.ref_mad
        result.n_runs_total = entry.n_runs_total
        local event = decide_edge(bin_key, result, kb4_cond_state)
        return result, event
    end
    return { bin_key = bin_key, mode = entry.mode, reason = "unknown mode" }, nil
end

-- Persist baselines back to disk. Called once per poll if any bin was updated.
function M.persist(baselines_root, baselines_path)
    return atomic_write(baselines_path, baselines_root)
end

return M
