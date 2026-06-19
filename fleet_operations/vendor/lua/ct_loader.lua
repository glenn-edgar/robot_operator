-- ct_loader.lua — load JSON IR into dict-based structure

local cjson = require("cjson")
local cjson_null = cjson.null

local M = {}

-- Convert cjson.null userdata to real nil throughout a table
local function scrub_nulls(t)
    if type(t) ~= "table" then return t end
    local to_remove = {}
    for k, v in pairs(t) do
        if v == cjson_null then
            to_remove[#to_remove + 1] = k
        elseif type(v) == "table" then
            scrub_nulls(v)
        end
    end
    for _, k in ipairs(to_remove) do
        t[k] = nil
    end
    return t
end

-- Metadata KB names to filter out
local METADATA_SUFFIXES = { "_functions" }
local METADATA_EXACT = {
    complete_functions_kb = true,
    bitmask_table_kb = true,
    event_string_table_kb = true,
}

local function is_metadata_kb(name)
    if METADATA_EXACT[name] then return true end
    for _, suffix in ipairs(METADATA_SUFFIXES) do
        if name:sub(-#suffix) == suffix then return true end
    end
    return false
end

-- Metadata node labels to filter
local METADATA_LABELS = {
    virtual_functions = true,
    complete_functions = true,
    main_functions = true,
    one_shot_functions = true,
    boolean_functions = true,
}

local function is_metadata_node(node)
    return METADATA_LABELS[node.label] or false
end

-- Normalize links: empty dict {} → empty list {}
local function normalize_links(links)
    if not links then return {} end
    if type(links) == "table" and #links == 0 then
        -- Could be empty dict or empty array; either way → empty list
        return {}
    end
    return links
end

function M.load(json_path)
    -- Read and parse JSON
    local f = assert(io.open(json_path, "r"))
    local raw = f:read("*a")
    f:close()

    local ir = scrub_nulls(cjson.decode(raw))
    assert(ir.schema_version == "1.0", "unsupported schema: " .. tostring(ir.schema_version))

    -- Build original-index → ltree map (for resolving node_id references)
    local idx_to_ltree = {}
    for ltree, idx in pairs(ir.ltree_to_index) do
        idx_to_ltree[idx] = ltree
    end

    -- Identify operational KBs (filter metadata)
    local operational_kbs = {}
    for kb_name in pairs(ir.kb_log_dict) do
        if not is_metadata_kb(kb_name) then
            operational_kbs[#operational_kbs + 1] = kb_name
        end
    end
    table.sort(operational_kbs)

    -- Collect operational nodes and inject ct_control
    local nodes = {}
    local main_names = {}
    local oneshot_names = {}
    local boolean_names = {}

    -- Track which ltrees belong to metadata KBs (to exclude their children)
    local metadata_ltree_prefixes = {}
    for kb_name in pairs(ir.kb_metadata) do
        if is_metadata_kb(kb_name) then
            metadata_ltree_prefixes[#metadata_ltree_prefixes + 1] = "kb." .. kb_name .. "."
        end
    end

    local function is_in_metadata_kb(ltree)
        for _, prefix in ipairs(metadata_ltree_prefixes) do
            if ltree:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    for ltree, node in pairs(ir.nodes) do
        if not is_in_metadata_kb(ltree) and not is_metadata_node(node) then
            -- Normalize links
            if node.label_dict then
                node.label_dict.links = normalize_links(node.label_dict.links)
            end

            -- Inject ct_control
            node.ct_control = { enabled = false, initialized = false }

            -- Resolve integer node_id references in node_dict to ltree strings
            if node.node_dict then
                local nd = node.node_dict
                if type(nd.node_id) == "number" then
                    nd.node_id = idx_to_ltree[nd.node_id] or nd.node_id
                end
                if type(nd.parent_node_name) == "string" and ir.ltree_to_index[nd.parent_node_name] then
                    -- Already an ltree string, keep as-is
                elseif type(nd.parent_node_name) == "number" then
                    nd.parent_node_name = idx_to_ltree[nd.parent_node_name] or nd.parent_node_name
                end
                if type(nd.target_node_id) == "number" then
                    nd.target_node_id = idx_to_ltree[nd.target_node_id] or nd.target_node_id
                end
                if type(nd.sm_node_id) == "number" then
                    nd.sm_node_id = idx_to_ltree[nd.sm_node_id] or nd.sm_node_id
                end
                -- Resolve node_index (used by avro test nodes)
                if type(nd.node_index) == "number" then
                    nd.node_index = idx_to_ltree[nd.node_index] or nd.node_index
                end
                -- Resolve server_node_index (used by client controlled nodes)
                if type(nd.server_node_index) == "number" then
                    nd.server_node_index = idx_to_ltree[nd.server_node_index] or nd.server_node_index
                end
                -- Resolve streaming event_column and output_event_column_id
                if type(nd.event_column) == "number" then
                    nd.event_column = idx_to_ltree[nd.event_column] or nd.event_column
                end
                if type(nd.output_event_column_id) == "number" then
                    nd.output_event_column_id = idx_to_ltree[nd.output_event_column_id] or nd.output_event_column_id
                end
                -- Resolve integer arrays of node references (e.g., CFL_ENABLE_NODES)
                if type(nd.nodes) == "table" then
                    for i, v in ipairs(nd.nodes) do
                        if type(v) == "number" then
                            nd.nodes[i] = idx_to_ltree[v] or v
                        end
                    end
                end
            end

            nodes[ltree] = node

            -- Collect function names
            local ld = node.label_dict
            if ld then
                if ld.main_function_name then
                    main_names[ld.main_function_name] = true
                end
                if ld.initialization_function_name then
                    oneshot_names[ld.initialization_function_name] = true
                end
                if ld.termination_function_name then
                    oneshot_names[ld.termination_function_name] = true
                end
                if ld.aux_function_name then
                    boolean_names[ld.aux_function_name] = true
                end
            end
        end
    end

    -- Build KB table keyed by name
    local kb_table = {}
    for _, kb_name in ipairs(operational_kbs) do
        -- Find root node: shortest ltree starting with "kb.<kb_name>."
        local prefix = "kb." .. kb_name .. "."
        local root_node = nil
        local root_depth = math.huge
        local kb_node_ids = {}
        for ltree, _ in pairs(nodes) do
            if ltree:sub(1, #prefix) == prefix then
                kb_node_ids[#kb_node_ids + 1] = ltree
                local depth = select(2, ltree:gsub("%.", ""))
                if depth < root_depth then
                    root_depth = depth
                    root_node = ltree
                end
            end
        end
        kb_table[kb_name] = {
            name = kb_name,
            root_node = root_node,
            node_ids = kb_node_ids,
        }
    end

    -- Parse blackboard section
    local bb_defaults = {}   -- field_name → default value (for mutable fields)
    local bb_const = {}      -- record_name → {field=value, ...}
    local bb_raw = ir.blackboard
    if bb_raw then
        -- Mutable record fields
        if bb_raw.record and bb_raw.record.fields then
            for _, fld in ipairs(bb_raw.record.fields) do
                local name = fld.name
                local val  = fld.default or 0
                -- Nested field: "nav.heading" → bb_defaults["nav"] = {heading=0}
                local dot = name:find("%.")
                if dot then
                    local parent = name:sub(1, dot - 1)
                    local child  = name:sub(dot + 1)
                    if not bb_defaults[parent] then
                        bb_defaults[parent] = {}
                    end
                    bb_defaults[parent][child] = val
                else
                    bb_defaults[name] = val
                end
            end
        end
        -- Constant records
        if bb_raw.const_records then
            for _, rec in ipairs(bb_raw.const_records) do
                local tbl = {}
                for _, fld in ipairs(rec.fields) do
                    tbl[fld.name] = fld.value or fld.default or 0
                end
                bb_const[rec.name] = tbl
            end
        end
    end

    return {
        nodes = nodes,
        kb_table = kb_table,
        event_strings = ir.event_string_table or {},
        bitmask_names = ir.bitmask_table or {},
        idx_to_ltree = idx_to_ltree,
        ltree_to_index = ir.ltree_to_index or {},
        main_names = main_names,
        oneshot_names = oneshot_names,
        boolean_names = boolean_names,
        -- Blackboard definitions
        blackboard = {
            field_defaults = bb_defaults,
            const_records  = bb_const,
        },
        -- Function dispatch dicts (filled by register_functions)
        main_functions = {},
        one_shot_functions = {},
        boolean_functions = {},
    }
end

function M.register_functions(handle_data, ...)
    -- Merge all registry tables into one lookup
    local merged = {}
    for _, reg in ipairs({...}) do
        if reg.main then
            for name, fn in pairs(reg.main) do merged[name:upper()] = { fn = fn, slot = "main" } end
        end
        if reg.one_shot then
            for name, fn in pairs(reg.one_shot) do merged[name:upper()] = { fn = fn, slot = "one_shot" } end
        end
        if reg.boolean then
            for name, fn in pairs(reg.boolean) do merged[name:upper()] = { fn = fn, slot = "boolean" } end
        end
        -- Flat registry: functions appear in all applicable slots
        if reg.flat then
            for name, entry in pairs(reg.flat) do
                merged[name:upper()] = entry
            end
        end
    end

    -- Fill function dicts from collected names
    for name in pairs(handle_data.main_names) do
        local entry = merged[name:upper()]
        if entry and entry.fn then
            handle_data.main_functions[name] = entry.fn
        end
    end
    for name in pairs(handle_data.oneshot_names) do
        local entry = merged[name:upper()]
        if entry and entry.fn then
            handle_data.one_shot_functions[name] = entry.fn
        end
    end
    for name in pairs(handle_data.boolean_names) do
        local entry = merged[name:upper()]
        if entry and entry.fn then
            handle_data.boolean_functions[name] = entry.fn
        end
    end

    -- Also register any functions from the registry that aren't in the name sets
    -- (e.g., finalize functions referenced in column_data but not in label_dict)
    for uname, entry in pairs(merged) do
        if entry.fn then
            if entry.slot == "main" and not handle_data.main_functions[uname] then
                handle_data.main_functions[uname] = entry.fn
            elseif entry.slot == "one_shot" and not handle_data.one_shot_functions[uname] then
                handle_data.one_shot_functions[uname] = entry.fn
            elseif entry.slot == "boolean" and not handle_data.boolean_functions[uname] then
                handle_data.boolean_functions[uname] = entry.fn
            end
        end
    end
end

-- Validate that all functions for a specific KB (or all KBs) are registered.
-- If kb_name is nil, validates all function names found in the JSON.
function M.validate(handle_data, kb_name)
    local needed_main = {}
    local needed_oneshot = {}
    local needed_boolean = {}

    if kb_name then
        -- Only check functions used by nodes in this KB
        local kb = handle_data.kb_table[kb_name]
        if not kb then return false, {"unknown KB: " .. kb_name} end
        for _, nid in ipairs(kb.node_ids) do
            local node = handle_data.nodes[nid]
            if node and node.label_dict then
                local ld = node.label_dict
                if ld.main_function_name then needed_main[ld.main_function_name] = true end
                if ld.initialization_function_name then needed_oneshot[ld.initialization_function_name] = true end
                if ld.termination_function_name then needed_oneshot[ld.termination_function_name] = true end
                if ld.aux_function_name then needed_boolean[ld.aux_function_name] = true end
            end
        end
    else
        needed_main = handle_data.main_names
        needed_oneshot = handle_data.oneshot_names
        needed_boolean = handle_data.boolean_names
    end

    local missing = {}
    for name in pairs(needed_main) do
        if not handle_data.main_functions[name] then
            missing[#missing + 1] = "main:" .. name
        end
    end
    for name in pairs(needed_oneshot) do
        if not handle_data.one_shot_functions[name] then
            missing[#missing + 1] = "one_shot:" .. name
        end
    end
    for name in pairs(needed_boolean) do
        if not handle_data.boolean_functions[name] then
            missing[#missing + 1] = "boolean:" .. name
        end
    end
    if #missing > 0 then
        return false, missing
    end
    return true, {}
end

return M
