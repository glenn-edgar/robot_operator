-- chains/kb5_filter_user_functions.lua — KB5_TICK handler.
--
-- KB5 = the PLC-source FILTER-LOAD detector (Glenn 2026-06-26 plan). The
-- complement to kb3's Hunter-only flow_deplete: it acts on the bins flow_deplete
-- does NOT (city OR non-ETO), and it keys off the PLC well-source meter with a
-- mandatory Hunter cross-check. PLC + Hunter falling in LOCKSTEP = filter/line
-- restriction → CLEAN_FILTER. Detector: lib/plc_filter.lua. DB: lib/kb5_filter.lua.
--
-- Per tick:
--   1. Poll past_actions delta. On STATION_START, classify the bin:
--        gate-in = is_city OR not is_eto_bin → arm (fresh plc_filter state).
--        otherwise (ETO non-city, flow_deplete's territory) → disarm.
--      STEP_COMPLETE / SKIP_OPERATION → disarm.
--   2. If armed, fetch popup; on each NEW minute call PlcFilter.observe(plc,hunter).
--   3. On would_trigger:
--        - 90-min GLOBAL rate gate (persisted last_fire_ms): a CLEAN_FILTER is a
--          global action; one per 90 min is plenty (filter doesn't re-clog faster).
--        - per-step anti-loop (one clean+retry per step).
--        RECOVERY (only when KB5_FILTER_ARM): reverse rpush so the controller
--        (rpop = front) runs [wait → CLEAN_FILTER → reinsert-remainder], then SKIP.
--          1. rpush(reinsert)     -- this step, remaining run_time = run_time − onset
--          2. rpush(CLEAN_FILTER) -- clean the loaded filter
--          3. rpush(wait)         -- 15-min 1:39 city wait (line settles)
--        Monitor mode logs exactly what it WOULD do and consumes NO cooldown.
--   4. Write an evals_kb5 row each minute; a runs_kb5 row on each (would-)fire.
--
-- Reuses flow_deplete.CLEAN_FILTER_JOB / reinsert_job and well_drawdown.WAIT_JOB
-- (byte-matched controller wire format) and ws_command (the live POST path).

local cjson         = require("cjson")
local controller    = require("controller_client")
local KB3           = require("kb3_sustained")   -- bin classification helpers (is_eto/is_city/bin_key)
local KB5           = require("kb5_filter")       -- this KB's db layer
local PlcFilter     = require("plc_filter")       -- the PLC filter-load detector
local NOTIFY        = require("notifications")
local WsCommand     = require("ws_command")
local WellDrawdown  = require("well_drawdown")    -- WAIT_JOB (the 1:39 recharge)
local FlowDeplete   = require("flow_deplete")     -- CLEAN_FILTER_JOB + reinsert_job
local app_heartbeat = require("app_heartbeat")

local NOTIFY_DB_PATH = os.getenv("NOTIFY_DB_PATH") or "/var/fleet/notify/notifications.db"

-- Actuation gate. Default OFF = monitor-only (validate on real filter-load
-- cycles before arming — like every other detector here). When on, the recovery
-- (wait + CLEAN_FILTER + rpush remainder + SKIP) fires.
local KB5_FILTER_ARM = (os.getenv("KB5_FILTER_ARM") == "1")

-- Global rate gate: at most one filter clean per this window. Persisted across
-- restarts via kb5_meta.last_fire_ms. Env-overridable for testing.
local COOLDOWN_MS = (tonumber(os.getenv("KB5_COOLDOWN_MIN") or "90")) * 60 * 1000

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC   = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY  = "fleet.notify.digest/1"
local DEFAULT_POLL_S = 30

local function log(id, fmt, ...)
    io.write(string.format("kb5_filter [%s]: " .. fmt .. "\n", id.namespace, ...))
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

M.one_shot.KB5_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local id, ps   = bb._identity, bb._pubsub
    local cs       = bb._class_spec
    local cfg      = (cs and cs.kb5_filter) or {}
    local poll_s   = cfg.poll_s or DEFAULT_POLL_S
    local ssh_host = cfg.ssh_host or "pi@irrigation"
    local db_path  = cfg.db_path  or "/var/fleet/kb5/kb5.db"

    -- Optional tunable overrides from config
    if cfg.plc_drop_frac then PlcFilter.PLC_DROP_FRAC = cfg.plc_drop_frac end
    if cfg.hun_drop_frac then PlcFilter.HUN_DROP_FRAC = cfg.hun_drop_frac end
    if cfg.onset_consec  then PlcFilter.ONSET_CONSEC  = cfg.onset_consec  end

    -- Init blackboard state
    if not bb._kb5 then
        bb._kb5 = {
            db = nil, last_stream_id = nil, initialized = false, arming = nil,
            -- anti-loop: steps we've already done one filter clean+retry for
            -- (keyed "schedule:step"). A reinserted step that's STILL low must NOT
            -- re-trigger — one clean+retry per step, then let it run.
            flow_acted = {},
        }
    end
    local st = bb._kb5

    if not st.db then
        local db, err = KB5.open_db(db_path)
        if not db then
            log(id, "open_db FAILED at %s: %s", db_path, tostring(err))
            app_heartbeat.stamp(handle, "kb5_filter", "degraded", "open_db failed", poll_s)
            return
        end
        st.db = db
        st.last_fire_ms = KB5.get_last_fire_ms(db)
        st.notify_db = NOTIFY.open_db(NOTIFY_DB_PATH)
        if not st.notify_db then log(id, "notifications log open failed at %s", NOTIFY_DB_PATH) end
        log(id, "db ready at %s (armed=%s, plc_drop<%.2f×steady AND hun_drop<%.2f×steady, consec=%d, cooldown=%dmin, last_fire=%s)",
            db_path, tostring(KB5_FILTER_ARM),
            PlcFilter.PLC_DROP_FRAC, PlcFilter.HUN_DROP_FRAC, PlcFilter.ONSET_CONSEC,
            COOLDOWN_MS / 60000, tostring(st.last_fire_ms))
    end
    local db = st.db

    -- Fast-forward past_actions cursor on first tick
    if not st.initialized then
        local tip, _ = controller.past_actions_tip({
            ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
        st.last_stream_id = tip
        st.initialized = true
        log(id, "past_actions cursor fast-forwarded to %s", tostring(tip))
    end

    -- Poll past_actions delta — STATION_START / STEP_COMPLETE / SKIP
    local delta, _ = controller.past_actions_xrange(
        st.last_stream_id, 50,
        { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
    delta = delta or {}

    for _, ent in ipairs(delta) do
        if ent.action == "IRRIGATION_STATION_START"
           and type(ent.details) == "table" then
            local io_setup = ent.details.io_setup
            local bin_key  = KB3.bin_key(io_setup)
            local is_city  = KB3.is_city_bin(io_setup)
            local is_eto   = KB3.is_eto_bin(io_setup)
            -- gate-in = the complement of flow_deplete's ETO-non-city scope.
            if is_city or (not is_eto) then
                st.arming = {
                    bin          = bin_key,
                    is_city      = is_city,
                    is_eto       = is_eto,
                    schedule     = ent.details.schedule_name,
                    station_step = ent.details.step,
                    run_time     = tonumber(ent.details.run_time),
                    io_setup     = io_setup,   -- to build the reinsert job on a trip
                    flow_last_min = nil,
                    plc_state    = PlcFilter.new_station(),
                }
                log(id, "STATION_START bin=%s sched=%s step=%s (%s%s — armed)",
                    bin_key, tostring(ent.details.schedule_name),
                    tostring(ent.details.step),
                    is_city and "CITY" or "non-city",
                    is_eto and ", ETO" or ", non-ETO")
            else
                st.arming = nil
                log(id, "STATION_START bin=%s — ETO non-city (flow_deplete's scope), skipping", bin_key)
            end
        elseif ent.action == "IRRIGATION_STEP_COMPLETE"
            or ent.action == "SKIP_OPERATION" then
            if st.arming then log(id, "STEP_COMPLETE/SKIP bin=%s — disarming", st.arming.bin) end
            st.arming = nil
        end
        if ent.stream_id then st.last_stream_id = ent.stream_id end
    end

    if not st.arming then
        app_heartbeat.stamp(handle, "kb5_filter", "ok", "idle (no armed bin)", poll_s)
        return
    end

    -- Fetch popup
    local popup, perr = controller.popup_get({
        ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
    if not popup then
        log(id, "popup fetch failed: %s", tostring(perr))
        app_heartbeat.stamp(handle, "kb5_filter", "degraded", "popup fetch failed", poll_s)
        return
    end

    local elapsed = tonumber(popup.ELASPED_TIME)
    local plc     = tonumber(popup.PLC_FLOW_METER)
    local hunter  = tonumber(popup.FILTERED_HUNTER_VALVE)

    -- Evaluate once per NEW minute (pcall-isolated — a fault must never disturb
    -- any other KB; this is an independent monitor).
    if elapsed and st.arming.plc_state and st.arming.flow_last_min ~= elapsed then
        st.arming.flow_last_min = elapsed
        local a = st.arming
        local ok_eval, eval_err = pcall(function()
            local r = PlcFilter.observe(a.plc_state, plc, hunter, elapsed,
                { run_time = a.run_time })

            -- per-minute trace
            KB5.insert_eval(db, {
                ts_ms = now_ms(), bin = a.bin, is_city = a.is_city, is_eto = a.is_eto,
                schedule = a.schedule, station_step = a.station_step, elapsed_min = elapsed,
                plc_gpm = plc, hunter_gpm = hunter,
                plc_steady = r.plc_steady, hun_steady = r.hun_steady,
                plc_ratio = r.plc_ratio, hun_ratio = r.hun_ratio,
                drop_consec = a.plc_state.drop_consec,
                below = r.below, fired = r.would_trigger, reason = r.reason,
            })

            if r.would_trigger then
                local skey = tostring(a.schedule or "") .. ":" .. tostring(a.station_step or "")
                if st.flow_acted[skey] then
                    log(id, "filter-load bin=%s step=%s already acted once → NOT re-acting (anti-loop; %s)",
                        a.bin, tostring(a.station_step), tostring(r.reason))
                    return
                end

                -- 90-min GLOBAL rate gate (consumed only by an ARMED actuation).
                local last  = st.last_fire_ms
                local since = last and (now_ms() - last) or nil
                local cooldown_block = (last ~= nil) and (since < COOLDOWN_MS) or false

                -- retry length: run_time − onset (when delivery started degrading)
                local full_rt      = tonumber(a.run_time) or 0
                local onset_min    = tonumber(r.onset_min) or tonumber(elapsed) or 0
                local remaining_rt = math.max(1, full_rt - onset_min)
                local reinsert = FlowDeplete.reinsert_job({
                    schedule = a.schedule, step = a.station_step,
                    io_setup = a.io_setup, run_time = remaining_rt })

                local armed_now = KB5_FILTER_ARM and not cooldown_block
                local actions_sent = {}

                if cooldown_block and KB5_FILTER_ARM then
                    log(id, "FILTER-LOAD bin=%s min=%s — COOLDOWN (%d min since last clean < %d min) → NOT acting",
                        a.bin, tostring(elapsed),
                        math.floor((since or 0) / 60000), COOLDOWN_MS / 60000)
                elseif armed_now then
                    st.flow_acted[skey] = true
                    -- reverse rpush: step, then CLEAN_FILTER, then wait →
                    -- controller pops [wait → CLEAN_FILTER → re-run remainder]
                    local rok = WsCommand.queue_front(reinsert,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    local cok = WsCommand.queue_front(FlowDeplete.CLEAN_FILTER_JOB,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    local wok = WsCommand.queue_front(WellDrawdown.WAIT_JOB,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    local sok = WsCommand.post("SKIP_STATION", {
                        schedule_name = a.schedule or "",
                        step          = tostring(a.station_step or ""),
                        logger        = function(m) log(id, "[ws] %s", m) end })
                    st.last_fire_ms = now_ms()
                    KB5.set_last_fire_ms(db, st.last_fire_ms)
                    actions_sent = {
                        string.format("reinsert(%s)", tostring(rok)),
                        string.format("CLEAN_FILTER(%s)", tostring(cok)),
                        string.format("wait(%s)", tostring(wok)),
                        string.format("SKIP(%s)", tostring(sok)),
                    }
                    log(id, "FILTER-LOAD ARMED bin=%s min=%s reason=%s PLC=%.1f/%.1f HUNTER=%.1f/%.1f reinsert_rt=%d/%d(onset=%d)"
                        .. " → rpush reinsert(%s) + CLEAN_FILTER(%s) + wait(%s) + SKIP(%s)",
                        a.bin, tostring(elapsed), tostring(r.reason),
                        plc or 0, r.plc_steady or 0, hunter or 0, r.hun_steady or 0,
                        remaining_rt, full_rt, onset_min,
                        tostring(rok), tostring(cok), tostring(wok), tostring(sok))
                else
                    -- monitor mode: log the exact jobs, consume NO cooldown.
                    log(id, "FILTER-LOAD [monitor] bin=%s min=%s reason=%s PLC=%.1f/%.1f HUNTER=%.1f/%.1f"
                        .. " → WOULD rpush reinsert + CLEAN_FILTER + wait + SKIP (KB5_FILTER_ARM off; would_cooldown_block=%s)"
                        .. "\n    reinsert=%s\n    clean=%s\n    wait=%s",
                        a.bin, tostring(elapsed), tostring(r.reason),
                        plc or 0, r.plc_steady or 0, hunter or 0, r.hun_steady or 0,
                        tostring(cooldown_block),
                        reinsert, FlowDeplete.CLEAN_FILTER_JOB, WellDrawdown.WAIT_JOB)
                end

                -- fire row (armed=0 in monitor mode; cooldown_block recorded)
                KB5.insert_fire(db, {
                    ts_ms = now_ms(), bin = a.bin, is_city = a.is_city, is_eto = a.is_eto,
                    schedule = a.schedule, station_step = a.station_step, elapsed_min = elapsed,
                    plc_gpm = plc, hunter_gpm = hunter,
                    plc_steady = r.plc_steady, hun_steady = r.hun_steady,
                    onset_min = onset_min, reinsert_rt = remaining_rt, run_time = full_rt,
                    cooldown_block = cooldown_block, armed = armed_now,
                    actions_sent = table.concat(actions_sent, ","),
                    note = r.reason,
                })

                -- Discord + past-actions only on a REAL actuation (monitor stays quiet).
                if armed_now then
                    local body = string.format(
                        "🚨 KB5 FILTER-LOAD — %s%s\nschedule=%s step=%s minute=%d\nPLC=%.1f→ (steady %.1f)  HUNTER=%.1f→ (steady %.1f)\nPLC+Hunter lockstep drop → clean filter + re-run remainder (%d/%d min)\nACTUATED: %s",
                        a.bin, a.is_city and " [CITY]" or "",
                        tostring(a.schedule), tostring(a.station_step), elapsed or 0,
                        plc or 0, r.plc_steady or 0, hunter or 0, r.hun_steady or 0,
                        remaining_rt, full_rt, table.concat(actions_sent, ", "))
                    local nok, nerr = push_notify(ps, id, body)
                    if not nok then log(id, "Discord push FAILED: %s", tostring(nerr)) end
                    if st.notify_db then
                        NOTIFY.record(st.notify_db, {
                            ts_ms = now_ms(), level = "RED", source = "KB5",
                            kind = "FILTER_LOAD", target = a.bin,
                            action = table.concat(actions_sent, "+"),
                            title = string.format("KB5 FILTER-LOAD %s — PLC+Hunter collapsed @ min %d",
                                a.bin, elapsed or 0),
                            body = body,
                        })
                    end
                end
            elseif r.below then
                log(id, "filter-load [watch] bin=%s min=%s PLC=%s(steady %s) HUNTER=%s(steady %s) consec=%d (%s)",
                    a.bin, tostring(elapsed),
                    plc and string.format("%.1f", plc) or "nil",
                    r.plc_steady and string.format("%.1f", r.plc_steady) or "-",
                    hunter and string.format("%.1f", hunter) or "nil",
                    r.hun_steady and string.format("%.1f", r.hun_steady) or "-",
                    a.plc_state.drop_consec, tostring(r.reason))
            end
        end)
        if not ok_eval then log(id, "observe error (isolated): %s", tostring(eval_err)) end
    end

    app_heartbeat.stamp(handle, "kb5_filter", "ok",
        string.format("bin=%s minute=%s plc=%.1f hunter=%.1f",
            st.arming.bin, tostring(elapsed), plc or 0, hunter or 0),
        poll_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
