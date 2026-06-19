-- chains/kb4_clog_user_functions.lua — KB4_TICK handler.
--
-- Per tick:
--   1. past_actions_xrange(cursor) — advance KB4-private cursor
--   2. For each new STEP_COMPLETE event:
--        a. derive sorted bin_key from io_setup
--        b. skip if ANY valve is in ETO set (deferred ETO path)
--        c. fetch TIME_HISTORY[bin] trying both key orderings
--        d. compute flow_5_15 from steady-state window
--        e. look up baseline (skip phantom bins)
--        f. classify, insert into SQLite runs table
--        g. if LEAK: publish to fleet/notify/digest/daily (Discord)
--        h. if OK: recompute baseline median across all OK rows for bin
--   3. publish heartbeat
--
-- State in blackboard under bb._kb4 for namespacing.

local cjson         = require("cjson")
local controller    = require("controller_client")
local KB4           = require("kb4_baselines")
local CoilOnset     = require("coil_onset")
local FlowWithin    = require("flow_within_run")
local FieldLog      = require("field_log")   -- manual-log baseline-reset watcher (monitor)
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC   = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY  = "fleet.notify.digest/1"
local SCHEMA_KB4     = "irrigation_analytics.kb4/1"
local DEFAULT_POLL_S = 30

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------
local function log(id, fmt, ...)
    io.write(string.format("kb4_clog [%s]: " .. fmt .. "\n", id.namespace, ...))
    io.flush()
end

local function now_ms()
    -- millisecond unix time
    local sec = os.time()
    return sec * 1000
end

