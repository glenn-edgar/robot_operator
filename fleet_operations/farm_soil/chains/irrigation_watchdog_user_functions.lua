-- chains/irrigation_watchdog_user_functions.lua — ct_* user fns for the
-- irrigation-site liveness watchdog.
--
-- IRRIGATION_WATCHDOG_TICK: probes the irrigation web server every poll_s.
-- After down_threshold_s of sustained unreachability, posts a Discord
-- alert; re-posts every alert_interval_s while still down; on recovery
-- posts a single "RESTORED" ack.
--
-- "Up" = any HTTP response (a 401 from the Digest realm is fine — the box
-- is responding, that's what the operator cares about). "Down" =
-- TCP/DNS/timeout failure (curl http_code == "000").
--
-- State in bb._watchdog_state (in-memory only — a container restart resets
-- to "assume up" and re-detects within poll_s + down_threshold_s if still
-- down. Side effect: if container restarts mid-outage, no "restored" ack
-- when the server comes back, since we never recorded the outage start.):
--
--   { is_up, first_failure_ms, last_alert_ms, alert_count,
--     last_probe_code, last_probe_ts }
--
-- Persistence:
--   <namespace>/irrigation_watchdog/status   — status (per-tick UPSERT)
--   <namespace>/irrigation_watchdog/events   — stream (only on transitions:
--                                              "down" first-alert, "restored")

local cjson              = require("cjson")
local clock              = require("clock")
local app_heartbeat      = require("app_heartbeat")
local irrigation_client  = require("irrigation_client")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC      = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY     = "fleet.notify.digest/1"
local SCHEMA_WATCHDOG   = "irrigation.watchdog/1"
local DEFAULT_POLL_S            = 60
local DEFAULT_DOWN_THRESHOLD_S  = 300       -- 5 min
local DEFAULT_ALERT_INTERVAL_S  = 300       -- 5 min

local function log(id, fmt, ...)
    io.stderr:write(string.format(
        "irrigation_watchdog [%s]: " .. fmt .. "\n", id.namespace, ...))
end

local function publish(ps, key, payload)
    local ok, err = pcall(function() ps:publish(key, payload) end)
    return ok, err
end

local function push_notify(ps, id, body)
    local payload = cjson.encode({
        schema   = SCHEMA_NOTIFY,
        class    = id.class,
        instance = id.instance,
        body     = body,
    })
    return publish(ps, DIGEST_TOPIC, payload)
end

local function fmt_duration(s)
    s = math.floor(s + 0.5)
    if s < 60 then return string.format("%d sec", s) end
    local m = math.floor(s / 60)
    local sr = s - m * 60
    if m < 60 then
        if sr == 0 then return string.format("%d min", m) end
        return string.format("%d min %d sec", m, sr)
    end
    local h = math.floor(m / 60)
    local mr = m - h * 60
    return string.format("%d h %d min", h, mr)
end

M.one_shot.IRRIGATION_WATCHDOG_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local cs       = bb._class_spec
    local id, ps   = bb._identity, bb._pubsub
    local irr      = (cs and cs.irrigation) or {}
    local cfg      = (cs and cs.irrigation_watchdog) or {}
    local poll_s   = cfg.poll_s             or DEFAULT_POLL_S
    local down_th  = cfg.down_threshold_s   or DEFAULT_DOWN_THRESHOLD_S
    local alert_iv = cfg.alert_interval_s   or DEFAULT_ALERT_INTERVAL_S
    local timeout  = cfg.probe_timeout_s    or 3
    local kb_label = "irrigation_watchdog"

    bb._watchdog_state = bb._watchdog_state or {
        is_up = nil, first_failure_ms = nil, last_alert_ms = nil,
        alert_count = 0, last_probe_code = nil, last_probe_ts = nil,
    }
    local state = bb._watchdog_state

    local host = irr.host
    if not host or host == "" then
        log(id, "config missing irrigation.host — skipping probe")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "config missing irrigation.host", poll_s)
        return
    end

    local client = irrigation_client.new{ host = host }
    local now_ms = clock.now_ms()
    local now_ts = os.time()
    local ok, code, err = client:ping(timeout)
    state.last_probe_code = code
    state.last_probe_ts   = now_ts

    if ok then
        -- Server reachable. If we'd previously alerted, ack the recovery.
        if state.alert_count and state.alert_count > 0 then
            local down_for_s = state.first_failure_ms
                and ((now_ms - state.first_failure_ms) / 1000) or 0
            local body = string.format(
                "🟢 Irrigation server %s RESTORED after %s (%d alert%s sent)",
                host, fmt_duration(down_for_s),
                state.alert_count, state.alert_count == 1 and "" or "s")
            push_notify(ps, id, body)
            local evt = cjson.encode({
                schema = SCHEMA_WATCHDOG, ts = now_ts,
                kind = "restored", host = host,
                down_duration_s = down_for_s,
                alert_count     = state.alert_count,
            })
            publish(ps, id.namespace .. "/irrigation_watchdog/events", evt)
            log(id, "RESTORED — was down %s, %d alerts sent",
                fmt_duration(down_for_s), state.alert_count)
        end
        state.is_up            = true
        state.first_failure_ms = nil
        state.last_alert_ms    = nil
        state.alert_count      = 0
    else
        -- Server unreachable. Start (or continue) tracking the outage.
        if state.first_failure_ms == nil then
            state.first_failure_ms = now_ms
            log(id, "probe failed (%s) — outage start recorded", tostring(err))
        end
        state.is_up = false
        local down_for_s = (now_ms - state.first_failure_ms) / 1000

        -- First alert at down_threshold_s; re-alert every alert_interval_s.
        if down_for_s >= down_th then
            local time_since_last = state.last_alert_ms
                and ((now_ms - state.last_alert_ms) / 1000) or math.huge
            if time_since_last >= alert_iv then
                local body = string.format(
                    "🔴 Irrigation server %s DOWN for %s. Please reset the Alexa plug.",
                    host, fmt_duration(down_for_s))
                local pn_ok, pn_err = push_notify(ps, id, body)
                if pn_ok then
                    state.last_alert_ms = now_ms
                    state.alert_count   = (state.alert_count or 0) + 1
                    log(id, "DOWN alert #%d sent (down for %s)",
                        state.alert_count, fmt_duration(down_for_s))
                    -- Only stream the FIRST alert as the down-transition event;
                    -- subsequent re-alerts are visible in the status leaf
                    -- (alert_count) and Discord. Avoids stream noise.
                    if state.alert_count == 1 then
                        local evt = cjson.encode({
                            schema = SCHEMA_WATCHDOG, ts = now_ts,
                            kind = "down", host = host,
                            down_for_s = down_for_s,
                        })
                        publish(ps, id.namespace .. "/irrigation_watchdog/events", evt)
                    end
                else
                    log(id, "WARN: alert push failed (%s) — will retry",
                        tostring(pn_err))
                end
            end
        end
    end

    -- Per-tick status leaf — dashboard reads this to show current state.
    local status = cjson.encode({
        schema           = SCHEMA_WATCHDOG,
        ts               = now_ts,
        host             = host,
        is_up            = state.is_up,
        last_probe_code  = state.last_probe_code,
        last_probe_ts    = state.last_probe_ts,
        first_failure_ts = state.first_failure_ms
            and (now_ts - math.floor((now_ms - state.first_failure_ms) / 1000))
            or nil,
        down_for_s       = state.first_failure_ms
            and math.floor((now_ms - state.first_failure_ms) / 1000)
            or 0,
        alert_count      = state.alert_count or 0,
    })
    publish(ps, id.namespace .. "/irrigation_watchdog/status", status)

    -- Heartbeat: ok when up; degraded when down (covers both pending-down
    -- and down-alerted — operator can see the precise status via the leaf).
    if state.is_up then
        app_heartbeat.stamp(handle, kb_label, "ok",
            string.format("up — last probe HTTP %s", tostring(code)), poll_s)
    else
        app_heartbeat.stamp(handle, kb_label, "degraded",
            string.format("down for %s (alerts=%d)",
                fmt_duration((now_ms - state.first_failure_ms) / 1000),
                state.alert_count or 0),
            poll_s)
    end
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
