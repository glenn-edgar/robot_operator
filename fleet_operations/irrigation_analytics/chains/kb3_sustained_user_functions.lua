-- chains/kb3_sustained_user_functions.lua — KB3_TICK handler.
--
-- Per tick:
--   1. Poll past_actions on private cursor for STATION_START / STEP_COMPLETE /
--      SKIP_OPERATION events. Maintain `arming` state per station.
--      - STATION_START on ETO bin → reset arming (consecutive=0, fired=false,
--        prev_elapsed=nil, bin_key=...)
--      - STATION_START on non-ETO bin → arming = nil (skip during this run)
--      - STEP_COMPLETE / SKIP_OPERATION → arming = nil
--   2. If arming is active (= ETO bin running), fetch popup.
--   3. Call KB3.evaluate_step(arming, popup.ELASPED_TIME, plc, hunter).
--      Returns one of:
--        action = "no_change"     → same minute, skip
--        action = "warmup"        → elapsed < 5, log + continue
--        action = "checked"       → evaluated, didn't fire
--        action = "FIRE"          → 3 consecutive crossed, time to actuate
--        action = "fired_already" → log only
--   4. Write evals_kb3 row for every minute-transition tick.
--   5. On FIRE: dispatch CLOSE_MASTER_VALVE + SKIP_STATION via ws_command,
--      push Discord, write runs_kb3 row.
--
-- Per-minute log lines:
--   kb3 [bin] minute=N PLC=X.X HUNTER=X.X (warmup|checked|FIRE) cons=N

local cjson         = require("cjson")
local controller    = require("controller_client")
local KB3           = require("kb3_sustained")
local KB4V2         = require("kb4_v2")    -- read-only access to baselines_kb4v2 for secondary trip
local NOTIFY        = require("notifications")
local WsCommand     = require("ws_command")
local WellDrawdown  = require("well_drawdown")   -- kept only for WAIT_JOB (the 1:39 recharge)
local FlowDeplete   = require("flow_deplete")    -- unified Hunter-only flow-depletion detector
local app_heartbeat = require("app_heartbeat")

local NOTIFY_DB_PATH = os.getenv("NOTIFY_DB_PATH") or "/var/fleet/notify/notifications.db"

local KB3_ARM_KILL = (os.getenv("KB3_ARM_KILL") == "1")
-- Separate gate for the new hydraulic trips (upstream-break divergence,
-- well-exhaustion). Default OFF so their thresholds are validated on real
-- alerts before they're allowed to close the master (Glenn 2026-06-10).
local KB3_HYDRAULIC_ARM = (os.getenv("KB3_HYDRAULIC_ARM") == "1")
-- Flow-depletion actuation gate (the unified Hunter-only detector). On trigger:
-- rpush(reinsert step) + rpush(1:39 wait) then SKIP_STATION, so the controller
-- pops [wait -> re-run step]. Default OFF = monitor-only (logs what it WOULD do).
-- Replaces the retired KB3_WELL_ARM: the old PLC well-drawdown false-skipped
-- healthy stations on the sand-fouled meter (2026-06-21), so PLC is out and the
-- Filtered Hunter is the sole trigger.
local KB3_FLOW_ARM = (os.getenv("KB3_FLOW_ARM") == "1")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC   = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY  = "fleet.notify.digest/1"
local DEFAULT_POLL_S = 30

local function log(id, fmt, ...)
    io.write(string.format("kb3_sustained [%s]: " .. fmt .. "\n", id.namespace, ...))
    io.flush()
end

local function now_ms() return os.time() * 1000 end

local function push_notify(ps, id, body)
    local payload = cjson.encode({
        schema   = SCHEMA_NOTIFY,
        class    = id.class,
        instance = id.instance,
        body     = body,
    })
    local ok, err = pcall(function() ps:publish(DIGEST_TOPIC, payload) end)
    return ok, err
end