local function sort_io_setup(io_setup)
    local parts = {}
    for _, s in ipairs(io_setup or {}) do
        for _, b in ipairs(s.bits or {}) do
            parts[#parts+1] = (s.remote or "?") .. ":" .. tostring(b)
        end
    end
    table.sort(parts)
    return table.concat(parts, "/")
end

local function unsorted_io_setup(io_setup)
    local parts = {}
    for _, s in ipairs(io_setup or {}) do
        for _, b in ipairs(s.bits or {}) do
            parts[#parts+1] = (s.remote or "?") .. ":" .. tostring(b)
        end
    end
    return table.concat(parts, "/")
end

-- Fetch the newest TIME_HISTORY entry for a bin. Returns FULL record
-- with all sensor channels (HUNTER_FLOW_METER, IRRIGATION_CURRENT, …).
-- Auto-handles the two-key-orderings gotcha by canonical-sort comparison
-- on the controller side (same pattern as controller_client.time_history_bin
-- but returns the full record instead of a summary).
local function fetch_th(opts, bin_key)
    local TH_DB  = 4
    local TH_KEY = "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT][IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL][PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]"
    local py = string.format([[
import redis, msgpack, json, sys
r = redis.Redis(db=%d)
KEY = %q
WANT = sorted(%q.split("/"))
v = r.hget(KEY, %q)
if v is None:
    for field in r.hkeys(KEY):
        f = field.decode() if isinstance(field, bytes) else field
        if sorted(f.split("/")) == WANT:
            v = r.hget(KEY, field); break
if v is None:
    sys.stdout.write(json.dumps({"_error": "bin not found"})); sys.exit(0)
runs = msgpack.unpackb(v, raw=False)
if not runs:
    sys.stdout.write(json.dumps({"_error": "empty runs"})); sys.exit(0)
sys.stdout.write(json.dumps(runs[-1], default=str))
]], TH_DB, TH_KEY, bin_key, bin_key)
    -- Use the SSH runner inside controller_client (private helper) via
    -- a small wrapper: write py to a temp file and invoke ssh.
    local tmp = os.tmpname()
    local f = io.open(tmp, "w"); if not f then return nil end
    f:write(py); f:close()
    local cmd = string.format(
        "ssh -o ConnectTimeout=%d -o BatchMode=yes %s 'python3 -' < %s 2>/dev/null",
        opts.timeout_s or 8, opts.ssh_host or "pi@irrigation", tmp)
    local pipe = io.popen(cmd, "r")
    if not pipe then os.remove(tmp); return nil end
    local raw = pipe:read("*a"); pipe:close(); os.remove(tmp)
    if not raw or raw == "" then return nil end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or not decoded or decoded._error then return nil end
    return decoded
end

-- ----------------------------------------------------------------------
-- KB4_TICK — invoked each cycle
-- ----------------------------------------------------------------------
function M.one_shot.KB4_TICK(handle, params)
    local bb  = handle.blackboard
    local id  = bb._identity
    local ps  = bb._pubsub
    local cfg = (bb._class_spec and bb._class_spec.kb4_clog) or {}
    local kb_label = "kb4_clog/" .. (id.instance or "?")
    local poll_s = cfg.poll_s or DEFAULT_POLL_S

    -- One-time init
    if not bb._kb4 then
        bb._kb4 = { cursor = nil, runs_processed = 0, runs_flagged = 0 }

        local db_path = cfg.db_path or "/var/fleet/kb4/kb4.db"
        os.execute("mkdir -p " .. (db_path:match("(.*/)") or "/var/fleet/kb4/"))
        local db, err = KB4.open_db(db_path)
        if not db then
            log(id, "FATAL: SQLite open failed: %s", tostring(err))
            app_heartbeat.stamp(handle, kb_label, "degraded", err, poll_s)
            return
        end
        bb._kb4.db = db

        local seeded, seed_err = KB4.seed_baselines_if_empty(
            db, cfg.seed_path or "/app/irrigation_analytics/data/kb4_nonETO_baselines.json",
            now_ms())
        if seed_err then
            log(id, "WARN: non-ETO baseline seed: %s", tostring(seed_err))
        end
        if seeded and seeded > 0 then
            log(id, "seeded %d non-ETO baseline rows", seeded)
        end

        local seeded_eto, seed_eto_err = KB4.seed_baselines_eto_if_empty(
            db, cfg.seed_eto_path or "/app/irrigation_analytics/data/kb4_ETO_baselines.json",
            now_ms())
        if seed_eto_err then
            log(id, "WARN: ETO baseline seed: %s", tostring(seed_eto_err))
        end
        if seeded_eto and seeded_eto > 0 then
            log(id, "seeded %d ETO baseline rows", seeded_eto)
        end

        local eto_set, eto_err = KB4.load_eto_valves(
            cfg.eto_valves_path or "/app/irrigation_analytics/data/eto_valves.json")
        if not eto_set then
            log(id, "FATAL: ETO valves load: %s", tostring(eto_err))
            app_heartbeat.stamp(handle, kb_label, "degraded", eto_err, poll_s)
            return
        end
        bb._kb4.eto_set = eto_set
        local n = 0; for _ in pairs(eto_set) do n = n + 1 end
        log(id, "loaded %d ETO valves; db ready at %s", n, db_path)

        -- Solenoid onset-signature monitor (monitor-only; see lib/coil_onset).
        local ok_co = pcall(CoilOnset.ensure_schema, db)
        if not ok_co then log(id, "WARN: coil_onset schema init failed") end
        -- Within-run flow time-bin monitor (monitor-only; lib/flow_within_run).
        local ok_fw = pcall(FlowWithin.ensure_schema, db)
        if not ok_fw then log(id, "WARN: flow_within schema init failed") end
        -- Manual-log baseline-reset watcher (monitor-only; lib/field_log).
        local ok_fl = pcall(FieldLog.ensure_schema, db)
        if not ok_fl then log(id, "WARN: field_log schema init failed") end
    end

    -- Manual-log watcher: scan clog_observations for new field-maintenance
    -- actions and log what baselines they WOULD reset (monitor-only, isolated).
    pcall(function()
        local nf = FieldLog.scan(bb._kb4.db, now_ms(),
            function(fmt, ...) log(id, fmt, ...) end)
        if nf and nf > 0 then log(id, "field-log: %d new field-action row(s)", nf) end
    end)

    local kb4 = bb._kb4
    local opts = {
        ssh_host  = cfg.ssh_host or "pi@irrigation",
        timeout_s = cfg.timeout_s or 8,
    }

    -- Fast-forward cursor on first tick
    if not kb4.cursor then
        local ok_tip, tip = pcall(controller.past_actions_tip, opts)
        if ok_tip and tip then
            kb4.cursor = tip
            log(id, "past_actions cursor fast-forwarded to %s", tostring(tip))
        else
            log(id, "WARN: past_actions_tip failed; will pull from earliest on next tick")
            kb4.cursor = nil
        end
        app_heartbeat.stamp(handle, kb_label, "ok",
            "cursor armed", poll_s)
        return
    end

    -- Pull new events. API: past_actions_xrange(last_id, count_max, opts)
    local ok, entries, err = pcall(controller.past_actions_xrange,
        kb4.cursor, 200, opts)
    if not ok or not entries then
        log(id, "WARN: past_actions fetch failed: %s", tostring(err or entries))
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "past_actions fetch fail", poll_s)
        return
    end

    local n_processed, n_flagged = 0, 0
    local newest_sid = kb4.cursor
    for _, e in ipairs(entries) do
        if e.stream_id and e.stream_id > (newest_sid or "") then newest_sid = e.stream_id end
        if e.action == "IRRIGATION_STEP_COMPLETE" then
            local det = e.details or {}
            local bin_sorted = sort_io_setup(det.io_setup)
            local bin_original = unsorted_io_setup(det.io_setup)
            if bin_sorted ~= "" then
                local is_non_eto = KB4.bin_is_non_eto(bin_sorted, kb4.eto_set)
                if not is_non_eto then
                    -- ETO PATH — 4 activities per kb4-eto-spec-2026-06-05.
                    n_processed = n_processed + 1
                    local bl_eto = KB4.get_baseline_eto(kb4.db, bin_sorted)
                    local th_entry = fetch_th(opts, bin_sorted)
                    if not th_entry then
                        log(id, "ETO no TH for %s", bin_sorted)
                    else
                        local flow_series = (th_entry.HUNTER_FLOW_METER or {}).data or {}
                        local curr_series = (th_entry.IRRIGATION_CURRENT or {}).data or {}
                        -- monitor-only solenoid onset signature (never breaks KB4).
                        -- step/schedule tag the run's cycle for the per-coil
                        -- decomposition monitor (group runs into cycles).
                        pcall(CoilOnset.record, kb4.db, bin_sorted,
                            tonumber(e.stream_id:match("^(%d+)")) or now_ms(),
                            e.stream_id, curr_series, det.step, det.schedule_name)
                        -- monitor-only within-run flow time-bin signature
                        -- (steady 5-15 level + within-run flatness + end-droop;
                        -- clog-trend analysis is read-time, see lib/flow_within_run)
                        pcall(FlowWithin.record, kb4.db, bin_sorted,
                            tonumber(e.stream_id:match("^(%d+)")) or now_ms(),
                            e.stream_id, flow_series)
                        local metrics = KB4.compute_eto_metrics(flow_series)
                        if not metrics then
                            log(id, "ETO too-short for window: %s (n=%d)",
                                bin_sorted, #flow_series)
                        else
                            local curr = KB4.compute_flow_window(curr_series) or 0
                            local cls_gal, d_gal = KB4.classify_eto_gallons(
                                metrics.gallons_5_15, bl_eto and bl_eto.gallons_5_15_med)
                            local cls_gpm, d_gpm = KB4.classify_eto_gpm(metrics, bl_eto)
                            local ts_ms = tonumber(e.stream_id:match("^(%d+)")) or now_ms()
                            local rec = {
                                ts_ms = ts_ms, sid = e.stream_id, bin = bin_sorted,
                                schedule = det.schedule_name or "",
                                step = det.step or 0,
                                run_time_m = det.run_time or 0,
                                flow_5_15 = metrics.flow_5_15,
                                gallons_5_15 = metrics.gallons_5_15,
                                slope = metrics.slope,
                                intercept = metrics.intercept,
                                wiggle_mad = metrics.wiggle_mad,
                                curr_5_15 = curr,
                                cls_gallons = cls_gal,
                                cls_gpm = cls_gpm,
                                delta_gallons = d_gal or 0,
                                delta_intercept = (d_gpm and d_gpm.d_intercept) or 0,
                                delta_slope = (d_gpm and d_gpm.d_slope) or 0,
                                delta_wiggle = (d_gpm and d_gpm.d_wiggle) or 0,
                            }
                            KB4.insert_run_eto(kb4.db, rec)
                            -- Update baseline only when BOTH classifications are OK
                            if bl_eto and cls_gal == "OK" and cls_gpm == "OK" then
                                KB4.update_baseline_eto_running_median(
                                    kb4.db, bin_sorted, now_ms())
                            end
                            -- Discord on ALERT-tier
                            local is_alert = (cls_gal == "BLOCKED_ALERT")
                                or (cls_gpm == "LEAK_ALERT")
                                or (cls_gpm == "WELL_UNSTABLE_ALERT")
                            if is_alert then
                                n_flagged = n_flagged + 1
                                local human
                                if cls_gpm == "LEAK_ALERT" then
                                    human = string.format(
                                        "🚨 %s LEAK — flow %.1f GPM (baseline %.2f, +%.1f). " ..
                                        "Schedule %s, %d min. Check for broken sprinkler / popped head / pipe break.",
                                        bin_sorted, metrics.intercept,
                                        bl_eto and bl_eto.intercept_med or 0,
                                        d_gpm.d_intercept, rec.schedule, rec.run_time_m)
                                elseif cls_gal == "BLOCKED_ALERT" then
                                    human = string.format(
                                        "🚨 %s BLOCKED — gallons %.0f (baseline %.0f, short %.0f). " ..
                                        "Schedule %s, %d min. Likely clogged sprinkler heads.",
                                        bin_sorted, metrics.gallons_5_15,
                                        bl_eto and bl_eto.gallons_5_15_med or 0,
                                        d_gal, rec.schedule, rec.run_time_m)
                                else  -- WELL_UNSTABLE_ALERT
                                    human = string.format(
                                        "🚨 %s WELL UNSTABLE — wiggle %.2f GPM (baseline %.2f, +%.2f). " ..
                                        "Schedule %s. Well delivering unsteady pressure — check well / pump / pressure tank. NOT a valve fault.",
                                        bin_sorted, metrics.wiggle_mad,
                                        bl_eto and bl_eto.wiggle_med or 0,
                                        d_gpm.d_wiggle, rec.schedule)
                                end
                                local payload = cjson.encode({
                                    schema = SCHEMA_NOTIFY,
                                    when = os.time(),
                                    instance = id.instance,
                                    class = id.class,
                                    kind = (cls_gpm ~= "OK") and cls_gpm or cls_gal,
                                    level = "RED",
                                    msg = human,
                                    bin = bin_sorted,
                                    metrics = metrics,
                                    schedule = rec.schedule,
                                })
                                if ps then
                                    local ok_pub, err_pub = pcall(function()
                                        ps:publish(DIGEST_TOPIC, payload)
                                    end)
                                    if not ok_pub then
                                        log(id, "ETO Discord publish failed: %s", tostring(err_pub))
                                    end
                                end
                                log(id, "ETO ALERT %s gal=%s gpm=%s",
                                    bin_sorted, cls_gal, cls_gpm)
                            elseif cls_gal ~= "OK" or cls_gpm ~= "OK" then
                                n_flagged = n_flagged + 1
                                log(id, "ETO warn %s gal=%s(Δ%.1f) gpm=%s",
                                    bin_sorted, cls_gal, d_gal or 0, cls_gpm)
                            end
                        end
                    end
                elseif is_non_eto then
                    -- NON-ETO PATH (existing absolute ±3/+5 GPM thresholds)
                    n_processed = n_processed + 1
                    -- Get baseline first to short-circuit phantoms cheaply
                    local bl = KB4.get_baseline(kb4.db, bin_sorted)
                    if bl and bl.phantom == 1 then
                        log(id, "skip phantom bin %s", bin_sorted)
                    else
                        -- Fetch TIME_HISTORY for this bin
                        local th_entry = fetch_th(opts, bin_sorted)
                        if not th_entry then
                            log(id, "no TH for %s (tried sorted+original)", bin_sorted)
                        else
                            local flow_series = (th_entry.HUNTER_FLOW_METER or {}).data or {}
                            local curr_series = (th_entry.IRRIGATION_CURRENT or {}).data or {}
                            -- monitor-only solenoid onset signature (never breaks KB4)
                            pcall(CoilOnset.record, kb4.db, bin_sorted,
                                tonumber(e.stream_id:match("^(%d+)")) or now_ms(),
                                e.stream_id, curr_series, det.step, det.schedule_name)
                            -- Non-ETO = LAST value of the run (Glenn 2026-06-10):
                            -- short bins never reach a steady window; the end value
                            -- is the per-run flow. Baseline seed is computed the same.
                            local flow = KB4.last_value(flow_series)
                            local total_gal = KB4.compute_total_gal(flow_series)
                            local curr = KB4.last_value(curr_series) or 0
                            if not flow then
                                log(id, "no flow samples: %s (n=%d)",
                                    bin_sorted, #flow_series)
                            else
                                local baseline_med = bl and bl.flow_med or nil
                                local cls, delta = KB4.classify(flow, baseline_med)
                                -- Parse sid timestamp (ms)
                                local ts_ms = tonumber(e.stream_id:match("^(%d+)")) or now_ms()
                                local rec = {
                                    ts_ms = ts_ms, sid = e.stream_id,
                                    bin = bin_sorted,
                                    schedule = det.schedule_name or "",
                                    step = det.step or 0,
                                    run_time_m = det.run_time or 0,
                                    flow_5_15 = flow, curr_5_15 = curr,
                                    total_gal = total_gal,
                                    baseline_used = baseline_med,
                                    delta = delta, cls = cls,
                                }
                                KB4.insert_run(kb4.db, rec)
                                if cls == "OK" and baseline_med then
                                    KB4.update_baseline_running_median(
                                        kb4.db, bin_sorted, now_ms())
                                end
                                if cls == "LEAK" then
                                    n_flagged = n_flagged + 1
                                    local human = string.format(
                                        "🚨 %s LEAK — flow %.1f GPM (baseline %.2f, Δ+%.1f). " ..
                                        "Schedule %s, %d min. Check for broken sprinkler / popped head / pipe break.",
                                        bin_sorted, flow, baseline_med, delta,
                                        rec.schedule, rec.run_time_m)
                                    -- Publish digest event
                                    local payload = cjson.encode({
                                        schema = SCHEMA_NOTIFY,
                                        when = os.time(),
                                        instance = id.instance,
                                        class = id.class,
                                        kind = "irrigation_kb4_leak",
                                        level = "RED",
                                        msg = human,
                                        bin = bin_sorted,
                                        flow_gpm = flow,
                                        baseline = baseline_med,
                                        delta = delta,
                                        schedule = rec.schedule,
                                    })
                                    if ps then
                                        local ok_pub, err_pub = pcall(function()
                                            ps:publish(DIGEST_TOPIC, payload)
                                        end)
                                        if not ok_pub then
                                            log(id, "Discord publish failed: %s", tostring(err_pub))
                                        end
                                    end
                                    log(id, "LEAK %s flow=%.1f bl=%.2f Δ+%.1f",
                                        bin_sorted, flow, baseline_med, delta)
                                elseif cls ~= "OK" then
                                    n_flagged = n_flagged + 1
                                    log(id, "%s %s flow=%.1f bl=%.2f Δ%+.1f (DB warn)",
                                        cls, bin_sorted, flow,
                                        baseline_med or 0, delta)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    kb4.cursor = newest_sid
    kb4.runs_processed = kb4.runs_processed + n_processed
    kb4.runs_flagged = kb4.runs_flagged + n_flagged

    if n_processed > 0 then
        log(id, "tick: %d non-ETO STEP_COMPLETEs processed (%d flagged), cursor=%s",
            n_processed, n_flagged, kb4.cursor)
    end

    app_heartbeat.stamp(handle, kb_label, "ok",
        string.format("processed=%d flagged=%d", kb4.runs_processed, kb4.runs_flagged),
        poll_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
