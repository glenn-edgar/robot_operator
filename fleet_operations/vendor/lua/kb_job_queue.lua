--[[
  kb_job_queue.lua — LuaJIT port of kb_job_queue.py

  Runtime job queue operations for the knowledge base.
  Pre-allocated slots; push reuses completed slots, peek claims the earliest
  pending job, mark_job_completed frees it.

  Usage:
    local KB_Search    = require('kb_query_support')
    local KB_Job_Queue = require('kb_job_queue')

    local kb  = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local jq  = KB_Job_Queue.new(kb, 'knowledge_base')

    jq:push_job_data('my_kb.worker1', { task = 'run_test' })
    local job = jq:peak_job_data('my_kb.worker1')
    if job then jq:mark_job_completed(job.id) end
]]

local ffi = require('ffi')

-- ── FFI (guarded) ───────────────────────────────────────────────────────
pcall(ffi.cdef, [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    int  sqlite3_exec(sqlite3*, const char*, int(*)(void*,int,char**,char**), void*, char**);
    void sqlite3_free(void*);
    int  sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
    int  sqlite3_step(sqlite3_stmt*);
    int  sqlite3_finalize(sqlite3_stmt*);
    int  sqlite3_changes(sqlite3*);
    int         sqlite3_column_count(sqlite3_stmt*);
    int         sqlite3_column_type(sqlite3_stmt*, int);
    const char *sqlite3_column_name(sqlite3_stmt*, int);
    const char *sqlite3_column_text(sqlite3_stmt*, int);
    int         sqlite3_column_int(sqlite3_stmt*, int);
    double      sqlite3_column_double(sqlite3_stmt*, int);
    int  sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
    int  sqlite3_bind_int(sqlite3_stmt*, int, int);
    int  sqlite3_bind_double(sqlite3_stmt*, int, double);
    int  sqlite3_bind_null(sqlite3_stmt*, int, int);
    const char *sqlite3_errmsg(sqlite3*);
]])

local sqlite3 = ffi.load('sqlite3')
local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void (*)(void*)", -1)
local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT     = 3
local SQLITE_NULL    = 5

-- ── JSON ────────────────────────────────────────────────────────────────
local json
do
    local ok, cjson = pcall(require, 'cjson')
    if ok then json = { encode = cjson.encode, decode = cjson.decode }
    else
        local ok2, dkjson = pcall(require, 'dkjson')
        if ok2 then json = { encode = dkjson.encode, decode = dkjson.decode }
        else error("No JSON library found.") end
    end
end

-- ── SQL helpers (local, same as other runtime modules) ──────────────────

