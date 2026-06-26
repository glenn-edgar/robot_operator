-- class_spec.lua — irrigation_analytics class spec.
--
-- The robot's job: real-time monitor + analyzer of the LaCima irrigation
-- controller. Mirrors the existing bare-LuaJIT robot at robot/main.lua, but
-- packaged into the fleet_design chain_tree framework so it gets:
--   - Zenoh persistence of state + events (queryable history)
--   - Dashboard panel via application_gateway
--   - Manual suspend RPC from the web portal
--   - Uniform heartbeat / Discord pattern
--
-- Phase 1: skeleton — single "monitor" app KB that just heartbeats. The
-- KB1/KB3 detection logic ports in Phase 3; KB2 calibrator in Phase 4.

local M = {}

M.capabilities = {
    "heartbeat",
    "irrigation_state",
    "irrigation_fault_detection",
}

M.app_kbs = { "monitor", "detector", "kb4_clog", "kb2_resistance",
              "kb1_overcurrent", "kb2_within_run", "kb3_sustained",
              "kb4_v2", "digest" }

-- Controller config — where to fetch popup + past_actions from.
-- Reused by lib/controller_client.lua (which wraps the SSH+python popup
-- fetch from the existing robot/lib/controller.lua).
M.controller = {
    ssh_host  = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s = 8,
    poll_s    = tonumber(os.getenv("IRRIGATION_POLL_S") or "30"),
}

-- Detector config — KB1+KB3 fault detector. Same SSH/poll knobs as controller
-- by default; can be split per-env if KB1 needs a different cadence.
-- curves_path  → per-bin KB1 current thresholds (output of explore/generate_curves)
-- baselines_path → per-bin KB3 flow baselines (output of explore/baseline_state/)
-- Both shipped into the image at build time; runtime is read-only for KB1/KB3.
-- KB2/KB4 (when added) will need a bind-mount instead since they write.
M.detector = {
    ssh_host       = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s      = 8,
    poll_s         = tonumber(os.getenv("IRRIGATION_DETECTOR_POLL_S") or "30"),
    curves_path    = os.getenv("KB1_THRESHOLDS_JSON")
                     or "/app/irrigation_analytics/data/kb1_thresholds.json",
    baselines_path = os.getenv("BASELINES_JSON")
                     or "/app/irrigation_analytics/data/baselines.json",
}

-- KB4 clog/leak detector config — flow-only, per-bin SQLite baseline.
-- Subscribes to past_actions STEP_COMPLETE, classifies non-ETO bins,
-- emits Discord on LEAK (flow > baseline+5 GPM), DB-warn on ±3 GPM drift.
-- ETO bins are skipped (deferred to a separate ETO-path handler).
-- db_path lives on the writable bind mount; seed + eto_valves are baked
-- into the image.
M.kb4_clog = {
    ssh_host         = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s        = 8,
    poll_s           = tonumber(os.getenv("IRRIGATION_KB4_POLL_S") or "30"),
    db_path          = os.getenv("KB4_DB_PATH") or "/var/fleet/kb4/kb4.db",
    seed_path        = os.getenv("KB4_SEED_JSON")
                       or "/app/irrigation_analytics/data/kb4_nonETO_baselines.json",
    seed_eto_path    = os.getenv("KB4_ETO_SEED_JSON")
                       or "/app/irrigation_analytics/data/kb4_ETO_baselines.json",
    eto_valves_path  = os.getenv("ETO_VALVES_JSON")
                       or "/app/irrigation_analytics/data/eto_valves.json",
}

-- KB2 resistance trend detector. Polls IRRIGATION_VALVE_TEST hash for new
-- valve_test cycles, computes per-valve coil R via 2-null offset method
-- (sat_3:1 + sat_4:6, R = 15.6 V / (I_raw - offset)), classifies vs
-- rolling-median baseline. WSL test phase: monitor-only, Discord on
-- R_DRIFT_ALERT (sustained 3-cycle) + MASTER_RELAY_CREEP for sat_1:43.
-- db_path lives on the writable bind mount; no static seed file — baseline
-- is built up at runtime from the first cycle onward.
M.kb2_resistance = {
    ssh_host       = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s      = 8,
    poll_s         = tonumber(os.getenv("IRRIGATION_KB2_POLL_S") or "60"),
    db_path        = os.getenv("KB2_DB_PATH") or "/var/fleet/kb2/kb2.db",
    topology_path  = os.getenv("KB2_TOPOLOGY_JSON")
                     or "/app/irrigation_analytics/data/kb2_topology.json",
}

