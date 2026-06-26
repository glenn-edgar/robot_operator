-- chains/kb1_overcurrent_user_functions.lua — KB1_TICK handler.
--
-- Simple absolute-threshold detector. Glenn's 2026-06-09 redesign:
-- KB1 stays independent of every other KB. No KB2 baselines, no
-- expected_I math, no SSH calls except the popup_get that detector
-- already does. Just two raw popup fields against fixed thresholds.
--
-- Per tick:
--   1. popup.PLC_IRRIGATION_CURRENT and popup.PLC_EQUIPMENT_CURRENT
--   2. classify against thresholds (KB1.IRR_KILL_A, KB1.EQ_KILL_A)
--   3. If KILL fires AND we haven't already fired this run:
--        a. CLOSE_MASTER_VALVE  (water off first — protects coils)
--        b. SKIP_STATION        (advance past bad station)
--        c. Discord push
--        d. INSERT runs_kb1 row
--   4. Edge-trigger: state.fired stays true until current drops back
--      below threshold for ≥2 consecutive ticks (re-armed)
--
-- Both actions dispatched only when KB1_ARM_KILL=1 env is set AND
-- ws_command's SKIP_LIVE=1 is set. WSL test phase: both off → log only.

local cjson         = require("cjson")
local controller    = require("controller_client")
local KB1           = require("kb1_overcurrent")
local NOTIFY        = require("notifications")
local WsCommand     = require("ws_command")
local app_heartbeat = require("app_heartbeat")
local BadSprinklers = require("bad_sprinklers")
local kb_alerts     = require("kb_alerts")

local NOTIFY_DB_PATH = os.getenv("NOTIFY_DB_PATH") or "/var/fleet/notify/notifications.db"

local KB1_ARM_KILL = (os.getenv("KB1_ARM_KILL") == "1")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC   = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY  = "fleet.notify.digest/1"
local DEFAULT_POLL_S = 30

local function log(id, fmt, ...)
    io.write(string.format("kb1_overcurrent [%s]: " .. fmt .. "\n", id.namespace, ...))
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

