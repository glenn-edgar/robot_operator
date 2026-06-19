-- chains/daily_pull_user_functions.lua — ct_* user fns for the daily-pull KB.
--
-- DAILY_PULL: calendar-gated daily fetch of Rancho's customer portal.
--
-- Daily-gate state machine, mirrors farm_soil/chains/digest_user_functions:
--   * already-published today      -> idle, ok
--   * pre-window (hour < hour_pacific) -> idle, ok
--   * in-window, not yet published -> fetch yesterday, format, publish
--                                     digest body + persistence leaves,
--                                     stamp last_published_date.
--
-- bb._rancho_state.last_published_date is in-memory only (reboot after
-- today's publish re-publishes today on the first in-window tick — same
-- caveat as farm_soil's digest, documented in class_spec).
--
-- Containment: portal fetch errors are return values, never raises; each
-- publish is pcall-wrapped. Degraded heartbeat surfaces the reason.

local cjson         = require("cjson")
local clock         = require("clock")
local app_heartbeat = require("app_heartbeat")
local daily_marker  = require("daily_marker")
local portal        = require("rancho_portal")
local fmt           = require("rancho_format")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC    = "fleet/notify/digest/daily"
local SCHEMA_DIGEST   = "fleet.notify.digest/1"
local SCHEMA_USAGE    = "rancho.water.usage/1"
local DEFAULT_RETRY_S = 900

local function log(id, fmt_str, ...)
    io.stderr:write(string.format(
        "daily_pull [%s]: " .. fmt_str .. "\n", id.namespace, ...))
end

-- "2026-05-24" -> "2026-05-23" (Pacific civil yesterday).
local function pacific_yesterday(epoch)
    local p = clock.pacific_at(epoch)
    local y, m, d = clock.civil_from_days(
        clock.days_from_civil(p.year, p.month, p.day) - 1)
    return string.format("%04d-%02d-%02d", y, m, d)
end

-- Compact hourly array for the persistence envelope. Each entry shrinks
-- from Rancho's ~140-byte JSON ({"Code":"","HCF":0,"GPH":...,"GPM":...,
-- "ThresholdHCF":0,"ThresholdGPH":0,"ExceededThreshold":false,"ReadTime":
-- "...T03:00:00"}) to ~30 bytes ({"h":"03","gph":135,"gpm":2}).
local function hourly_compact(usage)
    if type(usage) ~= "table" then return nil end
    local arr = {}
    for _, row in ipairs(usage) do
        local h = (type(row.ReadTime) == "string"
                   and row.ReadTime:match("T(%d%d):")) or "??"
        arr[#arr + 1] = { h = h, gph = row.GPH, gpm = row.GPM }
    end
    return arr
end

-- Build the per-day published envelope. Compact form is mandatory: the raw
-- Rancho API body is ~3.8 KB, and zenoh-pico SILENTLY DROPS multi-KB
-- payloads (see farm-soil-robot-2026-05-22 memory). With hourly_compact
-- the envelope lands at ~800 bytes — safely under any fragment limit.
local function usage_envelope(id, date_iso, data)
    data = data or {}
    return cjson.encode({
        schema   = SCHEMA_USAGE,
        class    = id.class,
        instance = id.instance,
        date     = date_iso,
        -- Day-level numbers — what a dashboard "today" panel needs.
        total_gallons = data.TotalGallons,
        total_hcf     = data.TotalHCF,
        day_of_week   = data.DayOfWeek,
        -- Rancho's own anomaly flags (we don't act on these in v1, but
        -- the dashboard and any v2 alert listener will).
        leak_detected              = data.LeakDetected,
        exceeded_flow_threshold    = data.ExceededFlowThreshold,
        exceeded_runtime_threshold = data.ExceededRuntimeThreshold,
        threshold_gallons          = data.ThresholdGallons,
        threshold_hcf              = data.ThresholdHCF,
        threshold_hours            = data.ThresholdHours,
        -- The per-hour series — compact form for the chart.
        hourly = hourly_compact(data.Usage),
    })
end

