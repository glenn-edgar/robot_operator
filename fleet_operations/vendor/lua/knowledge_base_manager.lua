--[[
    KnowledgeBaseManager - LuaJIT FFI SQLite3 Implementation
    
    Translated from Python KnowledgeBaseManager class.
    Uses LuaJIT FFI to bind directly to libsqlite3.
    
    Requirements:
        - LuaJIT 2.1+
        - libsqlite3 shared library
        - ltree SQLite extension (optional, for ltree query methods)
    
    Usage:
        local KBM = require('knowledge_base_manager')
        local kb = KBM.new('knowledge_base', 'knowledge_base.db')
        kb:add_kb('kb1', 'First knowledge base')
        kb:add_node('kb1', 'person', 'John', {age=30}, {email='john@example.com'}, 'people.john')
        kb:disconnect()
--]]

local ffi = require('ffi')
local json -- forward declaration, loaded below

-- ============================================================
-- JSON encoder/decoder (minimal, pure-Lua)
-- Uses cjson if available, otherwise a bundled fallback
-- ============================================================
local ok, cjson = pcall(require, 'cjson')
if ok then
    json = cjson
else
    -- Minimal JSON encode/decode for tables
    json = {}

    local function json_encode_value(val, indent, level)
        local t = type(val)
        if t == 'nil' then
            return 'null'
        elseif t == 'boolean' then
            return val and 'true' or 'false'
        elseif t == 'number' then
            if val ~= val then return 'null' end -- NaN
            if val == math.huge or val == -math.huge then return 'null' end
            if val == math.floor(val) and math.abs(val) < 1e15 then
                return string.format('%d', val)
            end
            return string.format('%.14g', val)
        elseif t == 'string' then
            -- Escape special characters
            local s = val:gsub('\\', '\\\\')
                         :gsub('"', '\\"')
                         :gsub('\n', '\\n')
                         :gsub('\r', '\\r')
                         :gsub('\t', '\\t')
            return '"' .. s .. '"'
        elseif t == 'table' then
            -- Detect array vs object
            local is_array = true
            local max_index = 0
            for k, _ in pairs(val) do
                if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
                    is_array = false
                    break
                end
                if k > max_index then max_index = k end
            end
            if is_array and max_index == #val then
                local parts = {}
                for i = 1, #val do
                    parts[i] = json_encode_value(val[i], indent, level + 1)
                end
                return '[' .. table.concat(parts, ', ') .. ']'
            else
                local parts = {}
                for k, v in pairs(val) do
                    local key = type(k) == 'string' and k or tostring(k)
                    parts[#parts + 1] = json_encode_value(key, indent, level + 1) ..
                                        ': ' ..
                                        json_encode_value(v, indent, level + 1)
                end
                return '{' .. table.concat(parts, ', ') .. '}'
            end
        else
            return '"' .. tostring(val) .. '"'
        end
    end

    function json.encode(val)
        return json_encode_value(val, false, 0)
    end

    -- Minimal JSON decoder
    local function skip_whitespace(s, pos)
        return s:match('^%s*()', pos)
    end

    local function decode_value(s, pos)
        pos = skip_whitespace(s, pos)
        local c = s:sub(pos, pos)

        if c == '"' then
            -- String
            local start = pos + 1
            local result = {}
            local i = start
            while i <= #s do
                local ch = s:sub(i, i)
                if ch == '\\' then
                    local next_ch = s:sub(i + 1, i + 1)
                    if next_ch == '"' then result[#result + 1] = '"'
                    elseif next_ch == '\\' then result[#result + 1] = '\\'
                    elseif next_ch == 'n' then result[#result + 1] = '\n'
                    elseif next_ch == 'r' then result[#result + 1] = '\r'
                    elseif next_ch == 't' then result[#result + 1] = '\t'
                    elseif next_ch == '/' then result[#result + 1] = '/'
                    elseif next_ch == 'u' then
                        -- Basic unicode escape (ASCII range only)
                        local hex = s:sub(i + 2, i + 5)
                        local code = tonumber(hex, 16)
                        if code and code < 128 then
                            result[#result + 1] = string.char(code)
                        else
                            result[#result + 1] = '?'
                        end
                        i = i + 4
                    end
                    i = i + 2
                elseif ch == '"' then
                    return table.concat(result), i + 1
                else
                    result[#result + 1] = ch
                    i = i + 1
                end
            end
            error('Unterminated string at position ' .. pos)

        elseif c == '{' then
            -- Object
            local obj = {}
            pos = pos + 1
            pos = skip_whitespace(s, pos)
            if s:sub(pos, pos) == '}' then return obj, pos + 1 end
            while true do
                local key, val
                key, pos = decode_value(s, pos)
                pos = skip_whitespace(s, pos)
                assert(s:sub(pos, pos) == ':', 'Expected : at position ' .. pos)
                pos = pos + 1
                val, pos = decode_value(s, pos)
                obj[key] = val
                pos = skip_whitespace(s, pos)
                local sep = s:sub(pos, pos)
                if sep == '}' then return obj, pos + 1 end
                assert(sep == ',', 'Expected , or } at position ' .. pos)
                pos = pos + 1
            end

        elseif c == '[' then
            -- Array
            local arr = {}
            pos = pos + 1
            pos = skip_whitespace(s, pos)
            if s:sub(pos, pos) == ']' then return arr, pos + 1 end
            while true do
                local val
                val, pos = decode_value(s, pos)
                arr[#arr + 1] = val
                pos = skip_whitespace(s, pos)
                local sep = s:sub(pos, pos)
                if sep == ']' then return arr, pos + 1 end
                assert(sep == ',', 'Expected , or ] at position ' .. pos)
                pos = pos + 1
            end

        elseif s:sub(pos, pos + 3) == 'true' then
            return true, pos + 4
        elseif s:sub(pos, pos + 4) == 'false' then
            return false, pos + 5
        elseif s:sub(pos, pos + 3) == 'null' then
            return nil, pos + 4
        else
            -- Number
            local num_str = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
            if num_str then
                return tonumber(num_str), pos + #num_str
            end
            error('Unexpected character at position ' .. pos .. ': ' .. c)
        end
    end

    function json.decode(s)
        if s == nil or s == '' then return nil end
        local val, _ = decode_value(s, 1)
        return val
    end
end

-- ============================================================
-- SQLite3 FFI Declarations
-- ============================================================
ffi.cdef[[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    // Return codes
    enum {
        SQLITE_OK         = 0,
        SQLITE_ERROR      = 1,
        SQLITE_BUSY       = 5,
        SQLITE_ROW        = 100,
        SQLITE_DONE       = 101,
        SQLITE_OPEN_READWRITE = 0x00000002,
        SQLITE_OPEN_CREATE    = 0x00000004,
    };

    // Core API
    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *db);
    const char *sqlite3_errmsg(sqlite3 *db);

    // Extension loading
    int sqlite3_enable_load_extension(sqlite3 *db, int onoff);
    int sqlite3_load_extension(sqlite3 *db, const char *zFile,
                               const char *zProc, char **pzErrMsg);
    void sqlite3_free(void *ptr);

    // Statement API
    int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                           sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *stmt);
    int sqlite3_finalize(sqlite3_stmt *stmt);
    int sqlite3_reset(sqlite3_stmt *stmt);
    int sqlite3_clear_bindings(sqlite3_stmt *stmt);

    // Binding parameters
    int sqlite3_bind_text(sqlite3_stmt *stmt, int idx, const char *val,
                          int n, void(*destructor)(void*));
    int sqlite3_bind_int(sqlite3_stmt *stmt, int idx, int val);
    int sqlite3_bind_int64(sqlite3_stmt *stmt, int idx, long long val);
    int sqlite3_bind_null(sqlite3_stmt *stmt, int idx);
    int sqlite3_bind_double(sqlite3_stmt *stmt, int idx, double val);

    // Column retrieval
    int sqlite3_column_count(sqlite3_stmt *stmt);
    int sqlite3_column_type(sqlite3_stmt *stmt, int col);
    const char *sqlite3_column_name(sqlite3_stmt *stmt, int col);
    const char *sqlite3_column_text(sqlite3_stmt *stmt, int col);
    int sqlite3_column_int(sqlite3_stmt *stmt, int col);
    long long sqlite3_column_int64(sqlite3_stmt *stmt, int col);
    double sqlite3_column_double(sqlite3_stmt *stmt, int col);
    int sqlite3_column_bytes(sqlite3_stmt *stmt, int col);

    // Exec (simple queries)
    int sqlite3_exec(sqlite3 *db, const char *sql,
                     int (*callback)(void*,int,char**,char**),
                     void *arg, char **errmsg);

    // Changes
    int sqlite3_changes(sqlite3 *db);
]]

-- Special destructor constant for transient strings
local SQLITE_TRANSIENT = ffi.cast('void(*)(void*)', -1)

local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101

-- Column types
local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

local sqlite3_lib = ffi.load('sqlite3')

-- ============================================================
-- Helper: sqlite3 wrapper functions
-- ============================================================

local function sql_errmsg(db)
    return ffi.string(sqlite3_lib.sqlite3_errmsg(db))
end

--- Execute a simple SQL statement (no results expected)
local function sql_exec(db, sql_str)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3_lib.sqlite3_exec(db, sql_str, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown error'
        sqlite3_lib.sqlite3_free(errmsg[0])
        error(string.format("SQL exec error (%d): %s\nSQL: %s", rc, msg, sql_str))
    end
end

--- Prepare a statement, bind parameters, and return results as array of tables
--- Each row is a table with column-name keys.
--- @param db     sqlite3*  database handle
--- @param sql    string    SQL with ? placeholders
--- @param params table|nil  array of bind values (string, number, nil, or boolean)
--- @return rows  table     array of row-tables
--- @return rowcount number  sqlite3_changes() value
local function sql_query(db, sql, params)
    local stmt = ffi.new('sqlite3_stmt*[1]')
    local rc = sqlite3_lib.sqlite3_prepare_v2(db, sql, #sql, stmt, nil)
    if rc ~= SQLITE_OK then
        error(string.format("Prepare error (%d): %s\nSQL: %s", rc, sql_errmsg(db), sql))
    end

    -- Bind parameters
    if params then
        for i, val in ipairs(params) do
            local t = type(val)
            if val == nil then
                sqlite3_lib.sqlite3_bind_null(stmt[0], i)
            elseif t == 'string' then
                sqlite3_lib.sqlite3_bind_text(stmt[0], i, val, #val, SQLITE_TRANSIENT)
            elseif t == 'number' then
                if val == math.floor(val) and math.abs(val) < 2^53 then
                    sqlite3_lib.sqlite3_bind_int64(stmt[0], i, val)
                else
                    sqlite3_lib.sqlite3_bind_double(stmt[0], i, val)
                end
            elseif t == 'boolean' then
                sqlite3_lib.sqlite3_bind_int(stmt[0], i, val and 1 or 0)
            else
                sqlite3_lib.sqlite3_finalize(stmt[0])
                error("Unsupported bind type: " .. t)
            end
        end
    end

    -- Collect results
    local rows = {}
    local col_count = sqlite3_lib.sqlite3_column_count(stmt[0])

    -- Cache column names
    local col_names = {}
    for c = 0, col_count - 1 do
        col_names[c] = ffi.string(sqlite3_lib.sqlite3_column_name(stmt[0], c))
    end

    while true do
        rc = sqlite3_lib.sqlite3_step(stmt[0])
        if rc == SQLITE_ROW then
            local row = {}
            for c = 0, col_count - 1 do
                local ctype = sqlite3_lib.sqlite3_column_type(stmt[0], c)
                local name = col_names[c]
                if ctype == SQLITE_NULL then
                    row[name] = nil
                elseif ctype == SQLITE_INTEGER then
                    row[name] = tonumber(sqlite3_lib.sqlite3_column_int64(stmt[0], c))
                elseif ctype == SQLITE_FLOAT then
                    row[name] = sqlite3_lib.sqlite3_column_double(stmt[0], c)
                elseif ctype == SQLITE_TEXT then
                    row[name] = ffi.string(sqlite3_lib.sqlite3_column_text(stmt[0], c))
                elseif ctype == SQLITE_BLOB then
                    local bytes = sqlite3_lib.sqlite3_column_bytes(stmt[0], c)
                    row[name] = ffi.string(sqlite3_lib.sqlite3_column_text(stmt[0], c), bytes)
                end
            end
            rows[#rows + 1] = row
        elseif rc == SQLITE_DONE then
            break
        else
            sqlite3_lib.sqlite3_finalize(stmt[0])
            error(string.format("Step error (%d): %s", rc, sql_errmsg(db)))
        end
    end

    sqlite3_lib.sqlite3_finalize(stmt[0])
    local changes = sqlite3_lib.sqlite3_changes(db)
    return rows, changes
end

-- ============================================================
-- KnowledgeBaseManager class
-- ============================================================
local KnowledgeBaseManager = {}
KnowledgeBaseManager.__index = KnowledgeBaseManager

--- Determine the platform-specific shared library suffix
local function get_lib_suffix()
    if ffi.os == 'OSX' then
        return '.dylib'
    elseif ffi.os == 'Windows' then
        return '.dll'
    else
        return '.so'
    end
end

--- Search for the ltree extension in common locations
local function find_ltree_extension()
    local suffix = get_lib_suffix()
    local search_paths = {
        './ltree',
        '/usr/local/lib/ltree',
        '/usr/lib/ltree',
    }

    for _, path in ipairs(search_paths) do
        local f = io.open(path .. suffix, 'r')
        if f then
            f:close()
            return path
        end
    end
    return './ltree' -- default fallback
end

--- Strip file extension from a path
local function strip_extension(path)
    return path:match('^(.+)%.[^%.]+$') or path
end

--- Constructor
--- @param table_name string            Base name for tables
--- @param db_path    string            Path to SQLite database file
--- @param ltree_extension_path string? Path to ltree extension (without suffix)
--- @param upload_flag boolean?         If true, skip table creation
--- @return KnowledgeBaseManager
function KnowledgeBaseManager.new(table_name, db_path, ltree_extension_path, upload_flag)
    assert(type(table_name) == 'string', 'table_name must be a string')
    assert(type(db_path) == 'string', 'db_path must be a string')

    local self = setmetatable({}, KnowledgeBaseManager)
    self.db_path = db_path
    self.table_name = table_name
    self.upload_flag = upload_flag or false
    self.ltree_extension_path = ltree_extension_path or find_ltree_extension()
    self.db = nil

    self:_connect()

    if not self.upload_flag then
        self:_create_tables()
    end

    return self
end

--- Establish database connection and load ltree extension
function KnowledgeBaseManager:_connect()
    local db_handle = ffi.new('sqlite3*[1]')
    local rc = sqlite3_lib.sqlite3_open(self.db_path, db_handle)
    if rc ~= SQLITE_OK then
        local msg = db_handle[0] ~= nil and sql_errmsg(db_handle[0]) or 'unknown error'
        error(string.format("Error connecting to database: %s", msg))
    end
    self.db = db_handle[0]

    -- Enable foreign keys
    sql_exec(self.db, "PRAGMA foreign_keys = ON")

    -- Load ltree extension
    sqlite3_lib.sqlite3_enable_load_extension(self.db, 1)

    local ext_path = strip_extension(self.ltree_extension_path)
    local errmsg = ffi.new('char*[1]')
    rc = sqlite3_lib.sqlite3_load_extension(self.db, ext_path, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown error'
        sqlite3_lib.sqlite3_free(errmsg[0])
        io.stderr:write(string.format(
            "Warning: Could not load ltree extension from %s: %s\n" ..
            "Ltree-specific query methods will not be available.\n",
            self.ltree_extension_path, msg))
    else
        print(string.format("Loaded ltree extension from: %s", ext_path))
    end

    sqlite3_lib.sqlite3_enable_load_extension(self.db, 0)
end

--- Close database connection
function KnowledgeBaseManager:disconnect()
    if self.db ~= nil then
        sqlite3_lib.sqlite3_close(self.db)
        self.db = nil
    end
end

--- Delete a table
function KnowledgeBaseManager:_delete_table(tbl_name)
    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", tbl_name))
end

--- Create all knowledge base tables and indexes
function KnowledgeBaseManager:_create_tables()
    local tn = self.table_name

    -- Drop existing tables
    self:_delete_table(tn)
    self:_delete_table(tn .. '_info')
    self:_delete_table(tn .. '_link')
    self:_delete_table(tn .. '_link_mount')

    -- Main knowledge base table
    sql_exec(self.db, string.format([[
        CREATE TABLE IF NOT EXISTS %s (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            knowledge_base TEXT NOT NULL,
            label TEXT NOT NULL,
            name TEXT NOT NULL,
            properties TEXT,
            data TEXT,
            has_link INTEGER DEFAULT 0,
            has_link_mount INTEGER DEFAULT 0,
            path TEXT UNIQUE
        )
    ]], tn))

    -- Info table
    sql_exec(self.db, string.format([[
        CREATE TABLE IF NOT EXISTS %s_info (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            knowledge_base TEXT NOT NULL UNIQUE,
            description TEXT
        )
    ]], tn))

    -- Link table
    sql_exec(self.db, string.format([[
        CREATE TABLE IF NOT EXISTS %s_link (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            link_name TEXT NOT NULL,
            parent_node_kb TEXT NOT NULL,
            parent_path TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(link_name, parent_node_kb, parent_path)
        )
    ]], tn))

    -- Link mount table
    sql_exec(self.db, string.format([[
        CREATE TABLE IF NOT EXISTS %s_link_mount (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            link_name TEXT NOT NULL UNIQUE,
            knowledge_base TEXT NOT NULL,
            mount_path TEXT NOT NULL,
            description TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(knowledge_base, mount_path)
        )
    ]], tn))

    -- Create indexes
    local indexes = {
        -- Main table
        "CREATE INDEX IF NOT EXISTS idx_%s_kb ON %s (knowledge_base)",
        "CREATE INDEX IF NOT EXISTS idx_%s_path ON %s (path)",
        "CREATE INDEX IF NOT EXISTS idx_%s_label ON %s (label)",
        "CREATE INDEX IF NOT EXISTS idx_%s_name ON %s (name)",
        "CREATE INDEX IF NOT EXISTS idx_%s_has_link ON %s (has_link)",
        "CREATE INDEX IF NOT EXISTS idx_%s_has_link_mount ON %s (has_link_mount)",
        "CREATE INDEX IF NOT EXISTS idx_%s_kb_path ON %s (knowledge_base, path)",
    }
    for _, fmt in ipairs(indexes) do
        sql_exec(self.db, string.format(fmt, tn, tn))
    end

    -- Info table indexes
    sql_exec(self.db, string.format(
        "CREATE INDEX IF NOT EXISTS idx_%s_info_kb ON %s_info (knowledge_base)", tn, tn))

    -- Link table indexes
    local link_indexes = {
        "CREATE INDEX IF NOT EXISTS idx_%s_link_name ON %s_link (link_name)",
        "CREATE INDEX IF NOT EXISTS idx_%s_link_parent_kb ON %s_link (parent_node_kb)",
        "CREATE INDEX IF NOT EXISTS idx_%s_link_parent_path ON %s_link (parent_path)",
        "CREATE INDEX IF NOT EXISTS idx_%s_link_created ON %s_link (created_at)",
        "CREATE INDEX IF NOT EXISTS idx_%s_link_composite ON %s_link (link_name, parent_node_kb)",
    }
    for _, fmt in ipairs(link_indexes) do
        sql_exec(self.db, string.format(fmt, tn, tn))
    end

    -- Link mount table indexes
    local mount_indexes = {
        "CREATE INDEX IF NOT EXISTS idx_%s_mount_link_name ON %s_link_mount (link_name)",
        "CREATE INDEX IF NOT EXISTS idx_%s_mount_kb ON %s_link_mount (knowledge_base)",
        "CREATE INDEX IF NOT EXISTS idx_%s_mount_path ON %s_link_mount (mount_path)",
        "CREATE INDEX IF NOT EXISTS idx_%s_mount_created ON %s_link_mount (created_at)",
        "CREATE INDEX IF NOT EXISTS idx_%s_mount_composite ON %s_link_mount (knowledge_base, mount_path)",
    }
    for _, fmt in ipairs(mount_indexes) do
        sql_exec(self.db, string.format(fmt, tn, tn))
    end
end

-- ============================================================
-- Data manipulation methods
-- ============================================================

--- Add a knowledge base entry to the info table
--- @param kb_name     string  Knowledge base name
--- @param description string? Optional description
function KnowledgeBaseManager:add_kb(kb_name, description)
    assert(type(kb_name) == 'string', 'kb_name must be a string')
    assert(description == nil or type(description) == 'string', 'description must be a string')

    local sql = string.format(
        "INSERT OR IGNORE INTO %s_info (knowledge_base, description) VALUES (?, ?)",
        self.table_name)
    sql_query(self.db, sql, { kb_name, description })
end

--- Add a node to the knowledge base
--- @param kb_name    string       Knowledge base name
--- @param label      string       Node label
--- @param name       string       Node name
--- @param properties table|nil    Optional properties (table -> JSON)
--- @param data       table|nil    Optional data (table -> JSON)
--- @param path       string       ltree path
function KnowledgeBaseManager:add_node(kb_name, label, name, properties, data, path)
    assert(type(kb_name) == 'string', 'kb_name must be a string')
    assert(type(label) == 'string', 'label must be a string')
    assert(type(name) == 'string', 'name must be a string')
    assert(type(path) == 'string', 'path must be a string')
    assert(properties == nil or type(properties) == 'table', 'properties must be a table')
    assert(data == nil or type(data) == 'table', 'data must be a table')

    -- Verify knowledge base exists
    local check_sql = string.format(
        "SELECT 1 FROM %s_info WHERE knowledge_base = ?", self.table_name)
    local rows = sql_query(self.db, check_sql, { kb_name })
    if #rows == 0 then
        error(string.format("Knowledge base '%s' not found in info table", kb_name))
    end

    local properties_json = properties and json.encode(properties) or nil
    local data_json = data and json.encode(data) or nil

    local insert_sql = string.format(
        "INSERT INTO %s (knowledge_base, label, name, properties, data, has_link, path) VALUES (?, ?, ?, ?, ?, ?, ?)",
        self.table_name)
    sql_query(self.db, insert_sql, { kb_name, label, name, properties_json, data_json, 0, path })
end

--- Add a link between nodes
--- @param parent_kb   string  Parent knowledge base name
--- @param parent_path string  Parent node path
--- @param link_name   string  Link name
function KnowledgeBaseManager:add_link(parent_kb, parent_path, link_name)
    assert(type(parent_kb) == 'string', 'parent_kb must be a string')
    assert(type(parent_path) == 'string', 'parent_path must be a string')
    assert(type(link_name) == 'string', 'link_name must be a string')

    -- Check knowledge base exists
    local rows = sql_query(self.db,
        string.format("SELECT knowledge_base FROM %s_info WHERE knowledge_base = ?", self.table_name),
        { parent_kb })
    if #rows == 0 then
        error(string.format("Parent knowledge base '%s' not found", parent_kb))
    end

    -- Check parent node exists
    rows = sql_query(self.db,
        string.format("SELECT path FROM %s WHERE path = ?", self.table_name),
        { parent_path })
    if #rows == 0 then
        error(string.format("Parent node with path '%s' not found", parent_path))
    end

    -- Check link name exists in link_mount table
    rows = sql_query(self.db,
        string.format("SELECT link_name FROM %s_link_mount WHERE link_name = ?", self.table_name),
        { link_name })
    if #rows == 0 then
        error(string.format("Link name '%s' not found in link_mount table", link_name))
    end

    -- Insert link
    sql_query(self.db,
        string.format("INSERT INTO %s_link (parent_node_kb, parent_path, link_name) VALUES (?, ?, ?)",
            self.table_name),
        { parent_kb, parent_path, link_name })

    -- Update has_link flag
    sql_query(self.db,
        string.format("UPDATE %s SET has_link = 1 WHERE path = ?", self.table_name),
        { parent_path })
end

--- Add a link mount
--- @param knowledge_base  string  Knowledge base name
--- @param path            string  ltree path
--- @param link_mount_name string  Link mount name
--- @param description     string? Optional description
--- @return string, string  knowledge_base, path
function KnowledgeBaseManager:add_link_mount(knowledge_base, path, link_mount_name, description)
    assert(type(knowledge_base) == 'string', 'knowledge_base must be a string')
    assert(type(path) == 'string', 'path must be a string')
    assert(type(link_mount_name) == 'string', 'link_mount_name must be a string')
    description = description or ""
    assert(type(description) == 'string', 'description must be a string')

    local tn = self.table_name

    -- Step 1: Verify knowledge base exists
    local rows = sql_query(self.db,
        string.format("SELECT knowledge_base FROM %s_info WHERE knowledge_base = ?", tn),
        { knowledge_base })
    if #rows == 0 then
        error(string.format("Knowledge base '%s' does not exist in info table", knowledge_base))
    end

    -- Step 2: Verify path exists for the knowledge base
    rows = sql_query(self.db,
        string.format("SELECT id FROM %s WHERE knowledge_base = ? AND path = ?", tn),
        { knowledge_base, path })
    if #rows == 0 then
        error(string.format("Path '%s' does not exist for knowledge base '%s'", path, knowledge_base))
    end

    -- Step 3: Verify link_name does not already exist in link_mount
    rows = sql_query(self.db,
        string.format("SELECT link_name FROM %s_link_mount WHERE link_name = ?", tn),
        { link_mount_name })
    if #rows > 0 then
        error(string.format("Link name '%s' already exists in link_mount table", link_mount_name))
    end

    -- Step 4: Insert record in link_mount table
    local _, changes = sql_query(self.db,
        string.format("INSERT INTO %s_link_mount (link_name, knowledge_base, mount_path, description) VALUES (?, ?, ?, ?)", tn),
        { link_mount_name, knowledge_base, path, description })
    if changes == 0 then
        error(string.format("Failed to insert record with link_name '%s'", link_mount_name))
    end

    -- Step 5: Verify entry with knowledge_base and mount_path exists
    rows = sql_query(self.db,
        string.format("SELECT id FROM %s WHERE knowledge_base = ? AND path = ?", tn),
        { knowledge_base, path })
    if #rows == 0 then
        error(string.format("Entry with knowledge_base '%s' and mount_path '%s' does not exist",
            knowledge_base, path))
    end

    -- Step 6: Set has_link_mount = 1
    _, changes = sql_query(self.db,
        string.format("UPDATE %s SET has_link_mount = 1 WHERE knowledge_base = ? AND path = ?", tn),
        { knowledge_base, path })
    if changes == 0 then
        error(string.format("No rows updated for knowledge_base '%s' and path '%s'",
            knowledge_base, path))
    end

    return knowledge_base, path
end

-- ============================================================
-- LTREE Query Methods
-- ============================================================

--- Find all nodes matching an ltree pattern
--- @param pattern string  ltree pattern (e.g. 'people.*', 'kb.*.GATE*.*')
--- @param kb_name string? Optional filter by knowledge base
--- @return table  Array of matching rows
function KnowledgeBaseManager:find_by_pattern(pattern, kb_name)
    local tn = self.table_name
    if kb_name then
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE knowledge_base = ? AND ltree_match(path, ?)", tn),
            { kb_name, pattern })
    else
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE ltree_match(path, ?)", tn),
            { pattern })
    end
end

--- Find all descendants of a given path
--- @param parent_path string  Parent path
--- @param kb_name     string? Optional filter by knowledge base
--- @return table  Array of descendant rows
function KnowledgeBaseManager:find_descendants(parent_path, kb_name)
    local tn = self.table_name
    if kb_name then
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE knowledge_base = ? AND ltree_descendant(?, path)", tn),
            { kb_name, parent_path })
    else
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE ltree_descendant(?, path)", tn),
            { parent_path })
    end
end

--- Find all ancestors of a given path
--- @param child_path string  Child path
--- @param kb_name    string? Optional filter by knowledge base
--- @return table  Array of ancestor rows
function KnowledgeBaseManager:find_ancestors(child_path, kb_name)
    local tn = self.table_name
    if kb_name then
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE knowledge_base = ? AND ltree_ancestor(?, path)", tn),
            { kb_name, child_path })
    else
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE ltree_ancestor(?, path)", tn),
            { child_path })
    end
end

--- Get the depth of a path
--- @param path string  Path to measure
--- @return number  Depth
function KnowledgeBaseManager:get_node_depth(path)
    local rows = sql_query(self.db, "SELECT ltree_depth(?)", { path })
    if #rows > 0 then
        -- The column name from sqlite will be 'ltree_depth(?)'
        -- so grab the first value from the first row
        for _, v in pairs(rows[1]) do
            return v
        end
    end
    return 0
end

--- Find all nodes at a specific depth
--- @param depth   number  Depth to search for
--- @param kb_name string? Optional filter by knowledge base
--- @return table  Array of rows
function KnowledgeBaseManager:find_by_depth(depth, kb_name)
    local tn = self.table_name
    if kb_name then
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE knowledge_base = ? AND ltree_depth(path) = ?", tn),
            { kb_name, depth })
    else
        return sql_query(self.db,
            string.format("SELECT * FROM %s WHERE ltree_depth(path) = ?", tn),
            { depth })
    end
end

--- Find immediate children of a path (depth = parent_depth + 1)
--- @param parent_path string  Parent path
--- @param kb_name     string? Optional filter by knowledge base
--- @return table  Array of child rows
function KnowledgeBaseManager:find_children(parent_path, kb_name)
    local parent_depth = self:get_node_depth(parent_path)
    local child_depth = parent_depth + 1

    local tn = self.table_name
    if kb_name then
        return sql_query(self.db,
            string.format([[
                SELECT * FROM %s
                WHERE knowledge_base = ?
                AND ltree_descendant(?, path)
                AND ltree_depth(path) = ?
            ]], tn),
            { kb_name, parent_path, child_depth })
    else
        return sql_query(self.db,
            string.format([[
                SELECT * FROM %s
                WHERE ltree_descendant(?, path)
                AND ltree_depth(path) = ?
            ]], tn),
            { parent_path, child_depth })
    end
end

-- ============================================================
-- Module export
-- ============================================================
return KnowledgeBaseManager
