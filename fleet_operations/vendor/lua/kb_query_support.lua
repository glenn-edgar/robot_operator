--[[
  kb_query_support.lua — LuaJIT port of kb_query_support.py (KB_Search class)

  A class to handle SQL filtering for the knowledge_base table in SQLite.
  Uses Common Table Expressions (CTEs) for reentrant queries.
  Always selects all columns from the knowledge_base table.
  Requires the ltree SQLite extension to be loaded.

  Usage:
    local KB_Search = require('kb_query_support')
    local kb = KB_Search.new({
        db_path     = 'knowledge_base.db',
        database    = 'knowledge_base',
        ltree_extension_path = nil,  -- auto-detect
    })

    kb:clear_filters()
    kb:search_kb('tech_docs')
    kb:search_label('article')
    local results = kb:execute_query()

    kb:disconnect()
]]

local ffi  = require('ffi')
local json -- resolved below

-- ── JSON (cjson first, then pure-Lua fallback) ──────────────────────────
local ok, cjson = pcall(require, 'cjson')
if ok then
    json = { encode = cjson.encode, decode = cjson.decode }
else
    -- minimal pure-Lua fallback (same approach as sqlite3_helpers)
    local ok2, dkjson = pcall(require, 'dkjson')
    if ok2 then
        json = { encode = dkjson.encode, decode = dkjson.decode }
    else
        error("No JSON library found. Install lua-cjson or dkjson.")
    end
end

-- ── FFI declarations (guarded against redefinition) ─────────────────────
pcall(ffi.cdef, [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    int  sqlite3_open(const char *filename, sqlite3 **ppDb);
    int  sqlite3_close(sqlite3 *db);
    int  sqlite3_exec(sqlite3 *db, const char *sql,
                      int (*callback)(void*,int,char**,char**),
                      void *arg, char **errmsg);
    void sqlite3_free(void *ptr);

    int  sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                            sqlite3_stmt **ppStmt, const char **pzTail);
    int  sqlite3_step(sqlite3_stmt *pStmt);
    int  sqlite3_finalize(sqlite3_stmt *pStmt);
    int  sqlite3_reset(sqlite3_stmt *pStmt);

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
    int  sqlite3_bind_parameter_index(sqlite3_stmt *pStmt, const char *zName);

    int  sqlite3_enable_load_extension(sqlite3 *db, int onoff);
    int  sqlite3_load_extension(sqlite3 *db, const char *zFile,
                                const char *zProc, char **pzErrMsg);

    const char *sqlite3_errmsg(sqlite3 *db);
]])

local sqlite3 = ffi.load('sqlite3')

-- SQLite constants
local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void (*)(void*)", -1)

-- Column type constants
local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT     = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

-- ── Helper: find ltree.so ───────────────────────────────────────────────
local function find_ltree_path()
    local search = { './ltree', '/usr/local/lib/ltree', '/usr/lib/ltree' }
    for _, p in ipairs(search) do
        local f = io.open(p .. '.so', 'r')
        if f then
            f:close()
            return p
        end
    end
    return './ltree'  -- default
end