M.one_shot.DAILY_PULL = function(handle, _node)
    local bb     = handle.blackboard
    local id, ps = bb._identity, bb._pubsub
    local cs     = bb._class_spec
    local digest_cfg = (cs and cs.digest)  or {}
    local rancho_cfg = (cs and cs.rancho)  or {}
    local hour_p     = digest_cfg.hour_pacific or 9
    local retry_s    = digest_cfg.retry_s      or DEFAULT_RETRY_S

    bb._rancho_state = bb._rancho_state or { last_published_date = nil }
    local state = bb._rancho_state
    -- Hydrate from the persistent daily marker on first invocation so a
    -- container restart after today's pull already went out doesn't
    -- re-publish (used to re-spam Discord + persistence with the same data).
    if not state._loaded_from_marker then
        local persisted = daily_marker.read(id, "daily_pull")
        if persisted then state.last_published_date = persisted end
        state._loaded_from_marker = true
    end

    -- Gate on Pacific civil time. We publish on day D for data of day D-1.
    local p             = clock.pacific_now()
    local pacific_today = clock.california_today()
    local tz            = p.is_dst and "PDT" or "PST"

    if state.last_published_date == pacific_today then
        app_heartbeat.stamp(handle, "daily_pull", "ok",
            "already published " .. pacific_today, retry_s)
        return
    end

    if p.hour < hour_p then
        app_heartbeat.stamp(handle, "daily_pull", "ok",
            string.format("pre-window (now %02d:%02d %s, opens %02d:00)",
                p.hour, p.minute, tz, hour_p),
            retry_s)
        return
    end

    -- In-window, today not yet published.  Fetch yesterday's usage.
    local user = os.getenv("RANCHO_WATER_ACCOUNT")
    local pass = os.getenv("RANCHO_WATER_PASSWORD")
    if not user or user == "" or not pass or pass == "" then
        log(id, "RANCHO_WATER_ACCOUNT / _PASSWORD not set — skipping")
        app_heartbeat.stamp(handle, "daily_pull", "degraded",
            "credentials not set", retry_s)
        return
    end
    if not rancho_cfg.account_number then
        log(id, "rancho.account_number not configured — skipping")
        app_heartbeat.stamp(handle, "daily_pull", "degraded",
            "account_number not configured", retry_s)
        return
    end

    local target_date = pacific_yesterday(os.time())
    local client = portal.new{
        account_number = rancho_cfg.account_number,
        username       = user,
        password       = pass,
        timeout_s      = rancho_cfg.timeout_s or 30,
    }
    local body, ok, err = client:fetch_day(target_date)
    if not ok then
        log(id, "fetch FAILED for %s: %s", target_date, tostring(err))
        app_heartbeat.stamp(handle, "daily_pull", "degraded",
            string.format("fetch failed: %s", tostring(err):sub(1, 100)),
            retry_s)
        return
    end

    -- Decode for formatting. A bad-shape body is degraded but non-fatal —
    -- we still publish a "no data" digest for the day so the operator sees
    -- the gap.
    local ok_dec, data = pcall(cjson.decode, body)
    if not ok_dec then
        log(id, "JSON decode failed: %s", tostring(data))
        data = nil
    end

    local digest_body = fmt.format_daily_report(data, target_date)

    -- Publish 1: digest body to the shared notification channel.
    local digest_payload = cjson.encode({
        schema   = SCHEMA_DIGEST,
        class    = id.class,
        instance = id.instance,
        body     = digest_body,
    })
    local pok1, perr1 = pcall(function() ps:publish(DIGEST_TOPIC, digest_payload) end)
    if not pok1 then
        log(id, "digest publish FAILED: %s", tostring(perr1))
    end

    -- Publish 2+3: persistence leaves (stream + status). Compact envelope —
    -- the raw API body cannot be persisted as-is (zenoh-pico drops it).
    local usage_payload = usage_envelope(id, target_date, data)
    local sample_key = id.namespace .. "/usage/sample"
    local latest_key = id.namespace .. "/usage/latest"
    local pok2, perr2 = pcall(function() ps:publish(sample_key, usage_payload) end)
    local pok3, perr3 = pcall(function() ps:publish(latest_key, usage_payload) end)
    if not pok2 then log(id, "sample publish FAILED: %s", tostring(perr2)) end
    if not pok3 then log(id, "latest publish FAILED: %s", tostring(perr3)) end

    if pok1 then
        state.last_published_date = pacific_today
        local _, mark_err = daily_marker.write(id, "daily_pull", pacific_today)
        if mark_err then
            log(id, "WARN: daily_marker write failed (%s); restart could republish",
                tostring(mark_err))
        end
        local hours = (data and data.Usage) and #data.Usage or 0
        local total = (data and data.TotalGallons) or 0
        log(id, "published %s — %d hourly rows, %d gallons total",
            target_date, hours, total)
        app_heartbeat.stamp(handle, "daily_pull", "ok",
            string.format("published %s — %d hourly rows, %d gal",
                target_date, hours, total),
            retry_s)
    else
        app_heartbeat.stamp(handle, "daily_pull", "degraded",
            "digest publish failed", retry_s)
    end
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
