--[[
    Construct_Status_Table - LuaJIT Implementation
    
    Constructs and manages a status table with knowledge base integration.
    Uses shared sqlite3_helpers for FFI bindings and SQL helpers.
    
    Usage:
        local CST = require('construct_status_table')
        local st = CST.new(db, construct_kb, 'knowledge_base')
        st:add_status_field('my_status', {}, 'A status field', {value=0})
        st:check_installation()
--]]

local h = require('sqlite3_helpers')

local sql_exec  = h.sql_exec
local sql_query = h.sql_query
local json      = h.json

-- ============================================================
-- Construct_Status_Table class
-- ============================================================
local Construct_Status_Table = {}
Construct_Status_Table.__index = Construct_Status_Table

--- Constructor
--- @param db           userdata      sqlite3* database handle
--- @param construct_kb Construct_KB  Knowledge base construct object
--- @param database     string        Base database/table name
--- @param upload_flag  boolean?      If true, skip schema creation
--- @return Construct_Status_Table
function Construct_Status_Table.new(db, construct_kb, database, upload_flag)
    local self = setmetatable({}, Construct_Status_Table)
    self.db = db
    self.construct_kb = construct_kb
    self.database = database
    self.table_name = database .. '_status'
    print(string.format("database: %s", self.database))
    self.upload_flag = upload_flag or false
    if not self.upload_flag then
        self:_setup_schema()
    end
    return self
end

--- Create the status table and indexes
function Construct_Status_Table:_setup_schema()
    local tn = self.table_name

    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", tn))

    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            data TEXT,
            path TEXT UNIQUE
        )
    ]], tn))

    sql_exec(self.db, string.format(
        "CREATE INDEX IF NOT EXISTS idx_%s_path ON %s (path)", tn, tn))

    print(string.format("Status table '%s' created with optimized indexes.", tn))
end

--- Add a status field to the knowledge base
--- @param status_key    string      Status field name
--- @param properties    table|nil   Properties for the status field
--- @param description   string      Description
--- @param initial_data  table       Initial data
--- @return table  Result summary
function Construct_Status_Table:add_status_field(status_key, properties, description, initial_data)
    assert(type(status_key) == 'string', 'status_key must be a string')
    assert(type(description) == 'string', 'description must be a string')
    assert(type(initial_data) == 'table', 'initial_data must be a table')

    local initial_properties
    if properties == nil then
        initial_properties = {}
    else
        initial_properties = properties
    end
    assert(type(initial_properties) == 'table', 'properties must be a table')

    print(string.format("Added status field '%s'", status_key))

    self.construct_kb:add_info_node("status", status_key,
        initial_properties, initial_data, description)

    return {
        status = "success",
        message = string.format("Status field '%s' added successfully", status_key),
        properties = initial_properties,
        data = initial_data,
    }
end

--- Synchronize status table with knowledge base
--- @return table  Summary of changes
function Construct_Status_Table:check_installation()
    local tn = self.table_name

    -- Get all paths from status table
    local rows = sql_query(self.db,
        string.format("SELECT path FROM %s", tn), {})
    local all_paths = {}
    local all_paths_set = {}
    for _, row in ipairs(rows) do
        all_paths[#all_paths + 1] = row.path
        all_paths_set[row.path] = true
    end

    -- Get specified paths from knowledge base
    rows = sql_query(self.db, string.format([[
        SELECT path FROM %s WHERE label = 'status'
    ]], self.database), {})

    local specified_paths = {}
    local specified_set = {}
    for _, row in ipairs(rows) do
        specified_paths[#specified_paths + 1] = row.path
        specified_set[row.path] = true
    end
    print(string.format("specified_paths: %s", json.encode(specified_paths)))

    -- Find missing paths (in KB but not in status table)
    local missing_paths = {}
    for _, path in ipairs(specified_paths) do
        if not all_paths_set[path] then
            missing_paths[#missing_paths + 1] = path
        end
    end
    print(string.format("missing_paths: %s", json.encode(missing_paths)))

    -- Find not-specified paths (in status table but not in KB)
    local not_specified_paths = {}
    for _, path in ipairs(all_paths) do
        if not specified_set[path] then
            not_specified_paths[#not_specified_paths + 1] = path
        end
    end
    print(string.format("not_specified_paths: %s", json.encode(not_specified_paths)))

    -- Delete not-specified paths
    for _, path in ipairs(not_specified_paths) do
        print(string.format("deleting path: %s", path))
        sql_query(self.db,
            string.format("DELETE FROM %s WHERE path = ?", tn),
            { path })
    end

    -- Insert missing paths
    for _, path in ipairs(missing_paths) do
        print(string.format("inserting path: %s", path))
        sql_query(self.db,
            string.format("INSERT INTO %s (data, path) VALUES (?, ?)", tn),
            { json.encode({}), path })
    end

    return {
        missing_paths_added = #missing_paths,
        not_specified_paths_removed = #not_specified_paths,
    }
end

return Construct_Status_Table
