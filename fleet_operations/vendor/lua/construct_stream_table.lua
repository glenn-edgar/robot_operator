--[[
    Construct_Stream_Table - LuaJIT Implementation
    
    Constructs and manages a stream table with knowledge base integration.
    Uses shared sqlite3_helpers for FFI bindings and SQL helpers.
    
    Usage:
        local CSTM = require('construct_stream_table')
        local st = CSTM.new(db, construct_kb, 'knowledge_base')
        st:add_stream_field('my_stream', 100, 'A data stream')
        st:check_installation()
--]]

local h = require('sqlite3_helpers')

local sql_exec  = h.sql_exec
local sql_query = h.sql_query
local json      = h.json

-- ============================================================
-- Construct_Stream_Table class
-- ============================================================
local Construct_Stream_Table = {}
Construct_Stream_Table.__index = Construct_Stream_Table

--- Constructor
--- @param db           userdata      sqlite3* database handle
--- @param construct_kb Construct_KB  Knowledge base construct object
--- @param database     string        Base database/table name
--- @param upload_flag  boolean?      If true, skip schema creation
--- @return Construct_Stream_Table
function Construct_Stream_Table.new(db, construct_kb, database, upload_flag)
    local self = setmetatable({}, Construct_Stream_Table)
    self.db = db
    self.construct_kb = construct_kb
    self.database = database
    self.table_name = database .. '_stream'
    self.upload_flag = upload_flag or false
    if not self.upload_flag then
        self:_setup_schema()
    end
    return self
end

--- Create the stream table and indexes
function Construct_Stream_Table:_setup_schema()
    local tn = self.table_name

    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", tn))

    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            recorded_at TEXT DEFAULT (datetime('now')),
            valid INTEGER DEFAULT 0,
            data TEXT
        )
    ]], tn))

    local indexes = {
        "CREATE INDEX IF NOT EXISTS idx_%s_path ON %s (path)",
        "CREATE INDEX IF NOT EXISTS idx_%s_recorded_at ON %s (recorded_at)",
        "CREATE INDEX IF NOT EXISTS idx_%s_recorded_at_desc ON %s (recorded_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_%s_path_recorded_at ON %s (path, recorded_at)",
    }
    for _, fmt in ipairs(indexes) do
        sql_exec(self.db, string.format(fmt, tn, tn))
    end

    print(string.format("Stream table '%s' created with optimized indexes.", tn))
end

--- Add a stream field to the knowledge base
--- @param stream_key    string  Stream field name
--- @param stream_length number  Length of the stream buffer
--- @param description   string  Description
--- @return table  Result summary
function Construct_Stream_Table:add_stream_field(stream_key, stream_length, description)
    assert(type(stream_key) == 'string', 'stream_key must be a string')
    assert(type(stream_length) == 'number', 'stream_length must be a number')

    local properties = { stream_length = stream_length }

    self.construct_kb:add_info_node("stream", stream_key, properties, {}, description)

    return {
        stream = "success",
        message = string.format("stream field '%s' added successfully", stream_key),
        properties = properties,
        data = description,
    }
end

--- Remove entries with invalid paths (chunked deletion)
--- @param invalid_stream_paths table   Array of paths to remove
--- @param chunk_size           number? Max paths per query (default: 500)
function Construct_Stream_Table:_remove_invalid_stream_fields(invalid_stream_paths, chunk_size)
    chunk_size = chunk_size or 500
    if #invalid_stream_paths == 0 then return end

    local tn = self.table_name

    for i = 1, #invalid_stream_paths, chunk_size do
        local chunk = {}
        for j = i, math.min(i + chunk_size - 1, #invalid_stream_paths) do
            chunk[#chunk + 1] = invalid_stream_paths[j]
        end

        local placeholders = {}
        for k = 1, #chunk do placeholders[k] = '?' end
        local ph_str = table.concat(placeholders, ',')

        sql_query(self.db,
            string.format("DELETE FROM %s WHERE path IN (%s)", tn, ph_str),
            chunk)
    end
end

--- Manage stream table record counts to match specified lengths per path
--- @param specified_stream_paths  table  Array of valid paths
--- @param specified_stream_length table  Array of corresponding lengths
function Construct_Stream_Table:_manage_stream_table(specified_stream_paths, specified_stream_length)
    local tn = self.table_name

    for i = 1, #specified_stream_paths do
        local path = specified_stream_paths[i]
        local target_length = specified_stream_length[i]

        local rows = sql_query(self.db,
            string.format("SELECT COUNT(*) as cnt FROM %s WHERE path = ?", tn),
            { path })
        local current_count = rows[1].cnt

        local diff = target_length - current_count

        if diff < 0 then
            sql_query(self.db, string.format([[
                DELETE FROM %s
                WHERE path = ? AND rowid IN (
                    SELECT rowid
                    FROM %s
                    WHERE path = ?
                    ORDER BY recorded_at ASC
                    LIMIT ?
                )
            ]], tn, tn),
            { path, path, math.abs(diff) })

        elseif diff > 0 then
            local insert_sql = string.format([[
                INSERT INTO %s (path, recorded_at, data, valid)
                VALUES (?, datetime('now'), ?, 0)
            ]], tn)
            local empty_json = json.encode({})
            for _ = 1, diff do
                sql_query(self.db, insert_sql, { path, empty_json })
            end
        end
    end
end

--- Synchronize stream table with knowledge base
function Construct_Stream_Table:check_installation()
    local tn = self.table_name

    -- Get unique paths from stream table
    local rows = sql_query(self.db,
        string.format("SELECT DISTINCT path FROM %s", tn), {})
    local unique_stream_paths = {}
    local unique_set = {}
    for _, row in ipairs(rows) do
        unique_stream_paths[#unique_stream_paths + 1] = row.path
        unique_set[row.path] = true
    end

    -- Get specified stream data from knowledge base
    rows = sql_query(self.db, string.format([[
        SELECT path, label, name, properties FROM %s
        WHERE label = 'stream'
    ]], self.database), {})

    local specified_stream_paths = {}
    local specified_stream_length = {}
    local specified_set = {}
    for _, row in ipairs(rows) do
        specified_stream_paths[#specified_stream_paths + 1] = row.path
        specified_set[row.path] = true
        if row.properties then
            local props = json.decode(row.properties)
            specified_stream_length[#specified_stream_length + 1] = (props and props.stream_length) or 0
        else
            specified_stream_length[#specified_stream_length + 1] = 0
        end
    end
    print(string.format("specified_stream_paths: %s", json.encode(specified_stream_paths)))
    print(string.format("specified_stream_length: %s", json.encode(specified_stream_length)))

    -- Find invalid paths (in stream table but not in KB)
    local invalid_stream_paths = {}
    for _, p in ipairs(unique_stream_paths) do
        if not specified_set[p] then
            invalid_stream_paths[#invalid_stream_paths + 1] = p
        end
    end

    -- Find missing paths (in KB but not in stream table)
    local missing_stream_paths = {}
    for _, p in ipairs(specified_stream_paths) do
        if not unique_set[p] then
            missing_stream_paths[#missing_stream_paths + 1] = p
        end
    end
    print(string.format("invalid_stream_paths: %s", json.encode(invalid_stream_paths)))
    print(string.format("missing_stream_paths: %s", json.encode(missing_stream_paths)))

    self:_remove_invalid_stream_fields(invalid_stream_paths)
    self:_manage_stream_table(specified_stream_paths, specified_stream_length)
end

return Construct_Stream_Table

