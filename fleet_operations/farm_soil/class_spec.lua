-- class_spec.lua — farm_soil class spec.
--
-- Per decision #31 every robot class ships a class_spec.lua. The shared KB0
-- consumes it: `capabilities` go in the registration payload, `app_kbs` are
-- spawned once the namespace is up, and `on_namespace_up` adds any
-- class-specific topology.

local M = {}

M.capabilities = {
    "heartbeat",
    "soil_moisture",
    "et_reference",         -- daily ASCE ETo via the CIMIS Web API
    "synoptic_eto",         -- daily per-bin Penman ETo from Synoptic stations
    "eto_resolver",         -- priority-chain selection of daily ETo source
}

-- Application KBs spawned after the robot reaches operating.
-- cimis_station/cimis_spatial are two instances of the same skill module
-- (chains/cimis.lua) — one per CIMIS provider, each with its own retry loop.
-- synoptic_se224/synoptic_sruc1 are two instances of the Synoptic skill
-- (chains/synoptic.lua) — one per station, per-bin Penman computed locally.
-- eto_resolver picks the daily ETo source by priority chain and publishes
-- the winner to <ns>/eto/{daily,latest} for the dashboard.
M.app_kbs = { "moisture", "cimis_station", "cimis_spatial",
              "sce_se224", "synoptic_sruc1", "eto_resolver",
              "digest", "eto_sync", "irrigation_watchdog" }

-- TTN v3 storage API config for the moisture skill. The bearer token is NOT
-- here — it is a secret, read from the TTN_BEARER_TOKEN env var (run.sh
-- sources secrets/ttn.env).
M.ttn = {
    url_base       = "https://nam1.cloud.thethings.network/api/v3/as/applications/",
    app_name       = "seeedec",
    url_after      = "/packages/storage/uplink_message?",
    -- 7 days of LaCima hourly uplinks = 168 records per device. Backfill
    -- window 168 h handles restart-after-multi-day-downtime. limit covers
    -- two devices' worth of records in one fetch (the per-fetch cap, not
    -- a TTN account quota).
    lookback_hours = 168,
    limit          = 500,
}