M.one_shot.KB1_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local id, ps   = bb._identity, bb._pubsub
    local cs       = bb._class_spec
    local cfg      = (cs and cs.kb1_overcurrent) or {}
    local poll_s   = cfg.poll_s or DEFAULT_POLL_S
    local ssh_host = cfg.ssh_host or "pi@irrigation"
    local db_path  = cfg.db_path  or "/var/fleet/kb1/kb1.db"

    -- Threshold overrides via env / class_spec (optional)
    if cfg.irr_kill_a then KB1.IRR_KILL_A = cfg.irr_kill_a end
    if cfg.eq_kill_a  then KB1.EQ_KILL_A  = cfg.eq_kill_a end

    -- Init blackboard state
    if not bb._kb1 then
        bb._kb1 = {
            db = nil,
            fired = false,           -- edge-trigger
            below_streak = 0,        -- how many ticks back below threshold
            last_bin = nil,
            last_step = nil,
        }
    end
    local st = bb._kb1

    if not st.db then
        local db, err = KB1.open_db(db_path)
        if not db then
            log(id, "open_db FAILED at %s: %s", db_path, tostring(err))
            app_heartbeat.stamp(handle, "kb1_overcurrent", "degraded",
                "open_db failed", poll_s)
            return
        end
        st.db = db
        st.notify_db = NOTIFY.open_db(NOTIFY_DB_PATH)  -- past-actions log (shared)
        if not st.notify_db then log(id, "notifications log open failed at %s", NOTIFY_DB_PATH) end
        -- EQ SAMPLER table (monitor-only, Glenn 2026-06-15): timestamped equipment
        -- + irrigation current, to read the quasi-period of the EQ excursion. pcall
        -- so a schema hiccup can NEVER disturb the armed kill path.
        pcall(function()
            db:exec([[CREATE TABLE IF NOT EXISTS eq_samples (
                ts_ms INTEGER, eq_i REAL, irr_i REAL, step INTEGER, sched TEXT)]])
        end)
        pcall(function() kb_alerts.ensure_schema(db) end)  -- spike-latch → 18:00 digest
        log(id, "db ready at %s (armed=%s, IRR_KILL=%.1fA non-city / %.1fA city(1:39) EQ_KILL=%.1fA)",
            db_path, tostring(KB1_ARM_KILL), KB1.IRR_KILL_A, KB1.IRR_KILL_CITY_A, KB1.EQ_KILL_A)
    end
    local db = st.db

    -- Read popup (one SSH call). If popup fails, just heartbeat degraded
    -- and skip this tick — DON'T fire on missing data.
    local popup, perr = controller.popup_get({
        ssh_host  = ssh_host,
        timeout_s = cfg.timeout_s or 8,
    })
    if not popup then
        log(id, "popup fetch failed: %s", tostring(perr))
        app_heartbeat.stamp(handle, "kb1_overcurrent", "degraded",
            "popup fetch failed", poll_s)
        return
    end

    local irr_I  = tonumber(popup.PLC_IRRIGATION_CURRENT) or 0
    local eq_I   = tonumber(popup.PLC_EQUIPMENT_CURRENT)  or 0
    local step   = tonumber(popup.STEP) or 0
    local sched  = popup.SCHEDULE_NAME or "?"

    -- BIN-AWARE THRESHOLD (Glenn 2026-06-26): resolve the running step's valves
    -- ONCE per step-change (one ssh) and check for the city valve 1:39. City bins
    -- (master + city coil + up to 3 valves, legit ~1.50 A) use 1.8 A; non-city
    -- bins use the sensitive 1.5 A. Cache the valves for the spike-latch too. On
    -- resolve failure default to CITY (1.8, the safe/higher one — never false-kill).
    if step ~= st.city_checked_step then
        st.city_checked_step = step
        st.step_is_city = true            -- safe default until resolved
        st.step_valves  = nil
        pcall(function()
            local valves = controller.schedule_step_valves(sched, step,
                { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
            if valves and #valves > 0 then
                st.step_valves = valves
                local city = false
                for _, v in ipairs(valves) do if v == "satellite_1:39" then city = true end end
                st.step_is_city = city
            end
        end)
    end
    local irr_kill = st.step_is_city and KB1.IRR_KILL_CITY_A or KB1.IRR_KILL_A

    -- EQ SAMPLER (monitor-only): one timestamped row per tick (~30 s) so we can
    -- read the quasi-period of the equipment-current excursion (suspected
    -- step-down/measurement noise off the 732's separate 5 V rail, NOT a real
    -- load). pcall-isolated: must NEVER disturb the armed kill path below.
    pcall(function()
        local stmt = db:prepare(
            "INSERT INTO eq_samples(ts_ms,eq_i,irr_i,step,sched) VALUES(?,?,?,?,?)")
        if stmt then
            stmt:bind_values(now_ms(), eq_I, irr_I, step, sched)
            stmt:step(); stmt:finalize()
        end
    end)

    local cls, sev, excess, note = KB1.classify(irr_I, eq_I, irr_kill)

    -- Re-arm: if we previously fired and current is back below threshold,
    -- count consecutive below-threshold ticks. After 2 ticks, allow next
    -- fire (handles oscillation around threshold).
    if st.fired and cls == "OK" then
        st.below_streak = st.below_streak + 1
        if st.below_streak >= 2 then
            log(id, "re-armed (current below threshold for %d ticks)",
                st.below_streak)
            st.fired = false
            st.below_streak = 0
        end
    elseif cls ~= "OK" then
        st.below_streak = 0
    end

    if cls == "OK" then
        app_heartbeat.stamp(handle, "kb1_overcurrent", "ok",
            string.format("IRR=%.2f EQ=%.2f sched=%s", irr_I, eq_I, sched),
            poll_s)
        return
    end

    -- Suppressed (already fired, current not back below threshold yet)
    if st.fired then
        app_heartbeat.stamp(handle, "kb1_overcurrent", "fired",
            string.format("suppressed: %s IRR=%.2f EQ=%.2f", cls, irr_I, eq_I),
            poll_s)
        return
    end

    -- FIRE
    st.fired = true

    -- LATCH BAD SOLENOID (Glenn 2026-06-26) — an irrigation-current spike is an
    -- intermittent short; the coil reseats and runs fine next time, so the SPIKE
    -- EVENT is the verdict. Resolve the running valve(s) from schedule+step (both
    -- off the popup; schedule file maps step→io_setup) and latch them BAD. Latches
    -- on EVERY irr spike, armed or not (it's a diagnosis, independent of whether
    -- we actuated). Cleared only by a replace_solenoid/replace_valve field log.
    -- pcall-isolated: must NEVER disturb the armed kill path below.
    if cls == "KB1_IRR_KILL" then
        pcall(function()
            -- reuse the valves resolved at step-change; re-resolve only if missing
            local valves = st.step_valves
            if not valves or #valves == 0 then
                valves = controller.schedule_step_valves(sched, step,
                    { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
            end
            if not valves or #valves == 0 then
                log(id, "spike-latch: could not resolve valves for %s step %s",
                    tostring(sched), tostring(step))
                return
            end
            local bdb = BadSprinklers.open()
            if not bdb then return end
            for _, v in ipairs(valves) do
                BadSprinklers.latch(bdb, v,
                    { ts_ms = now_ms(), peak_irr = irr_I, schedule = sched, step = step })
                -- surface in the 18:00 digest (kb1.db is in its kb_db_paths)
                pcall(function()
                    kb_alerts.record(db, {
                        ts_ms = now_ms(), source = "kb1", kind = "spike",
                        severity = "alert", target = v,
                        summary = string.format(
                            "BAD solenoid — IRR spike %.2f A > %.1f kill (sched=%s step=%s); replace",
                            irr_I, irr_kill, tostring(sched), tostring(step)) })
                end)
            end
            bdb:close()
            log(id, "SPIKE-LATCH bad solenoid(s): %s (IRR=%.2f A > %.1f %s) sched=%s step=%s",
                table.concat(valves, ","), irr_I, irr_kill,
                st.step_is_city and "city" or "non-city", tostring(sched), tostring(step))
        end)
    end

    -- Action dispatch order: CLOSE_MASTER_VALVE first (stops water),
    -- then SKIP_STATION (advances queue). Both gated by KB1_ARM_KILL.
    local actions_sent = {}
    if KB1_ARM_KILL then
        for _, action in ipairs({ "CLOSE_MASTER_VALVE", "SKIP_STATION" }) do
            local ok, code, err = WsCommand.post(action, {
                schedule_name = sched,
                step          = tostring(step),
                run_time      = tostring(popup.RUN_TIME or ""),
                logger        = function(m) log(id, "[ws] %s", m) end,
            })
            log(id, "ws_command %s → ok=%s code=%s err=%s",
                action, tostring(ok), tostring(code), tostring(err))
            actions_sent[#actions_sent+1] = string.format("%s(%s)",
                action, tostring(ok))
        end
    else
        log(id, "MONITOR-ONLY: KB1_ARM_KILL not set, actions suppressed")
    end

    -- Discord push (always, even when not armed — operator needs to know)
    local body = string.format(
        "🚨 KB1 OVERCURRENT — %s\nschedule=%s step=%s\nIRR=%.2f A  EQ=%.2f A\n%s\n%s",
        cls, sched, tostring(step), irr_I, eq_I, note or "",
        KB1_ARM_KILL and ("ACTUATED: " .. table.concat(actions_sent, ", "))
                     or "MONITOR-ONLY (KB1_ARM_KILL not set)")
    local nok, nerr = push_notify(ps, id, body)
    if not nok then
        log(id, "Discord push FAILED: %s", tostring(nerr))
    end

    -- Past-actions log (the /irrigation/actions page reads this).
    if st.notify_db then
        NOTIFY.record(st.notify_db, {
            ts_ms  = now_ms(), level = "RED", source = "KB1", kind = "OVERCURRENT",
            target = string.format("%s step %s", sched, tostring(step)),
            action = KB1_ARM_KILL and table.concat(actions_sent, "+") or "(monitor-only)",
            title  = string.format("KB1 OVERCURRENT %s — IRR=%.2f A EQ=%.2f A", cls, irr_I, eq_I),
            body   = body,
        })
    end

    -- SQLite row
    KB1.insert_run(db, {
        ts_ms        = now_ms(),
        bin          = nil,  -- KB1 doesn't track bin (popup doesn't have it directly)
        step         = step,
        schedule     = sched,
        irr_I        = irr_I,
        eq_I         = eq_I,
        cls          = cls,
        severity     = sev,
        excess       = excess,
        note         = note,
        actions_sent = table.concat(actions_sent, ","),
        armed        = KB1_ARM_KILL,
    })

    log(id, "FIRED %s IRR=%.2f EQ=%.2f excess=%+.2f armed=%s",
        cls, irr_I, eq_I, excess, tostring(KB1_ARM_KILL))

    app_heartbeat.stamp(handle, "kb1_overcurrent", "fired",
        string.format("FIRED %s IRR=%.2f EQ=%.2f", cls, irr_I, eq_I),
        poll_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
