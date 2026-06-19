--[[
    Construct_RPC_Client_Table - LuaJIT Implementation
    
    Constructs and manages an RPC client table with knowledge base integration.
    Uses shared sqlite3_helpers for FFI bindings and SQL helpers.
    
    Usage:
        local CRCT = require('construct_rpc_client_table')
        local rpc = CRCT.new(db, construct_kb, 'knowledge_base')
        rpc:add_rpc_client_field('my_rpc', 10, 'An RPC client queue')
        rpc:check_installation()
--]]

local h = require('sqlite3_helpers')

local sql_exec  = h.sql_exec
local sql_query = h.sql_query
local json      = h.json

--- Generate a UUID v4 string (pure Lua, no external dependency)
local function uuid4()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return (template:gsub('[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end))
end

-- Seed the RNG once
math.randomseed(os.time())

-- ============================================================
-- Construct_RPC_Client_Table class
-- ============================================================
local Construct_RPC_Client_Table = {}
Construct_RPC_Client_Table.__index = Construct_RPC_Client_Table

--- Constructor
--- @param db           userdata      sqlite3* database handle
--- @param construct_kb Construct_KB  Knowledge base construct object
--- @param database     string        Base database/table name
--- @param upload_flag  boolean?      If true, skip schema creation
--- @return Construct_RPC_Client_Table
function Construct_RPC_Client_Table.new(db, construct_kb, database, upload_flag)
    local self = setmetatable({}, Construct_RPC_Client_Table)
    self.db = db
    self.construct_kb = construct_kb
    self.database = database
    self.table_name = database .. '_rpc_client'
    self.upload_flag = upload_flag or false
    if not self.upload_flag then
        self:_setup_schema()
    end
    return self
end

--- Create the RPC client table
function Construct_RPC_Client_Table:_setup_schema()
    local tn = self.table_name

    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", tn))

    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            request_id TEXT NOT NULL,
            client_path TEXT NOT NULL,
            server_path TEXT NOT NULL,
            transaction_tag TEXT NOT NULL DEFAULT 'none',
            rpc_action TEXT NOT NULL DEFAULT 'none',
            response_payload TEXT NOT NULL,
            response_timestamp TEXT NOT NULL DEFAULT (datetime('now')),
            is_new_result INTEGER NOT NULL DEFAULT 0
        )
    ]], tn))

    print("rpc_client table created.")
end

--- Add an RPC client field to the knowledge base
--- @param rpc_client_key string  Field name
--- @param queue_depth    number  Queue depth
--- @param description    string  Description
--- @return table  Result summary
function Construct_RPC_Client_Table:add_rpc_client_field(rpc_client_key, queue_depth, description)
    assert(type(rpc_client_key) == 'string', 'rpc_client_key must be a string')
    assert(type(description) == 'string', 'description must be a string')
    assert(type(queue_depth) == 'number', 'queue_depth must be a number')

    local properties = { queue_depth = queue_depth }

    self.construct_kb:add_info_node("KB_RPC_CLIENT_FIELD", rpc_client_key, properties, {}, description)

    print(string.format("Added rpc_client field '%s' with queue_depth=%d", rpc_client_key, queue_depth))

    return {
        rpc_client = "success",
        message = string.format("rpc_client field '%s' added successfully", rpc_client_key),
        properties = properties,
        data = description,
    }
end

