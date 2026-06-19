--[[
    Construct_Data_Tables - LuaJIT Implementation
    
    Aggregator class that creates and manages all table constructors
    (KB, status, job, stream, RPC client, RPC server, bit mask).
    
    Delegates KB methods and table-specific methods for a unified API.
    
    Usage:
        local CDT = require('construct_data_tables')
        local kb = CDT.new('knowledge_base.db', 'knowledge_base')
        kb:add_kb('kb1', 'First KB')
        kb:select_kb('kb1')
        kb:add_header_node('link', 'name', {}, {})
        kb:add_status_field('status1', {}, 'desc', {})
        kb:leave_header_node('link', 'name')
        kb:check_installation()
        kb:disconnect()
--]]

local Construct_KB              = require('construct_kb')
local Construct_Status_Table    = require('construct_status_table')
local Construct_Job_Table       = require('construct_job_table')
local Construct_Stream_Table    = require('construct_stream_table')
local Construct_RPC_Client_Table = require('construct_rpc_client_table')
local Construct_RPC_Server_Table = require('construct_rpc_server_table')
local Construct_Bit_Mask_Store  = require('construct_bit_mask_store')

-- ============================================================
-- Construct_Data_Tables class
-- ============================================================
local Construct_Data_Tables = {}
Construct_Data_Tables.__index = Construct_Data_Tables

--- Constructor
--- @param db_path              string   Path to SQLite database file
--- @param database             string   Base knowledge base table name
--- @param ltree_extension_path string?  Path to ltree extension (without suffix)
--- @param upload_flag          boolean? If true, skip table creation
--- @return Construct_Data_Tables
function Construct_Data_Tables.new(db_path, database, ltree_extension_path, upload_flag)
    local self = setmetatable({}, Construct_Data_Tables)

    upload_flag = upload_flag or false

    -- Create KB instance
    self.kb = Construct_KB.new(db_path, database, ltree_extension_path, upload_flag)

    -- Get the raw db handle from KB for the table constructors
    local db = self.kb:get_db_objects()

    -- Create all table constructor instances
    self.status_table     = Construct_Status_Table.new(db, self.kb, database, upload_flag)
    self.job_table        = Construct_Job_Table.new(db, self.kb, database, upload_flag)
    self.stream_table     = Construct_Stream_Table.new(db, self.kb, database, upload_flag)
    self.rpc_client_table = Construct_RPC_Client_Table.new(db, self.kb, database, upload_flag)
    self.rpc_server_table = Construct_RPC_Server_Table.new(db, self.kb, database, upload_flag)
    self.bit_mask_store   = Construct_Bit_Mask_Store.new(db, self.kb, upload_flag)

    -- Expose KB path for direct access
    self.path = self.kb.path

    return self
end

-- ============================================================
-- Delegated KB methods
-- ============================================================
local kb_methods = {
    'add_kb', 'select_kb', 'add_link_node', 'add_link_mount',
    'add_header_node', 'add_info_node', 'leave_header_node', 'disconnect',
}
for _, method in ipairs(kb_methods) do
    Construct_Data_Tables[method] = function(self, ...)
        return self.kb[method](self.kb, ...)
    end
end

-- ============================================================
-- Delegated table-specific methods
-- ============================================================

function Construct_Data_Tables:add_stream_field(...)
    return self.stream_table:add_stream_field(...)
end

function Construct_Data_Tables:add_rpc_client_field(...)
    return self.rpc_client_table:add_rpc_client_field(...)
end

function Construct_Data_Tables:add_rpc_server_field(...)
    return self.rpc_server_table:add_rpc_server_field(...)
end

function Construct_Data_Tables:add_status_field(...)
    return self.status_table:add_status_field(...)
end

function Construct_Data_Tables:add_job_field(...)
    return self.job_table:add_job_field(...)
end

function Construct_Data_Tables:create_bit_mask_entry(...)
    return self.bit_mask_store:create_bit_mask_entry(...)
end

function Construct_Data_Tables:add_bit_mask_flag(...)
    return self.bit_mask_store:add_flag(...)
end

function Construct_Data_Tables:clear_bit_mask_flags()
    return self.bit_mask_store:clear_flags()
end

-- ============================================================
-- check_installation - calls check on all components
-- ============================================================

function Construct_Data_Tables:check_installation()
    self.kb:check_installation()
    self.status_table:check_installation()
    self.job_table:check_installation()
    self.stream_table:check_installation()
    self.rpc_client_table:check_installation()
    self.rpc_server_table:check_installation()
end

return Construct_Data_Tables


