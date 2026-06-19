-- chains/cimis_user_functions.lua — ct_* user fns for the CIMIS KBs.
--
-- Two app KB instances share this module:
--   cimis_station  -> M.one_shot.CIMIS_TICK_STATION
--   cimis_spatial  -> M.one_shot.CIMIS_TICK_SPATIAL
-- Each is a 2-line wrapper around cimis_tick_impl(handle, source_id); the
-- only thing that differs is which source_id ("station"/"spatial") they
-- dispatch with. cimis_tick_impl reads its immutable config from
-- bb._class_spec.cimis (api_base, data_items, window_start_h, lookback_days,
-- retry_s, sources[source_id].{target_kind,target}) and its mutable state
-- from bb._cimis[source_id] (last_recorded_date, last_record).
--
-- Daily-gate semantics (per KB), retry_s cadence:
--   1. Up to date  (last_recorded_date == yesterday)  -> idle, heartbeat ok.
--   2. Pre-window  (Pacific hour < window_start_h)    -> idle, heartbeat ok.
--   3. In-window, gap pending                          -> fetch the trailing
--      `lookback_days`-day window ending yesterday; publish every newly-
--      finalized day in date order (oldest first); advance last_recorded_date.
--
-- There is NO post-window cutoff — past 15:00 / overnight, the robot keeps
-- retrying every retry_s until the gap closes. window_start_h=09:00 is
-- driven by a CIMIS-API quirk, not by a daily quota: before 09:00 today's
-- row is posted as a provisional/partial value the filter cannot reliably
-- reject. After 09:00 the Qc=="A" station flag and the spatial-0.0-blank-Qc
-- trap are both stable enough for the filter.
--
-- Each published day goes onto two leaves per source:
--   <namespace>/cimis/<source>/latest  — status (last-write-wins)
--   <namespace>/cimis/<source>/sample  — stream (one record per day; the
--                                        durable per-day record the
--                                        persistence layer subscribes to)
--
-- Each KB owns one in-memory record per source — last_record is the freshest
-- finalized day. The per-source repost queryable returns that record JSON,
-- or the JSON literal `null` when nothing's recorded yet. main.lua wires
-- the queryables and calls M.handle_repost_request.
--
-- Containment: TTN-style — fetch errors are return values (skip cycle,
-- stamp degraded); each Zenoh publish is pcall-wrapped. No raises.
--
-- Secret: CIMIS_APP_KEY from the environment (run.sh sources secrets/).

local cjson         = require("cjson")
local clock         = require("clock")
local cimis_client  = require("cimis_client")
local cimis_decoder = require("cimis_decoder")
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

local SCHEMA_READING = "cimis.eto/1"
local MEASUREMENT    = "DayAsceEto"     -- the single item these KBs care about

local function log(id, source_id, fmt, ...)
    io.stderr:write(string.format(
        "cimis-%s [%s]: " .. fmt .. "\n", source_id, id.namespace, ...))
end

-- The published-reading envelope. Small (~300 B) — well under the
-- zenoh-pico multi-KB drop threshold.
local function reading_json(class, instance, source_id, src, record)
    return cjson.encode({
        schema      = SCHEMA_READING,
        class       = class,
        instance    = instance,
        source      = source_id,
        target_kind = src.target_kind,
        target      = src.target,
        date        = record.date,
        item        = record.item,
        value       = record.value,
        unit        = record.unit,
        qc          = record.qc,
    })
end

local function publish_to(id, ps, source_id, src, record, leaf)
    local key = id.namespace .. "/cimis/" .. source_id .. "/" .. leaf
    local msg = reading_json(id.class, id.instance, source_id, src, record)
    local ok, err = pcall(function() ps:publish(key, msg) end)
    if not ok then
        log(id, source_id, "publish %s failed: %s", leaf, tostring(err))
    end
    return ok
end

-- Compute the ISO start date of the lookback window — `lookback_days` days
-- ending at `yesterday_iso` inclusive. Uses clock's date primitives so we
-- avoid any os.time / TZ dependency.
local function window_start_iso(yesterday_iso, lookback_days)
    local y, m, d = yesterday_iso:match("(%d+)-(%d+)-(%d+)")
    local z = clock.days_from_civil(tonumber(y), tonumber(m), tonumber(d))
    local sy, sm, sd = clock.civil_from_days(z - (lookback_days - 1))
    return string.format("%04d-%02d-%02d", sy, sm, sd)
end

