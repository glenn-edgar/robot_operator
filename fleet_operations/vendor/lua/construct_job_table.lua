--[[
    Construct_Job_Table - LuaJIT Implementation
    
    Constructs and manages a job table with knowledge base integration.
    Uses shared sqlite3_helpers for FFI bindings and SQL helpers.
    
    Usage:
        local CJT = require('construct_job_table')
        local jt = CJT.new(db, construct_kb, 'knowledge_base')
        jt:add_job_field('my_job', 10, 'A job queue')
        jt:check_installation()
--]]

local h = require('sqlite3_helpers')

local sql_exec  = h.sql_exec
local sql_query = h.sql_query
local json      = h.json

-- ============================================================
-- Construct_Job_Table class
-- ============================================================
local Construct_Job_Table = {}
Construct_Job_Table.__index = Construct_Job_Table

--- Constructor
--- @param db           userdata      sqlite3* database handle
--- @param construct_kb Construct_KB  Knowledge base construct object
--- @param database     string        Base database/table name
--- @param upload_flag  boolean?      If true, skip schema creation
--- @return Construct_Job_Table
function Construct_Job_Table.new(db, construct_kb, database, upload_flag)
    local self = setmetatable({}, Construct_Job_Table)
    self.db = db
    self.construct_kb = construct_kb
    self.database = database
    self.table_name = database .. '_job'
    self.upload_flag = upload_flag or false
    if not self.upload_flag then
        self:_setup_schema()
    end
    return self
end

--- Create the job table and indexes
function Construct_Job_Table:_setup_schema()
    local tn = self.table_name

    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", tn))

    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            schedule_at TEXT DEFAULT (datetime('now')),
            started_at TEXT DEFAULT (datetime('now')),
            completed_at TEXT DEFAULT (datetime('now')),
            is_active INTEGER DEFAULT 0,
            valid INTEGER DEFAULT 0,
            data TEXT
        )
    ]], tn))

    local indexes = {
        "CREATE INDEX IF NOT EXISTS idx_%s_path ON %s (path)",
        "CREATE INDEX IF NOT EXISTS idx_%s_schedule_at ON %s (schedule_at)",
        "CREATE INDEX IF NOT EXISTS idx_%s_is_active ON %s (is_active)",
        "CREATE INDEX IF NOT EXISTS idx_%s_valid ON %s (valid)",
        "CREATE INDEX IF NOT EXISTS idx_%s_active_schedule ON %s (is_active, schedule_at)",
        "CREATE INDEX IF NOT EXISTS idx_%s_started_at ON %s (started_at)",
        "CREATE INDEX IF NOT EXISTS idx_%s_completed_at ON %s (completed_at)",
    }
    for _, fmt in ipairs(indexes) do
        sql_exec(self.db, string.format(fmt, tn, tn))
    end

    print(string.format("Job table '%s' created with optimized indexes.", tn))
end

--- Add a job field to the knowledge base
--- @param job_key     string  Job field name
--- @param job_length  number  Length of the job queue
--- @param description string  Description of the job queue
--- @return table  Result summary
function Construct_Job_Table:add_job_field(job_key, job_length, description)
    assert(type(job_key) == 'string', 'job_key must be a string')
    assert(type(job_length) == 'number', 'job_length must be a number')

    local properties = { job_length = job_length }
    local data = {}

    self.construct_kb:add_info_node("KB_JOB_QUEUE", job_key, properties, data, description)

    print(string.format("Added job field '%s' with properties: job_length=%d", job_key, job_length))

    return {
        job = "success",
        message = string.format("job field '%s' added successfully", job_key),
        properties = properties,
        data = data,
    }
end

