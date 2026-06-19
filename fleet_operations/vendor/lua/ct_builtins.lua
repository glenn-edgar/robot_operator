-- ct_builtins.lua — built-in functions for dict-based ChainTree runtime
--
-- Ported from cfl_builtins.lua + cfl_state_machine.lua (C-record style)
-- to the dict-based runtime where nodes are full tables, functions are
-- resolved by name, and return codes are strings.
--
-- Function signatures:
--   Main:     fn(handle, bool_fn, node, event_id, event_data) -> return_code_string
--   One-shot: fn(handle, node) -> nil
--   Boolean:  fn(handle, node, event_id, event_data) -> boolean
--
-- Key differences from C-record style:
--   - bool_fn is the actual function reference (not an index)
--   - node is the full node table (not an integer index)
--   - node_id = node.label_dict.ltree_name (ltree string)
--   - children via common.get_children(node) returning ltree strings
--   - node data via node.node_dict directly
--   - functions resolved by name from handle.one_shot_functions / handle.main_functions
--   - return codes are strings: "CFL_CONTINUE", "CFL_HALT", etc.
--   - timer: handle.timestamp (not handle.timer.timestamp)
--   - event queue: table.insert(handle.event_queue, {...})
--   - bitmask: handle.bitmask (integer), bit.band/bit.bor

local bit  = require("bit")
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local defs   = require("ct_definitions")
local common = require("ct_common")

-- Lazy require to break circular dependency
local engine
local function get_engine()
    if not engine then engine = require("ct_engine") end
    return engine
end

-- Local aliases for frequently used constants
local CFL_CONTINUE         = defs.CFL_CONTINUE
local CFL_HALT             = defs.CFL_HALT
local CFL_TERMINATE        = defs.CFL_TERMINATE
local CFL_RESET            = defs.CFL_RESET
local CFL_DISABLE          = defs.CFL_DISABLE
local CFL_SKIP_CONTINUE    = defs.CFL_SKIP_CONTINUE
local CFL_TERMINATE_SYSTEM = defs.CFL_TERMINATE_SYSTEM

local CFL_TIMER_EVENT                   = defs.CFL_TIMER_EVENT
local CFL_INIT_EVENT                    = defs.CFL_INIT_EVENT
local CFL_TERMINATE_EVENT               = defs.CFL_TERMINATE_EVENT
local CFL_RAISE_EXCEPTION_EVENT         = defs.CFL_RAISE_EXCEPTION_EVENT
local CFL_SET_EXCEPTION_STEP_EVENT      = defs.CFL_SET_EXCEPTION_STEP_EVENT
local CFL_TURN_HEARTBEAT_ON_EVENT       = defs.CFL_TURN_HEARTBEAT_ON_EVENT
local CFL_TURN_HEARTBEAT_OFF_EVENT      = defs.CFL_TURN_HEARTBEAT_OFF_EVENT
local CFL_HEARTBEAT_EVENT_ID            = defs.CFL_HEARTBEAT_EVENT
local CFL_CHANGE_STATE_EVENT            = defs.CFL_CHANGE_STATE_EVENT
local CFL_RESET_STATE_MACHINE_EVENT     = defs.CFL_RESET_STATE_MACHINE_EVENT
local CFL_TERMINATE_STATE_MACHINE_EVENT = defs.CFL_TERMINATE_STATE_MACHINE_EVENT

local M = {}

-- =========================================================================
-- Helper: get node_id (ltree string) from node table
-- =========================================================================
local function nid(node)
    return node.label_dict.ltree_name
end

-- =========================================================================
-- Helper: find nearest exception catch/controlled node up the parent chain
-- Returns ltree string of the matching ancestor, or nil
-- =========================================================================
local function find_parent_exception_node(handle, node_id)
    local current_id = common.get_parent_id(handle.nodes[node_id])
    while current_id and handle.nodes[current_id] do
        local n = handle.nodes[current_id]
        local mfn = n.label_dict.main_function_name
        if mfn == "CFL_EXCEPTION_CATCH_MAIN"
        or mfn == "CFL_EXCEPTION_CATCH_ALL_MAIN"
        or mfn == "CFL_CONTROLLED_NODE_MAIN" then
            return current_id
        end
        current_id = common.get_parent_id(n)
    end
    return nil
end

-- =========================================================================
-- MAIN FUNCTIONS
-- =========================================================================

M.main = {}

-- Simple constant-return main functions
M.main.CFL_NULL = function(handle, bool_fn, node, event_id, event_data)
    return CFL_CONTINUE
end

M.main.CFL_DISABLE = function(handle, bool_fn, node, event_id, event_data)
    return CFL_DISABLE
end

M.main.CFL_HALT = function(handle, bool_fn, node, event_id, event_data)
    return CFL_HALT
end

M.main.CFL_RESET = function(handle, bool_fn, node, event_id, event_data)
    return CFL_RESET
end

M.main.CFL_TERMINATE = function(handle, bool_fn, node, event_id, event_data)
    return CFL_TERMINATE
end

M.main.CFL_TERMINATE_SYSTEM = function(handle, bool_fn, node, event_id, event_data)
    return CFL_TERMINATE_SYSTEM
end

-- Column main: on timer, check bool_fn, check any child enabled, else disable
M.main.CFL_COLUMN_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if event_id ~= CFL_TIMER_EVENT then
        return CFL_CONTINUE
    end
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end
    local node_id = nid(node)
    if not common.any_child_enabled(handle, node_id) then
        return CFL_DISABLE
    end
    return CFL_CONTINUE
end

-- Aliases for column-like main functions
M.main.CFL_GATE_NODE_MAIN                  = M.main.CFL_COLUMN_MAIN
M.main.CFL_FORK_MAIN                       = M.main.CFL_COLUMN_MAIN
M.main.CFL_LOCAL_ARENA_MAIN                = M.main.CFL_COLUMN_MAIN
M.main.CFL_SEQUENCE_START_MAIN             = M.main.CFL_COLUMN_MAIN
M.main.CFL_CONTROLLED_NODE_CONTAINER_MAIN  = M.main.CFL_COLUMN_MAIN

-- Verify: check boolean, if false call error handler
M.main.CFL_VERIFY = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_CONTINUE
    end
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.error_function then
        local err_fn = handle.one_shot_functions[ns.error_function]
        if err_fn then err_fn(handle, node) end
        if ns.reset_flag then return CFL_RESET end
    end
    return CFL_TERMINATE
end

-- Wait: halt until boolean or event count reached
M.main.CFL_WAIT = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns or ns.timeout == 0 then
        return CFL_HALT
    end

    if ns.time_out_event and ns.time_out_event == event_id then
        ns.event_count = (ns.event_count or 0) + 1
        if ns.event_count >= ns.timeout then
            if ns.error_function then
                local err_fn = handle.one_shot_functions[ns.error_function]
                if err_fn then err_fn(handle, node) end
            end
            if ns.reset_flag then return CFL_RESET end
            return CFL_TERMINATE
        end
    end

    return CFL_HALT
end

-- Wait time: halt until timestamp exceeded
M.main.CFL_WAIT_TIME = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end
    if event_id ~= CFL_TIMER_EVENT then
        return CFL_HALT
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.wait_time_out and handle.timestamp >= ns.wait_time_out then
        return CFL_DISABLE
    end
    return CFL_HALT
end

-- ---------- Time-of-day window wait leaves ----------
-- Two native CFL wait-leaves that gate on whether the engine's wall clock
-- currently matches a configured local-time window. Standard wait-leaf shape:
-- HALT while the gate condition holds, DISABLE once it flips. Re-arm by
-- RESETting the surrounding parent (composition via subtrees).
--
--   CFL_WAIT_UNTIL_IN_TIME_WINDOW     HALT while OUT of window, DISABLE on entry
--   CFL_WAIT_UNTIL_OUT_OF_TIME_WINDOW HALT while IN window,     DISABLE on exit
--
-- Ported from the Python ct_builtins time_window.py — same window semantics.
--
-- Window shape: per-field [start,end] masks over {hour,minute,sec,dow,dom},
-- each field independent. Both bounds present => field in [start,end]
-- inclusive, wrap allowed when end < start (minute 50..10 = [50..59]+[0..10]).
-- Both absent => field unconstrained. Exactly one present => error (the
-- paired-or-absent rule; the DSL asm_* validates this at build time too).
-- Final answer = logical AND of all five per-field checks. Field ranges:
-- hour 0..23, minute 0..59, sec 0..59, dow 0..6 (0=Mon), dom 1..31.
--
-- Wall clock: handle.get_wall_time() if the runtime supplies it (epoch
-- seconds — lets a test inject a clock), else os.time(). Broken down to
-- local time, or UTC when handle.timezone == "utc".
--
-- node.node_dict = { start = <field table>, ["end"] = <field table> }

-- current in [start,end], wrapping when end < start
local function tw_span_contains(cur, start_v, end_v)
    if start_v <= end_v then
        return cur >= start_v and cur <= end_v
    end
    return cur >= start_v or cur <= end_v
end

local function tw_field_ok(cur, start_v, end_v, field_name)
    if start_v == nil and end_v == nil then return true end
    if start_v == nil or end_v == nil then
        error("time-window field '" .. field_name .. "' must be present in "
            .. "both start and end, or neither")
    end
    return tw_span_contains(cur, start_v, end_v)
end

