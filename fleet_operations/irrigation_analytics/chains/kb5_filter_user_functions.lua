-- chains/kb5_filter_user_functions.lua — KB5_TICK handler.
--
-- KB5 = the PLC-meter SAND-FOUL detector (Glenn 2026-06-28 rule). Key off the PLC:
-- if it DROPS while the smooth (filtered) Hunter is STILL FLOWING, the PLC
-- meter/filter is sand-fouled (the well IS delivering — Hunter proves it — so a low
-- upstream reading is the meter, not a real flow loss) → do ONE cleaning operation
-- (CLEAN_FILTER) to flush it. Detector: lib/plc_filter.lua. DB: lib/kb5_filter.lua.
--
-- This is the complement flow_deplete is BLIND to: flow_deplete (KB3_FLOW_ARM)
-- handles PLC+Hunter falling TOGETHER (a real delivery loss → clean+retry+skip);
-- KB5 handles Hunter FINE but PLC fouled (→ clean only, never skip a delivering run).
--
-- Per tick:
--   1. Poll past_actions delta. On STATION_START, gate-in = NON-CITY bins (a city
--      bin's low PLC + flowing Hunter could be city water, not a fouled meter).
--      Arm a fresh plc_filter state. STEP_COMPLETE / SKIP_OPERATION → disarm.
--   2. If armed, fetch popup; on each NEW minute call PlcFilter.observe(plc,hunter).
--   3. On would_trigger:
--        - 90-min GLOBAL rate gate (persisted last_fire_ms): CLEAN_FILTER is a
--          global action; one per 90 min is plenty (sand doesn't re-foul faster).
--        - per-step anti-loop (one clean per step).
--        RECOVERY (only when KB5_FILTER_ARM): queue_front ONE CLEAN_FILTER to run
--        next. NO skip and NO re-run — the station is delivering correctly, only the
--        meter is fouled, so we must not interrupt a healthy watering step.
--        Monitor mode logs exactly what it WOULD do and consumes NO cooldown.
--   4. Write an evals_kb5 row each minute; a runs_kb5 row on each (would-)fire.
--
-- Reuses flow_deplete.CLEAN_FILTER_JOB (byte-matched controller wire format) and
-- ws_command (the live POST path).

local cjson         = require("cjson")
local controller    = require("controller_client")
local KB3           = require("kb3_sustained")   -- bin classification helpers (is_eto/is_city/bin_key)
local KB5           = require("kb5_filter")       -- this KB's db layer
local PlcFilter     = require("plc_filter")       -- the PLC-meter sand-foul detector
local NOTIFY        = require("notifications")
local WsCommand     = require("ws_command")
local FlowDeplete   = require("flow_deplete")     -- CLEAN_FILTER_JOB (the cleaning step)
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
    if cfg.plc_low_gpm  then PlcFilter.PLC_LOW_GPM  = cfg.plc_low_gpm  end
    if cfg.hun_flow_gpm then PlcFilter.HUN_FLOW_GPM = cfg.hun_flow_gpm end
    if cfg.onset_consec then PlcFilter.ONSET_CONSEC = cfg.onset_consec end

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
        log(id, "db ready at %s (armed=%s, rule: PLC<%.1f GPM AND smooth HUNTER>=%.1f GPM for %d consec → CLEAN_FILTER, cooldown=%dmin, last_fire=%s)",
            db_path, tostring(KB5_FILTER_ARM),
            PlcFilter.PLC_LOW_GPM, PlcFilter.HUN_FLOW_GPM, PlcFilter.ONSET_CONSEC,
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
            -- gate-in = NON-CITY bins (Glenn 2026-06-28). On a city bin a low PLC +
            -- flowing Hunter could be city water (well not drawing), not a fouled
            -- meter; on a non-city bin Hunter flow PROVES the well is delivering, so
            -- a low PLC = a fouled meter. Coexists with flow_deplete on ETO-non-city:
            -- the two trigger on OPPOSITE Hunter conditions (kb5: Hunter flowing;
            -- flow_deplete: Hunter depleting) and kb5 never skips, so no double-act.
            if not is_city then
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
                log(id, "STATION_START bin=%s — city bin, skipping (city water can mask a fouled well meter)", bin_key)
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
                drop_consec = a.plc_state.drop_consec,
                below = r.below, fired = r.would_trigger, reason = r.reason,
            })

            if r.would_trigger then
                local skey = tostring(a.schedule or "") .. ":" .. tostring(a.station_step or "")
                if st.flow_acted[skey] then
                    log(id, "plc-foul bin=%s step=%s already cleaned once → NOT re-acting (anti-loop; %s)",
                        a.bin, tostring(a.station_step), tostring(r.reason))
                    return
                end

                -- 90-min GLOBAL rate gate (consumed only by an ARMED actuation).
                local last  = st.last_fire_ms
                local since = last and (now_ms() - last) or nil
                local cooldown_block = (last ~= nil) and (since < COOLDOWN_MS) or false

                local armed_now = KB5_FILTER_ARM and not cooldown_block
                local actions_sent = {}

                if cooldown_block and KB5_FILTER_ARM then
                    log(id, "PLC-FOUL bin=%s min=%s — COOLDOWN (%d min since last clean < %d min) → NOT cleaning",
                        a.bin, tostring(elapsed),
                        math.floor((since or 0) / 60000), COOLDOWN_MS / 60000)
                elseif armed_now then
                    st.flow_acted[skey] = true
                    -- The ONLY action: queue one CLEAN_FILTER to run next. NO skip,
                    -- NO reinsert — the station is delivering fine (Hunter flowing);
                    -- only the meter is fouled, so we flush the filter and let the
                    -- current step finish watering uninterrupted.
                    local cok = WsCommand.queue_front(FlowDeplete.CLEAN_FILTER_JOB,
                        { logger = function(m) log(id, "[ws] %s", m) end })
                    st.last_fire_ms = now_ms()
                    KB5.set_last_fire_ms(db, st.last_fire_ms)
                    actions_sent = { string.format("CLEAN_FILTER(%s)", tostring(cok)) }
                    log(id, "PLC-FOUL ARMED bin=%s min=%s reason=%s PLC=%.2f HUNTER=%.1f → rpush CLEAN_FILTER(%s) (no skip — run is delivering)",
                        a.bin, tostring(elapsed), tostring(r.reason),
                        plc or 0, hunter or 0, tostring(cok))
                else
                    -- monitor mode: log what it WOULD do, consume NO cooldown.
                    log(id, "PLC-FOUL [monitor] bin=%s min=%s reason=%s PLC=%.2f HUNTER=%.1f"
                        .. " → WOULD rpush CLEAN_FILTER (no skip) (KB5_FILTER_ARM off; would_cooldown_block=%s)",
                        a.bin, tostring(elapsed), tostring(r.reason),
                        plc or 0, hunter or 0, tostring(cooldown_block))
                end

                -- fire row (armed=0 in monitor mode; cooldown_block recorded)
                KB5.insert_fire(db, {
                    ts_ms = now_ms(), bin = a.bin, is_city = a.is_city, is_eto = a.is_eto,
                    schedule = a.schedule, station_step = a.station_step, elapsed_min = elapsed,
                    plc_gpm = plc, hunter_gpm = hunter,
                    run_time = tonumber(a.run_time) or 0,
                    cooldown_block = cooldown_block, armed = armed_now,
                    actions_sent = table.concat(actions_sent, ","),
                    note = r.reason,
                })

                -- Discord + past-actions only on a REAL actuation (monitor stays quiet).
                if armed_now then
                    local body = string.format(
                        "🧽 KB5 PLC-METER FOUL — %s\nschedule=%s step=%s minute=%d\nPLC=%.2f GPM (low) but smooth HUNTER=%.1f GPM (still flowing)\n→ well IS delivering; the upstream meter/filter is sand-fouled → CLEAN_FILTER (run NOT skipped)\nACTUATED: %s",
                        a.bin, tostring(a.schedule), tostring(a.station_step), elapsed or 0,
                        plc or 0, hunter or 0, table.concat(actions_sent, ", "))
                    local nok, nerr = push_notify(ps, id, body)
                    if not nok then log(id, "Discord push FAILED: %s", tostring(nerr)) end
                    if st.notify_db then
                        NOTIFY.record(st.notify_db, {
                            ts_ms = now_ms(), level = "YELLOW", source = "KB5",
                            kind = "PLC_FOUL", target = a.bin,
                            action = table.concat(actions_sent, "+"),
                            title = string.format("KB5 PLC-meter foul %s — PLC %.2f low, Hunter %.1f flowing @ min %d → CLEAN_FILTER",
                                a.bin, plc or 0, hunter or 0, elapsed or 0),
                            body = body,
                        })
                    end
                end
            elseif r.below then
                log(id, "plc-foul [watch] bin=%s min=%s PLC=%s HUNTER=%s consec=%d (%s)",
                    a.bin, tostring(elapsed),
                    plc and string.format("%.2f", plc) or "nil",
                    hunter and string.format("%.1f", hunter) or "nil",
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
