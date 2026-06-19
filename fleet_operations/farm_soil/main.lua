-- main.lua — farm_soil robot entry point.
--
-- Loads identity, opens Zenoh pub/sub + RPC sessions, requires the class
-- spec, loads the compiled KB IR, registers user fns + builtins, activates
-- KB0, and runs the chain_tree event pump.
--
-- Env contract:
--   ROBOT_CLASS, ROBOT_INSTANCE   required
--   IDENTITY_DIR                  optional, default ./identity
--   ZENOH_LOCATOR                 optional, default tcp/127.0.0.1:7447
--   FARM_SOIL_TICK_HZ             optional, default 10
--
-- Launch via ./run.sh — it sources secrets/ttn.env and sets LUA_CPATH /
-- LUA_PATH / LD_LIBRARY_PATH. KB0 + shared lib resolve from robot_common/.
--
-- Slice 3: KB0-only — boots, connects, registers, idles. The moisture
-- skill-KB lands in slice 4.

local ffi = require("ffi")

ffi.cdef[[
    int usleep(unsigned int usec);
    typedef void (*sighandler_t)(int);
    sighandler_t signal(int signum, sighandler_t handler);
]]
ffi.C.signal(13, ffi.cast("sighandler_t", 1))  -- ignore SIGPIPE

local script_dir = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
package.path = script_dir .. "lib/?.lua;"
            .. script_dir .. "?.lua;"
            .. script_dir .. "chains/?.lua;"
            .. script_dir .. "../robot_common/lib/?.lua;"
            .. script_dir .. "../robot_common/chains/?.lua;"
            .. package.path

local LOCATOR = os.getenv("ZENOH_LOCATOR") or "tcp/127.0.0.1:7447"
local TICK_HZ = tonumber(os.getenv("FARM_SOIL_TICK_HZ") or "10")
local TICK_US = math.floor(1e6 / TICK_HZ)
local FW_VER  = "farm_soil/0.1"

-- ---------------------------------------------------------------------------
-- Identity, class spec, sessions
-- ---------------------------------------------------------------------------

local identity_mod = require("identity")
local pubsub_mod   = require("zenoh_session")
local rpc_mod      = require("zenoh_rpc_session")

local id = identity_mod.load({ fw_version = FW_VER })
io.stderr:write(string.format(
    "FARM_SOIL [%s]: identity loaded (chip_uid=%s, dir=%s)\n",
    id.namespace, id.chip_uid, id.dir))

