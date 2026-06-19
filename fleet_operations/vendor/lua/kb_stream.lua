--[[
  kb_stream.lua — LuaJIT port of kb_stream.py

  Runtime stream data operations for the knowledge base.
  Stream table rows are pre-allocated; push_stream_data replaces the oldest
  entry (circular buffer pattern).  All queries return dict-style rows.

  Usage:
    local KB_Search = require('kb_query_support')
    local KB_Stream = require('kb_stream')

    local kb = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local stream = KB_Stream.new(kb, 'knowledge_base')

    stream:push_stream_data('my_kb.sensor1', { temperature = 72.5 })
    local latest = stream:get_latest_stream_data('my_kb.sensor1')
    local rows   = stream:list_stream_data('my_kb.sensor1', { limit = 10 })
]]

local ffi = require('ffi')

-- ── FFI declarations (guarded) ──────────────────────────────────────────
pcall(ffi.cdef, [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    int  sqlite3_exec(sqlite3 *db, const char *sql,
                      int (*callback)(void*,int,char**,char**),
                      void *arg, char **errmsg);
    void sqlite3_free(void *ptr);

    int  sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                            sqlite3_stmt **ppStmt, const char **pzTail);
    int  sqlite3_step(sqlite3_stmt *pStmt);
    int  sqlite3_finalize(sqlite3_stmt *pStmt);
    int  sqlite3_changes(sqlite3 *db);

    int         sqlite3_column_count(sqlite3_stmt *pStmt);
    int         sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
    int         sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    double      sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);

    int  sqlite3_bind_text(sqlite3_stmt *pStmt, int idx,
                           const char *val, int nByte,
                           void (*destructor)(void*));
    int  sqlite3_bind_int(sqlite3_stmt *pStmt, int idx, int val);
    int  sqlite3_bind_double(sqlite3_stmt *pStmt, int idx, double val);
    int  sqlite3_bind_null(sqlite3_stmt *pStmt, int idx, int n);

    const char *sqlite3_errmsg(sqlite3 *db);
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
    if ok then
        json = { encode = cjson.encode, decode = cjson.decode }
    else
        local ok2, dkjson = pcall(require, 'dkjson')
        if ok2 then
            json = { encode = dkjson.encode, decode = dkjson.decode }
        else
            error("No JSON library found. Install lua-cjson or dkjson.")
        end
    end
end

-- ── Local SQL helpers ───────────────────────────────────────────────────