--- Remove entries whose client_path is not in the specified list.
--- Uses a temp table for efficient NOT IN with large path lists.
--- @param specified_client_paths table  Array of valid client paths to keep
--- @return number  Count of deleted records
function Construct_RPC_Client_Table:remove_unspecified_entries(specified_client_paths)
    if #specified_client_paths == 0 then
        print("Warning: No client_paths specified. No entries will be removed.")
        return 0
    end

    -- Filter nil values
    local valid_paths = {}
    for _, path in ipairs(specified_client_paths) do
        if path ~= nil then
            valid_paths[#valid_paths + 1] = tostring(path)
        end
    end
    if #valid_paths == 0 then
        print("Warning: No valid client_paths found after filtering. No entries will be removed.")
        return 0
    end

    print(string.format("Processing %d valid client paths", #valid_paths))

    local tn = self.table_name

    -- Create temp table
    sql_exec(self.db, "CREATE TEMP TABLE IF NOT EXISTS valid_client_paths (path TEXT)")
    sql_exec(self.db, "DELETE FROM valid_client_paths")

    -- Insert paths in batches
    local batch_size = 1000
    for i = 1, #valid_paths, batch_size do
        local last = math.min(i + batch_size - 1, #valid_paths)
        for j = i, last do
            sql_query(self.db,
                "INSERT INTO valid_client_paths VALUES (?)",
                { valid_paths[j] })
        end
    end

    -- Delete entries not in temp table
    local _, changes = sql_query(self.db, string.format([[
        DELETE FROM %s
        WHERE client_path NOT IN (SELECT path FROM valid_client_paths)
    ]], tn), {})

    local deleted_count = changes or 0

    -- Cleanup
    pcall(sql_exec, self.db, "DROP TABLE IF EXISTS valid_client_paths")

    print(string.format("Removed %d unspecified entries from %s", deleted_count, tn))
    return deleted_count
end

--- Adjust queue lengths for each client path
--- @param specified_client_paths  table  Array of client paths
--- @param specified_queue_lengths table  Array of desired queue lengths
--- @return table  Results keyed by client_path
function Construct_RPC_Client_Table:adjust_queue_length(specified_client_paths, specified_queue_lengths)
    if #specified_client_paths ~= #specified_queue_lengths then
        error("The specified_client_paths and specified_queue_lengths lists must be of equal length")
    end

    local tn = self.table_name
    local results = {}

    for i = 1, #specified_client_paths do
        local client_path = specified_client_paths[i]
        local queue_length = specified_queue_lengths[i]

        if queue_length < 0 then
            results[client_path] = { error = "Invalid queue length (negative)" }
        else
            local rows = sql_query(self.db,
                string.format("SELECT COUNT(*) as cnt FROM %s WHERE client_path = ?", tn),
                { client_path })
            local current_count = rows[1].cnt
            local path_result = { added = 0, removed = 0 }

            if current_count > queue_length then
                local records_to_remove = current_count - queue_length
                local _, changes = sql_query(self.db, string.format([[
                    DELETE FROM %s
                    WHERE id IN (
                        SELECT id FROM %s
                        WHERE client_path = ?
                        ORDER BY response_timestamp ASC
                        LIMIT ?
                    )
                ]], tn, tn),
                { client_path, records_to_remove })
                path_result.removed = changes or 0

            elseif current_count < queue_length then
                local records_to_add = queue_length - current_count
                local insert_sql = string.format([[
                    INSERT INTO %s (
                        request_id, client_path, server_path,
                        transaction_tag, rpc_action,
                        response_payload, response_timestamp, is_new_result
                    ) VALUES (?, ?, ?, ?, ?, ?, datetime('now'), 0)
                ]], tn)

                for _ = 1, records_to_add do
                    sql_query(self.db, insert_sql, {
                        uuid4(),
                        client_path,
                        client_path,       -- default server_path = client_path
                        'none',            -- transaction_tag
                        'none',            -- rpc_action
                        json.encode({}),   -- empty payload
                    })
                    path_result.added = path_result.added + 1
                end
            end

            results[client_path] = path_result
        end
    end

    return results
end

--- Restore default values for all records (except client_path)
--- @return number  Count of updated records
function Construct_RPC_Client_Table:restore_default_values()
    local tn = self.table_name

    local rows = sql_query(self.db,
        string.format("SELECT id, client_path FROM %s", tn), {})

    local update_sql = string.format([[
        UPDATE %s
        SET
            request_id = ?,
            server_path = client_path,
            transaction_tag = 'none',
            rpc_action = 'none',
            response_payload = ?,
            response_timestamp = datetime('now'),
            is_new_result = 0
        WHERE id = ?
    ]], tn)

    local updated_count = 0
    for _, row in ipairs(rows) do
        sql_query(self.db, update_sql, {
            uuid4(),
            json.encode({}),
            row.id,
        })
        updated_count = updated_count + 1
    end

    return updated_count
end

--- Synchronize RPC client table with knowledge base
function Construct_RPC_Client_Table:check_installation()
    local rows = sql_query(self.db, string.format([[
        SELECT path, properties FROM %s
        WHERE label = 'KB_RPC_CLIENT_FIELD'
    ]], self.database), {})

    local paths = {}
    local lengths = {}
    print(string.format("specified_paths_data count: %d", #rows))

    for _, row in ipairs(rows) do
        paths[#paths + 1] = row.path
        if row.properties then
            local props = json.decode(row.properties)
            lengths[#lengths + 1] = (props and props.queue_depth) or 0
        else
            lengths[#lengths + 1] = 0
        end
    end

    self:remove_unspecified_entries(paths)
    self:adjust_queue_length(paths, lengths)
    self:restore_default_values()
end

return Construct_RPC_Client_Table

