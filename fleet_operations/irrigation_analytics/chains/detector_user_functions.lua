-- chains/detector_user_functions.lua — DETECTOR_TICK for the KB1+KB3 detector.
--
-- Ports the per-cycle logic from irrigation_analytics/robot/main.lua's
-- poll_once() into chain_tree form. KB2 + KB4 are intentionally deferred —
-- they land as separate chains once their offline analyses are blessed.
--
-- Per tick:
--   1. popup_get()
--   2. past_actions_xrange(cursor)  — advance cursor; first tick fast-forwards
--   3. Walk delta → arm on STATION_START / disarm on STEP_COMPLETE / track ETO
--   4. state_classifier.classify(popup)
--   5. Per-session rolling-median window (TIME_STAMP-gated)
--   6. KB1 modes.evaluate(state, popup, arming, last_sample, ctx)
--   7. KB3Live.update(baseline, arming.kb3, FILTERED_HUNTER_VALVE, STEP) when
--      ACTIVE_RUN
--   8. For each fired event (after per-session edge-trigger gate):
--        a. push to fleet/notify/digest/daily (Discord via notification_service)
--        b. ws_command.post(action) for ALLOWED_ACTIONS (SKIP_LIVE-gated dry-run)
--        c. publish to <ns>/events/sample (persistence stream)
--
-- All blackboard state lives under bb._detector so it's namespaced from other
-- chains. Curves + baselines are loaded once at startup in main.lua and
-- placed on bb._detector_curves / bb._detector_baselines.

