--[[
  kb_rpc_server.lua — LuaJIT port of kb_rpc_server.py

  RPC server queue operations for the knowledge base.
  Pre-allocated slots cycle through states: empty → new_job → processing → empty.

  Usage:
    local KB_Search     = require('kb_query_support')
    local KB_RPC_Server = require('kb_rpc_server')

    local kb  = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local rpc = KB_RPC_Server.new(kb, 'knowledge_base')

    rpc:push_rpc_queue('my_kb.server1', nil, 'do_work', {x=1}, 'tag1')
    local job = rpc:peak_server_queue('my_kb.server1')
    if job then rpc:mark_job_completion('my_kb.server1', job.id) end
]]

local ffi = require('ffi')

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
local SQLITE_OK = 0; local SQLITE_ROW = 100; local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void (*)(void*)", -1)
local SQLITE_INTEGER = 1; local SQLITE_FLOAT = 2; local SQLITE_NULL = 5

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

-- ── SQL helpers ─────────────────────────────────────────────────────────

local function sql_exec(db, sql)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3.sqlite3_exec(db, sql, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown'
        sqlite3.sqlite3_free(errmsg[0])
        error(string.format("SQL error (%d): %s", rc, msg))
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
    local cn = {}
    for i = 0, ncols - 1 do cn[i] = ffi.string(sqlite3.sqlite3_column_name(s, i)) end
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
            if ct == SQLITE_NULL then row[cn[i]] = nil
            elseif ct == SQLITE_INTEGER then row[cn[i]] = sqlite3.sqlite3_column_int(s, i)
            elseif ct == SQLITE_FLOAT then row[cn[i]] = sqlite3.sqlite3_column_double(s, i)
            else row[cn[i]] = ffi.string(sqlite3.sqlite3_column_text(s, i)) end
        end
        rows[#rows + 1] = row
    end
    sqlite3.sqlite3_finalize(s)
    return rows
end

local function sql_query_one(db, sql, params)
    return sql_query_rows(db, sql, params)[1]
end

local function utc_iso8601() return os.date('!%Y-%m-%dT%H:%M:%S') end
local function sleep_sec(s) os.execute(string.format("sleep %.2f", s)) end

--- Pure-Lua UUID4
local function uuid4()
    local rng = math.random
    local fmt = '%02x'
    local function r4() return string.format('%04x', rng(0, 0xffff)) end
    return string.format('%s%s-%s-4%s-%s%s-%s%s%s',
        r4(), r4(), r4(),
        string.format('%03x', rng(0, 0x0fff)),
        string.format('%x', rng(8, 11)) .. string.format('%03x', rng(0, 0x0fff)),
        '', r4(), r4(), r4())
end

--- Validate ltree path
local function is_valid_ltree(path)
    if not path or type(path) ~= 'string' or path == '' then return false end
    for part in path:gmatch('[^%.]+') do
        if part == '' then return false end
        local first = part:sub(1, 1)
        if not (first:match('%a') or first == '_') then return false end
        if not part:match('^[%w_]+$') then return false end
    end
    return true
end

-- ═══════════════════════════════════════════════════════════════════════
-- KB_RPC_Server
-- ═══════════════════════════════════════════════════════════════════════

local KB_RPC_Server = {}
KB_RPC_Server.__index = KB_RPC_Server

function KB_RPC_Server.new(kb_search, database)
    assert(kb_search, "kb_search is required")
    assert(database, "database is required")
    local self = setmetatable({}, KB_RPC_Server)
    self.kb_search  = kb_search
    self.base_table = database .. '_rpc_server'
    self._ok, self.db = kb_search:get_db()
    return self
end

-- ── Node finding ────────────────────────────────────────────────────────

function KB_RPC_Server:find_rpc_server_id(opts)
    opts = opts or {}
    local results = self:find_rpc_server_ids(opts)
    if #results == 0 then
        error(string.format("No node found matching path parameters: %s, %s, %s",
              tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    if #results > 1 then
        error(string.format("Multiple nodes found matching path parameters: %s, %s, %s",
              tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return results
end

function KB_RPC_Server:find_rpc_server_ids(opts)
    opts = opts or {}
    self.kb_search:clear_filters()
    self.kb_search:search_label('KB_RPC_SERVER_FIELD')
    if opts.kb        then self.kb_search:search_kb(opts.kb) end
    if opts.node_name then self.kb_search:search_name(opts.node_name) end
    if opts.properties and type(opts.properties) == 'table' then
        for k, v in pairs(opts.properties) do self.kb_search:search_property_value(k, v) end
    end
    if opts.node_path then self.kb_search:search_path(opts.node_path) end

    local node_ids = self.kb_search:execute_query()
    if not node_ids or #node_ids == 0 then
        error(string.format("No node found matching path parameters: %s, %s, %s",
              tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return node_ids
end

function KB_RPC_Server:find_rpc_server_table_keys(key_data)
    local rv = {}
    for _, row in ipairs(key_data) do rv[#rv + 1] = row.path end
    return rv
end

-- ── Job counting ────────────────────────────────────────────────────────

function KB_RPC_Server:count_jobs_job_types(server_path, state)
    if not is_valid_ltree(server_path) then
        error("server_path must be a valid ltree format")
    end
    local valid_states = { empty = true, new_job = true, processing = true, completed_job = true }
    if not valid_states[state] then
        error("state must be one of: empty, new_job, processing, completed_job")
    end

    local ok_t, result = pcall(function()
        sql_exec(self.db, "BEGIN")
        local row = sql_query_one(self.db,
            string.format("SELECT COUNT(*) AS job_count FROM %s WHERE server_path = ? AND state = ?",
                          self.base_table),
            { server_path, state })
        sql_exec(self.db, "COMMIT")
        return row and row.job_count or 0
    end)
    if not ok_t then
        pcall(sql_exec, self.db, "ROLLBACK")
        error(tostring(result))
    end
    return result
end

function KB_RPC_Server:count_empty_jobs(server_path)
    return self:count_jobs_job_types(server_path, 'empty')
end
function KB_RPC_Server:count_new_jobs(server_path)
    return self:count_jobs_job_types(server_path, 'new_job')
end
function KB_RPC_Server:count_processing_jobs(server_path)
    return self:count_jobs_job_types(server_path, 'processing')
end
function KB_RPC_Server:count_all_jobs(server_path)
    return {
        empty_jobs      = self:count_empty_jobs(server_path),
        new_jobs        = self:count_new_jobs(server_path),
        processing_jobs = self:count_processing_jobs(server_path),
    }
end

-- ── List jobs by state ──────────────────────────────────────────────────

function KB_RPC_Server:list_jobs_job_types(server_path, state)
    if not is_valid_ltree(server_path) then
        error("server_path must be a valid ltree format")
    end
    local allowed = { empty = true, new_job = true, processing = true }
    if not allowed[state] then error("state must be one of: empty, new_job, processing") end

    local ok_t, result = pcall(function()
        sql_exec(self.db, "BEGIN")
        local rows = sql_query_rows(self.db,
            string.format("SELECT * FROM %s WHERE server_path = ? AND state = ? ORDER BY priority DESC, request_timestamp ASC",
                          self.base_table),
            { server_path, state })
        sql_exec(self.db, "COMMIT")
        return rows
    end)
    if not ok_t then
        pcall(sql_exec, self.db, "ROLLBACK")
        error(tostring(result))
    end
    return result
end

-- ── Push to RPC queue ───────────────────────────────────────────────────

function KB_RPC_Server:push_rpc_queue(server_path, request_id, rpc_action,
                                       request_payload, transaction_tag, opts)
    opts = opts or {}
    local priority         = opts.priority or 0
    local rpc_client_queue = opts.rpc_client_queue
    local max_retries      = opts.max_retries or 5
    local wait_time        = opts.wait_time or 0.5

    -- Validation
    if not is_valid_ltree(server_path) then
        error("server_path must be a valid ltree format")
    end
    request_id = request_id or uuid4()
    if not rpc_action or type(rpc_action) ~= 'string' or rpc_action == '' then
        error("rpc_action must be a non-empty string")
    end
    if request_payload == nil then error("request_payload cannot be nil") end
    local payload_json = json.encode(request_payload)
    if not transaction_tag or type(transaction_tag) ~= 'string' or transaction_tag == '' then
        error("transaction_tag must be a non-empty string")
    end
    if rpc_client_queue ~= nil and not is_valid_ltree(rpc_client_queue) then
        error("rpc_client_queue must be nil or a valid ltree format")
    end

    local max_wait = 8
    for attempt = 1, max_retries do
        local ok_t, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local rec = sql_query_one(self.db,
                string.format("SELECT id FROM %s WHERE state = 'empty' ORDER BY priority DESC, request_timestamp ASC LIMIT 1",
                              self.base_table), {})
            if not rec then
                sql_exec(self.db, "ROLLBACK")
                error("NoMatchingRecord: No matching record found with state = 'empty'")
            end

            local ts = utc_iso8601()
            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s
                SET server_path = ?, request_id = ?, rpc_action = ?,
                    request_payload = ?, transaction_tag = ?, priority = ?,
                    rpc_client_queue = ?, state = 'new_job',
                    request_timestamp = ?, completed_timestamp = NULL
                WHERE id = ?
                RETURNING *
            ]], self.base_table), {
                server_path, request_id, rpc_action,
                payload_json, transaction_tag, priority,
                rpc_client_queue, ts, rec.id
            })

            if not upd then
                sql_exec(self.db, "ROLLBACK")
                error("Failed to update record in RPC queue")
            end

            sql_exec(self.db, "COMMIT")
            return upd
        end)

        if ok_t then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('nomatchingrecord') then error(tostring(result)) end
        if err_str:find('locked') then
            if attempt < max_retries then
                sleep_sec(math.min(wait_time * (2 ^ attempt), max_wait))
            else
                error(string.format("Failed to push to RPC queue after %d retries: %s",
                      max_retries, tostring(result)))
            end
        else
            error(tostring(result))
        end
    end
end

-- ── Peek server queue ───────────────────────────────────────────────────

function KB_RPC_Server:peak_server_queue(server_path, retries, wait_time)
    retries   = retries or 5
    wait_time = wait_time or 1

    for attempt = 1, retries do
        local ok_t, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local row = sql_query_one(self.db, string.format([[
                SELECT * FROM %s
                WHERE server_path = ? AND state = 'new_job'
                ORDER BY priority DESC, request_timestamp ASC
                LIMIT 1
            ]], self.base_table), { server_path })

            if not row then
                sql_exec(self.db, "ROLLBACK")
                return nil
            end

            local ts = utc_iso8601()
            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s SET state = 'processing', processing_timestamp = ?
                WHERE id = ? RETURNING id
            ]], self.base_table), { ts, row.id })

            if not upd then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("Failed to update state to 'processing' for id: %s",
                      tostring(row.id)))
            end

            sql_exec(self.db, "COMMIT")
            return row
        end)

        if ok_t then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('locked') then
            if attempt < retries then
                sleep_sec(wait_time * (2 ^ attempt))
            else
                error(string.format("Failed to peak server queue after %d attempts: %s",
                      retries, tostring(result)))
            end
        else
            error(tostring(result))
        end
    end
    return nil
