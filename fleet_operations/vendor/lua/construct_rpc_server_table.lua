--[[
    Construct_RPC_Server_Table - LuaJIT Implementation
    
    Constructs and manages an RPC server table with knowledge base integration.
    Uses shared sqlite3_helpers for FFI bindings and SQL helpers.
    
    Usage:
        local CRST = require('construct_rpc_server_table')
        local rpc = CRST.new(db, construct_kb, 'knowledge_base')
        rpc:add_rpc_server_field('my_rpc', 10, 'An RPC server queue')
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
-- Construct_RPC_Server_Table class
-- ============================================================
local Construct_RPC_Server_Table = {}
Construct_RPC_Server_Table.__index = Construct_RPC_Server_Table

--- Constructor
--- @param db           userdata      sqlite3* database handle
--- @param construct_kb Construct_KB  Knowledge base construct object
--- @param database     string        Base database/table name
--- @param upload_flag  boolean?      If true, skip schema creation
--- @return Construct_RPC_Server_Table
function Construct_RPC_Server_Table.new(db, construct_kb, database, upload_flag)
    local self = setmetatable({}, Construct_RPC_Server_Table)
    self.db = db
    self.construct_kb = construct_kb
    self.database = database
    self.table_name = database .. '_rpc_server'
    self.upload_flag = upload_flag or false
    if not self.upload_flag then
        self:_setup_schema()
    end
    return self
end

--- Create the RPC server table
function Construct_RPC_Server_Table:_setup_schema()
    local tn = self.table_name

    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", tn))

    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server_path TEXT NOT NULL,
            request_id TEXT NOT NULL,
            rpc_action TEXT NOT NULL DEFAULT 'none',
            request_payload TEXT NOT NULL,
            request_timestamp TEXT NOT NULL DEFAULT (datetime('now')),
            transaction_tag TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'empty'
                CHECK (state IN ('empty', 'new_job', 'processing')),
            priority INTEGER NOT NULL DEFAULT 0,
            processing_timestamp TEXT DEFAULT NULL,
            completed_timestamp TEXT DEFAULT NULL,
            rpc_client_queue TEXT
        )
    ]], tn))

    print("rpc_server table created.")
end

--- Add an RPC server field to the knowledge base
--- @param rpc_server_key string  Field name
--- @param queue_depth    number  Queue depth
--- @param description    string  Description
--- @return table  Result summary
function Construct_RPC_Server_Table:add_rpc_server_field(rpc_server_key, queue_depth, description)
    assert(type(rpc_server_key) == 'string', 'rpc_server_key must be a string')
    assert(type(queue_depth) == 'number', 'queue_depth must be a number')
    assert(type(description) == 'string', 'description must be a string')

    local properties = { queue_depth = queue_depth }
    local data = {}

    self.construct_kb:add_info_node("KB_RPC_SERVER_FIELD", rpc_server_key, properties, data, description)

    print(string.format("Added rpc_server field '%s' with queue_depth=%d", rpc_server_key, queue_depth))

    return {
        status = "success",
        message = string.format("RPC server field '%s' added successfully", rpc_server_key),
        properties = properties,
        data = description,
    }
end

