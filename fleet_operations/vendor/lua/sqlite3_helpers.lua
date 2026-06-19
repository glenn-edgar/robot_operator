--[[
    sqlite3_helpers - Shared SQLite3 FFI + JSON helpers for LuaJIT
    
    Provides:
        - sqlite3 FFI bindings (open, close, prepare, bind, step, etc.)
        - sql_exec(db, sql)           -- fire-and-forget DDL/DML
        - sql_query(db, sql, params)  -- prepare/bind/step/collect → rows, changes
        - sql_errmsg(db)              -- get last error message
        - json.encode(val)            -- table → JSON string
        - json.decode(str)            -- JSON string → table
        - sqlite3_lib                 -- raw ffi.load('sqlite3') handle
        - SQLITE_TRANSIENT            -- destructor constant for bind_text
    
    Usage:
        local h = require('sqlite3_helpers')
        h.sql_exec(db, "CREATE TABLE ...")
        local rows, changes = h.sql_query(db, "SELECT * FROM t WHERE id = ?", { 42 })
        local s = h.json.encode({ key = "value" })
        local t = h.json.decode(s)
--]]

local ffi = require('ffi')

-- ============================================================
-- JSON encoder/decoder
-- Uses cjson if available, otherwise a pure-Lua fallback
-- ============================================================
local json

do
    local ok, cjson = pcall(require, 'cjson')
    if ok then
        json = { encode = cjson.encode, decode = cjson.decode }
    else
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
                local s = val:gsub('\\', '\\\\')
                             :gsub('"', '\\"')
                             :gsub('\n', '\\n')
                             :gsub('\r', '\\r')
                             :gsub('\t', '\\t')
                return '"' .. s .. '"'
            elseif t == 'table' then
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
                local result = {}
                local i = pos + 1
                while i <= #s do
                    local ch = s:sub(i, i)
                    if ch == '\\' then
                        local next_ch = s:sub(i + 1, i + 1)
                        if     next_ch == '"'  then result[#result + 1] = '"'
                        elseif next_ch == '\\' then result[#result + 1] = '\\'
                        elseif next_ch == 'n'  then result[#result + 1] = '\n'
                        elseif next_ch == 'r'  then result[#result + 1] = '\r'
                        elseif next_ch == 't'  then result[#result + 1] = '\t'
                        elseif next_ch == '/'  then result[#result + 1] = '/'
                        elseif next_ch == 'u'  then
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
end

-- ============================================================
-- SQLite3 FFI Declarations (guarded against re-declaration)
-- ============================================================
pcall(ffi.cdef, [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;

    // Core API
    int sqlite3_open(const char *filename, sqlite3 **ppDb);
    int sqlite3_close(sqlite3 *db);
    const char *sqlite3_errmsg(sqlite3 *db);
    int sqlite3_extended_errcode(sqlite3 *db);

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
]])

-- ============================================================
-- Constants
-- ============================================================
local SQLITE_TRANSIENT = ffi.cast('void(*)(void*)', -1)

local SQLITE_OK   = 0
local SQLITE_ROW  = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

-- ============================================================
-- Load the shared library once
-- ============================================================
local sqlite3_lib = ffi.load('sqlite3')

-- ============================================================
-- Helper functions
-- ============================================================

local function sql_errmsg(db)
    return ffi.string(sqlite3_lib.sqlite3_errmsg(db))
end

--- Execute a simple SQL statement (no results expected)
--- @param db      userdata  sqlite3* handle
--- @param sql_str string    SQL to execute
local function sql_exec(db, sql_str)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3_lib.sqlite3_exec(db, sql_str, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown error'
        sqlite3_lib.sqlite3_free(errmsg[0])
        error(string.format("SQL exec error (%d): %s\nSQL: %s", rc, msg, sql_str))
    end
end

--- Prepare, bind, execute, and collect results.
--- @param db     userdata   sqlite3* handle
--- @param sql    string     SQL with ? placeholders
--- @param params table|nil  array of bind values
--- @return table   rows     array of {col_name = value} tables
--- @return number  changes  sqlite3_changes() value
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
            error(string.format("Step error (%d ext=%d): %s",
                rc, sqlite3_lib.sqlite3_extended_errcode(db),
                sql_errmsg(db)))
        end
    end

    sqlite3_lib.sqlite3_finalize(stmt[0])
    local changes = sqlite3_lib.sqlite3_changes(db)
    return rows, changes
end

-- ============================================================
-- Module export
-- ============================================================
return {
    -- FFI library handle
    sqlite3_lib      = sqlite3_lib,
    ffi              = ffi,

    -- Constants
    SQLITE_TRANSIENT = SQLITE_TRANSIENT,
    SQLITE_OK        = SQLITE_OK,
    SQLITE_ROW       = SQLITE_ROW,
    SQLITE_DONE      = SQLITE_DONE,

    -- Helper functions
    sql_errmsg       = sql_errmsg,
    sql_exec         = sql_exec,
    sql_query        = sql_query,

    -- JSON
    json             = json,
}