-- CIMIS Web API config for the cimis_station / cimis_spatial KBs. The appKey
-- is NOT here — it is a secret, read from the CIMIS_APP_KEY env var (run.sh
-- sources secrets/ttn.env). Spatial targets are zip codes ONLY (coordinate
-- forms are blocked by et.water.ca.gov's WAF, verified live 2026-05-22).
--
-- Daily-gate semantics (per KB): each retry_s seconds, run the gate.
--   * pre-window  (Pacific hour < window_start_h) -> idle, ok.
--   * in-window   (>= window_start_h, gap exists) -> fetch the last
--                 lookback_days through yesterday, publish every newly-
--                 finalized day in order, advance last_recorded_date.
--   * up-to-date  (last_recorded_date == yesterday) -> idle, ok.
--
-- window_start_h is 09:00 Pacific because CIMIS posts today's row earlier
-- in the day as a provisional/partial value the filter cannot reliably
-- reject. After 09:00 the Qc=="A" station flag and the spatial-today-
-- 0.0-with-blank-Qc trap are both stable. There is NO post-window cutoff:
-- the robot keeps retrying past 15:00 / overnight until the gap closes.
-- Publishes go to two leaves per source:
--   * <namespace>/cimis/<source>/latest  — status (last-write-wins)
--   * <namespace>/cimis/<source>/sample  — stream (one per finalized day)
M.cimis = {
    api_base       = "https://et.water.ca.gov/api/data",
    data_items     = "day-asce-eto",
    window_start_h = 9,            -- inclusive (Pacific civil)
    lookback_days  = 7,            -- multi-day fetch window for gap-self-heal
    retry_s        = 900,          -- 15 minutes between attempts
    sources = {
        -- station 237 = Temecula East II (closest to the Murrieta site).
        station = { target_kind = "station", target = "237"   },
        -- 92562 = Murrieta CA (21005 Paseo Montañez).
        spatial = { target_kind = "spatial", target = "92562" },
    },
}

-- Synoptic/MesoWest config — read by chains/synoptic_user_functions.lua.
-- Token comes from the environment (SYNOPTIC_TOKEN, sourced by run.sh from
-- secrets/ttn.env). cache_dir is the once-per-day belt-and-suspenders: if
-- the dated CSV exists, the API is not called. The dir is created by the
-- robot's writes; pre-existing files survive a restart. Same daily-gate
-- pattern as cimis: each retry_s, run the gate; pre-window -> idle.
--
-- Two app KB instances — same API client, different ground networks. The
-- station's publish_prefix encodes ownership and drives the persistence path:
--   sce_se224       -> SE224 (SCE Murrieta Hogbacks, 1370 ft, 10-min)
--                       publishes <ns>/sce/SE224/{sample,latest}
--   synoptic_sruc1  -> SRUC1 (Santa Rosa Plateau RAWS, 1987 ft, hourly)
--                       publishes <ns>/synoptic/SRUC1/{sample,latest}
-- cache_dir resolves to $FLEET_DATA_DIR/synoptic_cache on the container
-- (the start.sh supervisor sets FLEET_DATA_DIR=/var/fleet) and to ./var/...
-- on the bench. Same pattern as moisture.lua / daily_marker.lua.
local function resolve_data_dir(sub)
    local d = os.getenv("FLEET_DATA_DIR")
    if d and #d > 0 then return d .. "/" .. sub end
    return "./var/" .. sub
end

M.synoptic = {
    window_start_h = 9,        -- Pacific civil; matches CIMIS for consistency
    retry_s        = 900,      -- 15 minutes
    timeout        = 30,       -- per-curl timeout
    cache_dir      = resolve_data_dir("synoptic_cache"),
    stations = {
        SE224 = { alt_ft = 1370, lat = 33.584,  interval = 600,
                  publish_prefix = "sce" },
        SRUC1 = { alt_ft = 1987, lat = 33.5181, interval = 3600,
                  publish_prefix = "synoptic" },
    },
}

-- Daily ETo priority resolver — read by chains/eto_resolver_user_functions.lua.
-- Walks priority[] in order, picks the first source whose latest record is
-- for yesterday with status OK and coverage >= min_coverage. Non-Synoptic
-- (CIMIS) sources are treated as coverage=1.0 since they don't report it.
-- Publishes to <namespace>/eto/{daily,latest}; the dashboard reads these.
M.eto_resolver = {
    retry_s      = 900,
    min_coverage = 0.85,
    priority     = { "SE224", "cimis_spatial", "SRUC1", "cimis_station" },
}

-- Daily-digest config — read by chains/digest_user_functions.lua.
-- The digest is a calendar-anchored daily-gate state machine (same pattern
-- as the CIMIS KBs): the column ticks every retry_s, but DAILY_DIGEST
-- actually publishes at most once per Pacific civil day, on the first tick
-- at-or-after hour_pacific. Default hour 9 chosen so CIMIS's morning fetch
-- (window opens at 09:00 Pacific too) has a chance to publish today's ETo
-- before the digest snapshots blackboard state.
--
-- Last-published date is in-memory only (bb._digest_state.last_published_date).
-- A robot reboot AFTER today's digest already went out will re-publish today
-- when the retry cycle next opens the gate. Acceptable for v1; if dedup
-- matters later, persist to identity-dir state.
M.digest = {
    hour_pacific = 9,           -- inclusive (Pacific civil hour)
    retry_s      = 900,         -- 15 min retry cadence (matches CIMIS)
}

-- Irrigation-site config — read by chains/eto_sync_user_functions.lua.
-- Host is deployment data, not a secret. Account/password come from the
-- environment (IRRIGATION_ACCOUNT / IRRIGATION_PASSWORD, sourced by run.sh
-- from secrets/ttn.env).
M.irrigation = {
    host      = "192.168.1.146",
    timeout_s = 15,
}

-- Smart-plug control — read by chains/irrigation_watchdog_user_functions.lua
-- via lib/plug_client.lua. The irrigation Pi is powered by an Amazon Basics
-- smart plug, which has no LAN API — we power it on through Voice Monkey (an
-- Alexa skill) by firing a "trigger" device wired in the Alexa app to a
-- "turn ON <plug>" Routine. `device` is the Voice Monkey trigger-device id
-- (deployment data, not a secret); the token comes from the environment
-- (VOICEMONKEY_TOKEN, sourced by run.sh from secrets/ttn.env). Set
-- enabled=false (or leave the token/device blank) to disable auto power-on
-- and fall back to the manual "reset the Alexa plug" Discord nag.
M.plug = {
    enabled = true,
    device  = "irrigation-pi-power-3f7k2-d4ukm",  -- Voice Monkey trigger-device id
}

-- ETO-sync skill config — read by chains/eto_sync_user_functions.lua.
-- Daily one-shot that adjusts the irrigation controller's per-zone ETo
-- accumulator (eto_update_table Redis hash) by the CIMIS station-vs-spatial
-- delta, clamped to [floor, cap]. retry_s ticks; the actual once-per-day
-- gate is evaluated inside ETO_SYNC_TICK. If we haven't succeeded by
-- failure_hour_pacific, a single Discord failure notification fires for
-- the day (failure_hour_pacific=20 = 8pm Pacific). See [[cimis-skill-2026-05-22]]
-- for the daily-gate pattern this mirrors.
M.eto_sync = {
    hour_pacific          = 17,    -- window opens 17:30 PT (5:30pm)
    minute_pacific        = 30,    -- ...minute component of the window open
    failure_hour_pacific  = 20,    -- discord-failure deadline = 20:00 PT
    retry_s               = 900,   -- 15 min retry cadence
    cap                   = 0.18,  -- per-row upper clamp
    floor                 = 0.0,   -- per-row lower clamp
}

-- Irrigation-site liveness watchdog config — read by
-- chains/irrigation_watchdog_user_functions.lua.
-- Polls M.irrigation.host every poll_s. While down, it first tries to
-- self-heal by firing the Voice Monkey "turn ON" trigger (see M.plug):
-- after recover_after_s down it fires once, then re-fires every
-- recover_cooldown_s (long enough for the Pi to power up + boot) up to
-- recover_max_attempts. Only once auto-recovery is exhausted (or disabled)
-- does it fall back to the Discord "DOWN, reset the Alexa plug" nag at
-- down_threshold_s, re-posting every alert_interval_s. On recovery it posts
-- one "RESTORED" ack noting whether it self-healed. State is in-memory only
-- (container restart resets to "assume up"; tradeoff documented in the
-- user_functions module).
M.irrigation_watchdog = {
    poll_s               = 60,     -- probe cadence
    down_threshold_s     = 300,    -- 5 min sustained down before first nag
    alert_interval_s     = 300,    -- 5 min between repeated nags
    probe_timeout_s      = 3,      -- per-probe curl timeout
    recover_after_s      = 120,    -- down this long -> fire first auto power-on
    recover_cooldown_s   = 180,    -- min gap between power-on attempts (boot time)
    recover_max_attempts = 3,      -- give up auto-recovery after this many tries
}

-- device_id -> location (the sensing-point sub-namespace). Adding a sensor is
-- one line here. The locations below are placeholders — set the real
-- plot/zone names per deployment. An unmapped device publishes under
-- <device>/unknown rather than being dropped.
M.device_locations = {
    lacima1c  = "zone1",
    lacima1d  = "zone2",
    lacamia1b = "zone3",
}

-- Persistence-topology declaration. Returns the list of leaves under this
-- robot's namespace that the persistence layer should store, with their kind
-- (stream = circular per-path buffer of `length` rows; status = UPSERT-by-
-- path single value) and pre-allocation size. The robot announces this
-- once on namespace_up and the persistence service uses it to idempotently
-- construct_kb the matching ltree paths (decision #6/#9: firmware/class IS
-- the schema; the persistence layer does not know the topology a priori).
--
-- Each `path` is the leaf tail under `<namespace>/`; the persistence service
-- prepends `<class>.<instance>.` and converts `/` -> `.` to derive the
-- ltree field name (e.g. `cimis/station/sample` -> field name
-- `farm_soil.lacima01.cimis.station.sample`).
function M.persistence_topology()
    local topo = {}
    for source_id, _ in pairs(M.cimis.sources) do
        topo[#topo + 1] = {
            path   = "cimis/" .. source_id .. "/sample",
            kind   = "stream",
            length = 30,                       -- ~1 month of daily ETo per source
            desc   = "CIMIS daily ETo per-day stream (" .. source_id .. ")",
        }
        topo[#topo + 1] = {
            path = "cimis/" .. source_id .. "/latest",
            kind = "status",
            desc = "CIMIS daily ETo latest (" .. source_id .. ")",
        }
    end
    for device, location in pairs(M.device_locations) do
        topo[#topo + 1] = {
            path   = device .. "/" .. location .. "/latest",
            kind   = "stream",
            length = 256,                      -- matches the in-robot ring depth
            desc   = "soil moisture readings — " .. device .. " / " .. location,
        }
    end
    topo[#topo + 1] = {
        path = "heartbeat",
        kind = "status",
        desc = "robot rolled-up heartbeat",
    }
    -- ETO-sync daily-run result — one stream entry per applied day, plus a
    -- status leaf for the dashboard's most-recent panel.
    topo[#topo + 1] = {
        path   = "eto_sync/history",
        kind   = "stream",
        length = 30,                            -- ~1 month of daily runs
        desc   = "irrigation eto_sync per-day apply result",
    }
    topo[#topo + 1] = {
        path = "eto_sync/latest",
        kind = "status",
        desc = "irrigation eto_sync most-recent result",
    }
    -- Per-station daily ETo (per-bin Penman computed on-robot). Each
    -- station's publish_prefix encodes its ground network — sce/SE224/* for
    -- SCE Murrieta Hogbacks, synoptic/SRUC1/* for the Synoptic-native RAWS
    -- station. Adding a station = one row above.
    for stid, st in pairs(M.synoptic.stations) do
        local prefix = st.publish_prefix or "synoptic"
        topo[#topo + 1] = {
            path   = prefix .. "/" .. stid .. "/sample",
            kind   = "stream",
            length = 30,
            desc   = prefix:upper() .. " " .. stid .. " daily ETo per-day stream",
        }
        topo[#topo + 1] = {
            path = prefix .. "/" .. stid .. "/latest",
            kind = "status",
            desc = prefix:upper() .. " " .. stid .. " daily ETo latest",
        }
    end
    -- Resolved daily ETo — the value the dashboard renders as "today's ETo".
    -- Stream carries the full chain verdict; status is the freshest day.
    topo[#topo + 1] = {
        path   = "eto/daily",
        kind   = "stream",
        length = 60,                            -- ~2 months
        desc   = "resolved daily ETo (priority-chain winner + fallback trace)",
    }
    topo[#topo + 1] = {
        path = "eto/latest",
        kind = "status",
        desc = "resolved daily ETo (most recent)",
    }
    -- Irrigation-site liveness watchdog: status leaf updated every probe,
    -- events stream only on down/restored transitions.
    topo[#topo + 1] = {
        path   = "irrigation_watchdog/events",
        kind   = "stream",
        length = 60,                            -- ~headroom for a noisy outage week
        desc   = "irrigation server down/restored transition events",
    }
    topo[#topo + 1] = {
        path = "irrigation_watchdog/status",
        kind = "status",
        desc = "irrigation server liveness — most-recent probe result",
    }
    return topo
end

-- Publish the persistence topology onto BOTH channels:
--   <namespace>/persistence_topology
--       per-namespace channel; ad-hoc consumers (a CLI, a debug tool)
--       that already know the robot's identity subscribe here.
--   fleet/admin/persistence_topology_announce
--       fleet-wide discovery channel; the persistence service subscribes
--       only here, demuxing class+instance from the payload. The token
--       binding has no wildcard / string-prefix subscribe, so we cannot
--       use a `**/persistence_topology` sub; a single shared token is
--       the workaround.
--
-- Called from on_namespace_up (first publish) AND periodically from
-- main.lua's pump (default cadence below) so a late-joining persistence
-- service (e.g., persistence restarted while the robot is up) catches the
-- topology within one cadence and the next data publishes land on its
-- subs. `silent` suppresses the success log for periodic calls.
function M.publish_persistence_topology(ps, identity, silent)
    local cjson = require("cjson")
    local topo = M.persistence_topology()
    local payload = cjson.encode({
        schema   = "persistence_topology/1",
        class    = identity.class,
        instance = identity.instance,
        entries  = topo,
    })
    local function pub(key)
        local ok, err = pcall(function() ps:publish(key, payload) end)
        if not ok then
            io.stderr:write(string.format(
                "FARM_SOIL [%s]: persistence_topology publish to %s failed: %s\n",
                identity.namespace, key, tostring(err)))
        end
        return ok
    end
    local ok1 = pub(identity.namespace .. "/persistence_topology")
    local ok2 = pub("fleet/admin/persistence_topology_announce")
    if ok1 and ok2 and not silent then
        io.stderr:write(string.format(
            "FARM_SOIL [%s]: persistence_topology published (%d entries, 2 channels)\n",
            identity.namespace, #topo))
    end
    return ok1 and ok2
end

-- Topology re-announce cadence (seconds). Tuned to balance:
--   * how quickly a late-joining persistence service catches up (≤ this)
--   * how much wire chatter we add per robot (small payload, infrequent)
-- 30s gives a worst-case discovery delay of 30s for a persistence restart,
-- which is comfortably under the slowest data cadence on the robot
-- (CIMIS at 15 min).
M.PERSISTENCE_TOPOLOGY_REPUBLISH_S = 30

-- Class hook, run after KB0 publishes the core namespace leaves.
function M.on_namespace_up(ps, identity, bb)
    M.publish_persistence_topology(ps, identity, false)
end

return M