M.one_shot.KB3_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local id, ps   = bb._identity, bb._pubsub
    local cs       = bb._class_spec
    local cfg      = (cs and cs.kb3_sustained) or {}
    local poll_s   = cfg.poll_s or DEFAULT_POLL_S
    local ssh_host = cfg.ssh_host or "pi@irrigation"
    local db_path  = cfg.db_path  or "/var/fleet/kb3/kb3.db"

    -- Threshold overrides from config (optional)
    if cfg.gpm_threshold      then KB3.GPM_THRESHOLD       = cfg.gpm_threshold end
    if cfg.warmup_minutes     then KB3.WARMUP_MINUTES      = cfg.warmup_minutes end
    if cfg.consecutive_required then KB3.CONSECUTIVE_REQUIRED = cfg.consecutive_required end

    -- Init blackboard state
    if not bb._kb3 then
        bb._kb3 = {
            db = nil,
            last_stream_id = nil,
            initialized = false,
            arming = nil,
            -- anti-loop: steps we've already done one flow-deplete clean+retry for
            -- (keyed "schedule:step"). A reinserted step that's STILL low must NOT
            -- trigger again — one clean+wait+retry per step, then let it run.
            flow_acted = {},
        }
    end
    local st = bb._kb3

    if not st.db then
        local db, err = KB3.open_db(db_path)
        if not db then
            log(id, "open_db FAILED at %s: %s", db_path, tostring(err))
            app_heartbeat.stamp(handle, "kb3_sustained", "degraded",
                "open_db failed", poll_s)
            return
        end
        st.db = db
        st.notify_db = NOTIFY.open_db(NOTIFY_DB_PATH)  -- past-actions log (shared)
        if not st.notify_db then log(id, "notifications log open failed at %s", NOTIFY_DB_PATH) end
        log(id, "db ready at %s (armed=%s, threshold=%.1f GPM, warmup=%d min, consec=%d, secondary=baseline+%.1f after n>=%d)",
            db_path, tostring(KB3_ARM_KILL),
            KB3.GPM_THRESHOLD, KB3.WARMUP_MINUTES, KB3.CONSECUTIVE_REQUIRED,
            KB3.BASELINE_DELTA_GPM, KB3.BASELINE_MIN_N_CLEAN)
    end
    local db = st.db

    -- KB4 v2 baselines DB (read-only access for secondary trip)
    if not st.kb4v2_db then
        local kb4v2_path = cfg.kb4v2_db_path or "/var/fleet/kb4v2/kb4v2.db"
        local kb4_db, kerr = KB4V2.open_db(kb4v2_path)
        if not kb4_db then
            log(id, "kb4v2 db open FAILED at %s: %s — secondary trip disabled",
                kb4v2_path, tostring(kerr))
            st.kb4v2_db = false  -- false = tried-and-failed, don't retry every tick
        else
            st.kb4v2_db = kb4_db
            log(id, "kb4v2 baselines available at %s", kb4v2_path)
        end
    end

    -- Fast-forward past_actions cursor on first tick
    if not st.initialized then
        local tip, _ = controller.past_actions_tip({
            ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8,
        })
        st.last_stream_id = tip
        st.initialized = true
        log(id, "past_actions cursor fast-forwarded to %s", tostring(tip))
    end

    -- Poll past_actions delta — process STATION_START / STEP_COMPLETE / SKIP
    local delta, _ = controller.past_actions_xrange(
        st.last_stream_id, 50,
        { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
    delta = delta or {}

    for _, ent in ipairs(delta) do
        if ent.action == "IRRIGATION_STATION_START"
           and type(ent.details) == "table" then
            local io_setup = ent.details.io_setup
            local bin_key  = KB3.bin_key(io_setup)
            if KB3.is_eto_bin(io_setup) then
                local is_city = KB3.is_city_bin(io_setup)

                -- Secondary (relative) trip: per-bin Hunter expected-flow from
                -- KB4 v2 (median of the last 7 per-run means of Hunter over min
                -- 5-15). Fires at base_hunter + 4 GPM (Glenn 2026-06-10), gated
                -- on >= BASELINE_MIN_N_CLEAN runs so a thin baseline can't
                -- false-trip — until then, primary-only (absolute Hunter > 14).
                local baseline_gpm = nil
                if st.kb4v2_db then
                    local med, n = KB4V2.load_hunter_baseline(st.kb4v2_db, bin_key, 7)
                    if med and n >= KB3.BASELINE_MIN_N_CLEAN then
                        baseline_gpm = med
                    end
                end

                st.arming = {
                    bin           = bin_key,
                    is_city       = is_city,
                    baseline_gpm  = baseline_gpm,
                    schedule      = ent.details.schedule_name,
                    station_step  = ent.details.step,
                    run_time      = tonumber(ent.details.run_time),
                    started_sid   = ent.stream_id,
                    io_setup      = io_setup,   -- kept to build the reinsert job on a trip
                    prev_elapsed  = nil,
                    consecutive   = 0,
                    fired         = false,
                    -- unified Hunter-only flow-depletion detector state (pcall-isolated)
                    flow_state    = FlowDeplete.new_station(),
                }
                log(id, "STATION_START bin=%s sched=%s step=%s (ETO%s%s — armed)",
                    bin_key,
                    tostring(ent.details.schedule_name),
                    tostring(ent.details.step),
                    is_city and ", CITY" or "",
                    baseline_gpm
                        and string.format(", baseline=%.1f GPM secondary trip @ %.1f",
                            baseline_gpm, baseline_gpm + KB3.BASELINE_DELTA_GPM)
                        or ", no baseline — primary only")
            else
                st.arming = nil
                log(id, "STATION_START bin=%s — non-ETO, skipping",
                    bin_key)
            end
        elseif ent.action == "IRRIGATION_STEP_COMPLETE"
            or ent.action == "SKIP_OPERATION" then
            if st.arming then
                log(id, "STEP_COMPLETE/SKIP bin=%s — disarming", st.arming.bin)
            end
            st.arming = nil
        end
        if ent.stream_id then st.last_stream_id = ent.stream_id end
    end

    -- If nothing armed, just heartbeat
    if not st.arming then
        app_heartbeat.stamp(handle, "kb3_sustained", "ok",
            "idle (no armed ETO bin)", poll_s)
        return
    end

    -- Fetch popup
    local popup, perr = controller.popup_get({
        ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8,
    })
    if not popup then
        log(id, "popup fetch failed: %s", tostring(perr))
        app_heartbeat.stamp(handle, "kb3_sustained", "degraded",
            "popup fetch failed", poll_s)
        return
    end

    local elapsed = tonumber(popup.ELASPED_TIME)
    local plc     = tonumber(popup.PLC_FLOW_METER)
    local hunter  = tonumber(popup.FILTERED_HUNTER_VALVE)

    -- ===================================================================
    -- UNIFIED FLOW-DEPLETION detector (Hunter-only) — Glenn 2026-06-21.
    -- Replaces BOTH old low-flow detectors (PLC well-drawdown + Hunter clog-
    -- filter) with ONE that keys off the Filtered Hunter ALONE. PLC is gone: it
    -- is sand-fouled and reads false-0 on well runs, which made the armed PLC
    -- well-drawdown false-skip 5 healthy stations (06-20/21). Whatever the cause —
    -- a clogging filter (restriction) or a well drawing down (source dying) — the
    -- symptom that matters is the SAME: delivery (Hunter) depletes. We act on the
    -- symptom; PLC can't be trusted to name the cause.
    --
    -- Runs once per new minute, pcall-isolated so a fault can NEVER disturb the
    -- armed leak path (KB3.evaluate_step) below. is_city steps EXCLUDED (a 1:39
    -- recharge/flush delivers ~0 Hunter → would false-trip; a field-checked station
    -- is city-backed too).
    --
    -- ACTION on a trip (KB3_FLOW_ARM) — ONE consistent recovery for low-flow OR a
    -- clogged filter (Glenn 2026-06-21 "i believe the filter is bad"): SKIP the step,
    -- but first rpush the recovery so the controller (rpop = front) runs it NEXT.
    -- rpush ORDER is the REVERSE of run order, so push them backwards:
    --   1. rpush(reinsert)     -- this step, re-queued to retry
    --   2. rpush(CLEAN_FILTER) -- clean the (bad) filter
    --   3. rpush(wait)         -- the 15-min 1:39 city wait (well rests / line settles)
    -- → controller pops [wait → CLEAN_FILTER → reinsert]; then SKIP_STATION ends the
    -- depleting step so the queue advances into the wait. Monitor-only (gate off) logs
    -- the exact jobs it WOULD rpush and posts nothing. One clean+retry per step (anti-loop).
    if elapsed and st.arming.flow_state and not st.arming.is_city
       and st.arming.flow_last_min ~= elapsed then
        st.arming.flow_last_min = elapsed
        pcall(function()
            local r = FlowDeplete.observe(st.arming.flow_state, hunter, elapsed,
                { baseline_gpm = st.arming.baseline_gpm, run_time = st.arming.run_time })
            if r.would_trigger then
                -- Anti-loop: if we already did one wait+retry for this step, let the
                -- reinserted run finish — a real clog/drawdown recovers after one; a
                -- step still depleting after that is the head/valve, not flow.
                local skey = tostring(st.arming.schedule or "") .. ":" .. tostring(st.arming.station_step or "")
                if st.flow_acted[skey] then
                    log(id, "flow-deplete bin=%s step=%s already acted once → NOT re-acting (anti-loop; %s)",
                        st.arming.bin, tostring(st.arming.station_step), tostring(r.reason))
                    return
                end
                st.flow_acted[skey] = true
                -- Re-run only the REMAINING time = scheduled run_time − minutes already
                -- run (Glenn 2026-06-24). The first attempt already delivered `elapsed`
                -- minutes, so re-queuing the full run_time over-waters. The ETO path
                -- couldn't fix this: a front-pushed job gets no eto_list, so the
                -- controller neither re-resolves run_time (3:1 ran 48 not 0) nor credits
                -- the deficit (stayed at 0.025). The time-difference is exact,
                -- deterministic, and needs no controller cooperation.
                local full_rt      = tonumber(st.arming.run_time) or 0
                local remaining_rt = math.max(1, full_rt - (tonumber(elapsed) or 0))
                -- byte-matched reinsert job for THIS step (remainder re-run after the wait)
                local reinsert = FlowDeplete.reinsert_job({
                    schedule = st.arming.schedule, step = st.arming.station_step,
                    io_setup = st.arming.io_setup, run_time = remaining_rt })
                if KB3_FLOW_ARM then
                    -- reverse rpush: step, then CLEAN_FILTER, then wait →
                    -- pops [wait → CLEAN_FILTER → re-run step]
                    local rok = WsCommand.queue_front(reinsert,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    local cok = WsCommand.queue_front(FlowDeplete.CLEAN_FILTER_JOB,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    local wok = WsCommand.queue_front(WellDrawdown.WAIT_JOB,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    local sok = WsCommand.post("SKIP_STATION", {
                        schedule_name = st.arming.schedule or "",
                        step          = tostring(st.arming.station_step or ""),
                        logger        = function(m) log(id, "[ws] %s", m) end })
                    log(id, "FLOW-DEPLETE ARMED bin=%s min=%s reason=%s HUNTER_med=%.1f base=%.1f ratio=%.2f reinsert_rt=%d/%d"
                        .. " → rpush reinsert(%s) + rpush CLEAN_FILTER(%s) + rpush wait(%s) + SKIP(%s)",
                        st.arming.bin, tostring(elapsed), tostring(r.reason),
                        r.hun_med or 0, r.baseline or 0, r.ratio or 0, remaining_rt, full_rt,
                        tostring(rok), tostring(cok), tostring(wok), tostring(sok))
                else
                    log(id, "FLOW-DEPLETE [monitor] bin=%s min=%s reason=%s HUNTER_med=%.1f base=%.1f ratio=%.2f"
                        .. " → WOULD rpush reinsert + rpush CLEAN_FILTER + rpush wait + SKIP (KB3_FLOW_ARM off)"
                        .. "\n    reinsert=%s\n    clean=%s\n    wait=%s",
                        st.arming.bin, tostring(elapsed), tostring(r.reason),
                        r.hun_med or 0, r.baseline or 0, r.ratio or 0,
                        reinsert, FlowDeplete.CLEAN_FILTER_JOB, WellDrawdown.WAIT_JOB)
                end
            elseif r.below then
                log(id, "flow-deplete [watch] bin=%s min=%s HUNTER=%s steady=%s base=%s ratio=%s (%s)",
                    st.arming.bin, tostring(elapsed),
                    hunter and string.format("%.1f", hunter) or "nil",
                    r.steady and string.format("%.1f", r.steady) or "-",
                    r.baseline and string.format("%.1f", r.baseline) or "-",
                    r.ratio and string.format("%.2f", r.ratio) or "-", tostring(r.reason))
            end
        end)
    end

    local result = KB3.evaluate_step(st.arming, elapsed, plc, hunter)

    -- Skip silent no-change ticks
    if result.action == "no_change" then
        app_heartbeat.stamp(handle, "kb3_sustained", "ok",
            string.format("bin=%s minute=%s (no change)",
                st.arming.bin, tostring(elapsed)),
            poll_s)
        return
    end

    -- Per-minute log line (the trace Glenn asked for). On city bins also
    -- show city_delta = FHV - PLC (positive = city water flowing).
    if st.arming.is_city and result.city_delta then
        log(id, "bin=%s minute=%s PLC=%s HUNTER=%s city_delta=%+.1f %s cons=%d",
            st.arming.bin,
            tostring(elapsed),
            plc    and string.format("%.1f", plc)    or "nil",
            hunter and string.format("%.1f", hunter) or "nil",
            result.city_delta,
            result.action,
            result.consecutive or 0)
    else
        log(id, "bin=%s minute=%s PLC=%s HUNTER=%s %s cons=%d",
            st.arming.bin,
            tostring(elapsed),
            plc    and string.format("%.1f", plc)    or "nil",
            hunter and string.format("%.1f", hunter) or "nil",
            result.action,
            result.consecutive or 0)
    end

    -- Write evaluation row
    KB3.insert_eval(db, {
        ts_ms          = now_ms(),
        bin            = st.arming.bin,
        is_city        = st.arming.is_city,
        schedule       = st.arming.schedule,
        station_step   = st.arming.station_step,
        elapsed_min    = elapsed,
        plc_gpm        = plc,
        hunter_gpm     = hunter,
        city_delta_gpm = result.city_delta,
        baseline_gpm   = result.baseline_gpm,
        trip_primary   = result.trip_primary,
        trip_secondary = result.trip_secondary,
        trip_path      = result.trip_path,
        consecutive    = result.consecutive,
        in_warmup      = result.in_warmup,
        fired          = result.fired,
        action         = result.action,
    })

    -- FIRE path — leak (Hunter) OR upstream-break (divergence) OR well-exhaustion.
    if result.action == "FIRE" then
        local ftype = result.fire_type or "leak"
        -- Actuation gate: the Hunter leak trip uses KB3_ARM_KILL; the new
        -- hydraulic trips (divergence, well) use KB3_HYDRAULIC_ARM so their
        -- thresholds can be validated on real alerts before they're armed.
        local armed = (ftype == "leak") and KB3_ARM_KILL or KB3_HYDRAULIC_ARM
        local actions_sent = {}
        if armed and ftype == "leak" then
            -- LEAK (Glenn 2026-06-15): SKIP the leaking step + insert the 15-min
            -- 1:39 wait recharge (runs NEXT). NO CLOSE_MASTER — same skip+wait the
            -- well-drawdown uses. queue_front first so the wait is the next job,
            -- then SKIP ends the leaking step.
            local jok, jcode, jerr = WsCommand.queue_front(WellDrawdown.WAIT_JOB,
                { logger = function(m) log(id, "[ws] %s", m) end })
            log(id, "ws_command queue_front(wait) → ok=%s code=%s err=%s",
                tostring(jok), tostring(jcode), tostring(jerr))
            actions_sent[#actions_sent+1] = string.format("INSERT_WAIT(%s)", tostring(jok))
            local sok, scode, serr = WsCommand.post("SKIP_STATION", {
                schedule_name = st.arming.schedule or "",
                step          = tostring(st.arming.station_step or ""),
                run_time      = "",
                logger        = function(m) log(id, "[ws] %s", m) end })
            log(id, "ws_command SKIP_STATION → ok=%s code=%s err=%s",
                tostring(sok), tostring(scode), tostring(serr))
            actions_sent[#actions_sent+1] = string.format("SKIP_STATION(%s)", tostring(sok))
        elseif armed then
            -- divergence / well-exhaustion (KB3_HYDRAULIC_ARM, monitor-only today):
            -- CLOSE_MASTER_VALVE first (water off) then SKIP_STATION.
            for _, action in ipairs({ "CLOSE_MASTER_VALVE", "SKIP_STATION" }) do
                local ok, code, err = WsCommand.post(action, {
                    schedule_name = st.arming.schedule or "",
                    step          = tostring(st.arming.station_step or ""),
                    run_time      = "",
                    logger        = function(m) log(id, "[ws] %s", m) end,
                })
                log(id, "ws_command %s → ok=%s code=%s err=%s",
                    action, tostring(ok), tostring(code), tostring(err))
                actions_sent[#actions_sent+1] = string.format("%s(%s)",
                    action, tostring(ok))
            end
        else
            log(id, "MONITOR-ONLY (%s): actuation gate off, actions suppressed", ftype)
        end

        local kind, title, trip_desc
        if ftype == "divergence" then
            kind  = "UPSTREAM_BREAK"
            title = string.format("KB3 UPSTREAM BREAK %s — PLC-Hunter div=%.1f GPM @ min %d",
                st.arming.bin, result.divergence or 0, elapsed or 0)
            trip_desc = string.format("3 consec min PLC-Hunter divergence > %.0f GPM (main-line break upstream of the zone meter)",
                KB3.DIVERGENCE_GPM)
        elseif ftype == "well" then
            kind  = "WELL_EXHAUSTION"
            title = string.format("KB3 WELL EXHAUSTION %s — PLC collapsed to %.1f GPM @ min %d",
                st.arming.bin, plc or 0, elapsed or 0)
            trip_desc = string.format("3 consec min PLC < %.0f GPM after supplying (well drawdown / dry-run risk)",
                KB3.WELL_FLOOR_GPM)
        else
            kind  = "LEAK"
            title = string.format("KB3 SUSTAINED LEAK %s — HUNTER=%.1f GPM @ min %d",
                st.arming.bin, hunter or 0, elapsed or 0)
            if result.trip_path == "secondary" then
                trip_desc = string.format("%d consec min HUNTER > %.1f GPM (secondary: baseline %.1f + %.1f) → skip + 15-min wait",
                    KB3.CONSECUTIVE_REQUIRED,
                    (result.baseline_gpm or 0) + KB3.BASELINE_DELTA_GPM,
                    result.baseline_gpm or 0, KB3.BASELINE_DELTA_GPM)
            elseif result.trip_path == "both" then
                trip_desc = string.format("%d consec min HUNTER > %.1f GPM (both primary AND secondary) → skip + 15-min wait",
                    KB3.CONSECUTIVE_REQUIRED, KB3.GPM_THRESHOLD)
            else
                trip_desc = string.format("%d consec min HUNTER > %.1f GPM (primary/absolute) → skip + 15-min wait",
                    KB3.CONSECUTIVE_REQUIRED, KB3.GPM_THRESHOLD)
            end
        end
        local city_tail = st.arming.is_city and result.city_delta
            and string.format("\ncity_delta=%+.1f GPM (FHV-PLC)", result.city_delta) or ""
        local body = string.format(
            "🚨 KB3 %s — %s%s\nschedule=%s step=%s minute=%d\nPLC=%.1f GPM  HUNTER=%.1f GPM%s\n%s\n%s",
            kind, st.arming.bin, st.arming.is_city and " [CITY]" or "",
            tostring(st.arming.schedule), tostring(st.arming.station_step),
            elapsed or 0, plc or 0, hunter or 0, city_tail, trip_desc,
            armed and ("ACTUATED: " .. table.concat(actions_sent, ", "))
                  or string.format("MONITOR-ONLY (%s actuation gate off)", ftype))
        local nok, nerr = push_notify(ps, id, body)
        if not nok then
            log(id, "Discord push FAILED: %s", tostring(nerr))
        end

        -- Past-actions log (the /irrigation/actions page reads this).
        if st.notify_db then
            NOTIFY.record(st.notify_db, {
                ts_ms  = now_ms(), level = "RED", source = "KB3", kind = kind,
                target = st.arming.bin,
                action = armed and table.concat(actions_sent, "+") or "(monitor-only)",
                title  = title,
                body   = body,
            })
        end

        KB3.insert_fire(db, {
            ts_ms          = now_ms(),
            bin            = st.arming.bin,
            is_city        = st.arming.is_city,
            schedule       = st.arming.schedule,
            station_step   = st.arming.station_step,
            elapsed_min    = elapsed,
            plc_gpm        = plc,
            hunter_gpm     = hunter,
            city_delta_gpm = result.city_delta,
            baseline_gpm   = result.baseline_gpm,
            trip_path      = ftype .. (result.trip_path and ("/" .. result.trip_path) or ""),
            actions_sent   = table.concat(actions_sent, ","),
            armed          = armed,
            note           = trip_desc,
        })

        log(id, "FIRED type=%s bin=%s minute=%d PLC=%.1f HUNTER=%.1f div=%.1f armed=%s",
            ftype, st.arming.bin, elapsed or 0, plc or 0, hunter or 0,
            result.divergence or 0, tostring(armed))
    end

    app_heartbeat.stamp(handle, "kb3_sustained", "ok",
        string.format("bin=%s minute=%s plc=%.1f hunter=%.1f cons=%d %s",
            st.arming.bin, tostring(elapsed),
            plc or 0, hunter or 0, result.consecutive or 0,
            result.action),
        poll_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
