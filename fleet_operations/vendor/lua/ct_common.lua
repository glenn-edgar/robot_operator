-- ct_common.lua — shared helpers for dict-based ChainTree runtime

local defs = require("ct_definitions")

local M = {}

-- Normalize links: JSON has list for parents, empty dict {} for leaves
-- Returns a Lua array of ltree strings (may be empty)
function M.get_children(node)
    local links = node.label_dict and node.label_dict.links
    if not links then return {} end
    -- Empty dict from cjson decodes as table with no array part
    if type(links) == "table" and #links == 0 then return {} end
    return links
end

-- Enable all children of a node
function M.enable_children(handle, node_id)
    local node = handle.nodes[node_id]
    local children = M.get_children(node)
    for _, child_id in ipairs(children) do
        local child = handle.nodes[child_id]
        if child then
            child.ct_control.enabled = true
        end
    end
end

-- Disable all children of a node (clear enabled + initialized)
function M.disable_children(handle, node_id)
    local node = handle.nodes[node_id]
    local children = M.get_children(node)
    for _, child_id in ipairs(children) do
        local child = handle.nodes[child_id]
        if child then
            child.ct_control.enabled = false
            child.ct_control.initialized = false
        end
    end
end

-- Check if any child is enabled
function M.any_child_enabled(handle, node_id)
    local node = handle.nodes[node_id]
    local children = M.get_children(node)
    for _, child_id in ipairs(children) do
        local child = handle.nodes[child_id]
        if child and child.ct_control.enabled then
            return true
        end
    end
    return false
end

-- Enable a specific child by 1-based link index
function M.enable_child(handle, node_id, child_link_index)
    local node = handle.nodes[node_id]
    local children = M.get_children(node)
    local child_id = children[child_link_index]
    if child_id then
        local child = handle.nodes[child_id]
        if child then
            child.ct_control.enabled = true
        end
    end
end

-- Per-node mutable state (keyed by ltree string)
function M.get_node_state(handle, node_id)
    return handle.node_state[node_id]
end

function M.set_node_state(handle, node_id, data)
    handle.node_state[node_id] = data
end

function M.alloc_node_state(handle, node_id, initial)
    if not handle.node_state[node_id] then
        handle.node_state[node_id] = initial or {}
    end
    return handle.node_state[node_id]
end

-- Get node_dict (runtime configuration) for a node
function M.get_node_data(handle, node_id)
    local node = handle.nodes[node_id]
    if node then return node.node_dict end
    return nil
end

-- Deep access into node_dict by dotted path (e.g., "fn_data.time_out")
function M.get_node_data_field(handle, node_id, path)
    local data = M.get_node_data(handle, node_id)
    if not data then return nil end
    for key in path:gmatch("[^%.]+") do
        if type(data) ~= "table" then return nil end
        data = data[key]
    end
    return data
end

-- Get parent ltree string
function M.get_parent_id(node)
    return node.label_dict and node.label_dict.parent_ltree_name
end

-- Bitmask helpers (kept for builtins that use bitmask_table)
function M.get_bitmask(handle)
    return handle.bitmask or 0
end

function M.set_bitmask(handle, val)
    handle.bitmask = val
end

return M
