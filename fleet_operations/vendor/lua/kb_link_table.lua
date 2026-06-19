--[[
  kb_link_table.lua — LuaJIT port of KB_Link_Table

  Query operations on the knowledge_base_link table.
  Provides lookups by link_name, node_path (parent_path), and
  enumeration of all unique link names and node paths.

  Usage:
    local KB_Search     = require('kb_query_support')
    local KB_Link_Table = require('kb_link_table')

    local kb   = KB_Search.new({ db_path = 'kb.db', database = 'knowledge_base' })
    local _, db = kb:get_db()
    local links = KB_Link_Table.new(db, 'knowledge_base')

    local recs = links:find_records_by_link_name('my_link')
    local all  = links:find_all_link_names()
]]

local ffi = require('ffi')

pcall(ffi.cdef, [[
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    int  sqlite3_prepare_v2(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
    int  sqlite3_step(sqlite3_stmt*);
    int  sqlite3_finalize(sqlite3_stmt*);
    int         sqlite3_column_count(sqlite3_stmt*);
    int         sqlite3_column_type(sqlite3_stmt*, int);
    const char *sqlite3_column_name(sqlite3_stmt*, int);
    const char *sqlite3_column_text(sqlite3_stmt*, int);
    int         sqlite3_column_int(sqlite3_stmt*, int);
    double      sqlite3_column_double(sqlite3_stmt*, int);
    int  sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
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
local SQLITE_NULL    = 5

local function sql_query_rows(db, sql, params)
    local stmt = ffi.new('sqlite3_stmt*[1]')
    local rc = sqlite3.sqlite3_prepare_v2(db, sql, #sql, stmt, nil)
    if rc ~= SQLITE_OK then
        error(string.format("Prepare error (%d): %s", rc, ffi.string(sqlite3.sqlite3_errmsg(db))))
    end
    local s = stmt[0]
    for i, val in ipairs(params or {}) do
        if val == nil then sqlite3.sqlite3_bind_null(s, i, 0)
        else
            val = tostring(val)
            sqlite3.sqlite3_bind_text(s, i, val, #val, SQLITE_TRANSIENT)
        end
    end
    local ncols = sqlite3.sqlite3_column_count(s)
    local colnames = {}
    for i = 0, ncols - 1 do colnames[i] = ffi.string(sqlite3.sqlite3_column_name(s, i)) end
    local rows = {}
    while true do
        rc = sqlite3.sqlite3_step(s)
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

-- ═══════════════════════════════════════════════════════════════════════

local KB_Link_Table = {}
KB_Link_Table.__index = KB_Link_Table

--- Create a new KB_Link_Table instance.
-- @param db          sqlite3* FFI handle
-- @param base_table  base name (suffixed with '_link')
function KB_Link_Table.new(db, base_table)
    assert(db, "db handle is required")
    assert(base_table, "base_table is required")
    local self = setmetatable({}, KB_Link_Table)
    self.db         = db
    self.base_table = base_table .. '_link'
    return self
end

--- Find records by link_name, optionally filtered by knowledge_base.
function KB_Link_Table:find_records_by_link_name(link_name, kb)
    if kb then
        return sql_query_rows(self.db,
            string.format("SELECT * FROM %s WHERE link_name = ? AND parent_node_kb = ?", self.base_table),
            { link_name, kb })
    else
        return sql_query_rows(self.db,
            string.format("SELECT * FROM %s WHERE link_name = ?", self.base_table),
            { link_name })
    end
end

--- Find records by parent_path, optionally filtered by knowledge_base.
function KB_Link_Table:find_records_by_node_path(node_path, kb)
    if kb then
        return sql_query_rows(self.db,
            string.format("SELECT * FROM %s WHERE parent_path = ? AND parent_node_kb = ?", self.base_table),
            { node_path, kb })
    else
        return sql_query_rows(self.db,
            string.format("SELECT * FROM %s WHERE parent_path = ?", self.base_table),
            { node_path })
    end
end

--- Get all unique link names.
function KB_Link_Table:find_all_link_names()
    local rows = sql_query_rows(self.db,
        string.format("SELECT DISTINCT link_name FROM %s ORDER BY link_name", self.base_table), {})
    local rv = {}
    for _, r in ipairs(rows) do if r.link_name then rv[#rv + 1] = r.link_name end end
    return rv
end

--- Get all unique parent paths (node names).
function KB_Link_Table:find_all_node_names()
    local rows = sql_query_rows(self.db,
        string.format("SELECT DISTINCT parent_path FROM %s ORDER BY parent_path", self.base_table), {})
    local rv = {}
    for _, r in ipairs(rows) do if r.parent_path then rv[#rv + 1] = r.parent_path end end
    return rv
end

return KB_Link_Table