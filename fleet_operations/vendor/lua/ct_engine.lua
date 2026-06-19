-- ct_engine.lua — node execution engine (dict-based)

local defs    = require("ct_definitions")
local common  = require("ct_common")
local walker  = require("ct_walker")

local M = {}

-- Get all children (regardless of enabled state)
local function get_all_children(handle, node_id)
    local node = handle.nodes[node_id]
    if not node then return {} end
    return common.get_children(node)
end

-- Initialize a KB: enable root node
function M.init_test(handle, kb_name)
    local kb = handle.kb_table[kb_name]
    if not kb then error("unknown KB: " .. tostring(kb_name)) end
    local root = handle.nodes[kb.root_node]
    if root then
        root.ct_control.enabled = true
    end
end

-- Check if a node is enabled
function M.node_is_enabled(handle, node_id)
    local node = handle.nodes[node_id]
    return node and node.ct_control.enabled or false
end

-- Enable a node
function M.enable_node(handle, node_id)
    local node = handle.nodes[node_id]
    if node then
        node.ct_control.enabled = true
    end
end

-- Disable a single node: run aux terminate + term one-shot, clear ct_control
local function disable_node(handle, node_id)
    local node = handle.nodes[node_id]
    if not node then return end
    local ctl = node.ct_control

    if ctl.enabled and ctl.initialized then
        -- Run auxiliary function with terminate event
        local aux_name = node.label_dict.aux_function_name
        if aux_name and aux_name ~= "CFL_NULL" then
            local aux_fn = handle.boolean_functions[aux_name]
            if aux_fn then
                aux_fn(handle, node, defs.CFL_TERMINATE_EVENT, nil)
            end
        end
        -- Run termination one-shot
        local term_name = node.label_dict.termination_function_name
        if term_name and term_name ~= "CFL_NULL" then
            local term_fn = handle.one_shot_functions[term_name]
            if term_fn then
                term_fn(handle, node)
            end
        end
    end

    ctl.enabled = false
    ctl.initialized = false
    -- Clear per-node state
    handle.node_state[node_id] = nil
end

-- Terminate a subtree: collect enabled+initialized nodes, reverse, disable each
function M.terminate_node_tree(handle, node_id)
    local node = handle.nodes[node_id]
    if not node then return end

    -- Phase 1: collect all enabled nodes in DFS order
    local collected = {}
    local w = walker.create()
    walker.update_functions(w,
        function(h, nid)
            local n = h.nodes[nid]
            if n and n.ct_control.enabled then
                collected[#collected + 1] = nid
                return true  -- continue to children
            end
            return "SKIP_CHILDREN"
        end,
        get_all_children
    )
    walker.walk(w, handle, node_id)

    -- Phase 2: disable in reverse order (children before parents)
    for i = #collected, 1, -1 do
        disable_node(handle, collected[i])
    end
end

-- Terminate all nodes in a KB
function M.terminate_all_nodes_in_kb(handle, kb_name)
    local kb = handle.kb_table[kb_name]
    if not kb then return end
    M.terminate_node_tree(handle, kb.root_node)
end

-- Execute an event: walk tree from node_id, dispatch functions
-- event_type: nil for normal events, "streaming_data" for packets, "streaming_collected" for containers
-- Returns true if execution proceeded, false if system should stop
function M.execute_event(handle, node_id, event_id, event_data, event_type)
    local node = handle.nodes[node_id]
    if not node or not node.ct_control.enabled then
        return false
    end

    -- Store event_type on handle so streaming builtins can check it
    handle.current_event_type = event_type

    local execution_count = 0
    local system_running = true

    local w = walker.create()
    walker.update_functions(w,
        -- apply_func: execute a node
        function(h, nid)
            local n = h.nodes[nid]
            if not n or not n.ct_control.enabled then
                return "SKIP_CHILDREN"
            end

            local ctl = n.ct_control
            local ld = n.label_dict

            -- Initialize if first visit
            if not ctl.initialized then
                -- Run initialization one-shot
                local init_name = ld.initialization_function_name
                if init_name and init_name ~= "CFL_NULL" then
                    local init_fn = h.one_shot_functions[init_name]
                    if init_fn then
                        init_fn(h, n)
                    end
                end
                -- Run auxiliary function with init event
                local aux_name = ld.aux_function_name
                if aux_name and aux_name ~= "CFL_NULL" then
                    local aux_fn = h.boolean_functions[aux_name]
                    if aux_fn then
                        aux_fn(h, n, defs.CFL_INIT_EVENT, nil)
                    end
                end
                ctl.initialized = true

                -- Auto-start: enable all children (unless suppressed by init, e.g. state machine)
                if n.node_dict and n.node_dict.auto_start and not n.node_dict._sm_auto_start_suppressed then
                    common.enable_children(h, nid)
                end
                -- Clear suppression flag for next init cycle
                if n.node_dict then n.node_dict._sm_auto_start_suppressed = nil end
            end

            execution_count = execution_count + 1

            -- Dispatch main function
            local main_name = ld.main_function_name
            local main_fn = h.main_functions[main_name]
            if not main_fn then
                return true  -- no main function, continue
            end

            -- Resolve boolean function
            local bool_name = ld.aux_function_name or "CFL_NULL"
            local bool_fn = h.boolean_functions[bool_name]
            if not bool_fn then
                bool_fn = function() return false end
            end

            local rc = main_fn(h, bool_fn, n, event_id, event_data)

            -- Map return code to walker action
            if rc == defs.CFL_CONTINUE then
                return true  -- continue to children and siblings

            elseif rc == defs.CFL_HALT then
                return "STOP_SIBLINGS"

            elseif rc == defs.CFL_DISABLE then
                M.terminate_node_tree(h, nid)
                return "SKIP_CHILDREN"

            elseif rc == defs.CFL_SKIP_CONTINUE then
                return "SKIP_CHILDREN"

            elseif rc == defs.CFL_RESET then
                local parent_id = common.get_parent_id(n)
                if parent_id and h.nodes[parent_id] then
                    M.terminate_node_tree(h, parent_id)
                    M.enable_node(h, parent_id)
                end
                return "STOP_SIBLINGS"

            elseif rc == defs.CFL_TERMINATE then
                local parent_id = common.get_parent_id(n)
                if parent_id and h.nodes[parent_id] then
                    M.terminate_node_tree(h, parent_id)
                else
                    -- Root node: terminate self
                    M.terminate_node_tree(h, nid)
                    execution_count = 0
                end
                return "STOP_SIBLINGS"

            elseif rc == defs.CFL_TERMINATE_SYSTEM then
                system_running = false
                execution_count = 0
                return "STOP_ALL"
            end

            return true
        end,
        -- get_children
        get_all_children
    )

    walker.walk(w, handle, node_id)

    if not system_running then
        return false
    end
    return execution_count > 0
end

return M
