-- chains/synoptic_user_functions.lua — ct_* user fns for the weather-ETo KBs.
--
-- Two app KB instances share this module — same Synoptic API, different
-- ground networks reflected in KB name + publish path:
--   sce_se224       -> M.one_shot.SCE_TICK_SE224       publishes sce/SE224/*
--   synoptic_sruc1  -> M.one_shot.SYNOPTIC_TICK_SRUC1  publishes synoptic/SRUC1/*
--
-- Each is a 2-line wrapper around synoptic_tick_impl(handle, stid). The only
-- thing that differs is which station_id ("SE224"/"SRUC1") they dispatch
-- with. synoptic_tick_impl reads its immutable config from
-- bb._class_spec.synoptic (retry_s, window_start_h, stations, cache_dir) and
-- its mutable state from bb._synoptic[stid] (last_recorded_date, last_record).
-- Each station entry carries `publish_prefix` ("sce" or "synoptic") that
-- determines its persistence-leaf prefix; the bb storage stays one slot.
--
-- Daily-gate semantics (per KB), retry_s cadence:
--   1. Up to date  (last_recorded_date == yesterday) -> idle, heartbeat ok.
--   2. Pre-window  (Pacific hour < window_start_h)  -> idle, heartbeat ok.
--   3. In-window, gap pending                        -> pull station data
--      for yesterday, run per-bin Penman, publish.
--
-- Per-station cache_dir: the SRUC1 station explicitly opts in via the class
-- spec; SE224 also benefits (same-day restart short-circuits). The lib's
-- fetch_csv reads cache first, falls back to API on miss.
--
-- Each published day goes onto two leaves per station:
--   <namespace>/synoptic/<stid>/sample  — stream (one record per finalized day)
--   <namespace>/synoptic/<stid>/latest  — status (last-write-wins)
--
-- Containment: fetch/parse/integrate errors are return values (skip cycle,
-- stamp degraded); each Zenoh publish is pcall-wrapped. No raises.
--
-- Secret: SYNOPTIC_TOKEN from the environment (run.sh sources secrets/ttn.env).

local cjson         = require("cjson")
local clock         = require("clock")
local app_heartbeat = require("app_heartbeat")
local synoptic_eto  = require("synoptic_eto")

local M = { main = {}, one_shot = {}, boolean = {} }

local SCHEMA_READING = "weather_eto/1"

local function log(id, stid, fmt, ...)
    io.stderr:write(string.format(
        "weather-%s [%s]: " .. fmt .. "\n", stid, id.namespace, ...))
end

-- The published-reading envelope. Small (~400 B) — well under the
-- zenoh-pico multi-KB drop threshold. `network` is the publish prefix
-- ("sce"/"synoptic"); explicit on the wire so consumers know provenance
-- without inferring from station name.
local function reading_json(class, instance, network, stid, station_name, record)
    return cjson.encode({
        schema       = SCHEMA_READING,
        class        = class,
        instance     = instance,
        network      = network,
        station      = stid,
        station_name = station_name,
        date         = record.date,
        eto_in       = record.eto,
        status       = record.status,
        coverage     = record.coverage,
        n_obs        = record.n_obs,
        n_bins       = record.n_bins,
        interval     = record.interval,
        day_hours    = record.day_hours,
        max_gap_min  = record.max_gap_min,
        alt_ft       = record.alt_ft,
        from_cache   = record.from_cache,
    })
end

local function publish_to(id, ps, prefix, stid, station_name, record, leaf)
    local key = id.namespace .. "/" .. prefix .. "/" .. stid .. "/" .. leaf
    local msg = reading_json(id.class, id.instance, prefix, stid, station_name, record)
    local ok, err = pcall(function() ps:publish(key, msg) end)
    if not ok then
        log(id, stid, "publish %s failed: %s", leaf, tostring(err))
    end
    return ok
end

-- The daily-gate state machine, station-agnostic. Each station's
-- publish_prefix ("sce"/"synoptic") determines its leaf path prefix; the
-- bb._synoptic[stid] slot stays one storage location regardless.
local function synoptic_tick_impl(handle, stid)
    local bb         = handle.blackboard
    local cs         = bb._class_spec
    local id, ps     = bb._identity, bb._pubsub
    local cfg        = cs.synoptic
    local st         = cfg.stations[stid]
    local state      = bb._synoptic[stid]
    local yesterday  = clock.california_yesterday()
    local retry_s    = cfg.retry_s

    if not st then
        local kb_label = "weather_" .. stid:lower()
        log(id, stid, "no station entry in class_spec.synoptic.stations")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "no station config", retry_s)
        return
    end

    -- Heartbeat label tracks the actual KB name (sce_se224 / synoptic_sruc1)
    -- so the dashboard's per-app status line reads cleanly.
    local prefix   = st.publish_prefix or "synoptic"
    local kb_label = prefix .. "_" .. stid:lower()

    -- Gate 1: yesterday already recorded -> idle.
    if state.last_recorded_date == yesterday then
        app_heartbeat.stamp(handle, kb_label, "ok",
            "up to date — last recorded " .. yesterday, retry_s)
        return
    end

    -- Gate 2: pre-window Pacific -> idle.
    local p = clock.pacific_now()
    local tz = p.is_dst and "PDT" or "PST"
    if p.hour < (cfg.window_start_h or 9) then
        app_heartbeat.stamp(handle, kb_label, "ok",
            string.format("pre-window (now %02d:%02d %s, opens %02d:00)",
                p.hour, p.minute, tz, cfg.window_start_h or 9),
            retry_s)
        return
    end

    -- Gate 3: in-window, gap pending -> fetch + integrate.
    local token = os.getenv("SYNOPTIC_TOKEN")
    if not token or token == "" then
        log(id, stid, "SYNOPTIC_TOKEN not set — skipping fetch")
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "SYNOPTIC_TOKEN not set", retry_s)
        return
    end

    -- Build the per-station opts. cache_dir is class-spec-controlled.
    local opts = {
        token     = token,
        cache_dir = cfg.cache_dir,
        timeout   = cfg.timeout or 30,
    }
    -- Per-station alt_ft / lat / interval come from the lib's M.stations
    -- registry; we also let the class spec override (rare).
    local station_table = synoptic_eto.stations[stid]
    if not station_table then
        log(id, stid, "station %s not in synoptic_eto.stations registry", stid)
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "unknown station " .. stid, retry_s)
        return
    end
    if st.alt_ft   then opts.alt_ft   = st.alt_ft   end
    if st.interval then opts.interval = st.interval end

    local res, err = synoptic_eto.daily_eto(stid, yesterday, opts)
    if not res then
        log(id, stid, "daily_eto FAILED (%s)", tostring(err))
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "fetch/integrate failed: " .. tostring(err):sub(1, 100), retry_s)
        return
    end

    -- Always publish (even PARTIAL/SPARSE) — the resolver decides whether to
    -- consume. Status is on the wire; consumers gate themselves.
    state.last_recorded_date = res.date
    state.last_record        = res
    publish_to(id, ps, prefix, stid, res.name, res, "sample")
    publish_to(id, ps, prefix, stid, res.name, res, "latest")

    log(id, stid, "recorded %s ETo=%.3f in (cov %.0f%% / %d obs, %s%s)",
        res.date, res.eto, res.coverage * 100, res.n_obs, res.status,
        res.from_cache and ", cached" or "")
    app_heartbeat.stamp(handle, kb_label, "ok",
        string.format("recorded %s ETo=%.3f (%s)", res.date, res.eto, res.status),
        retry_s)
end

M.one_shot.SCE_TICK_SE224 = function(handle, _node)
    return synoptic_tick_impl(handle, "SE224")
end

M.one_shot.SYNOPTIC_TICK_SRUC1 = function(handle, _node)
    return synoptic_tick_impl(handle, "SRUC1")
end

-- Per-station repost RPC handler — main.lua's pump may call this. The
-- request payload is ignored (latest-only); reply is the latest recorded
-- reading JSON or the literal "null". Resolves the station's publish_prefix
-- so the reply carries the correct `network` field.
function M.handle_repost_request(handle, stid, _req_payload)
    local bb = handle.blackboard
    local state = (bb._synoptic or {})[stid]
    local id = bb._identity
    if not state or not state.last_record then return "null" end
    local cs = bb._class_spec
    local st = cs and cs.synoptic and cs.synoptic.stations[stid]
    local prefix = (st and st.publish_prefix) or "synoptic"
    return reading_json(id.class, id.instance, prefix, stid,
        state.last_record.name, state.last_record)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
