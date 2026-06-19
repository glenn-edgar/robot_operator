--[[
    BitMaskOperations - LuaJIT Implementation
    
    Manages bit mask operations for distributed control system nodes.
    Uses shared sqlite3_helpers for FFI bindings and SQL helpers.
    
    Usage:
        local BitMaskOps = require('bit_mask_operations')
        local ops = BitMaskOps.new(db_handle, 'bit_mask_table')
        ops:create_table()
        ops:create_entry('node1', 0)
        ops:set_bit_mask('node1', 0xFF, 0xFF)
        local mask = ops:get_bit_mask('node1')
--]]

local h = require('sqlite3_helpers')

local sql_exec  = h.sql_exec
local sql_query = h.sql_query

-- ============================================================
-- BitMaskOperations class
-- ============================================================
local BitMaskOperations = {}
BitMaskOperations.__index = BitMaskOperations

--- Constructor
--- @param db              userdata  sqlite3* database handle
--- @param bit_mask_table  string?   Table name (default: 'bit_mask_table')
--- @return BitMaskOperations
function BitMaskOperations.new(db, bit_mask_table)
    assert(db ~= nil, 'db handle is required')
    local self = setmetatable({}, BitMaskOperations)
    self.db = db
    self.table_name = bit_mask_table or 'bit_mask_table'
    return self
end

--- Create (or recreate) the bit mask table
function BitMaskOperations:create_table()
    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", self.table_name))
    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            node_id TEXT PRIMARY KEY,
            bit_mask INTEGER NOT NULL DEFAULT 0
        )
    ]], self.table_name))
end

--- Create a new entry
--- @param node_id  string  Unique node identifier
--- @param bit_mask number? Initial bit mask value (default: 0)
--- @return boolean  true on success
function BitMaskOperations:create_entry(node_id, bit_mask)
    bit_mask = bit_mask or 0
    local sql = string.format(
        "INSERT INTO %s (node_id, bit_mask) VALUES (?, ?)", self.table_name)

    local ok, err = pcall(sql_query, self.db, sql, { node_id, bit_mask })
    if not ok then
        error(string.format("Node ID '%s' already exists in table '%s': %s",
            node_id, self.table_name, err))
    end
    return true
end

--- Get the bit mask for a node
--- @param node_id string  Node identifier
--- @return number|nil  Bit mask value, or nil if not found
function BitMaskOperations:get_bit_mask(node_id)
    local rows = sql_query(self.db,
        string.format("SELECT bit_mask FROM %s WHERE node_id = ?", self.table_name),
        { node_id })
    if #rows == 0 then return nil end
    return rows[1].bit_mask
end

--- Atomically update specific bits in the bit_mask for a node.
--- new_mask = (current_mask & (~change_mask)) | (new_bits & change_mask)
---
--- @param node_id     string  Node identifier
--- @param new_bits    number  New bit values to apply
--- @param change_mask number? Mask of bits to change (default: -1 = all bits)
--- @return boolean  true if row was updated
function BitMaskOperations:set_bit_mask(node_id, new_bits, change_mask)
    change_mask = change_mask or -1

    if type(new_bits) == 'number' then
        if new_bits < -9223372036854775808 or new_bits > 9223372036854775807 then
            error(string.format("new_bits must be a valid 64-bit integer, got %s", tostring(new_bits)))
        end
    end
    if type(change_mask) == 'number' then
        if change_mask < -9223372036854775808 or change_mask > 9223372036854775807 then
            error(string.format("change_mask must be a valid 64-bit integer, got %s", tostring(change_mask)))
        end
    end

    local sql = string.format([[
        UPDATE %s
        SET bit_mask = (bit_mask & (~?)) | (? & ?)
        WHERE node_id = ?
    ]], self.table_name)

    local ok, rows_or_err, changes = pcall(sql_query, self.db, sql,
        { change_mask, new_bits, change_mask, node_id })
    if not ok then
        error(rows_or_err)
    end
    return (changes or 0) > 0
end

--- Get complete entry for a node
--- @param node_id string  Node identifier
--- @return table|nil  {node_id=, bit_mask=} or nil
function BitMaskOperations:get_entry(node_id)
    local rows = sql_query(self.db,
        string.format("SELECT node_id, bit_mask FROM %s WHERE node_id = ?", self.table_name),
        { node_id })
    if #rows == 0 then return nil end
    return rows[1]
end

--- Delete an entry
--- @param node_id string  Node identifier
--- @return boolean  true if deleted, false if not found
function BitMaskOperations:delete_entry(node_id)
    local _, changes = sql_query(self.db,
        string.format("DELETE FROM %s WHERE node_id = ?", self.table_name),
        { node_id })
    return (changes or 0) > 0
end

--- List all node IDs
--- @return table  Array of node_id strings
function BitMaskOperations:list_all_nodes()
    local rows = sql_query(self.db,
        string.format("SELECT node_id FROM %s ORDER BY node_id", self.table_name),
        {})
    local result = {}
    for _, row in ipairs(rows) do
        result[#result + 1] = row.node_id
    end
    return result
end

return BitMaskOperations

