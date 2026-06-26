-- lib/field_log.lua — manual-log baseline-reset watcher.
--
-- Runs inside kb4_clog's tick (it already owns kb4.db + clog_observations +
-- the baselines), so this is just a function — NO separate KB. When field
-- maintenance changes the physical system, the operator logs a per-valve
-- `action` via the dashboard (/irrigation/check -> clog_observations.action).
-- This scans for new action rows and resets the detector baselines that the
-- physical change invalidated, so a repair doesn't leave a stale baseline.
--
-- ARMING: monitor-only unless env FIELD_LOG_ARM=1. Monitor logs "WOULD reset ...".
-- Armed applies the reset (and sets clog_observations.action_applied=1).
--
-- The catch-22 it solves: the ETO baseline is the median of the bin's
-- cls='OK' runs_eto rows, but a post-change run is classified against the OLD
-- baseline (so a big change classifies BLOCKED/LEAK and never counts toward the
-- new median). So a flow rebaseline computes the new median DIRECTLY from
-- post-change runs (ignoring cls), then deletes the pre-change history. It
-- DEFERS until >= MIN_POST post-change runs exist (the action stays unapplied,
-- re-checked each tick, until the first post-change irrigation lands).
--
-- Idempotency: `manual_reset_log` records every obs row; applied=1 once done.
-- See [[irrigation-manual-log-reset-robot]].

local M = {}

M.ARMED    = (os.getenv("FIELD_LOG_ARM") == "1")
M.MIN_POST = 2   -- post-change runs needed before a flow rebaseline

-- action -> reset plan description.
M.PLAN = {
    cap_heads        = "rebaseline flow to post-change normal + clear watch",
    clean_heads      = "rebaseline flow (re-learn up) + clear watch",
    replace_valve    = "rebaseline flow + reset coil_onset + clear watch",
    replace_solenoid = "reset coil_onset + clear watch (kb2 R resets on deploy)",
    repair_leak      = "clear leak watch (flow returns to baseline on its own)",
    inspect_ok       = nil,
    other            = nil,
}

local NEEDS_FLOW  = { cap_heads = true, clean_heads = true, replace_valve = true }
local NEEDS_COIL  = { replace_valve = true, replace_solenoid = true }
local NEEDS_WATCH = { cap_heads = true, clean_heads = true, repair_leak = true,
                      replace_valve = true, replace_solenoid = true }

function M.ensure_schema(db)
    db:exec([[
        CREATE TABLE IF NOT EXISTS manual_reset_log (
            obs_id   INTEGER PRIMARY KEY,
            ts_ms    INTEGER,
            bin      TEXT,
            action   TEXT,
            plan     TEXT,
            applied  INTEGER DEFAULT 0
        );
    ]])
end