local function sql_exec(db, sql)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3.sqlite3_exec(db, sql, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown'
        sqlite3.sqlite3_free(errmsg[0])
        error(string.format("SQL error (%d): %s\nSQL: %s", rc, msg, sql))
    end
end

local function prepare_and_bind(db, sql, params)
    local stmt = ffi.new('sqlite3_stmt*[1]')
    local rc = sqlite3.sqlite3_prepare_v2(db, sql, #sql, stmt, nil)
    if rc ~= SQLITE_OK then
        error(string.format("Prepare error (%d): %s\nSQL: %s",
              rc, ffi.string(sqlite3.sqlite3_errmsg(db)), sql))
    end
    local s = stmt[0]
    for i, val in ipairs(params) do
        if val == nil then
            sqlite3.sqlite3_bind_null(s, i, 0)
        elseif type(val) == 'number' then
            if val == math.floor(val) and math.abs(val) < 2^31 then
                sqlite3.sqlite3_bind_int(s, i, val)
            else
                sqlite3.sqlite3_bind_double(s, i, val)
            end
        else
            val = tostring(val)
            sqlite3.sqlite3_bind_text(s, i, val, #val, SQLITE_TRANSIENT)
        end
    end
    return s
end

local function sql_query_rows(db, sql, params)
    local s = prepare_and_bind(db, sql, params or {})
    local ncols = sqlite3.sqlite3_column_count(s)
    local colnames = {}
    for i = 0, ncols - 1 do colnames[i] = ffi.string(sqlite3.sqlite3_column_name(s, i)) end
    local rows = {}
    while true do
        local rc = sqlite3.sqlite3_step(s)
        if rc == SQLITE_DONE then break end
        if rc ~= SQLITE_ROW then
            sqlite3.sqlite3_finalize(s)
            error(string.format("Step error (%d): %s", rc, ffi.string(sqlite3.sqlite3_errmsg(db))))
        end
        local row = {}
        for i = 0, ncols - 1 do
            local ct = sqlite3.sqlite3_column_type(s, i)
            if ct == SQLITE_NULL then     row[colnames[i]] = nil
            elseif ct == SQLITE_INTEGER then row[colnames[i]] = sqlite3.sqlite3_column_int(s, i)
            elseif ct == SQLITE_FLOAT then   row[colnames[i]] = sqlite3.sqlite3_column_double(s, i)
            else                             row[colnames[i]] = ffi.string(sqlite3.sqlite3_column_text(s, i))
            end
        end
        rows[#rows + 1] = row
    end
    sqlite3.sqlite3_finalize(s)
    return rows
end

local function sql_query_one(db, sql, params)
    local rows = sql_query_rows(db, sql, params)
    return rows[1]
end

local function utc_iso8601()
    return os.date('!%Y-%m-%dT%H:%M:%S')
end

local function sleep_sec(sec)
    os.execute(string.format("sleep %.2f", sec))
end

local function parse_json_field(row, field)
    if row and type(row[field]) == 'string' then
        local ok_j, d = pcall(json.decode, row[field])
        if ok_j then row[field] = d end
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- KB_Job_Queue
-- ═══════════════════════════════════════════════════════════════════════

local KB_Job_Queue = {}
KB_Job_Queue.__index = KB_Job_Queue

function KB_Job_Queue.new(kb_search, database)
    assert(kb_search, "kb_search is required")
    assert(database,  "database is required")
    local self = setmetatable({}, KB_Job_Queue)
    self.kb_search  = kb_search
    self.base_table = database .. '_job'
    self._ok, self.db = kb_search:get_db()
    return self
end

-- ── Node finding ────────────────────────────────────────────────────────

function KB_Job_Queue:find_job_id(opts)
    opts = opts or {}
    local results = self:find_job_ids(opts)
    if #results == 0 then
        error(string.format("No job found matching parameters: name=%s, properties=%s, path=%s",
              tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    if #results > 1 then
        error(string.format("Multiple jobs (%d) found matching parameters: name=%s, properties=%s, path=%s",
              #results, tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return results[1]
end

function KB_Job_Queue:find_job_ids(opts)
    opts = opts or {}
    self.kb_search:clear_filters()
    self.kb_search:search_label('KB_JOB_QUEUE')
    if opts.kb        then self.kb_search:search_kb(opts.kb) end
    if opts.node_name then self.kb_search:search_name(opts.node_name) end
    if opts.properties and type(opts.properties) == 'table' then
        for k, v in pairs(opts.properties) do self.kb_search:search_property_value(k, v) end
    end
    if opts.node_path then self.kb_search:search_path(opts.node_path) end

    local node_ids = self.kb_search:execute_query()
    if not node_ids or #node_ids == 0 then
        error(string.format("No jobs found matching parameters: name=%s, properties=%s, path=%s",
              tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return node_ids
end

function KB_Job_Queue:find_job_paths(table_dict_rows)
    if not table_dict_rows then return {} end
    local rv = {}
    for _, row in ipairs(table_dict_rows) do
        if row.path then rv[#rv + 1] = row.path end
    end
    return rv
end

-- ── Counts ──────────────────────────────────────────────────────────────

function KB_Job_Queue:get_queued_number(path)
    if not path or path == '' then error("Path cannot be empty or nil") end
    local row = sql_query_one(self.db,
        string.format("SELECT COUNT(*) as count FROM %s WHERE path = ? AND valid = 1", self.base_table),
        { path })
    return row and row.count or 0
end

function KB_Job_Queue:get_free_number(path)
    if not path or path == '' then error("Path cannot be empty or nil") end
    local row = sql_query_one(self.db,
        string.format("SELECT COUNT(*) as count FROM %s WHERE path = ? AND valid = 0", self.base_table),
        { path })
    return row and row.count or 0
end

-- ── Peek (claim the next pending job) ───────────────────────────────────

function KB_Job_Queue:peak_job_data(path, max_retries, retry_delay)
    if not path or path == '' then error("Path cannot be empty or nil") end
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1

    for attempt = 1, max_retries do
        local ok_try, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local ts = utc_iso8601()

            local row = sql_query_one(self.db, string.format([[
                SELECT id, data, schedule_at
                FROM %s
                WHERE path = ? AND valid = 1 AND is_active = 0
                  AND (schedule_at IS NULL OR schedule_at <= ?)
                ORDER BY
                  CASE WHEN schedule_at IS NULL THEN 0 ELSE 1 END,
                  schedule_at ASC
                LIMIT 1
            ]], self.base_table), { path, ts })

            if not row then
                sql_exec(self.db, "ROLLBACK")
                return nil
            end

            local job_id = row.id

            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s SET started_at = ?, is_active = 1
                WHERE id = ? AND is_active = 0 AND valid = 1
                RETURNING id, started_at
            ]], self.base_table), { ts, job_id })

            if not upd then
                sql_exec(self.db, "ROLLBACK")
                return '__retry__'
            end

            sql_exec(self.db, "COMMIT")

            parse_json_field(row, 'data')
            return {
                id          = row.id,
                data        = row.data,
                schedule_at = row.schedule_at,
                started_at  = upd.started_at,
            }
        end)

        if ok_try then
            if result == '__retry__' then
                if attempt < max_retries then sleep_sec(retry_delay) end
            else
                return result  -- nil or job dict
            end
        else
            pcall(sql_exec, self.db, "ROLLBACK")
            local err_str = tostring(result or ''):lower()
            if err_str:find('locked') then
                if attempt < max_retries then
                    sleep_sec(retry_delay * (1.5 ^ attempt))
                else
                    error(string.format(
                        "Could not lock and claim a job for path='%s' after %d retries",
                        path, max_retries))
                end
            else
                error(string.format("Error peeking job data for path '%s': %s", path, tostring(result)))
            end
        end
    end

    error(string.format("Could not lock and claim a job for path='%s' after %d retries",
          path, max_retries))
end

-- ── Mark completed ──────────────────────────────────────────────────────

function KB_Job_Queue:mark_job_completed(job_id, max_retries, retry_delay)
    if not job_id or type(job_id) ~= 'number' then error("job_id must be a valid integer") end
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1.0

    for attempt = 1, max_retries do
        local ok_try, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local row = sql_query_one(self.db,
                string.format("SELECT id FROM %s WHERE id = ?", self.base_table),
                { job_id })
            if not row then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("No job found with id=%d", job_id))
            end

            local ts = utc_iso8601()
            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s SET completed_at = ?, valid = 0, is_active = 0
                WHERE id = ?
                RETURNING id, completed_at
            ]], self.base_table), { ts, job_id })

            if not upd then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("Failed to mark job %d as completed", job_id))
            end

            sql_exec(self.db, "COMMIT")
            return { success = true, job_id = upd.id, completed_at = upd.completed_at }
        end)

        if ok_try then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('locked') then
            if attempt < max_retries then sleep_sec(retry_delay)
            else error(string.format("Could not lock job id=%d after %d attempts", job_id, max_retries)) end
        else
            error(tostring(result))
        end
    end
