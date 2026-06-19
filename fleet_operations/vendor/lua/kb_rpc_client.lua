--[[
  kb_rpc_client.lua — LuaJIT port of kb_rpc_client.py

  RPC client reply queue operations for the knowledge base.
  Pre-allocated slots; server pushes replies, client peeks & claims them.

  Usage:
    local KB_Search     = require('kb_query_support')
    local KB_RPC_Client = require('kb_rpc_client')

    local kb  = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local rpc = KB_RPC_Client.new(kb, 'knowledge_base')

    local free = rpc:find_free_slots('my_kb.client1')
    rpc:push_and_claim_reply_data('my_kb.client1', uuid, 'my_kb.server1',
                                   'action', 'tag', { result = 42 })
    local reply = rpc:peak_and_claim_reply_data('my_kb.client1')
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

local function uuid4()
    local rng = math.random
    local function r4() return string.format('%04x', rng(0, 0xffff)) end
    return string.format('%s%s-%s-4%s-%s%s-%s%s%s',
        r4(), r4(), r4(),
        string.format('%03x', rng(0, 0x0fff)),
        string.format('%x', rng(8, 11)) .. string.format('%03x', rng(0, 0x0fff)),
        '', r4(), r4(), r4())
end

-- ═══════════════════════════════════════════════════════════════════════
-- KB_RPC_Client
-- ═══════════════════════════════════════════════════════════════════════

local KB_RPC_Client = {}
KB_RPC_Client.__index = KB_RPC_Client

function KB_RPC_Client.new(kb_search, database)
    assert(kb_search, "kb_search is required")
    assert(database, "database is required")
    local self = setmetatable({}, KB_RPC_Client)
    self.kb_search  = kb_search
    self.base_table = database .. '_rpc_client'
    self._ok, self.db = kb_search:get_db()
    return self
end

-- ── Node finding ────────────────────────────────────────────────────────

function KB_RPC_Client:find_rpc_client_id(opts)
    opts = opts or {}
    local results = self:find_rpc_client_ids(opts)
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

function KB_RPC_Client:find_rpc_client_ids(opts)
    opts = opts or {}
    self.kb_search:clear_filters()
    self.kb_search:search_label('KB_RPC_CLIENT_FIELD')
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

function KB_RPC_Client:find_rpc_client_keys(key_data)
    local rv = {}
    for _, row in ipairs(key_data) do rv[#rv + 1] = row.path end
    return rv
end

-- ── Slot counting ───────────────────────────────────────────────────────

function KB_RPC_Client:find_free_slots(client_path)
    local row = sql_query_one(self.db, string.format([[
        SELECT COUNT(*) as total_records,
               COUNT(*) FILTER (WHERE is_new_result = 0) as free_slots
        FROM %s WHERE client_path = ?
    ]], self.base_table), { client_path })

    local total = row and row.total_records or 0
    if total == 0 then
        error(string.format("No records found for client_path: %s", client_path))
    end
    return row.free_slots
end

function KB_RPC_Client:find_queued_slots(client_path)
    local row = sql_query_one(self.db, string.format([[
        SELECT COUNT(*) as total_records,
               COUNT(*) FILTER (WHERE is_new_result = 1) as queued_slots
        FROM %s WHERE client_path = ?
    ]], self.base_table), { client_path })

    local total = row and row.total_records or 0
    if total == 0 then
        error(string.format("No records found for client_path: %s", client_path))
    end
    return row.queued_slots
end

-- ── Peek and claim reply ────────────────────────────────────────────────

function KB_RPC_Client:peak_and_claim_reply_data(client_path, max_retries, retry_delay)
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1.0

    for attempt = 1, max_retries do
        local ok_t, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local row = sql_query_one(self.db, string.format([[
                SELECT * FROM %s
                WHERE client_path = ? AND is_new_result = 1
                ORDER BY response_timestamp ASC
                LIMIT 1
            ]], self.base_table), { client_path })

            if row then
                -- Mark as processed
                local s = prepare_and_bind(self.db, string.format(
                    "UPDATE %s SET is_new_result = 0 WHERE id = ?", self.base_table),
                    { row.id })
                sqlite3.sqlite3_step(s)
                sqlite3.sqlite3_finalize(s)

                sql_exec(self.db, "COMMIT")
                return row
            end

            -- Check if any unclaimed exist at all
            local chk = sql_query_one(self.db, string.format([[
                SELECT EXISTS (SELECT 1 FROM %s WHERE client_path = ? AND is_new_result = 1) as ex
            ]], self.base_table), { client_path })

            if not chk or chk.ex == 0 then
                sql_exec(self.db, "ROLLBACK")
                return nil
            end

            sql_exec(self.db, "ROLLBACK")
            return '__retry__'
        end)

        if ok_t then
            if result == '__retry__' then
                sleep_sec(retry_delay)
            else
                return result
            end
        else
            pcall(sql_exec, self.db, "ROLLBACK")
            local err_str = tostring(result or ''):lower()
            if err_str:find('locked') then
                sleep_sec(retry_delay)
            else
                error(tostring(result))
            end
        end
    end

    error(string.format("Could not lock a new-reply row after %d attempts", max_retries))
end

-- ── Clear reply queue ───────────────────────────────────────────────────

function KB_RPC_Client:clear_reply_queue(client_path, max_retries, retry_delay)
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1.0

    for attempt = 1, max_retries do
        local ok_t, result = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local rows = sql_query_rows(self.db,
                string.format("SELECT id FROM %s WHERE client_path = ?", self.base_table),
                { client_path })

            if #rows == 0 then
                sql_exec(self.db, "COMMIT")
                return 0
            end

            local ts = utc_iso8601()
            local updated = 0
            for _, row in ipairs(rows) do
                local new_uuid = uuid4()
                local s = prepare_and_bind(self.db, string.format([[
                    UPDATE %s
                    SET request_id = ?, server_path = ?, response_payload = ?,
                        response_timestamp = ?, is_new_result = 0
                    WHERE id = ?
                ]], self.base_table), {
                    new_uuid, client_path, json.encode({}), ts, row.id
                })
                sqlite3.sqlite3_step(s)
                sqlite3.sqlite3_finalize(s)
                updated = updated + sqlite3.sqlite3_changes(self.db)
            end

            sql_exec(self.db, "COMMIT")
            return updated
        end)

        if ok_t then return result end

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(result or ''):lower()
        if err_str:find('locked') then
            if attempt < max_retries then sleep_sec(retry_delay)
            else error(string.format("Could not acquire lock after %d retries", max_retries)) end
        else error(tostring(result)) end
    end
end

-- ── Push and claim reply (server → client) ──────────────────────────────

function KB_RPC_Client:push_and_claim_reply_data(client_path, request_uuid, server_path,
                                                   rpc_action, transaction_tag, reply_data,
                                                   max_retries, retry_delay)
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1

    request_uuid = tostring(request_uuid)
    local reply_json = json.encode(reply_data)

    for attempt = 0, max_retries do
        local ok_t, err = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            local rec = sql_query_one(self.db, string.format([[
                SELECT id FROM %s
                WHERE client_path = ? AND is_new_result = 0
                ORDER BY response_timestamp ASC
                LIMIT 1
            ]], self.base_table), { client_path })

            if not rec then
                sql_exec(self.db, "ROLLBACK")
                error("No available record with is_new_result=FALSE found")
            end

            local ts = utc_iso8601()
            local upd = sql_query_one(self.db, string.format([[
                UPDATE %s
                SET request_id = ?, server_path = ?, rpc_action = ?,
                    transaction_tag = ?, response_payload = ?,
                    is_new_result = 1, response_timestamp = ?
                WHERE id = ?
                RETURNING id
            ]], self.base_table), {
                request_uuid, server_path, rpc_action,
                transaction_tag, reply_json, ts, rec.id
            })

            if not upd then
                sql_exec(self.db, "ROLLBACK")
                error("Failed to update record")
            end

            sql_exec(self.db, "COMMIT")
        end)

        if ok_t then return end  -- success, no return value like Python

        pcall(sql_exec, self.db, "ROLLBACK")
        local err_str = tostring(err or ''):lower()
        if err_str:find('locked') then
            if attempt < max_retries then sleep_sec(retry_delay)
            else error(string.format("Failed after %d retries: %s", max_retries, tostring(err))) end
        else
            error(tostring(err))
        end
    end
end

-- ── List waiting jobs ───────────────────────────────────────────────────

function KB_RPC_Client:list_waiting_jobs(client_path)
    local sql, params
    if client_path then
        sql = string.format([[
            SELECT id, request_id, client_path, server_path,
                   response_payload, response_timestamp, is_new_result
            FROM %s WHERE is_new_result = 1 AND client_path = ?
            ORDER BY response_timestamp ASC
        ]], self.base_table)
        params = { client_path }
    else
        sql = string.format([[
            SELECT id, request_id, client_path, server_path,
                   response_payload, response_timestamp, is_new_result
            FROM %s WHERE is_new_result = 1
            ORDER BY response_timestamp ASC
        ]], self.base_table)
        params = {}
    end

    local rows = sql_query_rows(self.db, sql, params)
    -- Ensure string types on path fields (already strings from SQLite TEXT)
    for _, row in ipairs(rows) do
        if row.request_id then row.request_id = tostring(row.request_id) end
    end
    return rows
end

return KB_RPC_Client