--- Remove entries whose server_path is not in the specified list.
--- Uses a temp table for efficient NOT IN with large path lists.
--- @param specified_server_paths table  Array of valid server paths to keep
--- @return number  Count of deleted records
function Construct_RPC_Server_Table:remove_unspecified_entries(specified_server_paths)
    if #specified_server_paths == 0 then
        print("Warning: No server_paths specified. No entries will be removed.")
        return 0
    end

    -- Filter nil values
    local valid_paths = {}
    for _, path in ipairs(specified_server_paths) do
        if path ~= nil then
            valid_paths[#valid_paths + 1] = tostring(path)
        end
    end
    if #valid_paths == 0 then
        print("Warning: No valid server_paths found after filtering. No entries will be removed.")
        return 0
    end

    print(string.format("Processing %d valid server paths", #valid_paths))

    local tn = self.table_name

    -- Create temp table
    sql_exec(self.db, "CREATE TEMP TABLE IF NOT EXISTS valid_server_paths (path TEXT)")
    sql_exec(self.db, "DELETE FROM valid_server_paths")

    -- Insert paths in batches
    local batch_size = 1000
    for i = 1, #valid_paths, batch_size do
        local last = math.min(i + batch_size - 1, #valid_paths)
        for j = i, last do
            sql_query(self.db,
                "INSERT INTO valid_server_paths VALUES (?)",
                { valid_paths[j] })
        end
    end

    -- Set state to empty for valid entries before deleting invalid ones
    sql_query(self.db, string.format([[
        UPDATE %s SET state = 'empty'
        WHERE server_path IN (SELECT path FROM valid_server_paths)
    ]], tn), {})

    -- Delete entries not in temp table
    local _, changes = sql_query(self.db, string.format([[
        DELETE FROM %s
        WHERE server_path NOT IN (SELECT path FROM valid_server_paths)
    ]], tn), {})

    local deleted_count = changes or 0

    -- Cleanup
    pcall(sql_exec, self.db, "DROP TABLE IF EXISTS valid_server_paths")

    print(string.format("Removed %d unspecified entries from %s", deleted_count, tn))
    return deleted_count
end

--- Adjust queue lengths for each server path
--- @param specified_server_paths  table  Array of server paths
--- @param specified_queue_lengths table  Array of desired queue lengths
--- @return table  Results keyed by server_path
function Construct_RPC_Server_Table:adjust_queue_length(specified_server_paths, specified_queue_lengths)
    if #specified_server_paths ~= #specified_queue_lengths then
        error("Mismatch between paths and lengths lists")
    end

    local tn = self.table_name
    local results = {}

    for i = 1, #specified_server_paths do
        local server_path = specified_server_paths[i]
        local target_length = specified_queue_lengths[i]

        local ok, err = pcall(function()
            local rows = sql_query(self.db,
                string.format("SELECT COUNT(*) as cnt FROM %s WHERE server_path = ?", tn),
                { server_path })
            local current_count = rows[1].cnt

            -- Set state to empty for all records with this server_path
            sql_query(self.db,
                string.format("UPDATE %s SET state = 'empty' WHERE server_path = ?", tn),
                { server_path })

            if current_count > target_length then
                local to_remove = current_count - target_length
                sql_query(self.db, string.format([[
                    DELETE FROM %s
                    WHERE id IN (
                        SELECT id FROM %s
                        WHERE server_path = ?
                        ORDER BY request_timestamp ASC
                        LIMIT ?
                    )
                ]], tn, tn),
                { server_path, to_remove })

                results[server_path] = {
                    action = 'removed',
                    count = to_remove,
                    new_total = target_length,
                }

            elseif current_count < target_length then
                local records_to_add = target_length - current_count
                local insert_sql = string.format([[
                    INSERT INTO %s (
                        server_path, request_id, request_payload,
                        transaction_tag, state
                    ) VALUES (?, ?, ?, ?, 'empty')
                ]], tn)

                for _ = 1, records_to_add do
                    sql_query(self.db, insert_sql, {
                        server_path,
                        uuid4(),
                        json.encode({}),
                        string.format("placeholder_%s", uuid4()),
                    })
                end

                results[server_path] = {
                    action = 'added',
                    count = records_to_add,
                    new_total = target_length,
                }
            else
                results[server_path] = {
                    action = 'unchanged',
                    count = 0,
                    new_total = current_count,
                }
            end
        end)

        if not ok then
            print(string.format("Error adjusting queue for path %s: %s", server_path, err))
            results[server_path] = { error = err }
        end
    end

    return results
end

--- Restore default values for all records (except server_path)
--- @return number  Count of updated records
function Construct_RPC_Server_Table:restore_default_values()
    local tn = self.table_name

    local rows = sql_query(self.db,
        string.format("SELECT id FROM %s", tn), {})

    local update_sql = string.format([[
        UPDATE %s
        SET
            request_id = ?,
            rpc_action = 'none',
            request_payload = ?,
            request_timestamp = datetime('now'),
            transaction_tag = ?,
            state = 'empty',
            priority = 0,
            processing_timestamp = NULL,
            completed_timestamp = NULL,
            rpc_client_queue = NULL
        WHERE id = ?
    ]], tn)

    local updated_count = 0
    for _, row in ipairs(rows) do
        sql_query(self.db, update_sql, {
            uuid4(),
            json.encode({}),
            string.format("reset_%s", uuid4()),
            row.id,
        })
        updated_count = updated_count + 1
    end

    print(string.format("Restored default values for %d records", updated_count))
    return updated_count
end

--- Synchronize RPC server table with knowledge base
function Construct_RPC_Server_Table:check_installation()
    local rows = sql_query(self.db, string.format([[
        SELECT path, properties FROM %s
        WHERE label = 'KB_RPC_SERVER_FIELD'
    ]], self.database), {})

    local paths = {}
    local lengths = {}
    for _, row in ipairs(rows) do
        paths[#paths + 1] = row.path
        if row.properties then
            local props = json.decode(row.properties)
            lengths[#lengths + 1] = (props and props.queue_depth) or 0
        else
            lengths[#lengths + 1] = 0
        end
    end

    print(string.format("paths: %s  lengths: %s", json.encode(paths), json.encode(lengths)))

    self:remove_unspecified_entries(paths)
    self:adjust_queue_length(paths, lengths)
    self:restore_default_values()
end

return Construct_RPC_Server_Table

