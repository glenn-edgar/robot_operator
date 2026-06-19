-- ct_walker.lua — iterative DFS tree walker with string node IDs

local M = {}

function M.create()
    return {
        visited = {},
        stop_all = false,
        apply_func = nil,   -- fn(handle, node_id) -> walker control code
        get_children = nil, -- fn(handle, node_id) -> list of ltree strings
    }
end

function M.update_functions(walker, apply_func, get_children)
    walker.apply_func = apply_func
    walker.get_children = get_children
end

function M.reset(walker)
    walker.visited = {}
    walker.stop_all = false
end

-- Save walker state for nested walks (termination uses this)
function M.save_context(walker)
    local saved_visited = {}
    for k, v in pairs(walker.visited) do saved_visited[k] = v end
    return {
        visited = saved_visited,
        stop_all = walker.stop_all,
    }
end

function M.restore_context(walker, ctx)
    walker.visited = ctx.visited
    walker.stop_all = ctx.stop_all
end

-- Iterative DFS walk from root_id
-- apply_func returns: true (continue), "SKIP_CHILDREN", "STOP_SIBLINGS", "STOP_BRANCH", "STOP_ALL"
function M.walk(walker, handle, root_id)
    walker.visited = {}
    walker.stop_all = false

    local apply = walker.apply_func
    local get_ch = walker.get_children
    if not apply or not get_ch then return end

    -- Stack entries: {node_id, child_index}
    -- child_index = 0 means node not yet visited (apply_func not called)
    -- child_index >= 1 means iterating children
    local stack = {}
    local sp = 1
    stack[sp] = { node_id = root_id, child_index = 0 }

    while sp > 0 do
        local entry = stack[sp]
        local node_id = entry.node_id
        local skip_children = false

        if entry.child_index == 0 then
            -- First visit: mark visited, call apply_func
            walker.visited[node_id] = true
            local rc = apply(handle, node_id)

            if rc == "STOP_ALL" then
                walker.stop_all = true
                return
            elseif rc == "SKIP_CHILDREN" or rc == "STOP_BRANCH" then
                sp = sp - 1
                skip_children = true
            elseif rc == "STOP_SIBLINGS" then
                sp = sp - 1
                if sp > 0 then sp = sp - 1 end
                skip_children = true
            else
                -- rc == true (CT_CONTINUE): proceed to children
                entry.child_index = 1
            end
        end

        if not skip_children and sp > 0 then
            -- Iterate children
            local children = get_ch(handle, node_id)
            local ci = entry.child_index
            if ci <= #children then
                entry.child_index = ci + 1
                local child_id = children[ci]
                if child_id and not walker.visited[child_id] then
                    sp = sp + 1
                    stack[sp] = { node_id = child_id, child_index = 0 }
                end
            else
                -- All children visited, pop
                sp = sp - 1
            end
        end

        if walker.stop_all then return end
    end
end

return M
