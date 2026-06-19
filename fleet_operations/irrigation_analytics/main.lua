-- main.lua — irrigation_analytics robot entry point.
--
-- Mirrors rancho_water/main.lua. Only the registered user-fn modules and
-- pre-populated blackboard state differ. Same boot flow:
--   identity → zenoh pub/sub + RPC → KB IR load → fn registry
--   → activate KB0 → event pump (tick + clock-boundary + zenoh poll).
--
-- Phase 1: skeleton. monitor KB heartbeats but takes no action. Controller
-- polling and KB1/KB3/KB2 detection get layered in over Phases 2-4.

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
local TICK_HZ = tonumber(os.getenv("IRRIGATION_ANALYTICS_TICK_HZ") or "10")
local TICK_US = math.floor(1e6 / TICK_HZ)
local FW_VER  = "irrigation_analytics/0.1"

local identity_mod = require("identity")
local pubsub_mod   = require("zenoh_session")
local rpc_mod      = require("zenoh_rpc_session")

local id = identity_mod.load({ fw_version = FW_VER })
io.stderr:write(string.format(
    "IRRIGATION_ANALYTICS [%s]: identity loaded (chip_uid=%s, dir=%s)\n",
    id.namespace, id.chip_uid, id.dir))

local class_spec = require("class_spec")
io.stderr:write(string.format(
    "IRRIGATION_ANALYTICS [%s]: class spec loaded (capabilities: %d, app KBs: %d)\n",
    id.namespace, #class_spec.capabilities, #(class_spec.app_kbs or {})))

local ps  = pubsub_mod.new({ locator = LOCATOR, client_name = id.namespace })
local rpc = rpc_mod.new({    locator = LOCATOR, client_name = id.namespace .. "/rpc" })

ps:open()
rpc:open()
io.stderr:write(string.format(
    "IRRIGATION_ANALYTICS [%s]: zenoh sessions open (locator=%s)\n", id.namespace, LOCATOR))

ps:subscribe("fleet/admin/heartbeat", { kind = "ctrl_heartbeat" })

-- ---------------------------------------------------------------------------
-- Chain_tree wire-up
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

local conn_fns     = require("connection_user_functions")
local monitor_fns  = require("monitor_user_functions")
local detector_fns = require("detector_user_functions")
local kb4_clog_fns = require("kb4_clog_user_functions")
local kb2_resistance_fns = require("kb2_resistance_user_functions")
local kb1_overcurrent_fns = require("kb1_overcurrent_user_functions")
local kb2_within_run_fns = require("kb2_within_run_user_functions")
local kb3_sustained_fns = require("kb3_sustained_user_functions")
local kb4_v2_fns = require("kb4_v2_user_functions")
local digest_fns = require("digest_user_functions")
fn_registry.register_functions(ir, builtins,
    conn_fns.registry, monitor_fns.registry, detector_fns.registry,
    kb4_clog_fns.registry, kb2_resistance_fns.registry,
    kb1_overcurrent_fns.registry, kb2_within_run_fns.registry,
    kb3_sustained_fns.registry, kb4_v2_fns.registry,
    digest_fns.registry)

local ok, missing = fn_registry.validate(ir)
if not ok then
    io.stderr:write("IRRIGATION_ANALYTICS: missing functions in KB IR:\n")
    for _, m in ipairs(missing) do io.stderr:write("  " .. m .. "\n") end
    os.exit(1)
end

local handle = ct_runtime.create({ delta_time = 1 / TICK_HZ, max_ticks = 999999 }, ir)

handle.blackboard._identity   = id
handle.blackboard._class_spec = class_spec
handle.blackboard._pubsub     = ps
handle.blackboard._rpc        = rpc
handle.blackboard.shutdown_requested = false

-- Eager-load KB1 curves + KB3 baselines so the detector chain doesn't pay
-- the load cost on its first tick (and so missing-file errors surface at
-- boot, not silently during a fault). KB1/KB3 are read-only consumers;
-- when KB2/KB4 land they'll need their own writer path (bind-mount + RW).
do
    local cjson_local = require("cjson")
    local T_local     = require("thresholds")
    local Baselines_local = require("baselines")
    local dcfg = class_spec.detector or {}

    -- Curves: explore/generate_curves output, per_bin schema.
    local curves_loaded = {}
    local cfh = io.open(dcfg.curves_path or "", "r")
    if cfh then
        local raw = cfh:read("*a"); cfh:close()
        local cok, decoded = pcall(cjson_local.decode, raw)
        if cok and decoded and decoded.per_bin then
            for bin_key, e in pairs(decoded.per_bin) do
                if e.mu_i_asym and e.i_low_open then
                    curves_loaded[T_local.canonicalize_key(bin_key)] = {
                        mu         = e.mu_i_asym,
                        sd         = e.sd_i_asym,
                        i_low_open = e.i_low_open,
                    }
                end
            end
            local n = 0
            for _ in pairs(curves_loaded) do n = n + 1 end
            io.stderr:write(string.format(
                "IRRIGATION_ANALYTICS [%s]: loaded %d KB1 curves from %s\n",
                id.namespace, n, dcfg.curves_path))
        else
            io.stderr:write(string.format(
                "IRRIGATION_ANALYTICS [%s]: KB1 curves decode failed at %s — KB1 calibrated modes disabled\n",
                id.namespace, dcfg.curves_path))
        end
    else
        io.stderr:write(string.format(
            "IRRIGATION_ANALYTICS [%s]: no KB1 curves at %s — running uncalibrated\n",
            id.namespace, tostring(dcfg.curves_path)))
    end
    handle.blackboard._detector_curves = curves_loaded

    -- Baselines: explore/baseline_state/baselines.json, schema baseline.v1.
    local bl, n_long, n_short, bl_err = Baselines_local.load(dcfg.baselines_path or "")
    if bl then
        local n_kb3 = 0
        for _, v in pairs(bl.bins) do
            if v.mode == "long" and v.kb3_eligible then n_kb3 = n_kb3 + 1 end
        end
        io.stderr:write(string.format(
            "IRRIGATION_ANALYTICS [%s]: loaded baselines schema=%s long=%d short=%d kb3_eligible=%d\n",
            id.namespace, bl.schema, n_long, n_short, n_kb3))
        handle.blackboard._detector_baselines = bl
    else
        io.stderr:write(string.format(
            "IRRIGATION_ANALYTICS [%s]: baselines load FAILED (%s) — KB3 disabled: %s\n",
            id.namespace, tostring(bl_err), tostring(dcfg.baselines_path)))
        handle.blackboard._detector_baselines = nil
    end

    -- KB3-curve removed 2026-06-09 (replaced by kb3_sustained chain which
    -- doesn't need baselines_eto — uses absolute 15 GPM threshold instead).
end

handle.controller_last_beat = nil

ct_engine.init_test(handle, "connection")
handle.active_tests["connection"] = true
handle.active_test_count = 1

local function post_kb_event(kb_name, event_name, event_data)
    local kb  = handle.kb_table[kb_name]
    local eid = handle.event_strings and handle.event_strings[event_name]
    if kb and eid then
        table.insert(handle.event_queue, {
            node_id = kb.root_node, event_id = eid, event_data = event_data,
        })
    else
        io.stderr:write("IRRIGATION_ANALYTICS: WARN — cannot post event "
            .. tostring(event_name) .. " (kb/eid missing)\n")
    end
end

io.stderr:write(string.format(
    "IRRIGATION_ANALYTICS [%s]: KB0 activated, entering pump @%d Hz\n",
    id.namespace, TICK_HZ))
io.stderr:flush()

-- ---------------------------------------------------------------------------
-- Event pump — same shape as rancho_water and farm_soil
-- ---------------------------------------------------------------------------

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

    for _, m in ipairs(ps:poll_all()) do
        if m.user and m.user.kind == "ctrl_heartbeat" then
            handle.controller_last_beat = handle.timestamp
        end
    end

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
                "IRRIGATION_ANALYTICS [%s]: wall-clock jump (wall=%.0fms mono=%dms) — boundary events skipped\n",
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
                        "IRRIGATION_ANALYTICS [%s]: CFL_%s_EVENT @ %04d-%02d-%02d %02d:%02d:%02d UTC\n",
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

    while #handle.event_queue > 0 do
        local ev = table.remove(handle.event_queue, 1)
        local okev, err = pcall(ct_engine.execute_event,
            handle, ev.node_id, ev.event_id, ev.event_data)
        if not okev then
            io.stderr:write(string.format(
                "IRRIGATION_ANALYTICS [%s]: event execution error (contained): %s\n",
                id.namespace, tostring(err)))
        end
    end

    if cur_mono_ms - last_summary_ms >= 10000 then
        io.stderr:write(string.format(
            "IRRIGATION_ANALYTICS [%s]: pump alive — %d SECOND events in last 10s\n",
            id.namespace, second_event_count))
        second_event_count = 0
        last_summary_ms = cur_mono_ms
    end

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

io.stderr:write("IRRIGATION_ANALYTICS: shutdown\n")
ps:close()
rpc:close()
