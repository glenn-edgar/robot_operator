-- chains/digest_user_functions.lua — DAILY_DIGEST one-shot for the
-- KB2/KB4 daily operator digest (Glenn 2026-06-10).
--
-- At most once per Pacific civil day, on/after hour_pacific (18:00), read
-- the confirmed alert rows the KBs recorded in kb_alerts (last 24 h),
-- compose a short summary + dashboard link, and publish on the shared
-- `fleet/notify/digest/daily` topic. notification_service POSTs it to the
-- same Discord channel the KB1/KB3 action alerts use.
--
-- Robot owns content, service owns transport — this KB does not know Discord
-- exists. Daily-gate + daily_marker restart-idempotency mirror
-- farm_soil/chains/digest_user_functions.lua.

local cjson         = require("cjson")
local clock         = require("clock")
local app_heartbeat = require("app_heartbeat")
local daily_marker  = require("daily_marker")
local digest_summary = require("digest_summary")
local NOTIFY        = require("notifications")

local NOTIFY_DB_PATH = os.getenv("NOTIFY_DB_PATH") or "/var/fleet/notify/notifications.db"

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC    = "fleet/notify/digest/daily"
local SCHEMA_DIGEST   = "fleet.notify.digest/1"
local DEFAULT_RETRY_S = 900
local DEFAULT_HOUR_P  = 18
local DEFAULT_KB_DBS  = { "/var/fleet/kb2/kb2.db", "/var/fleet/kb2_wr/kb2_wr.db" }

local function log(id, fmt, ...)
    io.stderr:write(string.format("digest [%s]: " .. fmt .. "\n", id.namespace, ...))
end

M.one_shot.DAILY_DIGEST = function(handle, _node)
    local bb     = handle.blackboard
    local id, ps = bb._identity, bb._pubsub
    local cs     = bb._class_spec
    local cfg    = (cs and cs.digest) or {}
    local hour_p  = cfg.hour_pacific or DEFAULT_HOUR_P
    local retry_s = cfg.retry_s or DEFAULT_RETRY_S
    local kb_dbs  = cfg.kb_db_paths or DEFAULT_KB_DBS
    local dash    = cfg.dashboard_url or os.getenv("DASHBOARD_URL")

    bb._digest_state = bb._digest_state or { last_published_date = nil }
    local state = bb._digest_state
    if not state._loaded_from_marker then
        local persisted = daily_marker.read(id, "irrigation_digest")
        if persisted then state.last_published_date = persisted end
        state._loaded_from_marker = true
    end

    local p             = clock.pacific_now()
    local pacific_today = clock.california_today()
    local tz            = p.is_dst and "PDT" or "PST"

    -- Gate 1: already published today.
    if state.last_published_date == pacific_today then
        app_heartbeat.stamp(handle, "digest", "ok",
            "already published " .. pacific_today, retry_s)
        return
    end

    -- Gate 2: pre-window.
    if p.hour < hour_p then
        app_heartbeat.stamp(handle, "digest", "ok",
            string.format("pre-window (now %02d:%02d %s, opens %02d:00)",
                p.hour, p.minute, tz, hour_p), retry_s)
        return
    end

    -- Gate 3: in-window — roll up confirmed KB2/KB4 alerts from the last 24 h.
    local body, counts = digest_summary.build_summary({
        kb_db_paths   = kb_dbs,
        now_ms        = os.time() * 1000,
        window_s      = 86400,
        report_date   = pacific_today,
        dashboard_url = dash,
    })

    -- Nothing flagged → no message. Do NOT stamp the day: keep watching so a
    -- late-afternoon resistance cycle can still produce today's digest.
    if not body then
        app_heartbeat.stamp(handle, "digest", "ok",
            string.format("in-window, nothing to report (%s)", pacific_today), retry_s)
        return
    end

    local payload = cjson.encode({
        schema = SCHEMA_DIGEST, class = id.class, instance = id.instance, body = body,
    })
    local ok, err = pcall(function() ps:publish(DIGEST_TOPIC, payload) end)
    if ok then
        state.last_published_date = pacific_today
        -- Past-actions log (the /irrigation/actions page reads this) + 14-day prune.
        if not state.notify_db then state.notify_db = NOTIFY.open_db(NOTIFY_DB_PATH) end
        if state.notify_db then
            local now_ms = os.time() * 1000
            NOTIFY.record(state.notify_db, {
                ts_ms = now_ms, level = "YELLOW", source = "DIGEST", kind = "DAILY_SUMMARY",
                target = pacific_today, action = "",
                title = string.format("Daily review — failrisk=%d short=%d thermal=%d wear=%d",
                    counts.failure_risk, counts.short, counts.thermal, counts.wear),
                body = body,
            })
            NOTIFY.prune(state.notify_db, now_ms)
        end
        local _, mark_err = daily_marker.write(id, "irrigation_digest", pacific_today)
        if mark_err then
            log(id, "WARN: daily_marker write failed (%s); restart could republish",
                tostring(mark_err))
        end
        log(id, "published digest %s — failrisk=%d short=%d thermal=%d wear=%d clog=%d",
            pacific_today, counts.failure_risk, counts.short,
            counts.thermal, counts.wear, counts.clog)
        app_heartbeat.stamp(handle, "digest", "ok",
            string.format("published %s (%d flagged groups)", pacific_today,
                (counts.failure_risk>0 and 1 or 0)+(counts.short>0 and 1 or 0)
               +(counts.thermal>0 and 1 or 0)+(counts.wear>0 and 1 or 0)
               +(counts.clog>0 and 1 or 0)),
            retry_s)
    else
        log(id, "digest publish FAILED: %s", tostring(err))
        app_heartbeat.stamp(handle, "digest", "degraded", "digest publish failed", retry_s)
    end
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