local function sql_exec(db, sql)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3.sqlite3_exec(db, sql, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown error'
        sqlite3.sqlite3_free(errmsg[0])
        error(string.format("SQL exec error (%d): %s\nSQL: %s", rc, msg, sql))
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
    for i = 0, ncols - 1 do
        colnames[i] = ffi.string(sqlite3.sqlite3_column_name(s, i))
    end
    local rows = {}
    while true do
        local rc = sqlite3.sqlite3_step(s)
        if rc == SQLITE_DONE then break end
        if rc ~= SQLITE_ROW then
            sqlite3.sqlite3_finalize(s)
            error(string.format("Step error (%d): %s",
                  rc, ffi.string(sqlite3.sqlite3_errmsg(db))))
        end
        local row = {}
        for i = 0, ncols - 1 do
            local ct = sqlite3.sqlite3_column_type(s, i)
            if ct == SQLITE_NULL then
                row[colnames[i]] = nil
            elseif ct == SQLITE_INTEGER then
                row[colnames[i]] = sqlite3.sqlite3_column_int(s, i)
            elseif ct == SQLITE_FLOAT then
                row[colnames[i]] = sqlite3.sqlite3_column_double(s, i)
            else
                row[colnames[i]] = ffi.string(sqlite3.sqlite3_column_text(s, i))
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

--- ISO-8601 UTC timestamp
local function utc_iso8601()
    return os.date('!%Y-%m-%dT%H:%M:%S')
end

-- ═══════════════════════════════════════════════════════════════════════
-- KB_Stream
-- ═══════════════════════════════════════════════════════════════════════

local KB_Stream = {}
KB_Stream.__index = KB_Stream

--- Create a new KB_Stream instance.
-- @param kb_search  KB_Search instance (already connected)
-- @param database   base table name prefix
function KB_Stream.new(kb_search, database)
    assert(kb_search, "kb_search is required")
    assert(database, "database is required")
    local self = setmetatable({}, KB_Stream)
    self.kb_search  = kb_search
    self.base_table = database .. '_stream'
    self._ok, self.db = kb_search:get_db()
    return self
end

-- ── Node finding (via KB_Search) ────────────────────────────────────────

--- Find a single stream node. Errors if 0 or >1.
function KB_Stream:find_stream_id(opts)
    opts = opts or {}
    local results = self:find_stream_ids(opts)
    if #results == 0 then
        error(string.format(
            "No stream node found matching parameters: name=%s, properties=%s, path=%s",
            tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    if #results > 1 then
        error(string.format(
            "Multiple stream nodes (%d) found matching parameters: name=%s, properties=%s, path=%s",
            #results, tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return results[1]
end

--- Find all stream nodes matching parameters.
function KB_Stream:find_stream_ids(opts)
    opts = opts or {}
    self.kb_search:clear_filters()
    self.kb_search:search_label('KB_STREAM_FIELD')

    if opts.kb        then self.kb_search:search_kb(opts.kb) end
    if opts.node_name then self.kb_search:search_name(opts.node_name) end
    if opts.properties and type(opts.properties) == 'table' then
        for k, v in pairs(opts.properties) do
            self.kb_search:search_property_value(k, v)
        end
    end
    if opts.node_path then self.kb_search:search_path(opts.node_path) end

    local node_ids = self.kb_search:execute_query()
    if not node_ids or #node_ids == 0 then
        error(string.format(
            "No stream nodes found matching parameters: name=%s, properties=%s, path=%s",
            tostring(opts.node_name), tostring(opts.properties), tostring(opts.node_path)))
    end
    return node_ids
end

--- Extract path values from query results.
function KB_Stream:find_stream_table_keys(key_data)
    if not key_data then return {} end
    local rv = {}
    for _, row in ipairs(key_data) do
        if row.path then rv[#rv + 1] = row.path end
    end
    return rv
end

-- ── Circular-buffer push ────────────────────────────────────────────────

--- Replace the oldest record for a path (circular buffer).
-- @param path        string
-- @param data        table (JSON-serializable)
-- @param max_retries int (default 3)
-- @param retry_delay number seconds (default 1.0)
-- @return dict with updated record info
function KB_Stream:push_stream_data(path, data, max_retries, retry_delay)
    if not path or path == '' then error("Path cannot be empty or nil") end
    if type(data) ~= 'table' then error("Data must be a table") end
    max_retries = max_retries or 3
    retry_delay = retry_delay or 1.0

    local json_data = json.encode(data)

    for attempt = 1, max_retries do
        local ok_try, result_or_err = pcall(function()
            sql_exec(self.db, "BEGIN IMMEDIATE")

            -- 1) check pre-allocated rows exist
            local count_row = sql_query_one(self.db,
                string.format("SELECT COUNT(*) as count FROM %s WHERE path = ?",
                              self.base_table),
                { path })
            local total = count_row and count_row.count or 0
            if total == 0 then
                sql_exec(self.db, "ROLLBACK")
                error(string.format(
                    "No records found for path='%s'. Records must be pre-allocated for stream tables.",
                    path))
            end

            -- 2) oldest record
            local row = sql_query_one(self.db,
                string.format(
                    "SELECT id, recorded_at, valid FROM %s WHERE path = ? ORDER BY recorded_at ASC LIMIT 1",
                    self.base_table),
                { path })
            if not row then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("Could not find any row for path='%s'", path))
            end

            local record_id       = row.id
            local old_recorded_at = row.recorded_at
            local was_valid       = row.valid

            -- 3) update
            local current_time = utc_iso8601()
            local update_sql = string.format(
                "UPDATE %s SET data = ?, recorded_at = ?, valid = 1 WHERE id = ?",
                self.base_table)
            local us = prepare_and_bind(self.db, update_sql,
                { json_data, current_time, record_id })
            local rc = sqlite3.sqlite3_step(us)
            sqlite3.sqlite3_finalize(us)
            if rc ~= SQLITE_DONE then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("Update error (%d): %s",
                      rc, ffi.string(sqlite3.sqlite3_errmsg(self.db))))
            end

            -- 4) verify
            local updated = sql_query_one(self.db,
                string.format(
                    "SELECT id, path, recorded_at, data, valid FROM %s WHERE id = ?",
                    self.base_table),
                { record_id })
            if not updated then
                sql_exec(self.db, "ROLLBACK")
                error(string.format("Failed to update record id=%d", record_id))
            end

            sql_exec(self.db, "COMMIT")

            local parsed_data = updated.data
            if type(parsed_data) == 'string' then
                local ok_j, d = pcall(json.decode, parsed_data)
                if ok_j then parsed_data = d end
            end

            return {
                id                   = updated.id,
                path                 = updated.path,
                recorded_at          = updated.recorded_at,
                data                 = parsed_data,
                valid                = (updated.valid ~= 0),
                previous_recorded_at = old_recorded_at,
                was_previously_valid = (was_valid ~= 0),
                operation            = 'circular_buffer_replace',
            }
        end)

        if ok_try then
            return result_or_err
        end

        -- Rollback if not already done
        pcall(sql_exec, self.db, "ROLLBACK")

        local err_str = tostring(result_or_err or '')
        -- Non-retryable errors
        if err_str:find('No records found') or err_str:find('Path cannot') then
            error(result_or_err)
        end

        if attempt < max_retries then
            os.execute(string.format("sleep %.1f", retry_delay))
        else
            error(string.format("Error pushing stream data for path '%s': %s",
                  path, err_str))
        end
    end
