-- chains/monitor_user_functions.lua — ct_* user fns for the monitor KB.
--
-- Phase 2: MONITOR_TICK fetches the controller popup, classifies state,
-- publishes a compact state snapshot to <namespace>/state/latest, and
-- stamps the heartbeat. No KB1/KB3 detection yet — that's Phase 3.
--
-- Containment: controller-fetch errors are return values (skip the tick,
-- degraded heartbeat with reason), never raises; each publish is
-- pcall-wrapped per the farm_soil/rancho_water pattern.

local cjson         = require("cjson")
local app_heartbeat = require("app_heartbeat")
local controller    = require("controller_client")
local sm            = require("state_classifier")

local M = { main = {}, one_shot = {}, boolean = {} }

local DEFAULT_POLL_S = 30
local SCHEMA_STATE   = "irrigation_analytics.state/1"

local function log(id, fmt_str, ...)
    io.stderr:write(string.format(
        "monitor [%s]: " .. fmt_str .. "\n", id.namespace, ...))
end

-- Build the compact state-publish envelope. Stays well under 1 KB so
-- zenoh-pico doesn't silently drop it (per the farm_soil lesson on
-- multi-KB payloads).
local function build_state_payload(id, popup, state, ts_iso)
    return cjson.encode({
        schema   = SCHEMA_STATE,
        class    = id.class,
        instance = id.instance,
        ts       = ts_iso,
        state    = state,
        -- Controller popup essentials. We omit verbose / debug-only fields.
        schedule_name        = popup.SCHEDULE_NAME,
        step                 = popup.STEP,
        run_time_s           = popup.RUN_TIME,
        elapsed_s            = popup.ELASPED_TIME,        -- note: controller's spelling
        master_valve         = popup.MASTER_VALVE and true or false,
        irrigation_current_a = popup.PLC_IRRIGATION_CURRENT,
        equipment_current_a  = popup.PLC_EQUIPMENT_CURRENT,
        flow_gpm             = popup.FILTERED_HUNTER_VALVE or popup.HUNTER_VALVE,
        controller_ts        = popup.TIME_STAMP,
    })
end

local function iso_now()
    -- 2026-06-02T17:30:00Z — UTC, second precision (matches event log style).
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

M.one_shot.MONITOR_TICK = function(handle, _node)
    local bb     = handle.blackboard
    local id, ps = bb._identity, bb._pubsub
    local cs     = bb._class_spec
    local ctrl   = (cs and cs.controller) or {}
    local poll_s = ctrl.poll_s or DEFAULT_POLL_S

    -- Manual suspend is Phase 5; pass false for now.
    local manual_suspend = bb._manual_suspend or false

    -- Fetch popup.
    local popup, err = controller.popup_get({
        ssh_host  = ctrl.ssh_host,
        timeout_s = ctrl.timeout_s,
    })
    if not popup then
        log(id, "popup fetch failed: %s", tostring(err))
        app_heartbeat.stamp(handle, "monitor", "degraded",
            string.format("popup fetch failed: %s", tostring(err):sub(1, 100)),
            poll_s)
        return
    end

    -- Classify state.
    local state = sm.classify(popup, manual_suspend)

    -- Publish state/latest.
    local payload = build_state_payload(id, popup, state, iso_now())
    local key = id.namespace .. "/state/latest"
    local pok, perr = pcall(function() ps:publish(key, payload) end)
    if not pok then
        log(id, "state/latest publish FAILED: %s", tostring(perr))
        app_heartbeat.stamp(handle, "monitor", "degraded",
            string.format("state publish failed: %s", tostring(perr):sub(1, 80)),
            poll_s)
        return
    end

    -- Healthy heartbeat with current state summary.
    local sched = popup.SCHEDULE_NAME or "OFFLINE"
    local step  = popup.STEP or 0
    local irr   = popup.PLC_IRRIGATION_CURRENT or 0
    app_heartbeat.stamp(handle, "monitor", "ok",
        string.format("state=%s schedule=%s step=%s irr=%.2fA",
            state, sched, tostring(step), irr),
        poll_s)
    -- Success-path log (the chain is otherwise silent on the happy path,
    -- which made it appear stuck in 2026-06-02 PM investigation — see
    -- persistence_storage_bug_2026-06-02 memory).
    log(id, "MONITOR_TICK ok state=%s sched=%s irr=%.2fA payload=%dB",
        state, sched, irr, #payload)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