end

-- ── Push (enqueue a new job into a free slot) ───────────────────────────

function KB_Job_Queue:push_job_data(path, data, max_retries, retry_delay)
    if not path or path == '' then error("Path cannot be empty or nil") end
    if type(data) ~= 'table' then error("Data must be a table") end
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1

    local json_data = json.encode(data)

    for attempt = 1, max_retries do
        local ok_try, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local row = sql_query_one(self.db, string.format([[
                SELECT id FROM %s WHERE path = ? AND valid = 0
                ORDER BY completed_at ASC LIMIT 1
            ]], self.base_table), { path })

            if not row then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("No available job slot for path '%s'", path))
            end

            local ts = utc_iso8601()
            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s
                SET data = ?, schedule_at = ?, started_at = ?, completed_at = ?,
                    valid = 1, is_active = 0
                WHERE id = ?
                RETURNING id, schedule_at, data
            ]], self.base_table), { json_data, ts, ts, ts, row.id })

            if not upd then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("Failed to update job slot for path '%s'", path))
            end

            sql_exec(self.db, "COMMIT")

            parse_json_field(upd, 'data')
            return { job_id = upd.id, schedule_at = upd.schedule_at, data = upd.data }
        end)

        if ok_try then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('locked') then
            if attempt < max_retries then sleep_sec(retry_delay)
            else error(string.format("Could not acquire lock for path '%s' after %d attempts", path, max_retries)) end
        else
            error(tostring(result))
        end
    end