end

-- ── Read operations ─────────────────────────────────────────────────────

--- Helper: parse JSON data and valid bool in a row.
local function parse_stream_row(row)
    if not row then return nil end
    if type(row.data) == 'string' then
        local ok_j, d = pcall(json.decode, row.data)
        if ok_j then row.data = d end
    end
    row.valid = (row.valid ~= 0)
    return row
end

--- Get the most recent valid stream record for a path.
-- @return dict or nil
function KB_Stream:get_latest_stream_data(path)
    if not path or path == '' then error("Path cannot be empty or nil") end
    local sql = string.format(
        "SELECT id, path, recorded_at, data, valid FROM %s WHERE path = ? AND valid = 1 ORDER BY recorded_at DESC LIMIT 1",
        self.base_table)
    return parse_stream_row(sql_query_one(self.db, sql, { path }))
end

--- Count stream entries for a path.
-- @param include_invalid  bool (default false — only valid)
-- @return int
function KB_Stream:get_stream_data_count(path, include_invalid)
    if not path or path == '' then error("Path cannot be empty or nil") end
    local sql
    if include_invalid then
        sql = string.format("SELECT COUNT(*) as count FROM %s WHERE path = ?",
                            self.base_table)
    else
        sql = string.format("SELECT COUNT(*) as count FROM %s WHERE path = ? AND valid = 1",
                            self.base_table)
    end
    local row = sql_query_one(self.db, sql, { path })
    return row and row.count or 0
end

--- Clear stream data by setting valid=0.
-- @param path       string
-- @param older_than string ISO-8601 (optional)
-- @return dict with success, cleared_count, etc.
function KB_Stream:clear_stream_data(path, older_than)
    if not path or path == '' then error("Path cannot be empty or nil") end

    local ok_try, result = pcall(function()
        local cleared_records, params

        if older_than then
            cleared_records = sql_query_rows(self.db,
                string.format("SELECT id, recorded_at FROM %s WHERE path = ? AND recorded_at < ? AND valid = 1",
                              self.base_table),
                { path, older_than })

            local us = prepare_and_bind(self.db,
                string.format("UPDATE %s SET valid = 0 WHERE path = ? AND recorded_at < ? AND valid = 1",
                              self.base_table),
                { path, older_than })
            sqlite3.sqlite3_step(us)
            sqlite3.sqlite3_finalize(us)
        else
            cleared_records = sql_query_rows(self.db,
                string.format("SELECT id, recorded_at FROM %s WHERE path = ? AND valid = 1",
                              self.base_table),
                { path })

            local us = prepare_and_bind(self.db,
                string.format("UPDATE %s SET valid = 0 WHERE path = ? AND valid = 1",
                              self.base_table),
                { path })
            sqlite3.sqlite3_step(us)
            sqlite3.sqlite3_finalize(us)
        end

        local op_desc = older_than
            and string.format("Cleared older than %s", older_than)
            or "Cleared all records"

        return {
            success         = true,
            cleared_count   = #cleared_records,
            cleared_records = cleared_records,
            path            = path,
            operation       = op_desc,
        }
    end)

    if ok_try then return result end

    pcall(sql_exec, self.db, "ROLLBACK")
    return {
        success       = false,
        cleared_count = 0,
        error         = tostring(result),
        path          = path,
    }