local function tw_in_window(handle, node)
    local nd    = node.node_dict or {}
    local win_s = nd.start or {}
    local win_e = nd["end"] or {}

    local epoch = (handle.get_wall_time and handle.get_wall_time())
        or os.time()
    local dt = os.date(handle.timezone == "utc" and "!*t" or "*t", epoch)
    -- os.date wday is 1=Sun..7=Sat; the window's dow is 0=Mon..6=Sun
    -- (Python datetime.weekday()).
    local dow = (dt.wday + 5) % 7

    return tw_field_ok(dt.hour, win_s.hour,   win_e.hour,   "hour")
       and tw_field_ok(dt.min,  win_s.minute, win_e.minute, "minute")
       and tw_field_ok(dt.sec,  win_s.sec,    win_e.sec,    "sec")
       and tw_field_ok(dow,     win_s.dow,    win_e.dow,    "dow")
       and tw_field_ok(dt.day,  win_s.dom,    win_e.dom,    "dom")
end

-- HALT while the wall clock is OUT of the window; DISABLE on first tick IN.
M.main.CFL_WAIT_UNTIL_IN_TIME_WINDOW = function(handle, bool_fn, node, event_id, event_data)
    if tw_in_window(handle, node) then
        return CFL_DISABLE
    end
    return CFL_HALT
end

-- HALT while the wall clock is IN the window; DISABLE on first tick OUT.
-- Idiomatic use: place after a one-shot action inside a column so the action
-- fires once per window crossing; RESET the parent to re-arm.
M.main.CFL_WAIT_UNTIL_OUT_OF_TIME_WINDOW = function(handle, bool_fn, node, event_id, event_data)
    if tw_in_window(handle, node) then
        return CFL_HALT
    end
    return CFL_DISABLE
end