-- The daily-gate state machine, source-agnostic.
local function cimis_tick_impl(handle, source_id)
    local bb         = handle.blackboard
    local cs         = bb._class_spec
    local id, ps     = bb._identity, bb._pubsub
    local cfg        = cs.cimis
    local src        = cfg.sources[source_id]
    local state      = bb._cimis[source_id]
    local kb_label   = "cimis_" .. source_id
    local yesterday  = clock.california_yesterday()

    -- Gate 1: yesterday already recorded -> idle.
    if state.last_recorded_date == yesterday then
        app_heartbeat.stamp(handle, kb_label, "ok",
            "up to date — last recorded " .. yesterday, cfg.retry_s)
        return
    end

    -- Gate 2: pre-09:00 Pacific -> idle (today's row still provisional).
    local p = clock.pacific_now()
    local tz = p.is_dst and "PDT" or "PST"
    if p.hour < cfg.window_start_h then
        app_heartbeat.stamp(handle, kb_label, "ok",
            string.format("pre-window (now %02d:%02d %s, opens %02d:00)",
                p.hour, p.minute, tz, cfg.window_start_h),
            cfg.retry_s)
        return
    end

    -- Gate 3: in-window, gap pending -> fetch the lookback window.
    local app_key = os.getenv("CIMIS_APP_KEY")
    if not app_key or app_key == "" then
        log(id, source_id, "CIMIS_APP_KEY not set — skipping fetch")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "CIMIS_APP_KEY not set", cfg.retry_s)
        return
    end

    local start_date = window_start_iso(yesterday, cfg.lookback_days)
    local client = cimis_client.new{
        app_key  = app_key,
        api_base = cfg.api_base,
    }
    local body, ok, err = client:fetch(
        src.target, cfg.data_items, start_date, yesterday)
    if not ok then
        log(id, source_id, "fetch FAILED (%s)", tostring(err))
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "fetch failed: " .. tostring(err):sub(1, 100), cfg.retry_s)
        return
    end

    -- Decode + filter: own target_kind, the ASCE ETo item, a finalized
    -- (non-A) qc on a non-null value, dated strictly after our last
    -- recorded date and strictly before today (belt-and-suspenders against
    -- the spatial provider's 0.0-with-blank-Qc trap; today's row should
    -- already be excluded by the API endDate=yesterday, but the filter
    -- is cheap and the wire isn't authoritative).
    local records   = cimis_decoder.parse_response(body)
    local today_iso = clock.california_today()
    local last_recorded = state.last_recorded_date or ""    -- "" sorts before any date
    local pending = {}
    for _, r in ipairs(records) do
        if  r.target_kind == src.target_kind
        and r.item        == MEASUREMENT
        and r.date        >  last_recorded
        and r.date        <  today_iso
        and r.value       ~= nil
        and r.qc          ~= "A"
        then
            pending[#pending + 1] = r
        end
    end
    table.sort(pending, function(a, b) return a.date < b.date end)

    if #pending == 0 then
        log(id, source_id, "no new finalized %s in window %s..%s (target=%s)",
            MEASUREMENT, start_date, yesterday, src.target)
        app_heartbeat.stamp(handle, kb_label, "ok",
            string.format("in window — no new data since %s (lookback %d d)",
                last_recorded == "" and "<never>" or last_recorded,
                cfg.lookback_days),
            cfg.retry_s)
        return
    end

    -- Publish in date order. The /sample leaf is the per-day stream; the
    -- /latest leaf gets overwritten N times so the freshest day wins.
    for _, r in ipairs(pending) do
        state.last_recorded_date = r.date
        state.last_record        = r
        publish_to(id, ps, source_id, src, r, "sample")
        publish_to(id, ps, source_id, src, r, "latest")
        log(id, source_id, "recorded %s %s = %s %s (qc=%s)",
            r.date, MEASUREMENT,
            tostring(r.value), tostring(r.unit), tostring(r.qc))
    end

    local newest = pending[#pending]
    app_heartbeat.stamp(handle, kb_label, "ok",
        string.format("recorded %d day(s); latest %s = %s",
            #pending, newest.date, tostring(newest.value)),
        cfg.retry_s)
end

M.one_shot.CIMIS_TICK_STATION = function(handle, _node)
    return cimis_tick_impl(handle, "station")
end

M.one_shot.CIMIS_TICK_SPATIAL = function(handle, _node)
    return cimis_tick_impl(handle, "spatial")
end

-- Per-source repost RPC handler — main.lua's pump calls this. The request
-- payload is ignored (latest-only by spec); reply is the latest recorded
-- reading JSON, or the JSON literal "null" when nothing's recorded yet.
function M.handle_repost_request(handle, source_id, _req_payload)
    local bb = handle.blackboard
    local cs = bb._class_spec
    local src = cs.cimis.sources[source_id]
    local state = (bb._cimis or {})[source_id]
    local id = bb._identity
    if not state or not state.last_record or not src then
        return "null"
    end
    return reading_json(id.class, id.instance, source_id, src, state.last_record)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
