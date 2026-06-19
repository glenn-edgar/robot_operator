--[[
    Construct_Bit_Mask_Store - LuaJIT Implementation
    
    High-level interface for creating and managing bit mask entries
    with knowledge base integration.
    Uses shared sqlite3_helpers for JSON encoding.
    
    Usage:
        local CBMS = require('construct_bit_mask_store')
        local store = CBMS.new(db_handle, construct_kb_instance)
        store:add_flag('enable', 0, 'Enable flag')
        store:add_flag('ready',  1, 'Ready flag')
        store:create_bit_mask_entry('admin', 'my_mask', 2, 0, 'Test mask')
        store:clear_flags()
--]]

local h = require('sqlite3_helpers')
local BitMaskOperations = require('bit_mask_operations')

local json = h.json

-- ============================================================
-- Construct_Bit_Mask_Store class
-- ============================================================
local Construct_Bit_Mask_Store = {}
Construct_Bit_Mask_Store.__index = Construct_Bit_Mask_Store

--- Constructor
--- @param db           userdata         sqlite3* database handle
--- @param construct_kb Construct_KB     Knowledge base construct object
--- @param upload_flag  boolean?         If true, skip table creation
--- @return Construct_Bit_Mask_Store
function Construct_Bit_Mask_Store.new(db, construct_kb, upload_flag)
    local self = setmetatable({}, Construct_Bit_Mask_Store)
    self.bit_mask_operations = BitMaskOperations.new(db)
    self.construct_kb = construct_kb
    self.db = db
    self.upload_flag = upload_flag or false
    if not self.upload_flag then
        self.bit_mask_operations:create_table()
    end
    self.bit_mask_flags = {}
    return self
end

--- Clear all registered bit mask flags
function Construct_Bit_Mask_Store:clear_flags()
    self.bit_mask_flags = {}
end

--- Register a flag definition
--- @param flag_name        string  Unique flag name
--- @param bit_position     number  Bit position (0-63)
--- @param flag_description string  Human-readable description
function Construct_Bit_Mask_Store:add_flag(flag_name, bit_position, flag_description)
    self.bit_mask_flags[flag_name] = {
        bit = bit_position,
        description = flag_description,
    }
end

--- Count entries in a table (Lua equivalent of len(dict))
local function table_count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

--- Create a new bit mask entry with validation and knowledge base integration
--- @param user_name   string  User creating this entry
--- @param name        string  Name identifier for the bit mask
--- @param mask_size   number  Number of bits (1-64)
--- @param bit_mask    number  Initial mask value
--- @param description string? Optional description
function Construct_Bit_Mask_Store:create_bit_mask_entry(user_name, name, mask_size, bit_mask, description)
    description = description or ""

    assert(type(name) == 'string', 'name must be a string')
    assert(type(mask_size) == 'number', 'mask_size must be a number')
    assert(type(bit_mask) == 'number', 'bit_mask must be a number')

    if mask_size < 1 or mask_size > 64 then
        error("mask_size must be between 1 and 64")
    end
    if bit_mask < 0 or bit_mask > 2^mask_size - 1 then
        error("bit_mask must be between 0 and 2^mask_size - 1")
    end
    if mask_size ~= table_count(self.bit_mask_flags) then
        error("bit_mask size must be equal to the number of flags")
    end

    -- Check for duplicate bit positions
    local temp_mask = {}
    for i = 0, mask_size - 1 do
        temp_mask[i] = 0
    end

    for flag_name, flag_data in pairs(self.bit_mask_flags) do
        if temp_mask[flag_data.bit] == 1 then
            error(string.format("Duplicate bit position %d for flag '%s'",
                flag_data.bit, flag_name))
        end
        temp_mask[flag_data.bit] = 1
    end

    -- Generate ltree-style node name
    local label = "KB_BIT_MASK"
    local kb = self.construct_kb
    local ltree_node_name = table.concat(kb.path[kb.working_kb], '.') ..
        '.' .. label .. '.' .. name
    ltree_node_name = ltree_node_name:gsub('%.', '_'):lower()

    -- Create the bit mask entry in the database
    self.bit_mask_operations:create_entry(ltree_node_name, bit_mask)

    -- Prepare node properties for knowledge base
    local node_properties = {
        user_name       = user_name,
        mask_size       = mask_size,
        bit_mask        = bit_mask,
        flag_dictionary = json.encode(self.bit_mask_flags),
        record_id       = ltree_node_name,
    }

    -- Add to knowledge base
    kb:add_info_node(label, name, node_properties, {}, description)
end

-- ============================================================
-- Delegate BitMaskOperations methods for direct access
-- ============================================================
local delegated = { 'get_bit_mask', 'set_bit_mask', 'get_entry', 'delete_entry', 'list_all_nodes' }
for _, method in ipairs(delegated) do
    Construct_Bit_Mask_Store[method] = function(self, ...)
        return self.bit_mask_operations[method](self.bit_mask_operations, ...)
    end
end

return Construct_Bit_Mask_Store

