--[[
  kb_bit_structures.lua — LuaJIT port of kb_bit_structures.py

  Runtime bit structure operations for the knowledge base.
  Combines KB_Search queries with BitMaskOperations and S-expression evaluation.

  Uses composition: holds kb_search, BitMaskOperations, and inherits
  SExpressionProcessor methods via delegation.

  Usage:
    local KB_Search        = require('kb_query_support')
    local KB_Bit_Structures = require('kb_bit_structures')

    local kb = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local bits = KB_Bit_Structures.new(kb)

    -- Find and assemble bit data
    local row = bits:find_bit_structure_id({ kb = 'my_kb', node_name = 'sensor1' })
    local data_map = bits:find_assemble_bit_data({ row })

    -- Set / get flags
    bits:set_flag_data(data_map['sensor1'], { temp_high = 1 })
    local flags = bits:get_flag_data(data_map['sensor1'])

    -- S-expression evaluation
    local result = bits:execute("(and sensor1:temp_high sensor1:pressure_ok)", data_map)
]]

local BitMaskOperations    = require('bit_mask_rt_operations')
local bse                  = require('bit_s_expression')
local KB_BIT_DATA          = bse.KB_BIT_DATA
local SExpressionProcessor = bse.SExpressionProcessor
local bit                  = require('bit')

-- JSON
local json
local ok, cjson = pcall(require, 'cjson')
if ok then
    json = { encode = cjson.encode, decode = cjson.decode }
else
    local ok2, dkjson = pcall(require, 'dkjson')
    if ok2 then
        json = { encode = dkjson.encode, decode = dkjson.decode }
    else
        error("No JSON library found. Install lua-cjson or dkjson.")
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- KB_Bit_Structures
-- ═══════════════════════════════════════════════════════════════════════

local KB_Bit_Structures = {}
KB_Bit_Structures.__index = KB_Bit_Structures

--- Create a new KB_Bit_Structures instance.
-- @param kb_search  KB_Search instance (already connected)
-- @param database   (unused, kept for API compat — db comes from kb_search)
function KB_Bit_Structures.new(kb_search, database)
    assert(kb_search, "kb_search is required")
    local self = setmetatable({}, KB_Bit_Structures)
    self.kb_search          = kb_search
    self.database           = database
    self._ok, self.db       = kb_search:get_db()
    self.bit_mask_operations = BitMaskOperations.new(self.db)
    self._sexpr             = SExpressionProcessor.new()
    return self
end

-- ── Delegate S-expression methods ───────────────────────────────────────

function KB_Bit_Structures:tokenize(s_expr)
    return self._sexpr:tokenize(s_expr)
end

function KB_Bit_Structures:execute(s_expr, kb_data)
    return self._sexpr:execute(s_expr, kb_data)
end

-- ── KB query methods ────────────────────────────────────────────────────

