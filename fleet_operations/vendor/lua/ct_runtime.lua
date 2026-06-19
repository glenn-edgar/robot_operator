-- ct_runtime.lua — event loop and KB lifecycle (dict-based)

local ffi  = require("ffi")
local defs   = require("ct_definitions")
local engine = require("ct_engine")

ffi.cdef[[
  int usleep(unsigned int usec);
]]

local M = {}

-- Deep-copy a table (one level of nesting is enough for blackboard)
local function shallow_copy_fields(defaults)
    local t = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            local inner = {}
            for ik, iv in pairs(v) do inner[ik] = iv end
            t[k] = inner
        else
            t[k] = v
        end
    end
    return t
end

-- Build the mutable blackboard table from handle_data.blackboard
local function init_blackboard(bb_def)
    if not bb_def then return {} end
    local bb = shallow_copy_fields(bb_def.field_defaults or {})
    -- Attach const_records (read-only by convention)
    if bb_def.const_records and next(bb_def.const_records) then
        local cr = {}
        for name, fields in pairs(bb_def.const_records) do
            local rec = {}
            for k, v in pairs(fields) do rec[k] = v end
            cr[name] = rec
        end
        bb.const_records = cr
    end
    return bb
end

function M.create(params, handle_data)
    local handle = {
        -- Node dict (string-keyed)
        nodes = handle_data.nodes,

        -- Function dispatch dicts (name → fn)
        main_functions    = handle_data.main_functions,
        one_shot_functions = handle_data.one_shot_functions,
        boolean_functions = handle_data.boolean_functions,

        -- KB table (name → {name, root_node, node_ids})
        kb_table = handle_data.kb_table,

        -- Event string table (name → integer id)
        event_strings = handle_data.event_strings,

        -- Index maps (for resolving integer node references and display)
        idx_to_ltree = handle_data.idx_to_ltree,
        ltree_to_index = handle_data.ltree_to_index,

        -- Event queue (simple list used as FIFO)
        event_queue = {},

        -- Per-node mutable state (keyed by ltree string)
        node_state = {},

        -- Active KBs (kb_name → true)
        active_tests = {},
        active_test_count = 0,

        -- Bitmask (for builtins)
        bitmask = 0,

        -- Blackboard (mutable fields + const_records)
        blackboard = init_blackboard(handle_data.blackboard),

        -- Stash the definition so reset() can restore defaults
        _bb_def = handle_data.blackboard,

        -- Timer / params
        delta_time = params.delta_time or 0.1,
        max_ticks = params.max_ticks or 5000,
        tick_count = 0,
        timestamp = 0,
    }
    return handle
end

function M.reset(handle)
    -- Clear event queue
    handle.event_queue = {}

    -- Reset all node ct_control and node_state
    for node_id, node in pairs(handle.nodes) do
        node.ct_control.enabled = false
        node.ct_control.initialized = false
    end
    handle.node_state = {}

    -- Reset bitmask
    handle.bitmask = 0

    -- Reset blackboard to defaults (preserves const_records)
    handle.blackboard = init_blackboard(handle._bb_def)

    -- Reset active tests
    handle.active_tests = {}
    handle.active_test_count = 0

    -- Reset timer
    handle.tick_count = 0
    handle.timestamp = 0
end

function M.add_test(handle, kb_name)
    if handle.active_tests[kb_name] then return false end

    local kb = handle.kb_table[kb_name]
    if not kb then
        error("ct_runtime.add_test: unknown KB: " .. tostring(kb_name))
    end

    engine.init_test(handle, kb_name)
    handle.active_tests[kb_name] = true
    handle.active_test_count = handle.active_test_count + 1
    return true
end

function M.delete_test(handle, kb_name)
    if not handle.active_tests[kb_name] then return false end

    engine.terminate_all_nodes_in_kb(handle, kb_name)
    handle.active_tests[kb_name] = nil
    handle.active_test_count = handle.active_test_count - 1
    return true
end

-- Main event loop
function M.run(handle)
    local sleep_us = math.floor(handle.delta_time * 1000000)

    local prev_second = 0
    local prev_minute = 0
    local prev_hour   = 0

    while handle.active_test_count > 0 and handle.tick_count < handle.max_ticks do
        ffi.C.usleep(sleep_us)
        handle.tick_count = handle.tick_count + 1
        handle.timestamp = handle.timestamp + handle.delta_time

        -- Detect time boundary crossings
        local cur_second = math.floor(handle.timestamp)
        local cur_minute = math.floor(handle.timestamp / 60)
        local cur_hour   = math.floor(handle.timestamp / 3600)
        local second_changed = cur_second > prev_second
        local minute_changed = cur_minute > prev_minute
        local hour_changed   = cur_hour   > prev_hour
        if second_changed then prev_second = cur_second end
        if minute_changed then prev_minute = cur_minute end
        if hour_changed   then prev_hour   = cur_hour   end

        -- Generate events for each active KB
        for kb_name, _ in pairs(handle.active_tests) do
            local kb = handle.kb_table[kb_name]
            if kb then
                local root = kb.root_node
                table.insert(handle.event_queue, {
                    node_id = root, event_id = defs.CFL_TIMER_EVENT, event_data = nil,
                })
                if second_changed then
                    table.insert(handle.event_queue, {
                        node_id = root, event_id = defs.CFL_SECOND_EVENT, event_data = nil,
                    })
                end
                if minute_changed then
                    table.insert(handle.event_queue, {
                        node_id = root, event_id = defs.CFL_MINUTE_EVENT, event_data = nil,
                    })
                end
                if hour_changed then
                    table.insert(handle.event_queue, {
                        node_id = root, event_id = defs.CFL_HOUR_EVENT, event_data = nil,
                    })
                end
            end
        end

        -- Drain event queue
        while #handle.event_queue > 0 do
            local event = table.remove(handle.event_queue, 1)
            local ok = engine.execute_event(
                handle,
                event.node_id,
                event.event_id,
                event.event_data,
                event.event_type
            )
            if ok == false then
                -- System terminated
                -- Deactivate all KBs
                for kb_name, _ in pairs(handle.active_tests) do
                    handle.active_tests[kb_name] = nil
                    handle.active_test_count = handle.active_test_count - 1
                end
                return true
            end
        end

        -- Check if any active KB's root node is disabled
        local to_remove = {}
        for kb_name, _ in pairs(handle.active_tests) do
            local kb = handle.kb_table[kb_name]
            if kb and not engine.node_is_enabled(handle, kb.root_node) then
                to_remove[#to_remove + 1] = kb_name
            end
        end
        for _, kb_name in ipairs(to_remove) do
            handle.active_tests[kb_name] = nil
            handle.active_test_count = handle.active_test_count - 1
        end
    end

    return true
end

return M