local class_spec = require("class_spec")
io.stderr:write(string.format(
    "FARM_SOIL [%s]: class spec loaded (capabilities: %d, app KBs: %d)\n",
    id.namespace, #class_spec.capabilities, #(class_spec.app_kbs or {})))

local ps  = pubsub_mod.new({ locator = LOCATOR, client_name = id.namespace })
local rpc = rpc_mod.new({    locator = LOCATOR, client_name = id.namespace .. "/rpc" })

ps:open()
rpc:open()
io.stderr:write(string.format(
    "FARM_SOIL [%s]: zenoh sessions open (locator=%s)\n", id.namespace, LOCATOR))

-- The runtime owns the controller-heartbeat subscription; the chain_tree
-- only consumes. Drained each pump tick — see the event pump below.
ps:subscribe("fleet/admin/heartbeat", { kind = "ctrl_heartbeat" })

-- RPC server — the `sample` queryable. A consumer calls it to pull one
-- entry from the in-memory 256-ring by index (0 = newest) — ad-hoc queries
-- and gap backfill, one small reply per request (no blob). Polled + handled
-- in the pump.
local zrpc = require("zenoh_rpc")
local zt   = require("zenoh_token")

local rpc_srv = zrpc.Server.new({
    locators = { LOCATOR }, client_name = id.namespace .. "/srv",
})
local sample_topic = id.namespace .. "/sample"
local sample_token = zt.hash(sample_topic)
zt.register(sample_token, sample_topic)
local sample_q = rpc_srv:register(sample_token, 8)

-- One repost queryable per CIMIS source. The handler returns the latest
-- recorded reading JSON, or the literal "null" when nothing's recorded yet.
-- Topic shape: <namespace>/cimis/<source>/repost.
local function register_cimis_repost(source_id)
    local topic = id.namespace .. "/cimis/" .. source_id .. "/repost"
    local token = zt.hash(topic)
    zt.register(token, topic)
    local q = rpc_srv:register(token, 8)
    return { source = source_id, q = q, topic = topic }
end
local cimis_qs = {
    register_cimis_repost("station"),
    register_cimis_repost("spatial"),
}

rpc_srv:start()
io.stderr:write(string.format(
    "FARM_SOIL [%s]: sample queryable up on %s\n",
    id.namespace, sample_topic))
for _, qrec in ipairs(cimis_qs) do
    io.stderr:write(string.format(
        "FARM_SOIL [%s]: cimis %s repost queryable up on %s\n",
        id.namespace, qrec.source, qrec.topic))
end

-- ---------------------------------------------------------------------------
-- Chain_tree wire-up: load compiled IR, register fns, activate KB0
-- ---------------------------------------------------------------------------

local ct_loader   = require("ct_loader")
local fn_registry = require("fn_registry")
local builtins    = require("ct_builtins")
local ct_runtime  = require("ct_runtime")
local ct_engine   = require("ct_engine")
local defs        = require("ct_definitions")
local clock       = require("clock")

local ir_path = script_dir .. "chains/connection.json"
local ir = ct_loader.load(ir_path)

-- KB0's user fns + the moisture skill-KB's user fns + both CIMIS KBs' fns
-- + the daily-digest KB's user fns.
local conn_fns         = require("connection_user_functions")
local moisture_fns     = require("moisture_user_functions")
local cimis_fns        = require("cimis_user_functions")
local synoptic_fns     = require("synoptic_user_functions")
local eto_resolver_fns = require("eto_resolver_user_functions")
local digest_fns       = require("digest_user_functions")
local eto_sync_fns     = require("eto_sync_user_functions")
local watchdog_fns     = require("irrigation_watchdog_user_functions")
fn_registry.register_functions(ir, builtins,
    conn_fns.registry, moisture_fns.registry,
    cimis_fns.registry, synoptic_fns.registry,
    eto_resolver_fns.registry, digest_fns.registry,
    eto_sync_fns.registry, watchdog_fns.registry)

local ok, missing = fn_registry.validate(ir)
if not ok then
    io.stderr:write("FARM_SOIL: missing functions in KB IR:\n")
    for _, m in ipairs(missing) do io.stderr:write("  " .. m .. "\n") end
    os.exit(1)
end

local handle = ct_runtime.create({ delta_time = 1 / TICK_HZ, max_ticks = 999999 }, ir)

-- Context the user fns need.
handle.blackboard._identity   = id
handle.blackboard._class_spec = class_spec
handle.blackboard._pubsub     = ps
handle.blackboard._rpc        = rpc
handle.blackboard.shutdown_requested = false

-- Per-source CIMIS runtime state — the in-memory single-value store + the
-- last_recorded_date gate flag. One entry per cimis_<source> KB; the KBs
-- read/write their own entry, and the repost queryable handler reads it.
handle.blackboard._cimis = { station = {}, spatial = {} }

-- Per-station Synoptic runtime state — same shape as _cimis. Each
-- synoptic_<stid> KB reads/writes its own slot. Stations come from the
-- class spec so adding a station is a class_spec edit, not a main.lua edit.
handle.blackboard._synoptic = {}
for stid, _ in pairs(class_spec.synoptic.stations) do
    handle.blackboard._synoptic[stid] = {}
end

-- The resolver KB writes its own state slot — last_published_date so it
-- doesn't republish, last_winner / last_chain for RPC / debug visibility.
handle.blackboard._eto_resolver = {}

-- Runtime-maintained field the KB0 controller-heartbeat boolean reads.
-- handle.timestamp is advanced in the pump from CLOCK_MONOTONIC.
handle.controller_last_beat = nil    -- stamped on the first drained heartbeat

ct_engine.init_test(handle, "connection")
handle.active_tests["connection"] = true
handle.active_test_count = 1

-- Post a named event to a KB's root node (resolves the IR event-string id).
local function post_kb_event(kb_name, event_name, event_data)
    local kb  = handle.kb_table[kb_name]
    local eid = handle.event_strings and handle.event_strings[event_name]
    if kb and eid then
        table.insert(handle.event_queue, {
            node_id = kb.root_node, event_id = eid, event_data = event_data,
        })
    else
        io.stderr:write("FARM_SOIL: WARN — cannot post event "
            .. tostring(event_name) .. " (kb/eid missing)\n")
    end
end

io.stderr:write(string.format(
    "FARM_SOIL [%s]: KB0 activated, entering pump @%d Hz\n",
    id.namespace, TICK_HZ))
io.stderr:flush()

-- ---------------------------------------------------------------------------
-- Event pump
-- ---------------------------------------------------------------------------
--
-- Each tick: advance handle.timestamp (CLOCK_MONOTONIC); drain the zenoh
-- session, stamping controller_last_beat on each controller heartbeat; post
-- ZENOH_CONNECTED once; inject CFL_TIMER_EVENT + wall-clock boundary events;
-- drain the chain_tree event queue. Every execute_event runs under pcall —
-- a faulting KB is contained to that one event, never crashes the tree.

local CLOCK_JUMP_GUARD_MS = 1000
local boundary_events = {
    { field = "second", id = defs.CFL_SECOND_EVENT, name = "SECOND" },
    { field = "minute", id = defs.CFL_MINUTE_EVENT, name = "MINUTE" },
    { field = "hour",   id = defs.CFL_HOUR_EVENT,   name = "HOUR"   },
    { field = "day",    id = defs.CFL_DAY_EVENT,    name = "DAY"    },
    { field = "month",  id = defs.CFL_MONTH_EVENT,  name = "MONTH"  },
    { field = "year",   id = defs.CFL_YEAR_EVENT,   name = "YEAR"   },
}

local prev_wc            = nil
local prev_mono_ms       = clock.now_ms()
local start_mono_ms      = prev_mono_ms
local zenoh_announced    = false
local second_event_count = 0
local last_summary_ms    = prev_mono_ms
local last_topo_pub_ms   = prev_mono_ms

local TOPO_REPUBLISH_MS  = (class_spec.PERSISTENCE_TOPOLOGY_REPUBLISH_S or 30) * 1000

while not handle.blackboard.shutdown_requested do
    local cur_mono_ms = clock.now_ms()
    local cur_wc      = clock.wall_now()
    local mono_delta  = cur_mono_ms - prev_mono_ms

    handle.timestamp = (cur_mono_ms - start_mono_ms) / 1000

    -- Drain the zenoh session — a controller heartbeat stamps
    -- controller_last_beat, read by the TEST_CONTROLLER_HEARTBEAT boolean.
    for _, m in ipairs(ps:poll_all()) do
        if m.user and m.user.kind == "ctrl_heartbeat" then
            handle.controller_last_beat = handle.timestamp
        end
    end

    -- Service `sample` RPC requests — return one ring entry per request
    -- (index 0 = newest). Handler + reply pcall-wrapped — a bad request
    -- cannot crash the pump.
    while true do
        local req = sample_q:poll()
        if not req then break end
        local okrp, reply = pcall(moisture_fns.handle_sample_request,
            handle, req:payload())
        if okrp then
            pcall(function() req:reply(reply) end)
        else
            io.stderr:write(string.format(
                "FARM_SOIL [%s]: sample request error (contained): %s\n",
                id.namespace, tostring(reply)))
            pcall(function() req:reply_error(tostring(reply)) end)
        end
    end

    -- Service CIMIS repost requests — one queryable per source. The handler
    -- returns the latest recorded reading JSON or the literal "null" when
    -- nothing has been recorded yet. Handler + reply pcall-wrapped.
    for _, qrec in ipairs(cimis_qs) do
        while true do
            local creq = qrec.q:poll()
            if not creq then break end
            local okrp, reply = pcall(cimis_fns.handle_repost_request,
                handle, qrec.source, creq:payload())
            if okrp then
                pcall(function() creq:reply(reply) end)
            else
                io.stderr:write(string.format(
                    "FARM_SOIL [%s]: cimis %s repost error (contained): %s\n",
                    id.namespace, qrec.source, tostring(reply)))
                pcall(function() creq:reply_error(tostring(reply)) end)
            end
        end
    end

    -- Announce the zenoh transport once — sessions opened at boot.
    if not zenoh_announced then
        zenoh_announced = true
        post_kb_event("connection", "ZENOH_CONNECTED", nil)
    end

    local emit_boundaries = false
    if prev_wc then
        local wall_delta_ms = (cur_wc.epoch_s - prev_wc.epoch_s) * 1000
        if math.abs(wall_delta_ms - mono_delta) < CLOCK_JUMP_GUARD_MS then
            emit_boundaries = true
        else
            io.stderr:write(string.format(
                "FARM_SOIL [%s]: wall-clock jump (wall=%.0fms mono=%dms) — boundary events skipped\n",
                id.namespace, wall_delta_ms, mono_delta))
        end
    end

    if emit_boundaries then
        for _, b in ipairs(boundary_events) do
            if cur_wc[b.field] ~= prev_wc[b.field] then
                for kb_name, _ in pairs(handle.active_tests) do
                    local kb = handle.kb_table[kb_name]
                    if kb then
                        table.insert(handle.event_queue, {
                            node_id    = kb.root_node,
                            event_id   = b.id,
                            event_data = cur_wc,
                        })
                    end
                end
                if b.name == "SECOND" then
                    second_event_count = second_event_count + 1
                else
                    io.stderr:write(string.format(
                        "FARM_SOIL [%s]: CFL_%s_EVENT @ %04d-%02d-%02d %02d:%02d:%02d UTC\n",
                        id.namespace, b.name,
                        cur_wc.year, cur_wc.month, cur_wc.day,
                        cur_wc.hour, cur_wc.minute, cur_wc.second))
                end
            end
        end
    end

    for kb_name, _ in pairs(handle.active_tests) do
        local kb = handle.kb_table[kb_name]
        if kb then
            table.insert(handle.event_queue, {
                node_id = kb.root_node, event_id = defs.CFL_TIMER_EVENT,
            })
        end
    end

    -- Drain the event queue. Each event runs under pcall — a faulting app KB
    -- is contained to that one event; KB0 and the engine carry on.
    while #handle.event_queue > 0 do
        local ev = table.remove(handle.event_queue, 1)
        local okev, err = pcall(ct_engine.execute_event,
            handle, ev.node_id, ev.event_id, ev.event_data)
        if not okev then
            io.stderr:write(string.format(
                "FARM_SOIL [%s]: event execution error (contained): %s\n",
                id.namespace, tostring(err)))
        end
    end

    if cur_mono_ms - last_summary_ms >= 10000 then
        io.stderr:write(string.format(
            "FARM_SOIL [%s]: pump alive — %d SECOND events in last 10s\n",
            id.namespace, second_event_count))
        second_event_count = 0
        last_summary_ms = cur_mono_ms
    end

    -- Periodic persistence_topology republish — so a late-joining
    -- persistence service (e.g., restarted while we're up) catches the
    -- topology within ~PERSISTENCE_TOPOLOGY_REPUBLISH_S seconds and its
    -- next subscribe-declarations propagate before the next data publish
    -- (closing both the late-joiner and post-mutation zenoh-pico
    -- propagation gaps). `silent=true` suppresses the per-republish log.
    if class_spec.publish_persistence_topology
       and cur_mono_ms - last_topo_pub_ms >= TOPO_REPUBLISH_MS then
        pcall(class_spec.publish_persistence_topology, ps, id, true)
        last_topo_pub_ms = cur_mono_ms
    end

    prev_wc = cur_wc
    prev_mono_ms = cur_mono_ms

    if handle.active_test_count == 0 then break end
    ffi.C.usleep(TICK_US)
end

io.stderr:write("FARM_SOIL: shutdown\n")
rpc_srv:stop()
rpc_srv:destroy()
ps:close()
rpc:close()
