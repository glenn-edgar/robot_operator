--[[
  kb_status_table.lua — LuaJIT port of kb_status_table.py

  Runtime status data operations for the knowledge base.
  Provides get/set for single and multiple status records with
  UPSERT support and retry logic for locked-database scenarios.

  Usage:
    local KB_Search       = require('kb_query_support')
    local KB_Status_Table = require('kb_status_table')

    local kb  = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local st  = KB_Status_Table.new(kb, 'knowledge_base')

    local row = st:find_node_id({ kb = 'my_kb', node_name = 'sensor1' })
    local data, path = st:get_status_data('my_kb.sensor1')
    st:set_status_data('my_kb.sensor1', { temperature = 72.5 })
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

--- Execute a query returning a list of dict-rows.
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

--- Execute a query returning only the first row (or nil).
local function sql_query_one(db, sql, params)
    local rows = sql_query_rows(db, sql, params)
    return rows[1]  -- nil if empty
end

-- ═══════════════════════════════════════════════════════════════════════
-- KB_Status_Table
-- ═══════════════════════════════════════════════════════════════════════

local KB_Status_Table = {}
KB_Status_Table.__index = KB_Status_Table

--- Create a new KB_Status_Table instance.
-- @param kb_search  KB_Search instance (already connected)
-- @param database   base database/table name prefix
function KB_Status_Table.new(kb_search, database)
    assert(kb_search, "kb_search is required")
    assert(database, "database is required")
    local self = setmetatable({}, KB_Status_Table)
    self.kb_search  = kb_search
    self.base_table = database .. '_status'
    self._ok, self.db = kb_search:get_db()
    return self
end

-- ── Node finding (via KB_Search filters) ────────────────────────────────

--- Find a single node. Errors if 0 or >1 matches.
-- @param opts  { kb=, node_name=, properties=, node_path= }
function KB_Status_Table:find_node_id(opts)
    opts = opts or {}
    local results = self:find_node_ids(opts)
    if #results == 0 then
        error(string.format(
            "No node found matching parameters: kb=%s, name=%s, properties=%s, path=%s",
            tostring(opts.kb), tostring(opts.node_name),
            tostring(opts.properties), tostring(opts.node_path)))
    end
    if #results > 1 then
        error(string.format(
            "Multiple nodes (%d) found matching parameters: kb=%s, name=%s, properties=%s, path=%s",
            #results, tostring(opts.kb), tostring(opts.node_name),
            tostring(opts.properties), tostring(opts.node_path)))
    end
    return results[1]
end

--- Find all nodes matching parameters.
-- @param opts  { kb=, node_name=, properties=, node_path= }
-- @return list of result rows
function KB_Status_Table:find_node_ids(opts)
    opts = opts or {}
    self.kb_search:clear_filters()
    self.kb_search:search_label('KB_STATUS_FIELD')

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
            "No nodes found matching parameters: kb=%s, name=%s, properties=%s, path=%s",
            tostring(opts.kb), tostring(opts.node_name),
            tostring(opts.properties), tostring(opts.node_path)))
    end
    return node_ids
end

-- ── Status data get/set ─────────────────────────────────────────────────

--- Retrieve status data for a single path.
-- @param path  string
-- @return data_table, path_string
function KB_Status_Table:get_status_data(path)
    if not path or path == '' then
        error("Path cannot be empty or nil")
    end

    local sql = string.format(
        "SELECT data, path FROM %s WHERE path = ? LIMIT 1", self.base_table)
    local row = sql_query_one(self.db, sql, { path })
    if not row then
        error(string.format("No data found for path: %s", path))
    end

    local data = row.data
    if type(data) == 'string' then
        local ok_j, decoded = pcall(json.decode, data)
        if not ok_j then
            error(string.format("Failed to decode JSON data for path '%s': %s",
                  path, tostring(decoded)))
        end
        data = decoded
    end
    return data, row.path
end

--- Retrieve status data for multiple paths in a single query.
-- @param paths  list of path strings
-- @return dict mapping path → data
function KB_Status_Table:get_multiple_status_data(paths)
    if not paths or #paths == 0 then return {} end
    if type(paths) == 'string' then paths = { paths } end

    local placeholders = {}
    for i = 1, #paths do placeholders[i] = '?' end
    local sql = string.format(
        "SELECT data, path FROM %s WHERE path IN (%s)",
        self.base_table, table.concat(placeholders, ','))

    local rows = sql_query_rows(self.db, sql, paths)
    local rv = {}
    for _, row in ipairs(rows) do
        local data = row.data
        if type(data) == 'string' then
            local ok_j, decoded = pcall(json.decode, data)
            if ok_j then data = decoded end
        end
        rv[row.path] = data
    end
    return rv
end

