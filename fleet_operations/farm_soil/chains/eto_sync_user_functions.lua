-- chains/eto_sync_user_functions.lua — ct_* user fns for the irrigation
-- ETo-sync KB.
--
-- ETO_SYNC_TICK: daily one-shot that adjusts the irrigation controller's
-- per-zone ETo accumulator to follow the difference between CIMIS station
-- and spatial readings.
--
-- Gates (evaluated each tick, every retry_s):
--   1. already-succeeded today                  -> idle ok
--   2. pre-window (Pacific hour < hour_pacific) -> idle ok
--   3. CIMIS station+spatial both present       -> idle (or 17:00 failure)
--   4. perform apply                            -> success or 17:00 failure
--
-- Math, per row in eto_update_table:
--   delta   = cimis.station.value - cimis.spatial.value          (one daily delta)
--   new_eto = clamp(0.0, 0.20, current_eto - delta)
--
-- Persistence: two leaves are published on success.
--   <namespace>/eto_sync/latest  — status row with last result
--   <namespace>/eto_sync/history — stream row per daily run
--
-- Discord push: a body string is published on the shared
-- `fleet/notify/digest/daily` topic. notification_service POSTs it.
--   * success    "ETO sync ok — N rows, K capped (cap=0.20), delta=+0.0234"
--   * failure    "ETO sync FAILED — <reason>"  (sent at-most-once per day,
--                                                only at-or-after 17:00 PT)
--
-- Idempotency: two disk markers under ${FLEET_DATA_DIR}/daily_markers/
--   farm_soil_<inst>_eto_sync.txt           — today's date when success.
--   farm_soil_<inst>_eto_sync_failure.txt   — today's date when failure
--                                             discord notification fired.
-- On boot we hydrate both into the blackboard state.

local cjson              = require("cjson")
local clock              = require("clock")
local app_heartbeat      = require("app_heartbeat")
local daily_marker       = require("daily_marker")
local irrigation_client  = require("irrigation_client")

local M = { main = {}, one_shot = {}, boolean = {} }

local TABLE_NAME       = "eto_update_table"
local DIGEST_TOPIC     = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY    = "fleet.notify.digest/1"
local SCHEMA_SUMMARY   = "irrigation.eto_sync/1"
local DEFAULT_RETRY_S  = 900
local MARKER_SUCCESS   = "eto_sync"
local MARKER_FAILURE   = "eto_sync_failure"

local function log(id, fmt, ...)
    io.stderr:write(string.format(
        "eto_sync [%s]: " .. fmt .. "\n", id.namespace, ...))
end

local function publish(ps, key, payload)
    local ok, err = pcall(function() ps:publish(key, payload) end)
    return ok, err
end

-- Push one Discord-bound message via the shared notify channel. The
-- notification_service subscribes to DIGEST_TOPIC and POSTs `body` verbatim
-- after a "[class/instance]" header.
local function push_notify(ps, id, body)
    local payload = cjson.encode({
        schema   = SCHEMA_NOTIFY,
        class    = id.class,
        instance = id.instance,
        body     = body,
    })
    return publish(ps, DIGEST_TOPIC, payload)
end

-- Publish the per-day result envelope on the eto_sync stream + status leaves.
local function publish_result_leaves(ps, id, summary)
    local payload = cjson.encode(summary)
    publish(ps, id.namespace .. "/eto_sync/latest", payload)
    publish(ps, id.namespace .. "/eto_sync/history", payload)
end

-- Hydrate persistent markers into bb state on the first call after a boot.
local function hydrate(state, id)
    if state._loaded then return end
    state.success_date          = daily_marker.read(id, MARKER_SUCCESS)
    state.failure_reported_date = daily_marker.read(id, MARKER_FAILURE)
    state._loaded = true
end

-- Pacific-tz-aware floor/cap on the per-row math.
local function clamp(v, lo, hi)
    if v < lo then return lo, "floor" end
    if v > hi then return hi, "cap"   end
    return v, nil
end