end

-- ── Mark job completion ─────────────────────────────────────────────────

function KB_RPC_Server:mark_job_completion(server_path, id, retries, wait_time)
    retries   = retries or 5
    wait_time = wait_time or 1

    for attempt = 1, retries do
        local ok_t, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local rec = sql_query_one(self.db, string.format([[
                SELECT id FROM %s WHERE id = ? AND server_path = ? AND state = 'processing'
            ]], self.base_table), { id, server_path })

            if not rec then
                sql_exec(self.db, "ROLLBACK")
                return false
            end

            local ts = utc_iso8601()
            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s SET state = 'empty', completed_timestamp = ?
                WHERE id = ? RETURNING id
            ]], self.base_table), { ts, id })

            sql_exec(self.db, "COMMIT")
            return upd ~= nil
        end)

        if ok_t then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('locked') then
            if attempt < retries then sleep_sec(wait_time * (2 ^ attempt))
            else error(string.format("Failed to mark job as completed after %d attempts", retries)) end
        else error(tostring(result)) end
    end
    return false
end

-- ── Clear server queue ──────────────────────────────────────────────────

function KB_RPC_Server:clear_server_queue(server_path, max_retries, retry_delay)
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1

    for attempt = 1, max_retries do
        local ok_t, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local new_uuid = uuid4()
            local ts = utc_iso8601()

            local s = prepare_and_bind(self.db, string.format([[
                UPDATE %s
                SET request_id = ?, request_payload = ?, completed_timestamp = ?,
                    state = 'empty', rpc_client_queue = NULL
                WHERE server_path = ?
            ]], self.base_table), { new_uuid, '{}', ts, server_path })
            sqlite3.sqlite3_step(s)
            sqlite3.sqlite3_finalize(s)
            local cnt = sqlite3.sqlite3_changes(self.db)

            sql_exec(self.db, "COMMIT")
            return cnt
        end)

        if ok_t then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('locked') then
            if attempt < max_retries then sleep_sec(retry_delay)
            else error(string.format("Failed to acquire lock after %d attempts for server path: %s",
                       max_retries, server_path)) end
        else error(tostring(result)) end
    end
    return 0
end

return KB_RPC_Server