--- Set (upsert) status data for a single path with retry.
-- @param path        string
-- @param data        table (will be JSON-encoded)
-- @param retry_count int (default 3)
-- @param retry_delay number seconds (default 1.0)
-- @return true, message_string
function KB_Status_Table:set_status_data(path, data, retry_count, retry_delay)
    if not path or path == '' then error("Path cannot be empty or nil") end
    if type(data) ~= 'table' then error("Data must be a table") end
    retry_count = retry_count or 3
    retry_delay = retry_delay or 1.0

    local json_data = json.encode(data)

    local check_sql = string.format(
        "SELECT path FROM %s WHERE path = ?", self.base_table)

    local upsert_sql = string.format([[
        INSERT INTO %s (path, data) VALUES (?, ?)
        ON CONFLICT (path) DO UPDATE SET data = excluded.data
        RETURNING path
    ]], self.base_table)

    local last_err
    for attempt = 0, retry_count do
        local ok_try, err = pcall(function()
            local existing = sql_query_one(self.db, check_sql, { path })
            local existed = existing ~= nil

            local rows = sql_query_rows(self.db, upsert_sql, { path, json_data })

            if not rows or #rows == 0 then
                error("Database operation completed but no result was returned")
            end

            local op = existed and 'updated' or 'inserted'
            return string.format("Successfully %s data for path: %s", op, rows[1].path)
        end)

        if ok_try then
            return true, err  -- err is the message string from the inner function
        end

        last_err = err
        if attempt < retry_count then
            local err_str = tostring(err or ''):lower()
            if err_str:find('locked') then
                os.execute(string.format("sleep %.1f", retry_delay))
            else
                error(string.format("Error setting status data for path '%s': %s",
                      path, tostring(err)))
            end
        end
    end

    error(string.format("Failed to set status data for path '%s' after %d attempts: %s",
          path, retry_count + 1, tostring(last_err)))
end

--- Set (upsert) multiple path-data pairs in a single transaction.
-- @param path_data_pairs  dict {path=data} or list of {path, data}
-- @param retry_count      int (default 3)
-- @param retry_delay      number seconds (default 1.0)
-- @return true, message_string, results_dict
function KB_Status_Table:set_multiple_status_data(path_data_pairs, retry_count, retry_delay)
    if not path_data_pairs then error("path_data_pairs cannot be empty") end
    retry_count = retry_count or 3
    retry_delay = retry_delay or 1.0

    -- Normalize to list of {path, json_str}
    local json_pairs = {}
    local is_list = (path_data_pairs[1] ~= nil)
    if is_list then
        for _, pair in ipairs(path_data_pairs) do
            local p, d = pair[1], pair[2]
            if not p or p == '' then error("Path cannot be empty or nil") end
            if type(d) ~= 'table' then
                error(string.format("Data for path '%s' must be a table", p))
            end
            json_pairs[#json_pairs + 1] = { p, json.encode(d) }
        end
    else
        for p, d in pairs(path_data_pairs) do
            if not p or p == '' then error("Path cannot be empty or nil") end
            if type(d) ~= 'table' then
                error(string.format("Data for path '%s' must be a table", p))
            end
            json_pairs[#json_pairs + 1] = { p, json.encode(d) }
        end
    end

    local upsert_sql = string.format([[
        INSERT INTO %s (path, data) VALUES (?, ?)
        ON CONFLICT (path) DO UPDATE SET data = excluded.data
        RETURNING path
    ]], self.base_table)

    local all_paths = {}
    for _, jp in ipairs(json_pairs) do all_paths[#all_paths + 1] = jp[1] end
    local ph = {}
    for i = 1, #all_paths do ph[i] = '?' end
    local check_sql = string.format(
        "SELECT path FROM %s WHERE path IN (%s)",
        self.base_table, table.concat(ph, ','))

    local last_err
    for attempt = 0, retry_count do
        local ok_try, msg_or_err, results_out = pcall(function()
            sql_exec(self.db, "BEGIN")

            local existing_set = {}
            local erows = sql_query_rows(self.db, check_sql, all_paths)
            for _, r in ipairs(erows) do existing_set[r.path] = true end

            local results = {}
            for _, jp in ipairs(json_pairs) do
                local p, jd = jp[1], jp[2]
                local existed = existing_set[p] or false
                local rows = sql_query_rows(self.db, upsert_sql, { p, jd })
                if rows and #rows > 0 then
                    results[rows[1].path] = existed and 'updated' or 'inserted'
                else
                    results[p] = 'failed'
                end
            end

            sql_exec(self.db, "COMMIT")

            local success_count = 0
            for _, v in pairs(results) do
                if v ~= 'failed' then success_count = success_count + 1 end
            end
            return string.format("Successfully processed %d/%d records",
                                 success_count, #json_pairs),
                   results
        end)

        if ok_try then
            return true, msg_or_err, results_out
        end

        last_err = msg_or_err
        pcall(sql_exec, self.db, "ROLLBACK")

        if attempt < retry_count then
            local err_str = tostring(msg_or_err or ''):lower()
            if err_str:find('locked') then
                os.execute(string.format("sleep %.1f", retry_delay))
            else
                error(string.format("Error setting multiple status data: %s",
                      tostring(msg_or_err)))
            end
        end
    end

    error(string.format("Failed to set multiple status data after %d attempts: %s",
          retry_count + 1, tostring(last_err)))
end

return KB_Status_Table