-- Event logger: check event_ids array, print matching events
M.main.CFL_EVENT_LOGGER = function(handle, bool_fn, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns or not ns.event_ids then return CFL_DISABLE end

    for _, eid in ipairs(ns.event_ids) do
        if eid == event_id then
            local node_num = handle.ltree_to_index and handle.ltree_to_index[node_id] or "?"
            print(string.format("++++ timestamp %f ,node id: %s event id: %d message: %s",
                handle.timestamp or 0, tostring(node_num), event_id, ns.message or ""))
        end
    end
    return CFL_CONTINUE
end

-- Join: halt until target node is disabled
M.main.CFL_JOIN_MAIN = function(handle, bool_fn, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end

    if ns.target_node and get_engine().node_is_enabled(handle, ns.target_node) then
        return CFL_HALT
    end
    return CFL_DISABLE
end

M.main.CFL_JOIN_SEQUENCE_ELEMENT = M.main.CFL_JOIN_MAIN

-- Sequence pass: step through children, advance on failure (child passed=stop, child failed=next)
M.main.CFL_SEQUENCE_PASS_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end
    if event_id ~= CFL_TIMER_EVENT then return CFL_CONTINUE end

    local children = common.get_children(node)
    local child_count = #children
    -- 0-based sequence index, 1-based Lua array
    local active_child_id = children[ns.current_sequence_index + 1]

    if active_child_id and get_engine().node_is_enabled(handle, active_child_id) then
        return CFL_CONTINUE
    end

    -- Active child finished
    ns.final_status = ns.sequence_results and ns.sequence_results[ns.current_sequence_index]
    if ns.current_sequence_index + 1 >= child_count then
        -- All children done
        if ns.finalize_fn then
            local fin = handle.one_shot_functions[ns.finalize_fn]
            if fin then fin(handle, node) end
        end
        return CFL_DISABLE
    end

    -- Pass semantics: if child failed (false), advance to next
    if ns.final_status == false then
        if active_child_id then
            get_engine().terminate_node_tree(handle, active_child_id)
        end
        ns.current_sequence_index = ns.current_sequence_index + 1
        local next_child_id = children[ns.current_sequence_index + 1]
        if next_child_id then
            get_engine().enable_node(handle, next_child_id)
        end
        return CFL_CONTINUE
    end

    -- Child passed: sequence done
    if ns.finalize_fn then
        local fin = handle.one_shot_functions[ns.finalize_fn]
        if fin then fin(handle, node) end
    end
    return CFL_DISABLE
end

-- Sequence fail: step through children, advance on success (child passed=next, child failed=stop)
M.main.CFL_SEQUENCE_FAIL_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end
    if event_id ~= CFL_TIMER_EVENT then return CFL_CONTINUE end

    local children = common.get_children(node)
    local child_count = #children
    local active_child_id = children[ns.current_sequence_index + 1]

    if active_child_id and get_engine().node_is_enabled(handle, active_child_id) then
        return CFL_CONTINUE
    end

    ns.final_status = ns.sequence_results and ns.sequence_results[ns.current_sequence_index]
    if ns.current_sequence_index + 1 >= child_count then
        if ns.finalize_fn then
            local fin = handle.one_shot_functions[ns.finalize_fn]
            if fin then fin(handle, node) end
        end
        return CFL_DISABLE
    end

    -- Fail semantics: if child passed (true), advance to next
    if ns.final_status == true then
        if active_child_id then
            get_engine().terminate_node_tree(handle, active_child_id)
        end
        ns.current_sequence_index = ns.current_sequence_index + 1
        local next_child_id = children[ns.current_sequence_index + 1]
        if next_child_id then
            get_engine().enable_node(handle, next_child_id)
        end
        return CFL_CONTINUE
    end

    -- Child failed: sequence done
    if ns.finalize_fn then
        local fin = handle.one_shot_functions[ns.finalize_fn]
        if fin then fin(handle, node) end
    end
    return CFL_DISABLE
end

-- For loop: re-enable single child until iteration count reached
M.main.CFL_FOR_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end

    local children = common.get_children(node)
    local child_id = children[1]

    if child_id and get_engine().node_is_enabled(handle, child_id) then
        return CFL_CONTINUE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end
    ns.current_iteration = (ns.current_iteration or 0) + 1
    if ns.current_iteration >= ns.number_of_iterations then
        return CFL_DISABLE
    end
    if child_id then
        get_engine().enable_node(handle, child_id)
    end
    return CFL_CONTINUE
end

-- While loop: re-enable single child while bool_fn returns true
M.main.CFL_WHILE_MAIN = function(handle, bool_fn, node, event_id, event_data)
    local children = common.get_children(node)
    local child_id = children[1]

    if child_id and get_engine().node_is_enabled(handle, child_id) then
        return CFL_CONTINUE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if ns then ns.current_iteration = (ns.current_iteration or 0) + 1 end

    if not bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end
    if child_id then
        get_engine().enable_node(handle, child_id)
    end
    return CFL_CONTINUE
end

-- Watchdog: count timer events, call wd_fn on timeout
M.main.CFL_WATCH_DOG_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns or not ns.wd_enabled then return CFL_CONTINUE end
    if event_id ~= CFL_TIMER_EVENT then return CFL_CONTINUE end

    ns.current_count = (ns.current_count or 0) + 1
    if ns.current_count >= ns.wd_time_count then
        if ns.wd_fn then
            local wd_fn = handle.one_shot_functions[ns.wd_fn]
            if wd_fn then wd_fn(handle, node) end
        end
        if ns.wd_reset then return CFL_RESET end
        return CFL_TERMINATE
    end
    return CFL_CONTINUE
end

-- Data flow bitmask: enable/disable children based on bitmask conditions
M.main.CFL_DF_MASK_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if bool_fn(handle, node, event_id, event_data) then
        return CFL_DISABLE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end

    if event_id == CFL_TIMER_EVENT then
        local required_met = band(ns.required_bitmask or 0, handle.bitmask or 0) == (ns.required_bitmask or 0)
        local excluded_clear = band(ns.excluded_bitmask or 0, handle.bitmask or 0) == 0
        local conditions_met = required_met and excluded_clear

        if not ns.node_state then
            if conditions_met then
                common.enable_children(handle, node_id)
                ns.node_state = true
            end
        else
            if not conditions_met then
                local children = common.get_children(node)
                for _, cid in ipairs(children) do
                    get_engine().terminate_node_tree(handle, cid)
                end
                ns.node_state = false
            end
        end
    end

    if not ns.node_state then return CFL_SKIP_CONTINUE end
    return CFL_CONTINUE
end

-- Supervisor: monitor children, restart on all-disabled, track reset count
-- Supervisor: per-child failure tracking, leaky bucket, termination types
M.main.CFL_SUPERVISOR_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if event_id ~= CFL_TIMER_EVENT then
        return CFL_CONTINUE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end

    ns.now_tick = (ns.now_tick or 0) + 1
    local children = common.get_children(node)
    local child_count = #children

    -- Leaky bucket: decay failure counts based on time window
    if ns.reset_limited_enabled then
        for i = 1, child_count do
            local fa = ns.failure_array[i]
            if fa then
                local elapsed = ns.now_tick - fa.last_tick
                local leak = math.floor(elapsed / ns.reset_window)
                fa.bucket = math.max(0, fa.bucket - leak)
                fa.last_tick = ns.now_tick
            end
        end
    end

    local any_active = false
    for i = 1, child_count do
        local fa = ns.failure_array[i]
        if fa and fa.active then
            any_active = true
            local child_id = children[i]
            if child_id and not get_engine().node_is_enabled(handle, child_id) then
                -- Child disabled (failed/terminated)
                fa.bucket = (fa.bucket or 0) + 1
                ns.failed_link_index = i - 1  -- 0-based for display

                -- Check boolean (user can override)
                if bool_fn(handle, node, event_id, event_data) then
                    return CFL_DISABLE
                end

                -- Leaky bucket: check if failure limit exceeded
                if ns.reset_limited_enabled then
                    local child_num = handle.ltree_to_index and handle.ltree_to_index[child_id] or "?"
                    print(string.format("cfl_leaky_bucket_check link_id: %s, i: %d", tostring(child_num), i - 1))
                    if fa.bucket >= ns.max_reset_number then
                        -- Failure window exceeded — call finalize and disable
                        if ns.finalize_fn then
                            local fin = handle.one_shot_functions[ns.finalize_fn]
                            if fin then fin(handle, node) end
                        end
                        return CFL_DISABLE
                    end
                end

                -- Handle termination based on termination_type
                -- 0: one_for_one — restart only the failed child
                -- 1: one_for_all — restart all children
                -- 2: rest_for_all — restart failed child and all after it
                if ns.termination_type == 0 then
                    get_engine().terminate_node_tree(handle, child_id)
                    if ns.restart_enabled then
                        get_engine().enable_node(handle, child_id)
                    end
                elseif ns.termination_type == 1 then
                    for j = 1, child_count do
                        local cid = children[j]
                        if cid then
                            get_engine().terminate_node_tree(handle, cid)
                            if ns.restart_enabled then
                                get_engine().enable_node(handle, cid)
                            end
                        end
                    end
                elseif ns.termination_type == 2 then
                    for j = i, child_count do
                        local cid = children[j]
                        if cid then
                            get_engine().terminate_node_tree(handle, cid)
                            if ns.restart_enabled then
                                get_engine().enable_node(handle, cid)
                            end
                        end
                    end
                end

                -- Check if any children still active after handling
                local still_active = false
                for j = 1, child_count do
                    if children[j] and get_engine().node_is_enabled(handle, children[j]) then
                        still_active = true
                        break
                    end
                end
                if not still_active then
                    if ns.finalize_fn then
                        local fin = handle.one_shot_functions[ns.finalize_fn]
                        if fin then fin(handle, node) end
                    end
                    return CFL_DISABLE
                end
                return CFL_CONTINUE
            end
        end
    end

    if not any_active then
        return CFL_DISABLE
    end
    return CFL_CONTINUE
end

-- Recovery: step-based recovery state machine
-- States: "eval" (check skip condition), "wait" (child running),
--         "parallel_enable" (enable remaining), "parallel_wait" (wait for all)
M.main.CFL_RECOVERY_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if event_id ~= CFL_TIMER_EVENT then
        return CFL_CONTINUE
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end

    local children = common.get_children(node)
    local child_count = #children
    if child_count == 0 then return CFL_DISABLE end

    local state = ns.recovery_state or "eval"

    if state == "eval" then
        -- Loop from current_step to max_steps, call bool_fn for each step
        while ns.current_step < ns.max_steps and ns.current_step < child_count do
            -- bool_fn is USER_SKIP_CONDITION: returns true to SKIP (enable) this step
            if bool_fn(handle, node, event_id, event_data) then
                -- Enable this child
                local child_id = children[ns.current_step + 1]
                if child_id then
                    get_engine().enable_node(handle, child_id)
                end
                ns.recovery_state = "wait"
                return CFL_CONTINUE
            end
            ns.current_step = ns.current_step + 1
        end
        -- No match found in eval range, fall to parallel_enable
        ns.recovery_state = "parallel_enable"
        return CFL_CONTINUE

    elseif state == "wait" then
        -- Check if the active child is still enabled
        local child_id = children[ns.current_step + 1]
        if child_id and get_engine().node_is_enabled(handle, child_id) then
            return CFL_CONTINUE
        end
        -- Child done, advance
        ns.current_step = ns.current_step + 1
        if ns.current_step >= ns.max_steps or ns.current_step >= child_count then
            ns.recovery_state = "parallel_enable"
            return CFL_CONTINUE
        end
        ns.recovery_state = "eval"
        return CFL_CONTINUE

    elseif state == "parallel_enable" then
        -- Enable all children after max_steps (parallel recovery steps)
        local any_enabled = false
        for i = ns.max_steps + 1, child_count do
            local child_id = children[i]
            if child_id then
                get_engine().enable_node(handle, child_id)
                any_enabled = true
            end
        end
        if not any_enabled then
            return CFL_DISABLE
        end
        ns.recovery_state = "parallel_wait"
        return CFL_CONTINUE

    elseif state == "parallel_wait" then
        -- Wait for all parallel children to finish
        for i = ns.max_steps + 1, child_count do
            local child_id = children[i]
            if child_id and get_engine().node_is_enabled(handle, child_id) then
                return CFL_CONTINUE
            end
        end
        return CFL_DISABLE
    end

    return CFL_CONTINUE
end

-- Exception catch-all: simpler version — bool_fn decides catch/forward
M.main.CFL_EXCEPTION_CATCH_ALL_MAIN = function(handle, bool_fn, node, event_id, event_data)
    if event_id == CFL_RAISE_EXCEPTION_EVENT then
        local node_id = nid(node)
        local ns = common.get_node_state(handle, node_id)
        if ns then
            ns.original_node_id = event_data
            ns.exception_type = 1
        end
        -- Call bool_fn (CATCH_ALL_EXCEPTION user boolean)
        if bool_fn(handle, node, event_id, event_data) then
            -- Caught: log and continue
            if ns and ns.logging_fn then
                local log_fn = handle.one_shot_functions[ns.logging_fn]
                if log_fn then log_fn(handle, node) end
            end
            return CFL_CONTINUE
        else
            -- Not caught: forward to parent exception node and disable
            if ns and ns.parent_exception_node then
                table.insert(handle.event_queue, 1, {
                    node_id = ns.parent_exception_node,
                    event_id = CFL_RAISE_EXCEPTION_EVENT,
                    event_data = event_data,
                })
            end
            return CFL_DISABLE
        end
    end

    if event_id ~= CFL_TIMER_EVENT then
        return CFL_CONTINUE
    end

    -- Normal tick: check if children still enabled
    local node_id = nid(node)
    if not common.any_child_enabled(handle, node_id) then
        return CFL_DISABLE
    end
    return CFL_CONTINUE
end

-- Exception catch (filtered): complex state machine with stages main/recovery/finalize
M.main.CFL_EXCEPTION_CATCH_MAIN = function(handle, bool_fn, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end

    -- ---------- RAISE_EXCEPTION_EVENT ----------
    if event_id == CFL_RAISE_EXCEPTION_EVENT then
        ns.original_node_id = event_data  -- ltree string of originating node
        ns.exception_type = 1  -- raised

        -- Call logging function if set
        if ns.logging_fn then
            local log_fn = handle.one_shot_functions[ns.logging_fn]
            if log_fn then log_fn(handle, node) end
        end

        -- Call bool_fn (EXCEPTION_FILTER): true means forward, false means caught
        if bool_fn(handle, node, event_id, event_data) then
            -- Filter says forward: propagate to parent exception node
            if ns.parent_exception_node then
                table.insert(handle.event_queue, 1, {
                    node_id = ns.parent_exception_node,
                    event_id = CFL_RAISE_EXCEPTION_EVENT,
                    event_data = event_data,
                })
            end
            return CFL_DISABLE
        end

        -- Caught: transition based on current stage
        if ns.exception_stage == "main" then
            -- Terminate main link, enable recovery link
            if ns.catch_links[1] then
                get_engine().terminate_node_tree(handle, ns.catch_links[1])
            end
            if ns.catch_links[2] then
                get_engine().enable_node(handle, ns.catch_links[2])
            end
            ns.exception_stage = "recovery"
            return CFL_CONTINUE
        else
            -- Not in main stage: forward to parent
            if ns.parent_exception_node then
                table.insert(handle.event_queue, 1, {
                    node_id = ns.parent_exception_node,
                    event_id = CFL_RAISE_EXCEPTION_EVENT,
                    event_data = event_data,
                })
            end
            return CFL_DISABLE
        end
    end

    -- ---------- CFL_SET_EXCEPTION_STEP_EVENT ----------
    if event_id == CFL_SET_EXCEPTION_STEP_EVENT then
        ns.step_count = event_data  -- integer step count
        return CFL_CONTINUE
    end

    -- ---------- HEARTBEAT events ----------
    if event_id == CFL_TURN_HEARTBEAT_ON_EVENT then
        ns.heartbeat_enabled = true
        ns.heartbeat_timeout = event_data
        ns.heartbeat_count = 0
        return CFL_CONTINUE
    end
    if event_id == CFL_TURN_HEARTBEAT_OFF_EVENT then
        ns.heartbeat_enabled = false
        return CFL_CONTINUE
    end
    if event_id == CFL_HEARTBEAT_EVENT_ID then
        ns.heartbeat_count = 0
        return CFL_CONTINUE
    end

    -- ---------- TIMER_EVENT ----------
    if event_id ~= CFL_TIMER_EVENT then
        return CFL_CONTINUE
    end

    -- Heartbeat timeout check
    if ns.heartbeat_enabled then
        ns.heartbeat_count = (ns.heartbeat_count or 0) + 1
        if ns.heartbeat_count >= (ns.heartbeat_timeout or 0) then
            -- Heartbeat timeout: same as raise exception
            ns.exception_type = 2  -- heartbeat
            if ns.logging_fn then
                local log_fn = handle.one_shot_functions[ns.logging_fn]
                if log_fn then log_fn(handle, node) end
            end
            if ns.exception_stage == "main" then
                if ns.catch_links[1] then
                    get_engine().terminate_node_tree(handle, ns.catch_links[1])
                end
                if ns.catch_links[2] then
                    get_engine().enable_node(handle, ns.catch_links[2])
                end
                ns.exception_stage = "recovery"
                ns.heartbeat_enabled = false
                return CFL_CONTINUE
            else
                if ns.parent_exception_node then
                    table.insert(handle.event_queue, 1, {
                        node_id = ns.parent_exception_node,
                        event_id = CFL_RAISE_EXCEPTION_EVENT,
                        event_data = ns.original_node_id or node_id,
                    })
                end
                return CFL_DISABLE
            end
        end
    end

    -- Normal execution: check if any catch_link child is still enabled
    local any_enabled = false
    for _, link_id in ipairs(ns.catch_links) do
        if get_engine().node_is_enabled(handle, link_id) then
            any_enabled = true
            break
        end
    end

    if not any_enabled then
        -- Stage transitions on child completion
        if ns.exception_stage == "main" then
            -- Main done: enable finalize link
            if ns.catch_links[3] then
                get_engine().enable_node(handle, ns.catch_links[3])
            end
            ns.exception_stage = "finalize"
            return CFL_CONTINUE
        elseif ns.exception_stage == "recovery" then
            -- Recovery done: enable finalize link
            if ns.catch_links[3] then
                get_engine().enable_node(handle, ns.catch_links[3])
            end
            ns.exception_stage = "finalize"
            return CFL_CONTINUE
        elseif ns.exception_stage == "finalize" then
            -- All done
            return CFL_DISABLE
        end
    end

    return CFL_CONTINUE
end

-- State machine: deferred state change (current_state vs new_state), bool_fn filters events
M.main.CFL_STATE_MACHINE_MAIN = function(handle, bool_fn, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_TERMINATE_SYSTEM end

    local children = common.get_children(node)

    -- Deferred state change: if new_state differs from current_state, execute transition
    if ns.new_state ~= ns.current_state then
        local old_child = children[ns.current_state + 1]
        if old_child then
            get_engine().terminate_node_tree(handle, old_child)
        end
        local new_child = children[ns.new_state + 1]
        if new_child then
            get_engine().enable_node(handle, new_child)
        end
        ns.current_state = ns.new_state
    end

    -- Boolean function: true → SKIP_CONTINUE (filter event, skip children)
    local return_value = CFL_CONTINUE
    if bool_fn(handle, node, event_id, event_data) then
        return_value = CFL_SKIP_CONTINUE
    end

    -- Check if any child is enabled
    for _, child_id in ipairs(children) do
        if get_engine().node_is_enabled(handle, child_id) then
            return return_value
        end
    end

    return CFL_DISABLE
end

-- SM event filtering: user function stub, just return CONTINUE
M.main.SM_EVENT_FILTERING_MAIN = function(handle, bool_fn, node, event_id, event_data)
    return CFL_CONTINUE
end

-- Controlled node stubs
-- CONTROLLED NODE (SERVER): receives request, enables children, sends response on term
M.main.CFL_CONTROLLED_NODE_MAIN = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_CONTINUE end

    -- Check for request event
    if ns.request_port and event_id == ns.request_port.event_id then
        if handle.current_event_type == "streaming_data" then
            -- Store request data and client source
            ns.request_data = event_data
            ns.client_node_id = ns.pending_client_node_id
            -- Call monitor boolean
            bool_fn(handle, node, event_id, event_data)
            -- Enable children (the processing pipeline)
            common.enable_children(handle, node_id)
            return CFL_HALT
        end
    end

    -- Check for exception
    if event_id == defs.CFL_RAISE_EXCEPTION_EVENT then
        return CFL_DISABLE
    end

    -- Normal tick: check if children still enabled
    if event_id == defs.CFL_TIMER_EVENT then
        if not common.any_child_enabled(handle, node_id) then
            return CFL_DISABLE
        end
    end
    return CFL_CONTINUE
end

-- CLIENT CONTROLLED NODE: sends request to server, waits for response
M.main.CFL_CLIENT_CONTROLLED_NODE_MAIN = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_CONTINUE end

    if not ns.node_is_active then
        -- First call: enable server and send request
        local server_id = ns.server_node_id
        if server_id and handle.nodes[server_id] then
            local server = handle.nodes[server_id]

            -- Enable server — set both enabled and initialized so the
            -- engine won't re-run the init one-shot (state was already
            -- set up by CFL_CONTROLLED_NODE_INIT on first use or by us now)
            server.ct_control.enabled = true
            server.ct_control.initialized = true

            -- Ensure all ancestors of server are enabled (container may have
            -- disabled itself when all children completed)
            local pid = common.get_parent_id(server)
            while pid and handle.nodes[pid] do
                local parent = handle.nodes[pid]
                if not parent.ct_control.enabled then
                    parent.ct_control.enabled = true
                    parent.ct_control.initialized = true
                end
                pid = common.get_parent_id(parent)
            end

            -- Ensure server has node state with port info + our client id
            local server_ns = common.alloc_node_state(handle, server_id)
            server_ns.pending_client_node_id = node_id
            -- Re-initialize server ports from node_dict if missing
            if not server_ns.request_port then
                local snd = server.node_dict or {}
                local scd = snd.column_data or {}
                if scd.request_port then
                    server_ns.request_port = {
                        event_id = scd.request_port.event_id,
                        handler_id = scd.request_port.handler_id,
                        schema_hash = scd.request_port.schema_hash,
                    }
                end
                if scd.response_port then
                    server_ns.response_port = {
                        event_id = scd.response_port.event_id,
                        handler_id = scd.response_port.handler_id,
                        schema_hash = scd.response_port.schema_hash,
                    }
                end
            end

            -- Send request as streaming event to server
            if ns.request_port then
                table.insert(handle.event_queue, 1, {
                    node_id = server_id,
                    event_id = ns.request_port.event_id,
                    event_type = "streaming_data",
                    event_data = ns.request_packet,
                })
            end
        end
        ns.node_is_active = true
        return CFL_HALT
    end

    -- Wait for response
    if ns.response_port and event_id == ns.response_port.event_id then
        if handle.current_event_type == "streaming_data" then
            ns.response_data = event_data
            local result = bool_fn(handle, node, event_id, event_data)
            if not result then
                return CFL_TERMINATE
            end
            return CFL_DISABLE
        end
    end

    -- Exception handling
    if event_id == defs.CFL_RAISE_EXCEPTION_EVENT then
        return CFL_DISABLE
    end

    return CFL_HALT
end

-- Streaming stubs (Avro-dependent)
-- Helper: check if event matches a streaming inport
local function streaming_event_matches(handle, event_id, event_data, inport)
    if handle.current_event_type ~= "streaming_data" then return false end
    if event_id ~= inport.event_id then return false end
    if event_data == nil then return false end
    -- Check schema_hash if event_data is FFI packet
    if type(event_data) == "cdata" then
        local ffi = require("ffi")
        local hash_ptr = ffi.cast("uint32_t*", ffi.cast("uint8_t*", event_data) + 8)
        -- Normalize both to int32: JSON may store hashes > 2^31 as negative
        -- Lua numbers, causing sign-extension mismatch with FFI uint32_t
        return bit.tobit(tonumber(hash_ptr[0])) == bit.tobit(inport.schema_hash)
    end
    return true
end

-- TAP: observe packet, always continue
M.main.CFL_STREAMING_TAP_PACKET = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.inport and streaming_event_matches(handle, event_id, event_data, ns.inport) then
        bool_fn(handle, node, event_id, event_data)
    end
    return CFL_CONTINUE
end

-- FILTER: check boolean, halt if false
M.main.CFL_STREAMING_FILTER_PACKET = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.inport and streaming_event_matches(handle, event_id, event_data, ns.inport) then
        if not bool_fn(handle, node, event_id, event_data) then
            return CFL_HALT
        end
    end
    return CFL_CONTINUE
end

-- SINK: consume packet, always continue
M.main.CFL_STREAMING_SINK_PACKET = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.inport and streaming_event_matches(handle, event_id, event_data, ns.inport) then
        bool_fn(handle, node, event_id, event_data)
    end
    return CFL_CONTINUE
end

-- TRANSFORM: read input, user transforms, always continue
M.main.CFL_STREAMING_TRANSFORM_PACKET = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.inport and streaming_event_matches(handle, event_id, event_data, ns.inport) then
        bool_fn(handle, node, event_id, event_data)
    end
    return CFL_CONTINUE
end

-- COLLECT: multi-port aggregator
M.main.CFL_STREAMING_COLLECT_PACKETS = function(handle, bool_fn, node, event_id, event_data)
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if not ns or not ns.inports then return CFL_CONTINUE end
    if ns.container_pending then return CFL_CONTINUE end

    for i, inport in ipairs(ns.inports) do
        if streaming_event_matches(handle, event_id, event_data, inport) then
            ns.current_port_index = i  -- pass port index to boolean via node state
            local accept = bool_fn(handle, node, event_id, event_data)
            if accept and ns.container_count < ns.container_capacity then
                ns.container_count = ns.container_count + 1
                ns.container_packets[ns.container_count] = event_data
                ns.container_port_indices[ns.container_count] = i

                if ns.container_count >= ns.container_capacity then
                    table.insert(handle.event_queue, {
                        node_id = ns.output_event_column_id,
                        event_id = ns.output_event_id,
                        event_type = "streaming_collected",
                        event_data = {
                            packets = ns.container_packets,
                            port_indices = ns.container_port_indices,
                            count = ns.container_count,
                        },
                    })
                    -- Reset container for next collection cycle
                    ns.container_count = 0
                    ns.container_packets = {}
                    ns.container_port_indices = {}
                    ns.container_pending = false
                end
            end
            break
        end
    end
    return CFL_CONTINUE
end

-- SINK COLLECTED: consume collected packet container
M.main.CFL_STREAMING_SINK_COLLECTED_PACKETS = function(handle, bool_fn, node, event_id, event_data)
    if handle.current_event_type ~= "streaming_collected" then return CFL_CONTINUE end
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if not ns then return CFL_CONTINUE end
    if event_id == ns.event_id then
        bool_fn(handle, node, event_id, event_data)
    end
    return CFL_CONTINUE
end


-- =========================================================================
-- ONE-SHOT FUNCTIONS
-- =========================================================================

M.one_shot = {}

-- Generic no-op
local function noop_oneshot(handle, node) end
local function clear_state(handle, node)
    handle.node_state[node.label_dict.ltree_name] = nil
end

M.one_shot.CFL_NULL = noop_oneshot

-- ---------- Column ----------
M.one_shot.CFL_COLUMN_INIT = function(handle, node)
    local node_id = nid(node)
    common.alloc_node_state(handle, node_id)
    common.enable_children(handle, node_id)
end

M.one_shot.CFL_COLUMN_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Gate node ----------
-- Gate node init: only enable children with auto_start=true (unlike column which enables all)
M.one_shot.CFL_GATE_NODE_INIT = function(handle, node)
    local node_id = nid(node)
    common.alloc_node_state(handle, node_id)
    local children = common.get_children(node)
    for _, child_id in ipairs(children) do
        local child = handle.nodes[child_id]
        if child and child.node_dict and child.node_dict.auto_start then
            child.ct_control.enabled = true
        end
    end
end
M.one_shot.CFL_GATE_NODE_TERM = M.one_shot.CFL_COLUMN_TERM

-- ---------- Fork ----------
M.one_shot.CFL_FORK_INIT = M.one_shot.CFL_COLUMN_INIT
M.one_shot.CFL_FORK_TERM = M.one_shot.CFL_COLUMN_TERM

-- ---------- Local arena ----------
M.one_shot.CFL_LOCAL_ARENA_INIT = M.one_shot.CFL_COLUMN_INIT
M.one_shot.CFL_LOCAL_ARENA_TERM = M.one_shot.CFL_COLUMN_TERM

-- ---------- Sequence start ----------
M.one_shot.CFL_SEQUENCE_START_INIT = M.one_shot.CFL_COLUMN_INIT
M.one_shot.CFL_SEQUENCE_START_TERM = M.one_shot.CFL_COLUMN_TERM

-- ---------- Controlled node container ----------
M.one_shot.CFL_CONTROLLED_NODE_CONTAINER_INIT = M.one_shot.CFL_COLUMN_INIT
M.one_shot.CFL_CONTROLLED_NODE_CONTAINER_TERM = M.one_shot.CFL_COLUMN_TERM

-- ---------- Log message ----------
-- Wall-clock timestamp helper (epoch seconds with microsecond precision)
local ffi = require("ffi")
pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } ct_log_timespec_t;")
pcall(ffi.cdef, "int clock_gettime(int clk_id, ct_log_timespec_t *tp);")
local log_ts_buf = ffi.new("ct_log_timespec_t")
local function wall_timestamp()
    ffi.C.clock_gettime(0, log_ts_buf)  -- CLOCK_REALTIME = 0
    return tonumber(log_ts_buf.tv_sec) + tonumber(log_ts_buf.tv_nsec) * 1e-9
end

M.one_shot.CFL_LOG_MESSAGE = function(handle, node)
    local msg = node.node_dict and node.node_dict.message or "(no message)"
    local node_id = node.label_dict.ltree_name
    local node_num = handle.ltree_to_index and handle.ltree_to_index[node_id] or "?"
    print(string.format("Timestamp: %f, Node Index: %s, Message: %s", wall_timestamp(), tostring(node_num), msg))
end

-- ---------- Wait time ----------
M.one_shot.CFL_WAIT_TIME_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local delay = node.node_dict and node.node_dict.time_delay or 0
    ns.wait_time_out = (handle.timestamp or 0) + delay
end

-- ---------- Verify ----------
M.one_shot.CFL_VERIFY_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.error_function = nd.error_function  -- string name
    ns.reset_flag = nd.reset_flag or false
    ns.error_data = nd.error_data
    ns.fn_data = nd.fn_data
end

M.one_shot.CFL_VERIFY_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Wait ----------
M.one_shot.CFL_WAIT_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.timeout = nd.timeout or 0
    ns.time_out_event = nd.time_out_event or CFL_TIMER_EVENT
    ns.error_function = nd.error_function  -- string name
    ns.reset_flag = nd.reset_flag or false
    ns.event_count = 0
end

M.one_shot.CFL_WAIT_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Send named event ----------
M.one_shot.CFL_SEND_NAMED_EVENT = function(handle, node)
    local nd = node.node_dict or {}
    local target_node_id = nd.node_id   -- ltree string (resolved by loader)
    local ev_id = nd.event_id
    local ev_data = nd.event_data
    if target_node_id and ev_id then
        table.insert(handle.event_queue, {
            node_id = target_node_id,
            event_id = ev_id,
            event_data = ev_data,
        })
    end
end

-- ---------- Event logger ----------
M.one_shot.CFL_EVENT_LOGGER_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.event_ids = nd.events or {}
    ns.message = nd.message or ""
end

M.one_shot.CFL_EVENT_LOGGER_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Enable / Disable nodes ----------
M.one_shot.CFL_ENABLE_NODES = function(handle, node)
    local nd = node.node_dict or {}
    local node_list = nd.nodes  -- list of ltree strings (resolved by loader)
    if node_list then
        for _, ltree in ipairs(node_list) do
            get_engine().enable_node(handle, ltree)
        end
    end
end

M.one_shot.CFL_DISABLE_NODES = function(handle, node)
    local nd = node.node_dict or {}
    local node_list = nd.nodes  -- list of ltree strings (resolved by loader)
    if node_list then
        for _, ltree in ipairs(node_list) do
            get_engine().terminate_node_tree(handle, ltree)
        end
    end
end

-- ---------- For loop ----------
M.one_shot.CFL_FOR_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.number_of_iterations = nd.number_of_iterations or 1
    ns.current_iteration = 0
    -- Enable first child
    local children = common.get_children(node)
    if children[1] then
        get_engine().enable_node(handle, children[1])
    end
end

M.one_shot.CFL_FOR_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- While loop ----------
M.one_shot.CFL_WHILE_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    ns.current_iteration = 0
    -- Enable first child
    local children = common.get_children(node)
    if children[1] then
        get_engine().enable_node(handle, children[1])
    end
end

M.one_shot.CFL_WHILE_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Watchdog ----------
M.one_shot.CFL_WATCH_DOG_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.wd_time_count = nd.wd_time_count or 100
    ns.wd_fn = nd.wd_fn          -- string function name
    ns.wd_reset = nd.wd_reset or false
    ns.wd_enabled = true
    ns.current_count = 0
end

M.one_shot.CFL_WATCH_DOG_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

M.one_shot.CFL_ENABLE_WATCH_DOG = function(handle, node)
    local nd = node.node_dict or {}
    local wd_node_id = nd.node_id or nid(node)
    local ns = common.get_node_state(handle, wd_node_id)
    if ns then
        ns.wd_enabled = true
        ns.current_count = 0
    end
end

M.one_shot.CFL_DISABLE_WATCH_DOG = function(handle, node)
    local nd = node.node_dict or {}
    local wd_node_id = nd.node_id or nid(node)
    local ns = common.get_node_state(handle, wd_node_id)
    if ns then
        ns.wd_enabled = false
    end
end

M.one_shot.CFL_PAT_WATCH_DOG = function(handle, node)
    local nd = node.node_dict or {}
    local wd_node_id = nd.node_id or nid(node)
    local ns = common.get_node_state(handle, wd_node_id)
    if ns then
        ns.current_count = 0
    end
end

-- ---------- Bitmask operations ----------
M.one_shot.CFL_SET_BITMASK = function(handle, node)
    local nd = node.node_dict or {}
    local mask_val = nd.bit_mask
    if mask_val then
        handle.bitmask = bor(handle.bitmask or 0, mask_val)
    end
end

M.one_shot.CFL_CLEAR_BITMASK = function(handle, node)
    local nd = node.node_dict or {}
    local mask_val = nd.bit_mask
    if mask_val then
        handle.bitmask = band(handle.bitmask or 0, bnot(mask_val))
    end
end

-- ---------- DF mask ----------
M.one_shot.CFL_DF_MASK_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    ns.required_bitmask = cd.required_bitmask or 0
    ns.excluded_bitmask = cd.excluded_bitmask or 0
    ns.node_state = false
end

M.one_shot.CFL_DF_MASK_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Supervisor ----------
M.one_shot.CFL_SUPERVISOR_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local sd = nd.column_data and nd.column_data.supervisor_data or nd.supervisor_data or {}
    ns.restart_enabled = sd.restart_enabled or false
    ns.reset_limited_enabled = sd.reset_limited_enabled or false
    ns.max_reset_number = sd.max_reset_number or 3
    ns.reset_window = sd.reset_window or 100
    ns.termination_type = sd.termination_type or 0
    ns.now_tick = 0
    ns.failed_link_index = -1
    local fin_name = sd.finalize_function
    ns.finalize_fn = fin_name
    -- Initialize per-child failure tracking array (1-based)
    local children = common.get_children(node)
    ns.failure_array = {}
    for i = 1, #children do
        ns.failure_array[i] = { node_id = nil, bucket = 0, last_tick = 0, active = true }
    end
    -- Enable all supervised children
    common.enable_children(handle, node_id)
end

M.one_shot.CFL_SUPERVISOR_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Recovery ----------
M.one_shot.CFL_RECOVERY_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    local max_steps = cd.max_steps or 99

    -- Find parent exception catch node and read its step_count
    local parent_id = find_parent_exception_node(handle, node_id)
    local step_count = 0
    if parent_id then
        local parent_ns = common.get_node_state(handle, parent_id)
        if parent_ns then
            step_count = parent_ns.step_count or 0
        end
    end

    -- Calculate: start recovery from the step that failed
    ns.current_step = max_steps - step_count
    if ns.current_step < 0 then ns.current_step = 0 end
    ns.max_steps = max_steps
    ns.recovery_state = "eval"
    -- Do NOT enable any child here; the main function handles it
end

M.one_shot.CFL_RECOVERY_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Supervisor failure mark ----------
-- Walk up parent chain to find the supervisor node, then mark the failed child link
M.one_shot.CFL_MARK_SUPERVISOR_NODE_FAILURE_INIT = function(handle, node)
    local ref_node_id = nid(node)
    local current_id = ref_node_id
    local previous_id = current_id

    while current_id do
        local n = handle.nodes[current_id]
        if not n then break end
        if n.label_dict.main_function_name == "CFL_SUPERVISOR_MAIN" then
            -- Found the supervisor — identify which child link failed
            local children = common.get_children(n)
            for i, child_id in ipairs(children) do
                if child_id == previous_id then
                    local ns = common.get_node_state(handle, current_id)
                    if ns then
                        ns.failed_link_index = i - 1  -- 0-based
                        if ns.failure_array and ns.failure_array[i] then
                            ns.failure_array[i].node_id = ref_node_id
                        end
                    end
                    return
                end
            end
        end
        previous_id = current_id
        current_id = common.get_parent_id(n)
    end
end

-- ---------- Sequence mark ----------
M.one_shot.CFL_MARK_SEQUENCE = function(handle, node)
    local nd = node.node_dict or {}
    local node_id = nid(node)
    local node_num = handle.ltree_to_index and handle.ltree_to_index[node_id] or "?"
    print(string.format("cfl_mark_sequence_one_shot_fn node_index: %s", tostring(node_num)))
    -- parent_node_name points to the sequence pass/fail node (not tree parent)
    local seq_node_id = nd.parent_node_name
    if seq_node_id then
        local ns = common.get_node_state(handle, seq_node_id)
        if ns and ns.sequence_results then
            local result = (nd.result == 1) and true or false
            ns.sequence_results[ns.current_sequence_index] = result
        end
    end
end

-- ---------- State machine ----------
M.one_shot.CFL_STATE_MACHINE_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    local initial = cd.initial_state_number or 0
    ns.current_state = initial
    ns.new_state = initial
    ns.sync_event_id = 0
    ns.sync_event_id_valid = false

    -- Build state name → index map from label_dict.state_names
    ns.state_name_to_index = {}
    local state_names = node.label_dict.state_names
    if state_names then
        for i, name in ipairs(state_names) do
            ns.state_name_to_index[name] = i - 1  -- 0-based
        end
    end

    -- Enable ONLY the initial state child (disable all others)
    local children = common.get_children(node)
    ns.state_count = #children
    for i, child_id in ipairs(children) do
        local child = handle.nodes[child_id]
        if child then
            if (i - 1) == initial then
                child.ct_control.enabled = true
            else
                child.ct_control.enabled = false
                child.ct_control.initialized = false
            end
        end
    end
    -- Suppress auto_start (engine would re-enable all children after init)
    if node.node_dict then
        node.node_dict._sm_auto_start_suppressed = true
    end
end

M.one_shot.CFL_STATE_MACHINE_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Change state ----------
M.one_shot.CFL_CHANGE_STATE = function(handle, node)
    local nd = node.node_dict or {}
    local sm_node_id = nd.sm_node_id or nd.node_id  -- ltree string (resolved by loader)
    if not sm_node_id then return end
    local new_state_name = nd.new_state
    local sync_event_id = nd.sync_event_id  -- nil (JSON null) or integer

    -- Resolve state name to index using the SM's state_name_to_index map
    local sm_ns = common.get_node_state(handle, sm_node_id)
    if not sm_ns then return end

    local new_state_index = 0
    if sm_ns.state_name_to_index and type(new_state_name) == "string" then
        new_state_index = sm_ns.state_name_to_index[new_state_name] or 0
    elseif type(new_state_name) == "number" then
        new_state_index = new_state_name
    end

    -- Deferred state change: set new_state, SM main will execute the transition
    sm_ns.new_state = new_state_index

    -- Store sync event if provided (nil = JSON null = no sync)
    if sync_event_id then
        sm_ns.sync_event_id = sync_event_id
        sm_ns.sync_event_id_valid = true
        -- Send the sync event to the SM so it can unblock itself
        table.insert(handle.event_queue, {
            node_id = sm_node_id,
            event_id = sync_event_id,
            event_data = nil,
        })
    else
        sm_ns.sync_event_id_valid = false
    end
end

-- ---------- Reset state machine ----------
M.one_shot.CFL_RESET_STATE_MACHINE = function(handle, node)
    local nd = node.node_dict or {}
    local sm_node_id = nd.sm_node_id or nd.node_id
    if sm_node_id then
        get_engine().terminate_node_tree(handle, sm_node_id)
        get_engine().enable_node(handle, sm_node_id)
    end
end

-- ---------- Terminate state machine ----------
M.one_shot.CFL_TERMINATE_STATE_MACHINE = function(handle, node)
    local nd = node.node_dict or {}
    local sm_node_id = nd.sm_node_id or nd.node_id
    if sm_node_id then
        get_engine().terminate_node_tree(handle, sm_node_id)
    end
end

-- ---------- Exception catch-all ----------
M.one_shot.CFL_CATCH_ALL_EXCEPTION_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    ns.aux_data = cd.aux_data
    ns.logging_fn = cd.logging_function  -- string function name
    ns.parent_exception_node = find_parent_exception_node(handle, node_id)
    ns.original_node_id = nil
    ns.exception_type = nil
    -- Enable all children
    common.enable_children(handle, node_id)
end

M.one_shot.CFL_CATCH_ALL_EXCEPTION_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Exception catch (filtered) ----------
M.one_shot.CFL_EXCEPTION_CATCH_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}

    -- State machine stage: "main", "recovery", "finalize"
    ns.exception_stage = "main"

    -- Resolve exception_catch_links from integer indices to ltree strings
    local raw_links = cd.exception_catch_links or {}
    ns.catch_links = {}
    for i, v in ipairs(raw_links) do
        if type(v) == "number" and handle.idx_to_ltree then
            ns.catch_links[i] = handle.idx_to_ltree[v] or v
        else
            ns.catch_links[i] = v
        end
    end

    ns.logging_fn = cd.logging_function  -- string function name
    ns.parent_exception_node = find_parent_exception_node(handle, node_id)
    ns.step_count = 0
    ns.heartbeat_enabled = false
    ns.original_node_id = nil
    ns.exception_type = nil

    -- Enable ONLY the first catch link (main link)
    -- Suppress auto_start (engine would re-enable all children after init)
    if node.node_dict then
        node.node_dict._sm_auto_start_suppressed = true
    end
    if ns.catch_links[1] then
        get_engine().enable_node(handle, ns.catch_links[1])
    end
end

M.one_shot.CFL_EXCEPTION_CATCH_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

-- ---------- Raise exception ----------
M.one_shot.CFL_RAISE_EXCEPTION = function(handle, node)
    local node_id = nid(node)
    -- Find nearest exception catch node by walking up from current node
    local target = find_parent_exception_node(handle, node_id)
    if target then
        -- Send high-priority RAISE_EXCEPTION_EVENT to nearest exception handler
        table.insert(handle.event_queue, 1, {
            node_id = target,
            event_id = CFL_RAISE_EXCEPTION_EVENT,
            event_data = node_id,  -- originating node ltree
        })
    end
end

-- ---------- Set exception step ----------
M.one_shot.CFL_SET_EXCEPTION_STEP = function(handle, node)
    local node_id = nid(node)
    local nd = node.node_dict or {}
    local step = nd.step
    if not step then return end
    -- Find nearest exception catch node
    local target = find_parent_exception_node(handle, node_id)
    if target then
        -- Send high-priority SET_EXCEPTION_STEP_EVENT with step count
        table.insert(handle.event_queue, 1, {
            node_id = target,
            event_id = CFL_SET_EXCEPTION_STEP_EVENT,
            event_data = step,
        })
    end
end

-- ---------- Heartbeat operations ----------
M.one_shot.CFL_TURN_HEARTBEAT_ON = function(handle, node)
    local node_id = nid(node)
    local nd = node.node_dict or {}
    local target = find_parent_exception_node(handle, node_id)
    if target then
        table.insert(handle.event_queue, 1, {
            node_id = target,
            event_id = CFL_TURN_HEARTBEAT_ON_EVENT,
            event_data = nd.time_out or 10,
        })
    end
end

M.one_shot.CFL_TURN_HEARTBEAT_OFF = function(handle, node)
    local node_id = nid(node)
    local target = find_parent_exception_node(handle, node_id)
    if target then
        table.insert(handle.event_queue, 1, {
            node_id = target,
            event_id = CFL_TURN_HEARTBEAT_OFF_EVENT,
            event_data = nil,
        })
    end
end

M.one_shot.CFL_HEARTBEAT_EVENT = function(handle, node)
    local node_id = nid(node)
    local target = find_parent_exception_node(handle, node_id)
    if target then
        table.insert(handle.event_queue, 1, {
            node_id = target,
            event_id = CFL_HEARTBEAT_EVENT_ID,
            event_data = nil,
        })
    end
end

-- ---------- Start/stop tests ----------
M.one_shot.CFL_START_STOP_TESTS = noop_oneshot

-- ---------- Controlled node stubs ----------
M.one_shot.CFL_CONTROLLED_NODE_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local node_index = handle.ltree_to_index and handle.ltree_to_index[node_id] or "?"
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    print(string.format("cfl_controlled_node_init_one_shot_fn: node_index: %s", tostring(node_index)))
    -- Store request/response port info
    if cd.request_port then
        ns.request_port = {
            event_id = cd.request_port.event_id,
            handler_id = cd.request_port.handler_id,
            schema_hash = cd.request_port.schema_hash,
        }
        print("cfl_avro_decode_port: port_path: node_dict.column_data.request_port")
        print(string.format("cfl_avro_decode_port: schema_hash: %d", bit.tobit(cd.request_port.schema_hash)))
        print(string.format("cfl_avro_decode_port: handler_id: %d", cd.request_port.handler_id))
    end
    if cd.response_port then
        ns.response_port = {
            event_id = cd.response_port.event_id,
            handler_id = cd.response_port.handler_id,
            schema_hash = cd.response_port.schema_hash,
        }
        print("cfl_avro_decode_port: port_path: node_dict.column_data.response_port")
        print(string.format("cfl_avro_decode_port: schema_hash: %d", bit.tobit(cd.response_port.schema_hash)))
        print(string.format("cfl_avro_decode_port: handler_id: %d", cd.response_port.handler_id))
    end
end
M.one_shot.CFL_CONTROLLED_NODE_TERM = function(handle, node)
    -- Server term: send response packet back to client
    local node_id = node.label_dict.ltree_name
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.response_port and ns.client_node_id then
        -- Create a simple response (success=true)
        local response = { success = true }
        table.insert(handle.event_queue, 1, {
            node_id = ns.client_node_id,
            event_id = ns.response_port.event_id,
            event_type = "streaming_data",
            event_data = response,
        })
    end
    handle.node_state[node_id] = nil
end
M.one_shot.CFL_CLIENT_CONTROLLED_NODE_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local node_index = handle.ltree_to_index and handle.ltree_to_index[node_id] or "?"
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    print(string.format("cfl_client_controlled_node_init_one_shot_fn: node_index: %s", tostring(node_index)))
    -- Store port info
    if nd.request_port then
        ns.request_port = {
            event_id = nd.request_port.event_id,
            handler_id = nd.request_port.handler_id,
            schema_hash = nd.request_port.schema_hash,
        }
        print("cfl_avro_decode_port: port_path: node_dict.request_port")
        print(string.format("cfl_avro_decode_port: schema_hash: %d", bit.tobit(nd.request_port.schema_hash)))
        print(string.format("cfl_avro_decode_port: handler_id: %d", nd.request_port.handler_id))
    end
    if nd.response_port then
        ns.response_port = {
            event_id = nd.response_port.event_id,
            handler_id = nd.response_port.handler_id,
            schema_hash = nd.response_port.schema_hash,
        }
        print("cfl_avro_decode_port: port_path: node_dict.response_port")
        print(string.format("cfl_avro_decode_port: schema_hash: %d", bit.tobit(nd.response_port.schema_hash)))
        print(string.format("cfl_avro_decode_port: handler_id: %d", nd.response_port.handler_id))
    end
    -- Resolve server node index to ltree
    ns.server_node_id = nd.server_node_index
    ns.aux_data = nd.aux_data
    ns.api_name = nd.api_name
    ns.node_is_active = false
    -- Create request packet as Lua table (user boolean will fill it on INIT)
    ns.request_packet = { aux_data = nd.aux_data }
end
M.one_shot.CFL_CLIENT_CONTROLLED_NODE_TERM   = noop_oneshot

-- ---------- Sequence pass ----------
M.one_shot.CFL_SEQUENCE_PASS_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    ns.current_sequence_index = 0
    ns.sequence_type = "pass"
    ns.final_status = nil
    ns.sequence_results = {}
    ns.finalize_fn = cd.finalize_function  -- string function name
    -- Enable first child
    local children = common.get_children(node)
    if children[1] then
        get_engine().enable_node(handle, children[1])
    end
end

M.one_shot.CFL_SEQUENCE_PASS_TERM = function(handle, node)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.finalize_fn then
        local fin = handle.one_shot_functions[ns.finalize_fn]
        if fin then fin(handle, node) end
    end
    handle.node_state[node_id] = nil
end

-- ---------- Sequence fail ----------
M.one_shot.CFL_SEQUENCE_FAIL_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    local cd = nd.column_data or {}
    ns.current_sequence_index = 0
    ns.sequence_type = "fail"
    ns.final_status = nil
    ns.sequence_results = {}
    ns.finalize_fn = cd.finalize_function  -- string function name
    -- Enable first child
    local children = common.get_children(node)
    if children[1] then
        get_engine().enable_node(handle, children[1])
    end
end

M.one_shot.CFL_SEQUENCE_FAIL_TERM = function(handle, node)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if ns and ns.finalize_fn then
        local fin = handle.one_shot_functions[ns.finalize_fn]
        if fin then fin(handle, node) end
    end
    handle.node_state[node_id] = nil
end

-- ---------- Join ----------
M.one_shot.CFL_JOIN_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.target_node = nd.parent_node_name  -- ltree string (resolved by loader)
end

M.one_shot.CFL_JOIN_TERM = function(handle, node)
    handle.node_state[nid(node)] = nil
end

M.one_shot.CFL_JOIN_SEQUENCE_ELEMENT_INIT = M.one_shot.CFL_JOIN_INIT
M.one_shot.CFL_JOIN_SEQUENCE_ELEMENT_TERM = M.one_shot.CFL_JOIN_TERM

-- ---------- SM event filtering init ----------
M.one_shot.SM_EVENT_FILTERING_INIT = function(handle, node)
    local node_id = nid(node)
    local ns = common.alloc_node_state(handle, node_id)
    -- Resolve event string to event_id
    if handle.event_strings then
        ns.event_id = handle.event_strings["TEST_EVENT_1"]
    end
end

-- ---------- Streaming stubs (all no-op) ----------
-- Streaming inport init helper
local function init_inport(ns, nd)
    if nd.inport then
        ns.inport = {
            event_id = nd.inport.event_id,
            handler_id = nd.inport.handler_id,
            schema_hash = nd.inport.schema_hash,
        }
    end
    ns.aux_data = nd.aux_data
end

-- Streaming outport init helper
local function init_outport(ns, nd)
    if nd.outport then
        ns.outport = {
            event_id = nd.outport.event_id,
            handler_id = nd.outport.handler_id,
            schema_hash = nd.outport.schema_hash,
            event_column_id = nd.event_column or nd.output_event_column_id,
        }
    end
end

M.one_shot.CFL_STREAMING_FILTER_PACKET_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local ns = common.alloc_node_state(handle, node_id)
    init_inport(ns, node.node_dict or {})
end
M.one_shot.CFL_STREAMING_FILTER_PACKET_TERM = clear_state

M.one_shot.CFL_STREAMING_SINK_PACKET_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local ns = common.alloc_node_state(handle, node_id)
    init_inport(ns, node.node_dict or {})
end
M.one_shot.CFL_STREAMING_SINK_PACKET_TERM = clear_state

M.one_shot.CFL_STREAMING_TAP_PACKET_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local ns = common.alloc_node_state(handle, node_id)
    init_inport(ns, node.node_dict or {})
end
M.one_shot.CFL_STREAMING_TAP_PACKET_TERM = clear_state

M.one_shot.CFL_STREAMING_TRANSFORM_PACKET_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    init_inport(ns, nd)
    init_outport(ns, nd)
    ns.output_event_column_id = nd.output_event_column_id
    ns.output_event_id = nd.output_event_id
end
M.one_shot.CFL_STREAMING_TRANSFORM_PACKET_TERM = clear_state

M.one_shot.CFL_STREAMING_COLLECT_PACKETS_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.inports = {}
    if nd.inports then
        for _, ip in ipairs(nd.inports) do
            ns.inports[#ns.inports + 1] = {
                event_id = ip.event_id,
                handler_id = ip.handler_id,
                schema_hash = ip.schema_hash,
            }
        end
    end
    local capacity = nd.aux_data and nd.aux_data.expected_count or #ns.inports
    ns.container_capacity = capacity
    ns.container_count = 0
    ns.container_packets = {}
    ns.container_port_indices = {}
    ns.container_pending = false
    ns.output_event_column_id = nd.output_event_column_id
    ns.output_event_id = nd.output_event_id
    ns.aux_data = nd.aux_data
end
M.one_shot.CFL_STREAMING_COLLECT_PACKETS_TERM = clear_state

M.one_shot.CFL_STREAMING_SINK_COLLECTED_PACKETS_INIT = function(handle, node)
    local node_id = node.label_dict.ltree_name
    local ns = common.alloc_node_state(handle, node_id)
    local nd = node.node_dict or {}
    ns.event_id = nd.event_id
    ns.aux_data = nd.aux_data
end
M.one_shot.CFL_STREAMING_SINK_COLLECTED_PACKETS_TERM = clear_state

-- ---------- Avro/user function stubs ----------
M.one_shot.PACKET_GENERATOR             = noop_oneshot
M.one_shot.UPDATE_FLY_1_FINAL           = noop_oneshot
M.one_shot.UPDATE_FLY_2_FINAL           = noop_oneshot
M.one_shot.UPDATE_FLY_3_FINAL           = noop_oneshot
M.one_shot.UPDATE_FLY_4_FINAL           = noop_oneshot


-- =========================================================================
-- BOOLEAN FUNCTIONS
-- =========================================================================

M.boolean = {}

-- Always false
M.boolean.CFL_NULL = function(handle, node, event_id, event_data)
    return false
end

M.boolean.CFL_BOOL_FALSE = function(handle, node, event_id, event_data)
    return false
end

M.boolean.CFL_COLUMN_NULL        = M.boolean.CFL_NULL
M.boolean.CFL_GATE_NODE_NULL     = M.boolean.CFL_NULL
M.boolean.CFL_STATE_MACHINE_NULL = M.boolean.CFL_NULL

-- Verify timeout: on INIT compute timeout timestamp, on TIMER check
M.boolean.CFL_VERIFY_TIME_OUT = function(handle, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return false end

    if event_id == CFL_INIT_EVENT then
        local fn_data = ns.fn_data or (node.node_dict and node.node_dict.fn_data)
        local timeout = fn_data and tonumber(fn_data.time_out) or 0
        ns.timestamp_timeout = (handle.timestamp or 0) + timeout
        return false
    end
    if event_id == CFL_TERMINATE_EVENT then return false end
    if event_id == CFL_TIMER_EVENT then
        if (handle.timestamp or 0) >= (ns.timestamp_timeout or 0) then
            return false  -- timed out: verification fails
        end
    end
    return true  -- not timed out: verification passes
end

-- Wait for event: match event_id, decrement count, return true when 0
M.boolean.CFL_WAIT_FOR_EVENT = function(handle, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return false end

    if event_id == CFL_INIT_EVENT then
        local nd = node.node_dict or {}
        local wfd = nd.wait_fn_data or {}
        ns.wait_event_id = wfd.event_id
        ns.wait_event_count = wfd.event_count or 1
        return false
    end
    if event_id == CFL_TERMINATE_EVENT then return false end

    if event_id == ns.wait_event_id then
        ns.wait_event_count = (ns.wait_event_count or 1) - 1
        if ns.wait_event_count <= 0 then return true end
    end
    return false
end

-- State machine event sync
M.boolean.CFL_SM_EVENT_SYNC = function(handle, node, event_id, event_data)
    if event_id == CFL_INIT_EVENT or event_id == CFL_TERMINATE_EVENT then
        return false
    end

    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns or not ns.sync_event_id_valid then return false end

    if event_id == ns.sync_event_id then
        ns.sync_event_id_valid = false
    end
    return true
end

-- Verify bitmask: check required and excluded against handle.bitmask
M.boolean.CFL_VERIFY_BITMASK = function(handle, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return false end

    if event_id == CFL_INIT_EVENT then
        local nd = node.node_dict or {}
        local fd = nd.fn_data or {}
        ns.required_bitmask = fd.required_bitmask or 0
        ns.excluded_bitmask = fd.excluded_bitmask or 0
        return false
    end
    if event_id == CFL_TERMINATE_EVENT then return false end
    if event_id ~= CFL_TIMER_EVENT then return true end

    local req = band(ns.required_bitmask or 0, handle.bitmask or 0) == (ns.required_bitmask or 0)
    local exc = band(ns.excluded_bitmask or 0, handle.bitmask or 0) == 0
    return req and exc
end

-- Wait for bitmask
M.boolean.CFL_WAIT_FOR_BITMASK = function(handle, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return false end

    if event_id == CFL_INIT_EVENT then
        local nd = node.node_dict or {}
        local wfd = nd.wait_fn_data or {}
        ns.required_bitmask = wfd.required_bitmask or 0
        ns.excluded_bitmask = wfd.excluded_bitmask or 0
        return false
    end
    if event_id == CFL_TERMINATE_EVENT then return false end
    if event_id ~= CFL_TIMER_EVENT then return false end

    local req = band(ns.required_bitmask or 0, handle.bitmask or 0) == (ns.required_bitmask or 0)
    local exc = band(ns.excluded_bitmask or 0, handle.bitmask or 0) == 0
    return req and exc
end

-- Verify tests active: true while any KB is active
-- CFL_VERIFY_TESTS_ACTIVE: checks if specific KB(s) are active
-- In single-KB mode, the target KB is never started by START_STOP_TESTS, so return false
M.boolean.CFL_VERIFY_TESTS_ACTIVE = function(handle, node, event_id, event_data)
    if event_id == CFL_INIT_EVENT or event_id == CFL_TERMINATE_EVENT then
        return false
    end
    -- Multi-KB not implemented: target KB never started → verify fails
    return false
end

-- CFL_WAIT_FOR_TESTS_COMPLETE: true when target KB(s) complete
-- In single-KB mode, return true immediately (no other KB to wait for)
M.boolean.CFL_WAIT_FOR_TESTS_COMPLETE = function(handle, node, event_id, event_data)
    if event_id == CFL_INIT_EVENT or event_id == CFL_TERMINATE_EVENT then
        return false
    end
    return true
end

-- Streaming verify packet boolean: wraps user aux function with inport matching
-- Returns true for non-streaming events (nothing to verify = pass-through).
-- Only returns false when a matching streaming packet fails the user check.
M.boolean.CFL_STREAMING_VERIFY_PACKET = function(handle, node, event_id, event_data)
    local node_id = nid(node)
    local ns = common.get_node_state(handle, node_id)
    if not ns then return true end

    if event_id == CFL_INIT_EVENT then
        -- Set up streaming inport from verify fn_data
        if ns.fn_data and ns.fn_data.inport then
            ns.verify_inport = {
                event_id = ns.fn_data.inport.event_id,
                handler_id = ns.fn_data.inport.handler_id,
                schema_hash = ns.fn_data.inport.schema_hash,
            }
        end
        ns.user_aux_function = ns.fn_data and ns.fn_data.user_aux_function
        -- Forward INIT to user aux function
        if ns.user_aux_function then
            local user_fn = handle.boolean_functions[ns.user_aux_function]
            if user_fn then user_fn(handle, node, event_id, event_data) end
        end
        return true
    end

    if event_id == CFL_TERMINATE_EVENT then
        if ns.user_aux_function then
            local user_fn = handle.boolean_functions[ns.user_aux_function]
            if user_fn then user_fn(handle, node, event_id, event_data) end
        end
        return true
    end

    -- Non-streaming events: nothing to verify, pass through
    if not ns.verify_inport then return true end
    if not streaming_event_matches(handle, event_id, event_data, ns.verify_inport) then
        return true
    end

    -- Matching streaming event: delegate to user aux function
    if ns.user_aux_function then
        local user_fn = handle.boolean_functions[ns.user_aux_function]
        if user_fn then
            return user_fn(handle, node, event_id, event_data)
        end
    end
    return true
end

-- ---------- Avro/user boolean stubs (all return false) ----------
M.boolean.PACKET_FILTER             = function(h, n, ei, ed) return false end
M.boolean.PACKET_SINK_A             = function(h, n, ei, ed) return false end
M.boolean.PACKET_SINK_B             = function(h, n, ei, ed) return false end
M.boolean.PACKET_TAP                = function(h, n, ei, ed) return false end
M.boolean.PACKET_TRANSFORM          = function(h, n, ei, ed) return false end
M.boolean.PACKET_COLLECTOR          = function(h, n, ei, ed) return false end
M.boolean.PACKET_COLLECTOR_SINK     = function(h, n, ei, ed) return false end
M.boolean.PACKET_VERIFIED_SINK      = function(h, n, ei, ed) return false end
M.boolean.ON_FLY_1_COMPLETE         = function(h, n, ei, ed) return false end
M.boolean.ON_FLY_2_COMPLETE         = function(h, n, ei, ed) return false end
M.boolean.ON_FLY_3_COMPLETE         = function(h, n, ei, ed) return false end
M.boolean.ON_FLY_4_COMPLETE         = function(h, n, ei, ed) return false end
M.boolean.fly_1_monitor             = function(h, n, ei, ed) return false end
M.boolean.fly_2_monitor             = function(h, n, ei, ed) return false end
M.boolean.fly_3_monitor             = function(h, n, ei, ed) return false end
M.boolean.fly_4_monitor             = function(h, n, ei, ed) return false end

return M