end

--- List valid stream data with optional filtering and pagination.
-- @param path  string
-- @param opts  { limit=, offset=, recorded_after=, recorded_before=, order=,
--                order_by=, after_id= }
-- `order_by` is 'recorded_at' (default, back-compat) or 'id'.
-- `after_id` adds `AND id < ?` (DESC) / `AND id > ?` (ASC) for cursored
-- pagination — robust to concurrent inserts. Pairs with `order_by='id'`
-- so first page and subsequent pages share a single sort dimension.
-- @return list of dicts
function KB_Stream:list_stream_data(path, opts)
    if not path or path == '' then error("Path cannot be empty or nil") end
    opts = opts or {}
    local order = (opts.order or 'ASC'):upper()
    if order ~= 'ASC' and order ~= 'DESC' then
        error("Order must be 'ASC' or 'DESC'")
    end
    local order_by = (opts.order_by or 'recorded_at'):lower()
    if order_by ~= 'recorded_at' and order_by ~= 'id' then
        error("order_by must be 'recorded_at' or 'id'")
    end

    local parts = { string.format(
        "SELECT id, path, recorded_at, data, valid FROM %s WHERE path = ? AND valid = 1",
        self.base_table) }
    local params = { path }

    if opts.recorded_after then
        parts[#parts + 1] = "AND recorded_at >= ?"
        params[#params + 1] = opts.recorded_after
    end
    if opts.recorded_before then
        parts[#parts + 1] = "AND recorded_at <= ?"
        params[#params + 1] = opts.recorded_before
    end
    if opts.after_id then
        parts[#parts + 1] = (order == 'DESC' and "AND id < ?" or "AND id > ?")
        params[#params + 1] = opts.after_id
    end

    parts[#parts + 1] = "ORDER BY " .. order_by .. " " .. order

    if opts.limit and opts.limit > 0 then
        parts[#parts + 1] = "LIMIT ?"
        params[#params + 1] = opts.limit
    end
    if opts.offset and opts.offset > 0 then
        parts[#parts + 1] = "OFFSET ?"
        params[#params + 1] = opts.offset
    end

    local sql = table.concat(parts, ' ')
    local rows = sql_query_rows(self.db, sql, params)
    for _, row in ipairs(rows) do parse_stream_row(row) end
    return rows
end

--- Get valid stream data within a time range.
-- @return list of dicts
function KB_Stream:get_stream_data_range(path, start_time, end_time)
    if not path or path == '' then error("Path cannot be empty or nil") end
    if not start_time or not end_time then
        error("Both start_time and end_time must be provided")
    end
    if start_time >= end_time then
        error("start_time must be before end_time")
    end

    local sql = string.format(
        "SELECT id, path, recorded_at, data, valid FROM %s "
        .. "WHERE path = ? AND recorded_at >= ? AND recorded_at <= ? AND valid = 1 "
        .. "ORDER BY recorded_at ASC",
        self.base_table)
    local rows = sql_query_rows(self.db, sql, { path, start_time, end_time })
    for _, row in ipairs(rows) do parse_stream_row(row) end
    return rows
end

--- Get statistics for stream data at a path.
-- @param include_invalid  bool (default false)
-- @return dict
function KB_Stream:get_stream_statistics(path, include_invalid)
    if not path or path == '' then error("Path cannot be empty or nil") end

    if include_invalid then
        local stats = sql_query_one(self.db, string.format([[
            SELECT
                COUNT(*) as total_records,
                SUM(CASE WHEN valid = 1 THEN 1 ELSE 0 END) as valid_records,
                SUM(CASE WHEN valid = 0 THEN 1 ELSE 0 END) as invalid_records,
                MIN(CASE WHEN valid = 1 THEN recorded_at END) as earliest_valid_recorded,
                MAX(CASE WHEN valid = 1 THEN recorded_at END) as latest_valid_recorded,
                MIN(recorded_at) as earliest_recorded_overall,
                MAX(recorded_at) as latest_recorded_overall
            FROM %s WHERE path = ?
        ]], self.base_table), { path })

        if not stats or stats.total_records == 0 then
            return {
                total_records            = 0,
                valid_records            = 0,
                invalid_records          = 0,
                earliest_valid_recorded  = nil,
                latest_valid_recorded    = nil,
                earliest_recorded_overall = nil,
                latest_recorded_overall  = nil,
                avg_interval_seconds_all   = nil,
                avg_interval_seconds_valid = nil,
            }
        end

        -- Average intervals (all)
        local iv_all = sql_query_one(self.db, string.format([[
            SELECT AVG((julianday(t1.recorded_at) - julianday(t2.recorded_at)) * 86400.0) as avg_seconds
            FROM %s t1 JOIN %s t2 ON t1.path = t2.path
            WHERE t1.path = ? AND t1.id > t2.id
            AND t1.id = (SELECT MIN(id) FROM %s WHERE path = t1.path AND id > t2.id)
        ]], self.base_table, self.base_table, self.base_table), { path })

        -- Average intervals (valid only)
        local iv_valid = sql_query_one(self.db, string.format([[
            SELECT AVG((julianday(t1.recorded_at) - julianday(t2.recorded_at)) * 86400.0) as avg_seconds
            FROM %s t1 JOIN %s t2 ON t1.path = t2.path
            WHERE t1.path = ? AND t1.valid = 1 AND t2.valid = 1 AND t1.id > t2.id
            AND t1.id = (SELECT MIN(id) FROM %s WHERE path = t1.path AND id > t2.id AND valid = 1)
        ]], self.base_table, self.base_table, self.base_table), { path })

        stats.avg_interval_seconds_all   = iv_all and iv_all.avg_seconds or nil
        stats.avg_interval_seconds_valid = iv_valid and iv_valid.avg_seconds or nil
        return stats
    else
        local stats = sql_query_one(self.db, string.format([[
            SELECT
                COUNT(*) as valid_records,
                MIN(recorded_at) as earliest_recorded,
                MAX(recorded_at) as latest_recorded
            FROM %s WHERE path = ? AND valid = 1
        ]], self.base_table), { path })

        if not stats or stats.valid_records == 0 then
            return {
                valid_records        = 0,
                earliest_recorded    = nil,
                latest_recorded      = nil,
                avg_interval_seconds = nil,
            }
        end

        local iv = sql_query_one(self.db, string.format([[
            SELECT AVG((julianday(t1.recorded_at) - julianday(t2.recorded_at)) * 86400.0) as avg_seconds
            FROM %s t1 JOIN %s t2 ON t1.path = t2.path
            WHERE t1.path = ? AND t1.valid = 1 AND t2.valid = 1 AND t1.id > t2.id
            AND t1.id = (SELECT MIN(id) FROM %s WHERE path = t1.path AND id > t2.id AND valid = 1)
        ]], self.base_table, self.base_table, self.base_table), { path })

        stats.avg_interval_seconds = iv and iv.avg_seconds or nil
        return stats
    end
end

--- Retrieve a specific stream record by ID.
-- @return dict or nil
function KB_Stream:get_stream_data_by_id(record_id)
    if not record_id or type(record_id) ~= 'number' then
        error("record_id must be a valid integer")
    end
    local sql = string.format(
        "SELECT id, path, recorded_at, data, valid FROM %s WHERE id = ?",
        self.base_table)
    return parse_stream_row(sql_query_one(self.db, sql, { record_id }))
end

return KB_Stream