local cjson         = require("cjson")
local controller    = require("controller_client")
local SM            = require("state_classifier")
local Modes         = require("modes")
local T             = require("thresholds")
local Baselines     = require("baselines")
local KB3Live       = require("kb3_live")
-- KB3-curve removed 2026-06-09 (Glenn's redesign — replaced by kb3_sustained chain)
local WsCommand     = require("ws_command")
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC   = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY  = "fleet.notify.digest/1"
local SCHEMA_FAULT   = "irrigation_analytics.fault/1"
local DEFAULT_POLL_S = 30

-- ALLOWED_ACTIONS gates which event.action strings actually POST to the
-- controller. Anything not in this set falls through to log-only — avoids
-- accidentally emitting CLEAR or other dangerous commands if a future
-- event tags one.
local ALLOWED_ACTIONS = {
    SKIP_STATION       = true,
    CLOSE_MASTER_VALVE = true,
}

local function log(id, fmt_str, ...)
    io.stderr:write(string.format(
        "detector [%s]: " .. fmt_str .. "\n", id.namespace, ...))
end

local function iso_now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function publish(ps, key, payload)
    local ok, err = pcall(function() ps:publish(key, payload) end)
    return ok, err
end

-- Discord push via the shared notify channel. The notification_service
-- subscribes to DIGEST_TOPIC and POSTs `body` verbatim after a header.
local function push_notify(ps, id, body)
    local payload = cjson.encode({
        schema   = SCHEMA_NOTIFY,
        class    = id.class,
        instance = id.instance,
        body     = body,
    })
    return publish(ps, DIGEST_TOPIC, payload)
end

-- Persist one fault event into the persistence stream <ns>/events/sample.
local function persist_fault(ps, id, event, state, bin_key, ts_iso, extras)
    local rec = {
        schema    = SCHEMA_FAULT,
        ts        = ts_iso,
        state     = state,
        bin_key   = bin_key,
        kind      = event.kind,
        level     = event.level,
        action    = event.action,
        msg       = event.msg,
    }
    if extras then
        for k, v in pairs(extras) do rec[k] = v end
    end
    return publish(ps, id.namespace .. "/events/sample", cjson.encode(rec))
end

-- Format Discord body. Compact one-block message matching the temp robot
-- style ("[class/instance] LEVEL kind\n msg"). notification_service prepends
-- its own "[class/instance]" header so we only need LEVEL + kind + msg.
local function format_discord_body(event, state, schedule, step, bin_key)
    local action_tag = event.action and (" >> " .. event.action) or ""
    return string.format(
        "%s %s%s\nstate=%s schedule=%s step=%s bin=%s\n%s",
        event.level or "?", event.kind or "?", action_tag,
        state or "?", schedule or "?", tostring(step or "?"),
        bin_key or "-", event.msg or "")
end

-- Fetch the detector state blob from blackboard, creating it on first call.
local function get_state(bb)
    if not bb._detector then
        bb._detector = {
            initialized      = false,
            last_stream_id   = nil,
            prev_state       = nil,
            last_sample      = nil,    -- { irr_current, eq_current }
            arming           = nil,    -- per-bin session, see below
            master_idle      = nil,    -- MASTER_IDLE_CHECK session
        }
    end
    return bb._detector
end

-- Fast-forward the past_actions cursor to the current tip. Called once on
-- the first DETECTOR_TICK so we only observe state changes going forward.
local function init_cursor(bb, ctrl, id)
    local st = get_state(bb)
    if st.initialized then return end
    local tip, terr = controller.past_actions_tip({
        ssh_host  = ctrl.ssh_host,
        timeout_s = ctrl.timeout_s,
    })
    if tip and tip ~= "" then
        st.last_stream_id = tip
        log(id, "past_actions cursor fast-forwarded to %s", tip)
    else
        log(id, "past_actions_tip failed (%s) — will replay full stream",
            tostring(terr))
    end
    st.initialized = true
end

-- Walk a past_actions delta. Mutates state in place. Returns
-- pending_kb4 (list of bin_keys to process for KB4 — collected here but
-- unused until KB4 chain lands; emitted in cycle log only for now).
local function apply_past_actions(st, delta, curves, baselines, id)
    local pending_kb4 = nil
    for _, ent in ipairs(delta) do
        if ent.action == "IRRIGATION_STATION_START" and type(ent.details) == "table" then
            local io_setup = ent.details.io_setup
            local bin_key  = T.canonicalize_io_setup(io_setup)
            st.arming = {
                bin_key                = bin_key,
                io_setup               = io_setup,
                curve                  = T.lookup_curve(curves, bin_key),
                eto_restriction_seen   = false,
                samples_seen           = 0,
                started_at             = ent.stream_id,
                started_at_ts          = os.time(),
                schedule_name          = ent.details.schedule_name,
                step                   = ent.details.step,
                irr_window             = {},
                last_accepted_ts       = nil,
                cond_state             = {},
                kb3                    = { by_step = {}, last_step = 0, fired = false },
                -- kb3_curve session-state removed 2026-06-09; kb3_sustained chain
                -- has its own independent arming state in bb._kb3.
            }
            log(id, "STATION_START bin=%s calibrated=%s baseline=%s",
                bin_key,
                tostring(st.arming.curve ~= nil),
                tostring(baselines and Baselines.lookup(baselines, bin_key) ~= nil))
        elseif ent.action == "IRRIGATION_STEP_COMPLETE" then
            local bin_key = nil
            if type(ent.details) == "table" then
                bin_key = T.canonicalize_io_setup(ent.details.io_setup)
            end
            if (not bin_key or bin_key == "?") and st.arming then
                bin_key = st.arming.bin_key
            end
            if bin_key and bin_key ~= "?" then
                pending_kb4 = pending_kb4 or {}
                pending_kb4[#pending_kb4+1] = bin_key
                log(id, "STEP_COMPLETE bin=%s (KB4 deferred)", bin_key)
            end
            st.arming = nil
        elseif ent.action == "SKIP_OPERATION" then
            st.arming = nil
        elseif ent.action == "IRRIGATION_ETO_RESTRICTION" then
            if st.arming then st.arming.eto_restriction_seen = true end
        end
        if ent.stream_id then st.last_stream_id = ent.stream_id end
    end
    return pending_kb4
end

-- Per-session rolling median update (TIME_STAMP-gated). Returns
-- (median, window_n, sample_accepted).
local function update_window(active_session, irr, cur_ts)
    if not active_session then return nil, 0, false end
    local last_ts = active_session.last_accepted_ts
    local accepted = false
    if (not last_ts) or (cur_ts and (cur_ts - last_ts) >= T.SAMPLE_DEDUP_TS_GAP_S) then
        T.push_window(active_session.irr_window, irr, T.MEDIAN_WINDOW_N)
        active_session.last_accepted_ts = cur_ts
        accepted = true
    end
    return T.rolling_median(active_session.irr_window),
           #active_session.irr_window,
           accepted
end

-- Edge-triggered Discord cooldown helpers. Mirrors robot/main.lua section 9.
local function session_for_event(state, st)
    if state == SM.states.ACTIVE_RUN        then return st.arming end
    if state == SM.states.MASTER_IDLE_CHECK then return st.master_idle end
    return nil
end

local function clear_unseen_cond(sess, seen_kinds)
    if not sess or not sess.cond_state then return end
    for k, s in pairs(sess.cond_state) do
        if s == "fired" and not seen_kinds[k] then
            sess.cond_state[k] = "ok"
        end
    end
end

M.one_shot.DETECTOR_TICK = function(handle, _node)
    local bb     = handle.blackboard
    local id, ps = bb._identity, bb._pubsub
    local cs     = bb._class_spec
    local ctrl   = (cs and cs.controller) or {}
    local poll_s = ctrl.poll_s or DEFAULT_POLL_S

    local curves    = bb._detector_curves    or {}
    local baselines = bb._detector_baselines    -- nil → KB3 disabled, KB1 still partial

    local st = get_state(bb)
    init_cursor(bb, ctrl, id)

    local manual_suspend = bb._manual_suspend or false
    local cycle_t = iso_now()

    -- 1) popup
    local popup, perr = controller.popup_get({
        ssh_host  = ctrl.ssh_host,
        timeout_s = ctrl.timeout_s,
    })
    if not popup then
        log(id, "popup fetch failed: %s", tostring(perr))
        app_heartbeat.stamp(handle, "detector", "degraded",
            string.format("popup fetch failed: %s", tostring(perr):sub(1, 100)),
            poll_s)
        return
    end

    -- 2) past_actions delta
    local delta, derr = controller.past_actions_xrange(
        st.last_stream_id, 200,
        { ssh_host = ctrl.ssh_host, timeout_s = ctrl.timeout_s })
    if not delta then
        log(id, "past_actions fetch failed: %s", tostring(derr))
        delta = {}
    end

    -- 3) apply delta to session state
    apply_past_actions(st, delta, curves, baselines, id)

    -- 4) state classification
    local state = SM.classify(popup, manual_suspend)

    -- 4b) track MASTER_IDLE_CHECK session
    if state == SM.states.MASTER_IDLE_CHECK then
        if st.prev_state ~= SM.states.MASTER_IDLE_CHECK then
            st.master_idle = {
                armed_ts         = os.time(),
                irr_window       = {},
                last_accepted_ts = nil,
                cond_state       = {},
            }
        end
    else
        st.master_idle = nil
    end

    -- 5) advance sample counter (ACTIVE_RUN only — sample-0 skip is handled
    --    by warm-up gating in Modes.eval_calibrated_modes)
    if state == SM.states.ACTIVE_RUN and st.arming then
        st.arming.samples_seen = (st.arming.samples_seen or 0) + 1
    end

    -- 6) per-session rolling-median window
    local cur_ts = tonumber(popup.TIME_STAMP)
    local irr    = tonumber(popup.PLC_IRRIGATION_CURRENT) or 0
    local active_session
    if state == SM.states.ACTIVE_RUN and st.arming then
        active_session = st.arming
    elseif state == SM.states.MASTER_IDLE_CHECK and st.master_idle then
        active_session = st.master_idle
    end
    local irr_median, irr_window_n, _accepted =
        update_window(active_session, irr, cur_ts)

    -- 7) KB1 modes evaluator
    local events = Modes.evaluate(state, popup, st.arming, st.last_sample, {
        now_ts               = os.time(),
        master_idle_armed_ts = st.master_idle and st.master_idle.armed_ts,
        irr_median           = irr_median,
        irr_window_n         = irr_window_n,
    }) or {}

    -- 8/8b prologue — fetch the LIVE per-minute HUNTER_FLOW_METER reading
    -- from IRRIGATION_MARK_DATA. This is in correct GPM units that match
    -- the baseline ceilings. popup.FILTERED_HUNTER_VALVE is the WRONG
    -- source — its value is ~2-3× lower than per-minute binned HUNTER
    -- (different scale/encoding); using it caused KB3 / KB3-curve to
    -- silently miss the 2026-06-08 sat_3:15 16 GPM spike + sustained
    -- 10-13 GPM over baseline 10.8. Bug found 2026-06-08 PM.
    --
    -- Falls back to popup.FILTERED_HUNTER_VALVE if MARK_DATA fetch fails
    -- (defensive — better stale fallback than no signal).
    local live_hunter_gpm = nil
    if state == SM.states.ACTIVE_RUN and st.arming and st.arming.bin_key then
        local md, mderr = controller.mark_hunter_latest(st.arming.bin_key, {
            ssh_host  = ctrl.ssh_host,
            timeout_s = ctrl.timeout_s,
        })
        if md and md.value then
            live_hunter_gpm = tonumber(md.value)
        else
            -- Fallback only (and log once per run that we're degraded).
            if not st.arming.mark_fallback_logged then
                log(id, "mark_hunter unavailable (%s) — falling back to popup FILTERED_HUNTER_VALVE",
                    tostring(mderr))
                st.arming.mark_fallback_logged = true
            end
            live_hunter_gpm = tonumber(popup.FILTERED_HUNTER_VALVE)
        end
    end

    -- 8) KB3 LIVE — only during ACTIVE_RUN, only when baselines available
    if state == SM.states.ACTIVE_RUN
       and st.arming and st.arming.bin_key
       and baselines then
        local bl   = Baselines.lookup(baselines, st.arming.bin_key)
        local filt = live_hunter_gpm
        local step = tonumber(popup.STEP)
        if bl and filt and step then
            local res = KB3Live.update(bl, st.arming.kb3, filt, step)
            if res and res.fired then
                log(id, "KB3 LIVE FIRE bin=%s sample=%.2f err=%+.2f step=%d",
                    st.arming.bin_key, res.sample, res.err, res.step)
                events[#events+1] = KB3Live.event(
                    st.arming.bin_key, bl, st.arming.kb3, res)
            end
        end
    end

    -- 8b) KB3 CURVE REMOVED 2026-06-09 (Glenn's redesign).
    -- Replaced by kb3_sustained chain (chains/kb3_sustained_user_functions.lua)
    -- which is schedule-aware, ETO-only, uses 5-min warmup + 3 consecutive
    -- minutes over 15 GPM threshold on EITHER PLC_FLOW_METER OR
    -- FILTERED_HUNTER_VALVE. Independent of detector chain entirely.

    -- 9) last_sample for next cycle (sustained-N comparison in Modes.eval_eq)
    st.last_sample = {
        irr_current = irr,
        eq_current  = tonumber(popup.PLC_EQUIPMENT_CURRENT) or 0,
    }

    -- 10) Discord + ws_command + persistence — EDGE-TRIGGERED.
    --     Alert once on ok→fired; suppress while fired; return to ok silently.
    local seen_kinds = {}
    for _, ev in ipairs(events) do seen_kinds[ev.kind] = true end
    clear_unseen_cond(st.arming, seen_kinds)
    clear_unseen_cond(st.master_idle, seen_kinds)

    for _, ev in ipairs(events) do
        local sess = session_for_event(state, st)
        local suppressed = false
        if sess and sess.cond_state and sess.cond_state[ev.kind] == "fired" then
            suppressed = true
        end

        if not suppressed then
            if not ev.db_only then
                local body = format_discord_body(ev, state,
                    popup.SCHEDULE_NAME, popup.STEP,
                    st.arming and st.arming.bin_key)
                local nok, nerr = push_notify(ps, id, body)
                if not nok then
                    log(id, "Discord notify FAILED kind=%s: %s",
                        ev.kind, tostring(nerr))
                end
            end
            if sess and sess.cond_state then
                sess.cond_state[ev.kind] = "fired"
            end

            -- ws_command dispatch — same edge as Discord.
            local ws_ok, ws_code, ws_err
            if ev.action and ALLOWED_ACTIONS[ev.action] then
                ws_ok, ws_code, ws_err = WsCommand.post(ev.action, {
                    schedule_name = popup.SCHEDULE_NAME or "",
                    step          = tostring(popup.STEP or ""),
                    run_time      = tostring(popup.RUN_TIME or ""),
                    logger        = function(m) log(id, "[ws] %s", m) end,
                })
                log(id, "ws_command %s → ok=%s code=%s err=%s",
                    ev.action, tostring(ws_ok), tostring(ws_code),
                    tostring(ws_err))
            end

            -- Persistence stream — every fired event, suppressed or not.
            persist_fault(ps, id, ev, state,
                st.arming and st.arming.bin_key, cycle_t,
                {
                    schedule        = popup.SCHEDULE_NAME,
                    step            = popup.STEP,
                    irr_median      = irr_median,
                    window_n        = irr_window_n,
                    ws_dispatched   = ws_ok,
                    ws_http_code    = ws_code,
                    ws_err          = ws_err,
                })
        end
    end

    -- 11) prev_state for next tick (edge detection in SM.edges)
    st.prev_state = state

    -- Healthy heartbeat.
    local sched = popup.SCHEDULE_NAME or "OFFLINE"
    app_heartbeat.stamp(handle, "detector", "ok",
        string.format("state=%s sched=%s irr=%.2fA win=%d events=%d cursor=%s",
            state, sched, irr, irr_window_n, #events,
            tostring(st.last_stream_id or "-")),
        poll_s)
    log(id, "DETECTOR_TICK ok state=%s sched=%s irr=%.2fA win=%d events=%d delta=%d",
        state, sched, irr, irr_window_n, #events, #delta)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