-- ── Helper: execute SQL (no results) ────────────────────────────────────
local function sql_exec(db, sql)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3.sqlite3_exec(db, sql, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown error'
        sqlite3.sqlite3_free(errmsg[0])
        error(string.format("SQL exec error (%d): %s\nSQL: %s", rc, msg, sql))
    end
end

-- ── Helper: query with prepared statement, named params, dict rows ──────
local function sql_query(db, sql, params)
    params = params or {}
    local stmt = ffi.new('sqlite3_stmt*[1]')
    local rc = sqlite3.sqlite3_prepare_v2(db, sql, #sql, stmt, nil)
    if rc ~= SQLITE_OK then
        error(string.format("Prepare error (%d): %s\nSQL: %s",
              rc, ffi.string(sqlite3.sqlite3_errmsg(db)), sql))
    end
    local s = stmt[0]

    -- Bind named parameters  (:name style)
    for name, val in pairs(params) do
        local pname = ':' .. name
        local idx = sqlite3.sqlite3_bind_parameter_index(s, pname)
        if idx > 0 then
            if val == nil then
                sqlite3.sqlite3_bind_null(s, idx, 0)
            elseif type(val) == 'number' then
                if val == math.floor(val) and math.abs(val) < 2^31 then
                    sqlite3.sqlite3_bind_int(s, idx, val)
                else
                    sqlite3.sqlite3_bind_double(s, idx, val)
                end
            else
                val = tostring(val)
                sqlite3.sqlite3_bind_text(s, idx, val, #val, SQLITE_TRANSIENT)
            end
        end
    end

    -- Collect column names
    local ncols = sqlite3.sqlite3_column_count(s)
    local colnames = {}
    for i = 0, ncols - 1 do
        colnames[i] = ffi.string(sqlite3.sqlite3_column_name(s, i))
    end

    -- Fetch rows as dictionaries
    local rows = {}
    while true do
        rc = sqlite3.sqlite3_step(s)
        if rc == SQLITE_DONE then break end
        if rc ~= SQLITE_ROW then
            sqlite3.sqlite3_finalize(s)
            error(string.format("Step error (%d): %s",
                  rc, ffi.string(sqlite3.sqlite3_errmsg(db))))
        end
        local row = {}
        for i = 0, ncols - 1 do
            local ctype = sqlite3.sqlite3_column_type(s, i)
            if ctype == SQLITE_NULL then
                row[colnames[i]] = nil
            elseif ctype == SQLITE_INTEGER then
                row[colnames[i]] = sqlite3.sqlite3_column_int(s, i)
            elseif ctype == SQLITE_FLOAT then
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

-- ── Helper: positional-param query (for ? placeholders) ─────────────────
local function sql_query_positional(db, sql, params)
    params = params or {}
    local stmt = ffi.new('sqlite3_stmt*[1]')
    local rc = sqlite3.sqlite3_prepare_v2(db, sql, #sql, stmt, nil)
    if rc ~= SQLITE_OK then
        error(string.format("Prepare error (%d): %s\nSQL: %s",
              rc, ffi.string(sqlite3.sqlite3_errmsg(db)), sql))
    end
    local s = stmt[0]

    -- Bind positional parameters
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

    -- Collect column names
    local ncols = sqlite3.sqlite3_column_count(s)
    local colnames = {}
    for i = 0, ncols - 1 do
        colnames[i] = ffi.string(sqlite3.sqlite3_column_name(s, i))
    end

    -- Fetch rows as dictionaries
    local rows = {}
    while true do
        rc = sqlite3.sqlite3_step(s)
        if rc == SQLITE_DONE then break end
        if rc ~= SQLITE_ROW then
            sqlite3.sqlite3_finalize(s)
            error(string.format("Step error (%d): %s",
                  rc, ffi.string(sqlite3.sqlite3_errmsg(db))))
        end
        local row = {}
        for i = 0, ncols - 1 do
            local ctype = sqlite3.sqlite3_column_type(s, i)
            if ctype == SQLITE_NULL then
                row[colnames[i]] = nil
            elseif ctype == SQLITE_INTEGER then
                row[colnames[i]] = sqlite3.sqlite3_column_int(s, i)
            elseif ctype == SQLITE_FLOAT then
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

-- ═══════════════════════════════════════════════════════════════════════
-- KB_Search class
-- ═══════════════════════════════════════════════════════════════════════

local KB_Search = {}
KB_Search.__index = KB_Search

--- Create a new KB_Search instance.
-- @param opts table with keys:
--   db_path              (string)  path to SQLite database
--   database             (string)  base table name (e.g. 'knowledge_base')
--   ltree_extension_path (string|nil)  path to ltree.so WITHOUT suffix; nil = auto-detect
-- @return KB_Search instance
function KB_Search.new(opts)
    assert(opts and opts.db_path, "db_path is required")
    assert(opts.database, "database (table name) is required")

    local self = setmetatable({}, KB_Search)
    self.db_path     = opts.db_path
    self.base_table  = opts.database
    self.link_table  = self.base_table .. '_link'
    self.link_mount_table = self.base_table .. '_link_mount'
    self.filters     = {}
    self.results     = nil
    self.path_values = {}
    self.db          = nil   -- sqlite3* handle

    self.ltree_extension_path = opts.ltree_extension_path or find_ltree_path()
    self:_connect()
    return self
end

--- Connect to the database and load the ltree extension.
function KB_Search:_connect()
    local db_handle = ffi.new('sqlite3*[1]')
    local rc = sqlite3.sqlite3_open(self.db_path, db_handle)
    if rc ~= SQLITE_OK then
        error(string.format("Failed to open database '%s': %d", self.db_path, rc))
    end
    self.db = db_handle[0]

    -- Enable extension loading
    sqlite3.sqlite3_enable_load_extension(self.db, 1)

    -- Load ltree extension
    local errmsg = ffi.new('char*[1]')
    rc = sqlite3.sqlite3_load_extension(self.db, self.ltree_extension_path, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown'
        sqlite3.sqlite3_free(errmsg[0])
        io.stderr:write(string.format(
            "Warning: Could not load ltree extension from %s: %s\n"
            .. "Continuing without ltree — path matching may not work\n",
            self.ltree_extension_path, msg))
    end

    -- Disable extension loading for security
    sqlite3.sqlite3_enable_load_extension(self.db, 0)
end

--- Close the database connection.
function KB_Search:disconnect()
    if self.db ~= nil then
        sqlite3.sqlite3_close(self.db)
        self.db = nil
    end
end

--- Get the raw db handle (for external use).
-- @return success_flag, db_handle
function KB_Search:get_db()
    if self.db == nil then
        error("Not connected to database. Call _connect() first.")
    end
    return true, self.db
end

--- Clear all filters and reset the query state.
function KB_Search:clear_filters()
    self.filters = {}
    self.results = nil
end

-- ── Filter methods ──────────────────────────────────────────────────────

function KB_Search:search_kb(knowledge_base)
    self.filters[#self.filters + 1] = {
        condition = "knowledge_base = :knowledge_base",
        params    = { knowledge_base = knowledge_base },
    }
end

function KB_Search:search_label(label)
    self.filters[#self.filters + 1] = {
        condition = "label = :label",
        params    = { label = label },
    }
end

function KB_Search:search_name(name)
    self.filters[#self.filters + 1] = {
        condition = "name = :name",
        params    = { name = name },
    }
end

function KB_Search:search_property_key(key)
    self.filters[#self.filters + 1] = {
        condition = "json_type(properties, :json_path) IS NOT NULL",
        params    = { json_path = '$.' .. key },
    }
end

function KB_Search:search_property_value(key, value)
    self.filters[#self.filters + 1] = {
        condition = "json_extract(properties, :json_path) = :json_value",
        params    = { json_path = '$.' .. key, json_value = value },
    }
end

function KB_Search:search_starting_path(starting_path)
    self.filters[#self.filters + 1] = {
        condition = "ltree_ancestor(path, :starting_path) = 1",
        params    = { starting_path = starting_path },
    }
end

function KB_Search:search_path(path_expression)
    self.filters[#self.filters + 1] = {
        condition = "ltree_match(path, :path_expr) = 1",
        params    = { path_expr = path_expression },
    }
end

function KB_Search:search_has_link()
    self.filters[#self.filters + 1] = {
        condition = "has_link = 1",
        params    = {},
    }
end

function KB_Search:search_has_link_mount()
    self.filters[#self.filters + 1] = {
        condition = "has_link_mount = 1",
        params    = {},
    }
end

-- ── Query execution ─────────────────────────────────────────────────────

--- Execute the progressive query with all added filters using CTEs.
-- @return list of row-dictionaries
function KB_Search:execute_query()
    if self.db == nil then
        error("Not connected to database. Call _connect() first.")
    end

    local column_str = '*'

    -- No filters → simple SELECT
    if #self.filters == 0 then
        local sql = string.format("SELECT %s FROM %s", column_str, self.base_table)
        self.results = sql_query(self.db, sql, {})
        return self.results
    end

    -- Build CTE chain
    local cte_parts = {}
    local combined_params = {}

    cte_parts[1] = string.format("base_data AS (SELECT %s FROM %s)",
                                  column_str, self.base_table)

    for i, filt in ipairs(self.filters) do
        local condition = filt.condition
        local params    = filt.params or {}

        -- Prefix parameter names to avoid collisions between filters
        local prefixed_condition = condition
        for pname, pval in pairs(params) do
            local pref = string.format("p%d_%s", i - 1, pname)
            prefixed_condition = prefixed_condition:gsub(':' .. pname, ':' .. pref)
            combined_params[pref] = pval
        end

        local cte_name = string.format("filter_%d", i - 1)
        local prev_cte = (i == 1) and "base_data" or string.format("filter_%d", i - 2)

        if condition ~= '' then
            cte_parts[#cte_parts + 1] = string.format(
                "%s AS (SELECT %s FROM %s WHERE %s)",
                cte_name, column_str, prev_cte, prefixed_condition)
        else
            cte_parts[#cte_parts + 1] = string.format(
                "%s AS (SELECT %s FROM %s)",
                cte_name, column_str, prev_cte)
        end
    end

    local with_clause  = "WITH " .. table.concat(cte_parts, ",\n")
    local final_select = string.format("SELECT %s FROM filter_%d",
                                        column_str, #self.filters - 1)
    local final_query  = with_clause .. "\n" .. final_select

    local ok_flag, res = pcall(sql_query, self.db, final_query, combined_params)
    if not ok_flag then
        error(string.format("Error executing query: %s\nQuery: %s",
              tostring(res), final_query))
    end

    self.results = res
    return self.results
end

-- ── Result helpers ──────────────────────────────────────────────────────

--- Extract path values from query results.
-- @param key_data list of row dictionaries
-- @return list of path strings
function KB_Search:find_path_values(key_data)
    if not key_data then return {} end
    if not key_data[1] then
        -- single row passed as dict
        key_data = { key_data }
    end
    local rv = {}
    for _, row in ipairs(key_data) do
        rv[#rv + 1] = row.path
    end
    return rv
end

--- Get the results of the last executed query.
-- @return list of row dictionaries (or empty table)
function KB_Search:get_results()
    return self.results or {}
end

--- Extract description from properties field of query results.
-- @param key_data single row dict or list of row dicts
-- @return list of {path = description} tables
function KB_Search:find_description(key_data)
    if not key_data[1] then
        key_data = { key_data }
    end
    local rv = {}
    for _, row in ipairs(key_data) do
        local props_str = row.properties or '{}'
        local ok_j, props = pcall(json.decode, props_str)
        if not ok_j then props = {} end
        local desc = (props and props.description) or ''
        local path = row.path or ''
        rv[#rv + 1] = { [path] = desc }
    end
    return rv
end

--- Find data for specified paths in the knowledge base.
-- @param path_array string or list of path strings
-- @return dict mapping path → data (nil for missing paths)
function KB_Search:find_description_paths(path_array)
    if type(path_array) == 'string' then
        path_array = { path_array }
    end
    if #path_array == 0 then return {} end

    -- Build query with ? placeholders
    local placeholders = {}
    for i = 1, #path_array do
        placeholders[i] = '?'
    end
    local sql = string.format(
        "SELECT path, data FROM %s WHERE path IN (%s)",
        self.base_table, table.concat(placeholders, ','))

    local rows = sql_query_positional(self.db, sql, path_array)

    -- Build result dict
    local rv = {}
    local found = {}
    for _, row in ipairs(rows) do
        rv[row.path] = row.data
        found[row.path] = true
    end
    -- nil for missing paths
    for _, p in ipairs(path_array) do
        if not found[p] then
            rv[p] = nil  -- explicit nil (key won't exist, but matches Python behavior)
        end
    end
    return rv
end

--- Decode an ltree path into knowledge base name and node link/name pairs.
-- Path format: kb.link1.name1.link2.name2...
-- @param path string
-- @return kb_name, node_pairs (list of {link, name} pairs)
function KB_Search:decode_link_nodes(path)
    if not path or type(path) ~= 'string' or path == '' then
        error("Path must be a non-empty string")
    end

    local parts = {}
    for seg in path:gmatch('[^%.]+') do
        parts[#parts + 1] = seg
    end

    if #parts < 3 then
        error(string.format(
            "Path must have at least 3 elements (kb.link.name), got %d", #parts))
    end

    local remaining = #parts - 1
    if remaining % 2 ~= 0 then
        error(string.format(
            "Bad path format: after kb identifier, must have even number of "
            .. "elements (link/name pairs), got %d elements", remaining))
    end

    local kb = parts[1]
    local result = {}
    for i = 2, #parts, 2 do
        result[#result + 1] = { parts[i], parts[i + 1] }
    end
    return kb, result
end

return KB_Search