-- KB1 overcurrent — live current monitor. Reads KB2's per-valve coil R
-- from /var/fleet/kb2/kb2.db at boot + each STATION_START. Computes expected
-- current per active bin as V/R_master + sum(V/R_zone) + null_offset, with
-- empirical 0.93 wire-drop multiplier. KILL @ I > 1.8 A absolute (Discord),
-- WARN @ I > expected + 0.3 A (DB). WSL test phase = monitor-only.
M.kb1_overcurrent = {
    ssh_host    = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s   = 8,
    poll_s      = tonumber(os.getenv("IRRIGATION_KB1_POLL_S") or "30"),
    db_path     = os.getenv("KB1_DB_PATH")     or "/var/fleet/kb1/kb1.db",
    kb2_db_path = os.getenv("KB2_DB_PATH")     or "/var/fleet/kb2/kb2.db",
}

-- KB2 within-run — per-minute R analysis on ETO STEP_COMPLETE. Pulls
-- TIME_HISTORY's IRRIGATION_CURRENT.data[], back-derives R(t) per minute
-- via parallel-coil math (R_total includes master + n_zone coils), detects
-- R_HEATING_DURING_RUN / R_STEP_DURING_RUN / R_END_HIGH / R_INSTABILITY.
-- Discord push on R_STEP_DURING_RUN (intermittent dropout) +
-- R_HEATING_DURING_RUN (predictive summer thermal failure).
M.kb2_within_run = {
    ssh_host    = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s   = 8,
    poll_s      = tonumber(os.getenv("IRRIGATION_KB2_WR_POLL_S") or "60"),
    -- Separate DB file to avoid SQLite lock contention with kb2_resistance
    db_path     = os.getenv("KB2_WR_DB_PATH") or "/var/fleet/kb2_wr/kb2_wr.db",
    -- Read-only reference to kb2_resistance's baseline DB
    kb2_db_path = os.getenv("KB2_DB_PATH")    or "/var/fleet/kb2/kb2.db",
}

-- KB3 sustained — schedule-aware ETO leak detector (Glenn 2026-06-09).
-- Fires on 3 consecutive minutes of PLC_FLOW_METER above 15 GPM after a
-- 5-min warmup. ETO bins only. PLC main_flow_meter is the new
-- high-accuracy well-side sensor (post-filter-fix 2026-06-09 PM); FHV
-- (FILTERED_HUNTER_VALVE) is no longer in the trip path — on city bins
-- (any group containing sat_1:39) it's used as a side-channel
-- city_delta = FHV - PLC to detect city water use. On fire: dispatches
-- CLOSE_MASTER_VALVE + SKIP_STATION. Independent of every other KB.
M.kb3_sustained = {
    ssh_host             = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s            = 8,
    poll_s               = tonumber(os.getenv("IRRIGATION_KB3_POLL_S") or "30"),
    db_path              = os.getenv("KB3_DB_PATH") or "/var/fleet/kb3/kb3.db",
    -- Trip signal is the SMOOTH HUNTER meter (GPM curve), not PLC — Glenn
    -- 2026-06-10. Retuned 2026-06-15: 13.5 = expected MAX filtered flow in the
    -- 5-15 window for a functioning well; consec 3→4. Replay-validated: 0 false
    -- trips in 125 runs (healthy max 11.9), catches 4:4 (~14). Action on the
    -- leak trip is now SKIP + insert 15-min wait (not CLOSE_MASTER). The
    -- secondary base+2 (lib BASELINE_DELTA_GPM) catches sub-13.5 leaks (e.g. 4:10).
    gpm_threshold        = tonumber(os.getenv("KB3_GPM_THRESHOLD")    or "13.5"),
    warmup_minutes       = tonumber(os.getenv("KB3_WARMUP_MIN")       or "5"),
    consecutive_required = tonumber(os.getenv("KB3_CONSECUTIVE_MIN")  or "4"),
}