-- Returns true if it's at-or-after the failure-deadline hour.
local function past_failure_deadline(p, failure_hour)
    return p.hour >= failure_hour
end

-- Emit the failure notification (and write the failure marker) iff it's
-- past the deadline AND not already reported today.
local function maybe_report_failure(handle, state, id, ps, p, today, reason)
    local cs = handle.blackboard._class_spec
    local cfg = (cs and cs.eto_sync) or {}
    if state.failure_reported_date == today then return end
    if not past_failure_deadline(p, cfg.failure_hour_pacific or 17) then return end
    local body = string.format(
        "ETO sync FAILED for %s — %s", today, reason)
    local ok, err = push_notify(ps, id, body)
    if ok then
        local _, mark_err = daily_marker.write(id, MARKER_FAILURE, today)
        if mark_err then
            log(id, "WARN: failure marker write failed (%s); may double-notify",
                tostring(mark_err))
        end
        state.failure_reported_date = today
        log(id, "failure notified (%s)", reason)
    else
        log(id, "failure notify FAILED (%s) — will retry next tick",
            tostring(err))
    end
end

M.one_shot.ETO_SYNC_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local cs       = bb._class_spec
    local id, ps   = bb._identity, bb._pubsub
    local cfg      = (cs and cs.eto_sync) or {}
    local irr      = (cs and cs.irrigation) or {}
    local hour_p   = cfg.hour_pacific or 14
    local retry_s  = cfg.retry_s or DEFAULT_RETRY_S
    local kb_label = "eto_sync"

    bb._eto_sync_state = bb._eto_sync_state or {}
    local state = bb._eto_sync_state
    hydrate(state, id)

    local p             = clock.pacific_now()
    local pacific_today = clock.california_today()
    local tz            = p.is_dst and "PDT" or "PST"

    -- Gate 1: already succeeded today -> idle.
    if state.success_date == pacific_today then
        app_heartbeat.stamp(handle, kb_label, "ok",
            "already synced " .. pacific_today, retry_s)
        return
    end

    -- Gate 2: pre-window -> idle, no failure check (we haven't even tried).
    if p.hour < hour_p then
        app_heartbeat.stamp(handle, kb_label, "ok",
            string.format("pre-window (now %02d:%02d %s, opens %02d:00)",
                p.hour, p.minute, tz, hour_p), retry_s)
        return
    end

    -- Gate 3: CIMIS station + spatial both present?
    local cimis = bb._cimis or {}
    local r_st  = cimis.station and cimis.station.last_record or nil
    local r_sp  = cimis.spatial and cimis.spatial.last_record or nil
    if not r_st or not r_sp then
        local missing = (not r_st) and "station"
                          or "spatial"
        if (not r_st) and (not r_sp) then missing = "station+spatial" end
        maybe_report_failure(handle, state, id, ps, p, pacific_today,
            "CIMIS data not ready (missing " .. missing .. ")")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "waiting for CIMIS " .. missing, retry_s)
        return
    end

    -- Gate 4: read+write. Either step can fail; either failure triggers
    -- the 17:00 notification path.
    local host      = irr.host
    local account   = os.getenv("IRRIGATION_ACCOUNT")
    local password  = os.getenv("IRRIGATION_PASSWORD")
    if not host or host == "" then
        maybe_report_failure(handle, state, id, ps, p, pacific_today,
            "config missing irrigation.host")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "config missing irrigation.host", retry_s)
        return
    end
    if not account or account == "" or not password or password == "" then
        maybe_report_failure(handle, state, id, ps, p, pacific_today,
            "IRRIGATION_ACCOUNT/PASSWORD env not set")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "missing irrigation creds", retry_s)
        return
    end

    local client = irrigation_client.new{
        host      = host,
        account   = account,
        password  = password,
        timeout_s = irr.timeout_s or 15,
    }

    local current, ok, err = client:hgetall(TABLE_NAME)
    if not ok then
        local why = "fetch eto_update_table: " .. tostring(err):sub(1, 120)
        log(id, "%s", why)
        maybe_report_failure(handle, state, id, ps, p, pacific_today, why)
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "fetch failed", retry_s)
        return
    end
    if type(current) ~= "table" then
        local why = "fetch returned non-table"
        log(id, "%s (got %s)", why, type(current))
        maybe_report_failure(handle, state, id, ps, p, pacific_today, why)
        app_heartbeat.stamp(handle, kb_label, "degraded", why, retry_s)
        return
    end

    -- Compute the new dict and accounting fields.
    local delta = (r_st.value or 0) - (r_sp.value or 0)
    local cap   = cfg.cap   or 0.20
    local floor = cfg.floor or 0.0
    local new_table = {}
    local rows_total, rows_modified, rows_capped, rows_floored = 0, 0, 0, 0
    for k, v in pairs(current) do
        if type(v) == "number" then
            local proposed = v - delta
            local clamped, why = clamp(proposed, floor, cap)
            new_table[k] = clamped
            rows_total = rows_total + 1
            if math.abs(clamped - v) > 1e-9 then rows_modified = rows_modified + 1 end
            if why == "cap"   then rows_capped   = rows_capped   + 1 end
            if why == "floor" then rows_floored  = rows_floored  + 1 end
        end
    end

    if rows_total == 0 then
        local why = "eto_update_table is empty"
        log(id, "%s — treating as successful no-op", why)
        local summary = {
            schema      = SCHEMA_SUMMARY,
            date        = pacific_today,
            success     = true,
            no_op       = true,
            delta       = delta,
            cap         = cap, floor = floor,
            rows_total  = 0,   rows_modified = 0,
            rows_capped = 0,   rows_floored  = 0,
            cimis = { station = r_st.value, spatial = r_sp.value },
        }
        publish_result_leaves(ps, id, summary)
        push_notify(ps, id, string.format(
            "ETO sync ok %s — table empty, no-op (delta=%+.4f)",
            pacific_today, delta))
        daily_marker.write(id, MARKER_SUCCESS, pacific_today)
        state.success_date = pacific_today
        app_heartbeat.stamp(handle, kb_label, "ok",
            "no-op (table empty) " .. pacific_today, retry_s)
        return
    end

    local reply, ok2, err2 = client:hmset(TABLE_NAME, new_table)
    if not ok2 then
        local why = "hmset eto_update_table: " .. tostring(err2):sub(1, 120)
        log(id, "%s", why)
        maybe_report_failure(handle, state, id, ps, p, pacific_today, why)
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "hmset failed", retry_s)
        return
    end

    -- Success path. Build summary, publish leaves, push Discord notify,
    -- write the success marker.
    local summary = {
        schema        = SCHEMA_SUMMARY,
        date          = pacific_today,
        success       = true,
        delta         = delta,
        cap           = cap,
        floor         = floor,
        rows_total    = rows_total,
        rows_modified = rows_modified,
        rows_capped   = rows_capped,
        rows_floored  = rows_floored,
        cimis = { station = r_st.value, spatial = r_sp.value,
                  station_date = r_st.date, spatial_date = r_sp.date },
        reply = reply,
    }
    publish_result_leaves(ps, id, summary)

    local body = string.format(
        "ETO sync ok %s — %d rows, %d capped, %d floored (cap=%.2f, delta=%+.4f, station=%.4f spatial=%.4f)",
        pacific_today, rows_modified, rows_capped, rows_floored,
        cap, delta, r_st.value or 0, r_sp.value or 0)
    push_notify(ps, id, body)

    local _, mark_err = daily_marker.write(id, MARKER_SUCCESS, pacific_today)
    if mark_err then
        log(id, "WARN: success marker write failed (%s); restart may re-fire",
            tostring(mark_err))
    end
    state.success_date = pacific_today

    log(id, "applied %s — %d/%d rows changed, %d capped, %d floored, delta=%+.4f",
        pacific_today, rows_modified, rows_total,
        rows_capped, rows_floored, delta)
    app_heartbeat.stamp(handle, kb_label, "ok",
        string.format("applied %s — %d rows, delta=%+.4f",
            pacific_today, rows_modified, delta),
        retry_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
