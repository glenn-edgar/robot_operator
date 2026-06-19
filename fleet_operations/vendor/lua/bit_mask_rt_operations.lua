--[[
  bit_mask_rt_operations.lua — LuaJIT port of bit_mask_operations.py

  Manages bit masks for distributed node control systems.
  Operates on a pre-existing bit_mask_table created by construct_bit_mask_store.

  Usage:
    local BitMaskOperations = require('bit_mask_rt_operations')
    local bmo = BitMaskOperations.new(db)          -- db is an sqlite3* handle
    bmo:create_entry('node_1', 0)
    bmo:set_bit_mask('node_1', 0xFF, 0xFF)
    local mask = bmo:get_bit_mask('node_1')
]]

local ffi = require('ffi')
local bit = require('bit')

-- ── FFI declarations (guarded) ──────────────────────────────────────────
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
    int  sqlite3_changes(sqlite3 *db);

    int         sqlite3_column_count(sqlite3_stmt *pStmt);
    int         sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
    const char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
    int         sqlite3_column_int(sqlite3_stmt *pStmt, int iCol);
    double      sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
    long long   sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);

    int  sqlite3_bind_text(sqlite3_stmt *pStmt, int idx,
                           const char *val, int nByte,
                           void (*destructor)(void*));
    int  sqlite3_bind_int(sqlite3_stmt *pStmt, int idx, int val);
    int  sqlite3_bind_int64(sqlite3_stmt *pStmt, int idx, long long val);
    int  sqlite3_bind_null(sqlite3_stmt *pStmt, int idx, int n);

    const char *sqlite3_errmsg(sqlite3 *db);
]])

local sqlite3 = ffi.load('sqlite3')

local SQLITE_OK        = 0
local SQLITE_ROW       = 100
local SQLITE_DONE      = 101
local SQLITE_CONSTRAINT = 19
local SQLITE_TRANSIENT = ffi.cast("void (*)(void*)", -1)

-- ── Local helpers ───────────────────────────────────────────────────────

local function sql_exec(db, sql)
    local errmsg = ffi.new('char*[1]')
    local rc = sqlite3.sqlite3_exec(db, sql, nil, nil, errmsg)
    if rc ~= SQLITE_OK then
        local msg = errmsg[0] ~= nil and ffi.string(errmsg[0]) or 'unknown error'
        sqlite3.sqlite3_free(errmsg[0])
        error(string.format("SQL exec error (%d): %s\nSQL: %s", rc, msg, sql))
    end
end