-- KB3-curve REMOVED 2026-06-09. Replaced by kb3_sustained (Glenn's redesign).
-- See M.kb3_sustained above.

-- KB4 v2 — PLC-based flow baseline (Glenn 2026-06-09 PM, COLLECTION-ONLY).
-- Builds per-bin normalized flow + total gallons references over a 5-15
-- minute window for ETO runs; end-of-run last-3-min flow for non-ETO.
-- Rolling-7 median per bin (separate baselines for city bins).
-- NO alerts. KB3 prevents well depletion and thus most baseline poisoning;
-- median-of-7 absorbs the rest. Future detector modules can read
-- runs_kb4v2 + baselines_kb4v2 to define thresholds once we have field
-- data from the post-sprinkler-check repair cycle.
-- Coexists with kb4_clog (cohort starvation / clog fingerprints).
M.kb4_v2 = {
    ssh_host  = os.getenv("IRRIGATION_CONTROLLER_HOST") or "pi@irrigation",
    timeout_s = 8,
    poll_s    = tonumber(os.getenv("IRRIGATION_KB4V2_POLL_S") or "60"),
    db_path   = os.getenv("KB4V2_DB_PATH") or "/var/fleet/kb4v2/kb4v2.db",
    rolling_n = tonumber(os.getenv("KB4V2_ROLLING_N") or "7"),
}

-- Daily KB2/KB4 operator digest (Glenn 2026-06-10). At/after hour_pacific
-- (18:00 PT) once per day, rolls up the confirmed alert rows the KBs wrote
-- to kb_alerts (last 24 h) into one summary + dashboard link, published to
-- the shared digest topic. KB1/KB3 keep their immediate per-event alerts;
-- KB2/KB4 are summary-only. DASHBOARD_URL must be operator-reachable
-- (192.168.1.66 over the LAN / OpenVPN), NOT the 0.0.0.0 listen address.
M.digest = {
    hour_pacific  = tonumber(os.getenv("DIGEST_HOUR_PACIFIC") or "18"),
    retry_s       = tonumber(os.getenv("DIGEST_RETRY_S") or "900"),
    dashboard_url = os.getenv("DASHBOARD_URL") or "http://192.168.1.66:28080/irrigation/alerts",
    kb_db_paths   = {
        os.getenv("KB2_DB_PATH")    or "/var/fleet/kb2/kb2.db",
        os.getenv("KB2_WR_DB_PATH") or "/var/fleet/kb2_wr/kb2_wr.db",
        os.getenv("KB4V2_DB_PATH")  or "/var/fleet/kb4v2/kb4v2.db",  -- blocked-sprinkler (kind=clog)
        os.getenv("KB1_DB_PATH")    or "/var/fleet/kb1/kb1.db",      -- overcurrent spike-latch (kind=spike)
    },
}

-- Persistence-topology declaration. Three leaves for the v1 skeleton:
--   state/latest  — UPSERT status; current irrigation state snapshot
--   events/sample — append-only stream of KB1/KB3 fires (Phase 3+)
--   heartbeat     — rolled up via KB0
--
-- valve_test/{latest,sample} get added in Phase 4 when the KB2
-- calibrator KB lands.
function M.persistence_topology()
    return {
        { path = "state/latest",
          kind = "status",
          desc = "current irrigation state (schedule, step, master, currents)" },
        { path   = "events/sample",
          kind   = "stream",
          length = 200,
          desc   = "KB1/KB3 fire events (level/kind/action/msg per fire)" },
        { path = "heartbeat",
          kind = "status",
          desc = "robot rolled-up heartbeat" },
    }
end

-- Publish persistence_topology on namespace_up + periodically. Mirrors
-- rancho_water/farm_soil pattern — could share via robot_common later.
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
                "IRRIGATION_ANALYTICS [%s]: persistence_topology publish to %s failed: %s\n",
                identity.namespace, key, tostring(err)))
        end
        return ok
    end
    local ok1 = pub(identity.namespace .. "/persistence_topology")
    local ok2 = pub("fleet/admin/persistence_topology_announce")
    if ok1 and ok2 and not silent then
        io.stderr:write(string.format(
            "IRRIGATION_ANALYTICS [%s]: persistence_topology published (%d entries, 2 channels)\n",
            identity.namespace, #topo))
    end
    return ok1 and ok2
end

M.PERSISTENCE_TOPOLOGY_REPUBLISH_S = 30

function M.on_namespace_up(ps, identity, bb)
    M.publish_persistence_topology(ps, identity, false)
end

return M