--- Find a single bit structure record. Errors if 0 or >1 matches.
-- @param opts table with optional keys: kb, node_name, properties, node_path
-- @return single result row (dict)
function KB_Bit_Structures:find_bit_structure_id(opts)
    opts = opts or {}
    local results = self:find_bit_structure_ids(opts)
    if #results == 0 then
        error(string.format(
            "No bit structure found matching parameters: name=%s, properties=%s, path=%s",
            tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    if #results > 1 then
        error(string.format(
            "Multiple bit structures (%d) found matching parameters: name=%s, properties=%s, path=%s",
            #results, tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return results[1]
end

--- Find all bit structure records matching parameters.
-- @param opts table with optional keys: kb, node_name, properties, node_path
-- @return list of result rows
function KB_Bit_Structures:find_bit_structure_ids(opts)
    opts = opts or {}
    self.kb_search:clear_filters()
    self.kb_search:search_label('KB_BIT_MASK')

    if opts.kb then
        self.kb_search:search_kb(opts.kb)
    end
    if opts.node_name then
        self.kb_search:search_name(opts.node_name)
    end
    if opts.properties and type(opts.properties) == 'table' then
        for key, value in pairs(opts.properties) do
            self.kb_search:search_property_value(key, value)
        end
    end
    if opts.node_path then
        self.kb_search:search_path(opts.node_path)
    end

    local node_ids = self.kb_search:execute_query()
    if not node_ids or #node_ids == 0 then
        error(string.format(
            "No bit structures found matching parameters: name=%s, properties=%s, path=%s",
            tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return node_ids
end

-- ── Bit data assembly ───────────────────────────────────────────────────

--- Assemble a single KB_BIT_DATA from a query result row.
-- @param row  dict from KB query (must have 'properties' JSON string)
-- @return KB_BIT_DATA instance
function KB_Bit_Structures:assemble_bit_data(row)
    local rd = KB_BIT_DATA.new()
    local props = json.decode(row.properties)
    rd.user_name = props.user_name
    rd.flags     = json.decode(props.flag_dictionary)
    rd.bit_size  = props.mask_size
    rd.node_id   = props.record_id

    -- Build per-flag bitmasks
    for flag_name, flag_info in pairs(rd.flags) do
        rd.flags_mask[flag_name] = bit.lshift(1, tonumber(flag_info.bit))
    end

    -- Read current mask from DB
    local bm = self.bit_mask_operations:get_bit_mask(props.record_id) or 0
    rd.bit_mask = bm
    for flag_name, _ in pairs(rd.flags) do
        rd.flag_data[flag_name]   = bit.band(bm, rd.flags_mask[flag_name])
        rd.flag_change[flag_name] = false
    end
    return rd
end

--- Assemble bit data for multiple rows.
-- @param table_dict_rows  list of query result rows
-- @param clear_flag_data  if true, zero the mask before reading
-- @param user_names       optional list of override user names
-- @return dict mapping user_name → KB_BIT_DATA
function KB_Bit_Structures:find_assemble_bit_data(table_dict_rows, clear_flag_data, user_names)
    if not table_dict_rows or #table_dict_rows == 0 then
        return {}
    end

    local rv = {}
    for _, row in ipairs(table_dict_rows) do
        if clear_flag_data then
            local props = json.decode(row.properties)
            self.bit_mask_operations:set_bit_mask(props.record_id, 0, -1)
        end
        local dc = self:assemble_bit_data(row)
        rv[dc.user_name] = dc
    end

    if user_names then
        if #user_names ~= #table_dict_rows then
            error(string.format(
                "Number of user names (%d) must match number of table dict rows (%d)",
                #user_names, #table_dict_rows))
        end
    end

    return rv
end

-- ── Bit mask pass-through ───────────────────────────────────────────────

function KB_Bit_Structures:get_bit_mask(node_id)
    return self.bit_mask_operations:get_bit_mask(node_id)
end

function KB_Bit_Structures:set_bit_mask(node_id, new_bits, change_mask)
    return self.bit_mask_operations:set_bit_mask(node_id, new_bits, change_mask)
end

function KB_Bit_Structures:set_all_ones(node_id)
    self.bit_mask_operations:set_bit_mask(node_id, -1, -1)
end

function KB_Bit_Structures:set_all_zeros(node_id)
    self.bit_mask_operations:set_bit_mask(node_id, 0, -1)
end

-- ── Flag-level operations ───────────────────────────────────────────────

--- Set specific flag values.
-- @param data_class  KB_BIT_DATA instance
-- @param flag_data   dict mapping flag_name → 0|1
function KB_Bit_Structures:set_flag_data(data_class, flag_data)
    local mask        = 0
    local change_mask = 0

    for flag_name, flag_value in pairs(flag_data) do
        if not data_class.flags[flag_name] then
            error(string.format("Flag '%s' not found in data class", flag_name))
        end
        if flag_value ~= 0 and flag_value ~= 1 then
            error(string.format("Flag value %s must be 0 or 1", tostring(flag_value)))
        end

        if flag_value == 1 then
            mask = bit.bor(mask, data_class.flags_mask[flag_name])
        else
            mask = bit.band(mask, bit.bnot(data_class.flags_mask[flag_name]))
        end
        change_mask = bit.bor(change_mask, data_class.flags_mask[flag_name])
    end

    self.bit_mask_operations:set_bit_mask(data_class.node_id, mask, change_mask)
end

--- Read current flag values from DB and update data_class in place.
-- @param data_class  KB_BIT_DATA instance
-- @return dict of flag_name → 0|1
function KB_Bit_Structures:get_flag_data(data_class)
    local bm = self.bit_mask_operations:get_bit_mask(data_class.node_id) or 0
    data_class.bit_mask = bm

    for flag_name, _ in pairs(data_class.flags) do
        local flag_value = bit.band(bm, data_class.flags_mask[flag_name])

        -- Detect change
        if flag_value ~= data_class.flag_data[flag_name] then
            data_class.flag_change[flag_name] = true
        else
            data_class.flag_change[flag_name] = false
        end

        -- Normalize to 0/1
        if flag_value ~= 0 then
            data_class.flag_data[flag_name] = 1
        else
            data_class.flag_data[flag_name] = 0
        end
    end

    return data_class.flag_data
end

return KB_Bit_Structures