-- chains/connection_user_functions.lua — ct_* user functions for KB0.
--
-- ct_* (dict runtime) signatures:
--   one_shot : function(handle, node)                       -- fires on init
--   boolean  : function(handle, node, event_id, event_data) -- fed the event stream
-- Per-node config travels in node.node_dict; per-node state via ct_common.
--
-- main.lua attaches context to the blackboard before activating KB0:
--   bb._identity, bb._class_spec, bb._pubsub, bb._rpc
--
-- ===== Runtime contract (main.lua's pump must provide) =====
-- The chain_tree only consumes; the runtime feeds the event queue and a few
-- handle fields:
--   * handle.timestamp            seconds, advanced by delta_time each tick
--   * CFL_TIMER_EVENT / CFL_SECOND_EVENT   emitted each tick / second boundary
--   * event "ZENOH_CONNECTED"     posted when the zenoh transport comes up
--   * event "REGISTRATION_ACK"    posted when the controller acks (see note in
--                                 ANNOUNCE_REGISTRATION — currently posted by
--                                 that one-shot off the RPC reply)
--   * handle.controller_last_beat seconds (handle.timestamp scale) — stamped
--                                 each time a controller heartbeat is drained

local common = require("ct_common")
local defs   = require("ct_definitions")
local cjson  = require("cjson")
local clock  = require("clock")

local M = { main = {}, one_shot = {}, boolean = {} }

-- KB0's own name — every other active KB is an application KB.
local KB0_NAME = "connection"

-- Wall-clock epoch seconds (fractional) for ts fields on the wire.
local function wall_s() return clock.wall_now().epoch_s end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Kill every application KB — every active KB except KB0 itself. Collect
-- first: delete_test mutates handle.active_tests.
local function kill_app_kbs(handle)
    local ct_runtime = require("ct_runtime")
    local victims = {}
    for kb_name in pairs(handle.active_tests or {}) do
        if kb_name ~= KB0_NAME then victims[#victims + 1] = kb_name end
    end
    for _, kb_name in ipairs(victims) do
        pcall(ct_runtime.delete_test, handle, kb_name)
    end
    return #victims
end

-- Post a named event onto KB0's event queue (targets KB0's root so it walks
-- down to whatever node is waiting on it).
local function post_event(handle, event_name, event_data)
    local kb  = handle.kb_table and handle.kb_table[KB0_NAME]
    local eid = handle.event_strings and handle.event_strings[event_name]
    if not (kb and eid) then return false end
    table.insert(handle.event_queue, {
        node_id    = kb.root_node,
        event_id   = eid,
        event_data = event_data,
    })
    return true
end

-- From a verify node inside a state machine, resolve the SM node id:
-- verify node -> parent (state column) -> parent (SM node).
local function parent_sm_id(handle, verify_node)
    local state_col_id = common.get_parent_id(verify_node)
    local state_col    = state_col_id and handle.nodes[state_col_id]
    return state_col and common.get_parent_id(state_col) or nil
end

-- ---------------------------------------------------------------------------
-- One-shots
-- ---------------------------------------------------------------------------

-- Announce registration to the controller and, on a positive ack, post the
-- REGISTRATION_ACK event so the wait_for_event node advances.
-- NOTE: the fleet_manager exposes an RPC queryable on fleet/admin/register, so
-- the ack is synchronous here; we convert the RPC reply into a chain_tree event.
-- If registration moves to pub + a separate ack subscription, this one-shot
-- becomes a plain publish and the runtime posts REGISTRATION_ACK instead.
M.one_shot.ANNOUNCE_REGISTRATION = function(handle, node)
    local bb  = handle.blackboard
    local id  = bb._identity
    local cs  = bb._class_spec
    local rpc = bb._rpc

    local req = cjson.encode({
        class        = id.class,
        instance     = id.instance,
        chip_uid     = id.chip_uid,
        fw_version   = id.fw_version,
        capabilities = cs.capabilities,
        ts           = wall_s(),
    })
    io.stderr:write(string.format(
        "KB0 [%s]: announcing registration on fleet/admin/register\n", id.namespace))

    local reply, err = rpc:call("fleet/admin/register", req, 2000)
    if reply then
        local ok, dec = pcall(cjson.decode, reply)
        if ok and dec and dec.ok then
            bb.controller_id = tostring(dec.controller_id or "")
            io.stderr:write(string.format(
                "KB0 [%s]: controller ack (controller_id=%s)\n",
                id.namespace, bb.controller_id))
            post_event(handle, "REGISTRATION_ACK", dec)
            return
        end
    end
    io.stderr:write(string.format(
        "KB0 [%s]: registration not acked (%s) — wait_for_event will time out and retry\n",
        id.namespace, tostring(err or reply)))
end

-- Publish the standard namespace leaves (decision #31).
M.one_shot.PUBLISH_NAMESPACE = function(handle, node)
    local bb = handle.blackboard
    local id, cs, ps = bb._identity, bb._class_spec, bb._pubsub

    ps:publish(id.namespace .. "/capabilities", cjson.encode(cs.capabilities))
    ps:publish(id.namespace .. "/hardware", cjson.encode({
        chip_uid   = id.chip_uid,
        fw_version = id.fw_version,
        first_seen = id.first_seen,
    }))
    ps:publish(id.namespace .. "/state", cjson.encode({
        state = "ready", ts = wall_s(),
    }))
    io.stderr:write(string.format(
        "KB0 [%s]: namespace leaves published\n", id.namespace))
end

-- Run the class-specific on_namespace_up hook (decision #32).
M.one_shot.NAMESPACE_UP_HOOK = function(handle, node)
    local bb = handle.blackboard
    local id, cs = bb._identity, bb._class_spec
    if type(cs.on_namespace_up) == "function" then
        local ok, err = pcall(cs.on_namespace_up, bb._pubsub, id, bb)
        if not ok then
            io.stderr:write(string.format(
                "KB0 [%s]: on_namespace_up hook errored: %s\n",
                id.namespace, tostring(err)))
        end
    end
end

-- Spawn the class-specific application KB(s). class_spec.app_kbs lists KB
-- names that exist in the loaded IR. fake_robot declares none yet => no-op.
M.one_shot.SPAWN_APP_KBS = function(handle, node)
    local ct_runtime = require("ct_runtime")
    local kbs = (handle.blackboard._class_spec or {}).app_kbs or {}
    for _, kb_name in ipairs(kbs) do
        local ok = pcall(ct_runtime.add_test, handle, kb_name)
        io.stderr:write(string.format(
            "KB0: spawn app KB '%s' — %s\n", kb_name, ok and "ok" or "FAILED"))
    end
    if #kbs == 0 then
        io.stderr:write("KB0: no app KBs declared by class_spec — nothing to spawn\n")
    end
end

-- verify(TEST_CONTROLLER_HEARTBEAT) error handler — controller heartbeat lost.
-- Narrow recovery: kill app KBs and drive the protocol SM back to
-- wait_for_ack. Zenoh is untouched. Replicates the CFL_CHANGE_STATE builtin
-- (resolve the SM node state, set new_state; the SM main applies it).
M.one_shot.ERROR_CONTROLLER_LOST = function(handle, node)
    local n = kill_app_kbs(handle)
    io.stderr:write(string.format(
        "KB0: controller heartbeat lost — killed %d app KB(s); re-handshaking\n", n))

    local sm_id = parent_sm_id(handle, node)
    local sm_ns = sm_id and common.get_node_state(handle, sm_id)
    if sm_ns and sm_ns.state_name_to_index then
        sm_ns.new_state = sm_ns.state_name_to_index["wait_for_ack"] or 0
    else
        io.stderr:write("KB0: WARN — could not resolve protocol SM for state change\n")
    end
end

-- Publish the robot's heartbeat — the aggregate app-KB health. KB0 owns the
-- robot's heartbeat leaf (#31). Each app KB stamps bb.app_heartbeats via
-- robot_common/lib/app_heartbeat.lua; this rolls them up so the published
-- heartbeat is honest — a robot with a degraded or silent app KB shows
-- "degraded", not "operating". Fires every verify_controller_heartbeat loop.
M.one_shot.PUBLISH_ROBOT_HEARTBEAT = function(handle, node)
    local bb = handle.blackboard
    local id, ps = bb._identity, bb._pubsub
    local now    = handle.timestamp or 0
    local beats  = bb.app_heartbeats or {}

    local apps, state = {}, "operating"
    for kb_name in pairs(handle.active_tests or {}) do
        if kb_name ~= KB0_NAME then
            local h = beats[kb_name]
            if not h then
                apps[kb_name] = { health = "unknown" }
                state = "degraded"
            else
                local age   = now - (h.ts or 0)
                local stale = (h.interval_s ~= nil) and age > h.interval_s * 3
                apps[kb_name] = {
                    health = h.health,
                    detail = h.detail,
                    age_s  = math.floor(age),
                    stale  = stale or nil,
                }
                if h.health ~= "ok" or stale then state = "degraded" end
            end
        end
    end

    local ok = pcall(function()
        ps:publish(id.namespace .. "/heartbeat", cjson.encode({
            ts = wall_s(), state = state, apps = apps,
        }))
    end)
    if not ok then
        io.stderr:write(string.format(
            "KB0 [%s]: heartbeat publish failed — retry next loop\n", id.namespace))
    end
end

-- ---------------------------------------------------------------------------
-- Booleans  (fed every event by verify; return true = pass / connection ok)
-- ---------------------------------------------------------------------------

-- Controller heartbeat guard. Fresh if a controller heartbeat was drained
-- within threshold_s. threshold_s comes from the verify's fn data
-- ({ threshold_s = 3.5 } in connection.lua).
M.boolean.TEST_CONTROLLER_HEARTBEAT = function(handle, node, event_id, event_data)
    if event_id == defs.CFL_INIT_EVENT then return true end
    if event_id == defs.CFL_TERMINATE_EVENT then return false end
    local nd      = node.node_dict or {}
    local fn_data = nd.fn_data or nd.user_data or {}
    local threshold = tonumber(fn_data.threshold_s) or 3.5
    local now  = handle.timestamp or 0
    local last = handle.controller_last_beat or now   -- nil => assume fresh
    return (now - last) < threshold
end

-- ---------------------------------------------------------------------------

M.registry = {
    main     = M.main,
    one_shot = M.one_shot,
    boolean  = M.boolean,
}

return M