--- Prepare, bind positional params, step, return (rc, stmt).
--- Caller must finalize.
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
                sqlite3.sqlite3_bind_int64(s, i, ffi.cast('long long', val))
            end
        elseif type(val) == 'cdata' then
            -- int64 cdata from bit.tobit etc.
            sqlite3.sqlite3_bind_int64(s, i, val)
        else
            val = tostring(val)
            sqlite3.sqlite3_bind_text(s, i, val, #val, SQLITE_TRANSIENT)
        end
    end
    return s
end

-- ═══════════════════════════════════════════════════════════════════════
-- BitMaskOperations class
-- ═══════════════════════════════════════════════════════════════════════

local BitMaskOperations = {}
BitMaskOperations.__index = BitMaskOperations

--- Create a new BitMaskOperations instance.
-- @param db        sqlite3* FFI handle (already opened)
-- @param tbl_name  table name (default "bit_mask_table")
function BitMaskOperations.new(db, tbl_name)
    assert(db, "db handle is required")
    local self = setmetatable({}, BitMaskOperations)
    self.db         = db
    self.table_name = tbl_name or 'bit_mask_table'
    return self
end

--- (Re)create the bit mask table (drops existing).
function BitMaskOperations:create_table()
    sql_exec(self.db, string.format("DROP TABLE IF EXISTS %s", self.table_name))
    sql_exec(self.db, string.format([[
        CREATE TABLE %s (
            node_id  TEXT PRIMARY KEY,
            bit_mask INTEGER NOT NULL DEFAULT 0
        )
    ]], self.table_name))
end

--- Insert a new entry.
-- @return true on success
function BitMaskOperations:create_entry(node_id, bit_mask_val)
    bit_mask_val = bit_mask_val or 0
    local sql = string.format(
        "INSERT INTO %s (node_id, bit_mask) VALUES (?, ?)", self.table_name)
    local s = prepare_and_bind(self.db, sql, { node_id, bit_mask_val })
    local rc = sqlite3.sqlite3_step(s)
    sqlite3.sqlite3_finalize(s)
    if rc ~= SQLITE_DONE then
        if rc == SQLITE_CONSTRAINT then
            error(string.format("Node ID '%s' already exists in table '%s'",
                  node_id, self.table_name))
        end
        error(string.format("Insert error (%d): %s",
              rc, ffi.string(sqlite3.sqlite3_errmsg(self.db))))
    end
    return true
end

--- Get the bit mask integer for a node.
-- @return integer or nil if not found
function BitMaskOperations:get_bit_mask(node_id)
    local sql = string.format(
        "SELECT bit_mask FROM %s WHERE node_id = ?", self.table_name)
    local s = prepare_and_bind(self.db, sql, { node_id })
    local rc = sqlite3.sqlite3_step(s)
    if rc ~= SQLITE_ROW then
        sqlite3.sqlite3_finalize(s)
        return nil
    end
    local val = sqlite3.sqlite3_column_int64(s, 0)
    sqlite3.sqlite3_finalize(s)
    return tonumber(val)
end

--- Atomically update bits: new_mask = (cur & ~change_mask) | (new_bits & change_mask)
-- @return true if a row was updated
function BitMaskOperations:set_bit_mask(node_id, new_bits, change_mask)
    change_mask = change_mask or -1
    local sql = string.format([[
        UPDATE %s
        SET bit_mask = (bit_mask & (~?)) | (? & ?)
        WHERE node_id = ?
    ]], self.table_name)
    local s = prepare_and_bind(self.db, sql,
        { change_mask, new_bits, change_mask, node_id })
    local rc = sqlite3.sqlite3_step(s)
    sqlite3.sqlite3_finalize(s)
    if rc ~= SQLITE_DONE then
        error(string.format("Update error (%d): %s",
              rc, ffi.string(sqlite3.sqlite3_errmsg(self.db))))
    end
    return sqlite3.sqlite3_changes(self.db) > 0
end

--- Get complete entry as a table {node_id=, bit_mask=}, or nil.
function BitMaskOperations:get_entry(node_id)
    local sql = string.format(
        "SELECT node_id, bit_mask FROM %s WHERE node_id = ?", self.table_name)
    local s = prepare_and_bind(self.db, sql, { node_id })
    local rc = sqlite3.sqlite3_step(s)
    if rc ~= SQLITE_ROW then
        sqlite3.sqlite3_finalize(s)
        return nil
    end
    local row = {
        node_id  = ffi.string(sqlite3.sqlite3_column_text(s, 0)),
        bit_mask = tonumber(sqlite3.sqlite3_column_int64(s, 1)),
    }
    sqlite3.sqlite3_finalize(s)
    return row
end

--- Delete an entry. Returns true if a row was deleted.
function BitMaskOperations:delete_entry(node_id)
    local sql = string.format(
        "DELETE FROM %s WHERE node_id = ?", self.table_name)
    local s = prepare_and_bind(self.db, sql, { node_id })
    local rc = sqlite3.sqlite3_step(s)
    sqlite3.sqlite3_finalize(s)
    if rc ~= SQLITE_DONE then
        error(string.format("Delete error (%d): %s",
              rc, ffi.string(sqlite3.sqlite3_errmsg(self.db))))
    end
    return sqlite3.sqlite3_changes(self.db) > 0
end

--- List all node IDs, sorted.
-- @return list of strings
function BitMaskOperations:list_all_nodes()
    local sql = string.format(
        "SELECT node_id FROM %s ORDER BY node_id", self.table_name)
    local s = prepare_and_bind(self.db, sql, {})
    local nodes = {}
    while sqlite3.sqlite3_step(s) == SQLITE_ROW do
        nodes[#nodes + 1] = ffi.string(sqlite3.sqlite3_column_text(s, 0))
    end
    sqlite3.sqlite3_finalize(s)
    return nodes
end

return BitMaskOperations