end

-- ── List helpers ────────────────────────────────────────────────────────

local function list_jobs_query(db, base_table, path, valid, is_active, order_col, opts)
    opts = opts or {}
    local parts = { string.format(
        "SELECT id, path, schedule_at, started_at, completed_at, is_active, valid, data FROM %s "
        .. "WHERE path = ? AND valid = %d AND is_active = %d ORDER BY %s ASC",
        base_table, valid, is_active, order_col) }
    local params = { path }
    if opts.limit and opts.limit > 0 then
        parts[#parts + 1] = "LIMIT ?"
        params[#params + 1] = opts.limit
    end
    if opts.offset and opts.offset > 0 then
        parts[#parts + 1] = "OFFSET ?"
        params[#params + 1] = opts.offset
    end
    local rows = sql_query_rows(db, table.concat(parts, ' '), params)
    for _, row in ipairs(rows) do parse_json_field(row, 'data') end
    return rows
end

function KB_Job_Queue:list_pending_jobs(path, opts)
    if not path or path == '' then error("Path cannot be empty or nil") end
    return list_jobs_query(self.db, self.base_table, path, 1, 0, 'schedule_at', opts)
end

function KB_Job_Queue:list_active_jobs(path, opts)
    if not path or path == '' then error("Path cannot be empty or nil") end
    return list_jobs_query(self.db, self.base_table, path, 1, 1, 'started_at', opts)
end

-- ── Clear queue ─────────────────────────────────────────────────────────

function KB_Job_Queue:clear_job_queue(path)
    if not path or path == '' then error("Path cannot be empty or nil") end

    local ok_try, result = pcall(function()
        sql_exec(self.db, "BEGIN IMMEDIATE")

        local ts = utc_iso8601()
        local rows = sql_query_rows(self.db, string.format([[
            UPDATE %s
            SET schedule_at = ?, started_at = ?, completed_at = ?,
                is_active = 0, valid = 0, data = '{}'
            WHERE path = ?
            RETURNING id, completed_at
        ]], self.base_table), { ts, ts, ts, path })

        sql_exec(self.db, "COMMIT")
        return { success = true, cleared_count = #rows, cleared_jobs = rows }
    end)

    if ok_try then return result end
    pcall(sql_exec, self.db, "ROLLBACK")
    error(string.format("Error in clear_job_queue for path '%s': %s", path, tostring(result)))
end

-- ── Statistics ──────────────────────────────────────────────────────────

function KB_Job_Queue:get_job_statistics(path)
    if not path or path == '' then error("Path cannot be empty or nil") end

    local row = sql_query_one(self.db, string.format([[
        SELECT
            COUNT(*) as total_jobs,
            SUM(CASE WHEN valid = 1 AND is_active = 0 THEN 1 ELSE 0 END) as pending_jobs,
            SUM(CASE WHEN valid = 1 AND is_active = 1 THEN 1 ELSE 0 END) as active_jobs,
            SUM(CASE WHEN valid = 0 THEN 1 ELSE 0 END) as completed_jobs,
            MIN(schedule_at) as earliest_scheduled,
            MAX(completed_at) as latest_completed,
            AVG((julianday(completed_at) - julianday(started_at)) * 86400.0) as avg_processing_time_seconds
        FROM %s WHERE path = ?
    ]], self.base_table), { path })

    if not row or row.total_jobs == 0 then
        return {
            total_jobs      = 0, pending_jobs   = 0,
            active_jobs     = 0, completed_jobs = 0,
            earliest_scheduled = nil, latest_completed = nil,
            avg_processing_time_seconds = nil,
        }
    end
    return row
end

-- ── By ID ───────────────────────────────────────────────────────────────

function KB_Job_Queue:get_job_by_id(job_id)
    if not job_id or type(job_id) ~= 'number' then error("job_id must be a valid integer") end
    local row = sql_query_one(self.db, string.format(
        "SELECT id, path, schedule_at, started_at, completed_at, is_active, valid, data FROM %s WHERE id = ?",
        self.base_table), { job_id })
    if row then parse_json_field(row, 'data') end
    return row
end

return KB_Job_Queue