--- Manage job table record counts to match specified lengths per path
--- @param specified_job_paths  table  Array of valid paths
--- @param specified_job_length table  Array of corresponding lengths
function Construct_Job_Table:_manage_job_table(specified_job_paths, specified_job_length)
    print(string.format("specified_job_paths: %s", json.encode(specified_job_paths)))
    print(string.format("specified_job_length: %s", json.encode(specified_job_length)))

    local tn = self.table_name

    for i = 1, #specified_job_paths do
        local path = specified_job_paths[i]
        local target_length = specified_job_length[i]

        local rows = sql_query(self.db,
            string.format("SELECT COUNT(*) as cnt FROM %s WHERE path = ?", tn),
            { path })
        local current_count = rows[1].cnt
        print(string.format("current_count: %d", current_count))

        local diff = target_length - current_count

        if diff < 0 then
            sql_query(self.db, string.format([[
                DELETE FROM %s
                WHERE path = ? AND rowid IN (
                    SELECT rowid
                    FROM %s
                    WHERE path = ?
                    ORDER BY completed_at ASC
                    LIMIT ?
                )
            ]], tn, tn),
            { path, path, math.abs(diff) })

        elseif diff > 0 then
            local insert_sql = string.format(
                "INSERT INTO %s (path, data) VALUES (?, ?)", tn)
            for _ = 1, diff do
                sql_query(self.db, insert_sql, { path, nil })
            end
        end
    end

    print("Job table management completed.")
end

--- Remove entries with invalid paths (chunked deletion)
--- @param invalid_job_paths table   Array of paths to remove
--- @param chunk_size        number? Max paths per query (default: 500)
function Construct_Job_Table:_remove_invalid_job_fields(invalid_job_paths, chunk_size)
    chunk_size = chunk_size or 500
    if #invalid_job_paths == 0 then return end

    local tn = self.table_name

    for i = 1, #invalid_job_paths, chunk_size do
        local chunk = {}
        for j = i, math.min(i + chunk_size - 1, #invalid_job_paths) do
            chunk[#chunk + 1] = invalid_job_paths[j]
        end

        local placeholders = {}
        for k = 1, #chunk do placeholders[k] = '?' end
        local ph_str = table.concat(placeholders, ',')

        sql_query(self.db,
            string.format("DELETE FROM %s WHERE path IN (%s)", tn, ph_str),
            chunk)
    end
end

--- Synchronize job table with knowledge base
function Construct_Job_Table:check_installation()
    local tn = self.table_name

    -- Get unique paths from job table
    local rows = sql_query(self.db,
        string.format("SELECT DISTINCT path FROM %s", tn), {})
    local unique_job_paths = {}
    for _, row in ipairs(rows) do
        unique_job_paths[#unique_job_paths + 1] = row.path
    end
    print(string.format("unique_job_paths: %s", json.encode(unique_job_paths)))

    -- Get specified job data from knowledge base
    rows = sql_query(self.db, string.format([[
        SELECT path, label, name, properties FROM %s
        WHERE label = 'KB_JOB_QUEUE'
    ]], self.database), {})

    local specified_job_paths = {}
    local specified_job_length = {}
    for _, row in ipairs(rows) do
        specified_job_paths[#specified_job_paths + 1] = row.path
        if row.properties then
            local props = json.decode(row.properties)
            specified_job_length[#specified_job_length + 1] = (props and props.job_length) or 0
        else
            specified_job_length[#specified_job_length + 1] = 0
        end
    end
    print(string.format("specified_job_paths: %s", json.encode(specified_job_paths)))
    print(string.format("specified_job_length: %s", json.encode(specified_job_length)))

    -- Find invalid paths (in job table but not in knowledge base)
    local specified_set = {}
    for _, p in ipairs(specified_job_paths) do specified_set[p] = true end

    local invalid_job_paths = {}
    for _, p in ipairs(unique_job_paths) do
        if not specified_set[p] then
            invalid_job_paths[#invalid_job_paths + 1] = p
        end
    end

    self:_remove_invalid_job_fields(invalid_job_paths)
    self:_manage_job_table(specified_job_paths, specified_job_length)
end

return Construct_Job_Table