local function q(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

local function median(xs)
    if #xs == 0 then return nil end
    table.sort(xs)
    return xs[math.floor(#xs / 2) + 1]
end

-- Flow rebaseline from post-change runs. Returns (done, n_post). done=false with
-- n_post<MIN_POST means DEFER. Handles ETO (baselines_eto/runs_eto) and non-ETO
-- (baselines/runs). since_ts = the field-check time (pre-change cutoff).
local function rebaseline_flow(db, bin, since_ts)
    -- ETO?
    local is_eto = false
    for r in db:nrows("SELECT 1 AS x FROM baselines_eto WHERE bin=" .. q(bin)) do is_eto = true end
    if is_eto then
        local f, g, sl, ic, wg, cu = {}, {}, {}, {}, {}, {}
        local n = 0
        for r in db:nrows(string.format(
            "SELECT flow_5_15,gallons_5_15,slope,intercept,wiggle_mad,curr_5_15 " ..
            "FROM runs_eto WHERE bin=%s AND ts_ms>=%d", q(bin), since_ts)) do
            n = n + 1
            f[#f+1]=r.flow_5_15; g[#g+1]=r.gallons_5_15; sl[#sl+1]=r.slope
            ic[#ic+1]=r.intercept; wg[#wg+1]=r.wiggle_mad; cu[#cu+1]=r.curr_5_15
        end
        if n < M.MIN_POST then return false, n end
        db:exec(string.format([[UPDATE baselines_eto SET
            flow_5_15_med=%f, gallons_5_15_med=%f, slope_med=%f, intercept_med=%f,
            wiggle_med=%f, curr_med=%f, n_healthy=%d, note=%s
            WHERE bin=%s]],
            median(f) or 0, median(g) or 0, median(sl) or 0, median(ic) or 0,
            median(wg) or 0, median(cu) or 0, n,
            q("field-reset " .. os.date("!%m-%d")), q(bin)))
        db:exec(string.format("DELETE FROM runs_eto WHERE bin=%s AND ts_ms<%d", q(bin), since_ts))
        return true, n
    else
        -- non-ETO: baselines.flow_med over runs.flow_5_15
        local fl = {}; local n = 0
        for r in db:nrows(string.format(
            "SELECT flow_5_15 FROM runs WHERE bin=%s AND ts_ms>=%d", q(bin), since_ts)) do
            n = n + 1; fl[#fl+1] = r.flow_5_15
        end
        if n < M.MIN_POST then return false, n end
        db:exec(string.format(
            "UPDATE baselines SET flow_med=%f, n_healthy=%d, note=%s WHERE bin=%s",
            median(fl) or 0, n, q("field-reset " .. os.date("!%m-%d")), q(bin)))
        db:exec(string.format("DELETE FROM runs WHERE bin=%s AND ts_ms<%d", q(bin), since_ts))
        return true, n
    end
end

local function reset_coil(db, bin)
    db:exec("DELETE FROM coil_onset_baseline WHERE valve=" .. q(bin))
    db:exec("DELETE FROM coil_onset WHERE valve=" .. q(bin))
end

local function clear_watch(db, bin)
    db:exec("DELETE FROM watch_list WHERE valve=" .. q(bin))
end

-- Apply one action's reset. Returns (applied, detail). applied=false => deferred.
local function apply_reset(db, bin, action, check_ts)
    local parts = {}
    if NEEDS_FLOW[action] then
        local done, n = rebaseline_flow(db, bin, check_ts or 0)
        if not done then
            return false, string.format("DEFER flow rebaseline (%d/%d post-change runs)", n, M.MIN_POST)
        end
        parts[#parts+1] = string.format("flow rebaselined (%d post-change runs)", n)
    end
    if NEEDS_COIL[action] then
        reset_coil(db, bin); parts[#parts+1] = "coil_onset reset"
        -- replace_solenoid / replace_valve also clears the latched BAD flag KB1 set
        -- on an irrigation-current spike (the new coil is presumed good).
        pcall(function()
            local BS = require("bad_sprinklers")
            local bdb = BS.open()
            if bdb then
                local cleared = BS.clear(bdb, bin, (check_ts and check_ts ~= 0) and check_ts or 0)
                bdb:close()
                if cleared and cleared > 0 then parts[#parts+1] = "bad-solenoid flag cleared" end
            end
        end)
    end
    if NEEDS_WATCH[action] then clear_watch(db, bin); parts[#parts+1] = "watch cleared" end
    if #parts == 0 then parts[#parts+1] = "no-op (record only)" end
    return true, table.concat(parts, "; ")
end

-- Scan clog_observations for action rows and reset (or log would-reset). db is an
-- already-open kb4.db. log is log(fmt, ...). Returns number of rows handled.
function M.scan(db, now_ms, log)
    if not db then return 0 end
    local pending = {}
    local ok = pcall(function()
        for r in db:nrows([[
            SELECT co.id AS oid, co.bin AS bin, co.action AS action,
                   COALESCE(fc.ts_ms, 0) AS check_ts
            FROM clog_observations co
            LEFT JOIN field_checks fc ON fc.id = co.check_id
            WHERE co.action IS NOT NULL AND co.action != ''
              AND (co.action_applied IS NULL OR co.action_applied = 0)
              AND co.id NOT IN (SELECT obs_id FROM manual_reset_log WHERE applied = 1)
            ORDER BY co.id ]]) do
            pending[#pending + 1] = r
        end
    end)
    if not ok then return 0 end

    local n = 0
    for _, r in ipairs(pending) do
        local plan_txt = M.PLAN[r.action]
        if not M.ARMED then
            if log then
                log("MANUAL-LOG [monitor] obs=%d bin=%s action=%s -> WOULD %s",
                    r.oid, tostring(r.bin), tostring(r.action),
                    plan_txt or "no reset (record only)")
            end
            db:exec(string.format(
                "INSERT OR IGNORE INTO manual_reset_log(obs_id,ts_ms,bin,action,plan,applied) " ..
                "VALUES(%d,%d,%s,%s,%s,0)",
                r.oid, now_ms, q(r.bin), q(r.action), q(plan_txt or "record only")))
        else
            local applied, detail = apply_reset(db, r.bin, r.action, r.check_ts)
            if applied then
                db:exec(string.format("UPDATE clog_observations SET action_applied=1 WHERE id=%d", r.oid))
                db:exec(string.format(
                    "INSERT OR REPLACE INTO manual_reset_log(obs_id,ts_ms,bin,action,plan,applied) " ..
                    "VALUES(%d,%d,%s,%s,%s,1)",
                    r.oid, now_ms, q(r.bin), q(r.action), q(detail)))
                if log then
                    log("MANUAL-LOG [APPLIED] obs=%d bin=%s action=%s -> %s",
                        r.oid, tostring(r.bin), tostring(r.action), detail)
                end
            else
                if log then
                    log("MANUAL-LOG [deferred] obs=%d bin=%s action=%s -> %s",
                        r.oid, tostring(r.bin), tostring(r.action), detail)
                end
            end
        end
        n = n + 1
    end
    return n
end

return M
