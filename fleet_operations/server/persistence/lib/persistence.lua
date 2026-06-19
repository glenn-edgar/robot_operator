-- server/persistence/lib/persistence.lua — the persistence service core.
--
-- Maintains one SQLite database (persistence.db) holding aux tables (status,
-- stream, ...) built by `construct_kb`. Each robot instance gets its own
-- knowledge_base (kb_name = "<class>_<instance>") — a query-time partition.
-- Inside that kb, paths mirror the Zenoh keys verbatim: Zenoh
-- `<class>/<instance>/<tail>` becomes ltree
-- `<kb_name>.<kind>.<tail-with-/-as-.>` where <kind> is the row-type label
-- ("stream" / "status") that construct_kb inserts between header and field.
--
-- The persistence service is a pure subscriber: it does NOT know the
-- topology a priori. Robots announce on `fleet/admin/persistence_topology_announce`
-- (decision: robot-announces, persistence-builds-on-first-contact). On each
-- announce, apply_topology() reconciles by diffing the announced entry set
-- against the cached in-memory leaves; ADDED leaves get declared + pre-
-- allocated, REMOVED leaves get returned to the driver so it can close their
-- subs. Subsequent samples are dispatched via dispatch() to
-- push_stream_data / set_status_data.
--
-- Schema policy is ADDITIVE-ONLY: removed leaves' rows stay in the DB
-- (both stream history and last-known status are preserved). The cost of
-- a stale status row is small (a dashboard timestamp filter handles it);
-- the cost of accidentally trimming live data on a malformed announce is
-- much larger. Explicit decommissioning is a future operator tool, not an
-- automatic side effect of a topology change.
--
-- Construct semantics: `construct_kb.add_node` always INSERTs, so we cannot
-- naïvely re-declare a kb. The reconciliation only invokes the construct
-- path for the ADDED set (so each ADDED leaf is declared exactly once), and
-- gates on a content-hash to short-circuit identical re-announces (the
-- common case after a robot reboot).

local cjson = require("cjson")
local CDT   = require("construct_data_tables")
local KBDS  = require("kb_data_structures")

local DEFAULT_DB_TABLE = "knowledge_base"

local M = {}
M.__index = M

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Schema-presence check. "File exists" is not enough — a 0-byte file (left
-- behind by a prior crashed-during-bootstrap run, or by some other process
-- opening the path with write mode) makes file_exists() return true but
-- the canonical knowledge_base_info table is missing; subsequent queries
-- (e.g. _kb_exists below) then crash with "no such table". This check
-- opens the DB and asks sqlite_master directly.
local function schema_present(path)
    if not file_exists(path) then return false end
    local ok_sql, sqlite3 = pcall(require, "lsqlite3")
    if not ok_sql then
        -- lsqlite3 missing — fall back to "file exists" semantics so we
        -- don't gratuitously re-bootstrap (which would DROP+CREATE tables).
        return true
    end
    local db, _, _err = sqlite3.open(path)
    if not db then return false end
    local has_kb_info = false
    for row in db:nrows(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='knowledge_base_info'") do
        if row.name == "knowledge_base_info" then has_kb_info = true end
    end
    db:close()
    return has_kb_info
end

-- Convert a Zenoh tail ("cimis/station/sample") to an ltree field name
-- ("cimis.station.sample"). `/` is the only special character we expect.
local function tail_to_field(tail)
    return (tail:gsub("/", "."))
end

-- Count non-nil keys of a map. Lua's `#t` only works on integer-indexed
-- sequences; this is for sparse / string-keyed tables.
local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function M.new(db_path)
    assert(db_path, "db_path required")
    local self = setmetatable({}, M)
    self.db_path  = db_path
    self.database = DEFAULT_DB_TABLE

    -- Bootstrap the schema on a brand-new DB (or a DB whose schema is
    -- incomplete — e.g. a 0-byte file left by a prior crash). With
    -- upload_flag=false the construct path runs DROP/CREATE for every aux
    -- table; we gate on schema_present() (not just file_exists) so we
    -- don't gratuitously drop tables that already exist with real data.
    if not schema_present(db_path) then
        io.stderr:write(string.format(
            "PERSISTENCE: bootstrapping new db at %s\n", db_path))
        local cdt = CDT.new(db_path, self.database, nil, false)
        cdt:check_installation()
        cdt:disconnect()
    end

    -- Long-lived runtime handle for push_stream_data / set_status_data.
    self.rt = KBDS.new(db_path, self.database)

    -- (class .. "/" .. instance) -> state table
    self.instances = {}

    return self
end

-- Check whether a kb_name is already present in <database>_info.
function M:_kb_exists(kb_name)
    self.rt:clear_filters()
    self.rt:search_kb(kb_name)
    local rows = self.rt:execute_kb_search()
    return rows and #rows > 0
end

-- Load the leaves already declared in the DB for a given kb_name. Used on
-- process restart against a populated DB — without it, the in-memory cache
-- is empty and apply_topology() would mark every announced leaf as new,
-- re-call construct_kb's add_*_field, and crash with UNIQUE constraint
-- failed on knowledge_base.path.
--
-- Returns: map of leaf-tail -> minimal leaf info table (compatible with
-- the `desired` shape used by apply_topology for diff purposes).
function M:_load_existing_leaves(kb_name, class, instance)
    local out = {}
    for _, kind in ipairs({ "stream", "status" }) do
        self.rt:clear_filters()
        self.rt:search_kb(kb_name)
        self.rt:search_label(kind)
        local rows = self.rt:execute_kb_search() or {}
        for _, row in ipairs(rows) do
            local name = row.name        -- "cimis.station.sample"
            local ltp  = row.path        -- "kb_name.stream.cimis.station.sample"
            if name and ltp then
                local tail = (name:gsub("%.", "/"))   -- "cimis/station/sample"
                out[tail] = {
                    tail       = tail,
                    full_key   = class .. "/" .. instance .. "/" .. tail,
                    kind       = kind,
                    ltree_path = ltp,
                    -- length / desc deliberately omitted: this entry is
                    -- only used by the diff (apply_topology overwrites
                    -- state.leaves from `desired` at the end of the call).
                }
            end
        end
    end
    return out
end

-- Two-phase apply. The historical apply_topology is preserved as a thin
-- wrapper for compatibility, but the driver should prefer the split form:
--
--   diff_topology()       -- FAST: builds desired/existing diff, returns
--                            (state, added, removed). Caller opens subs
--                            NOW so messages arriving during the slow
--                            reconcile buffer in the sub queue (depth 64).
--   reconcile_schema()    -- SLOW: declares construct_kb stream/status
--                            fields for leaves not already in the DB.
--
-- The original ordering (apply_topology = diff + reconcile, then caller
-- opens subs) caused stream subs to miss every initial publish (moisture's
-- 68-uplink backfill, cimis's 7-day historical seed) because reconcile
-- took ~3-5s on a fresh DB while publishes were already in flight. With
-- subs opened BEFORE reconcile, sub queues buffer through reconcile and
-- the pump's first post-reconcile drain dispatches them all.
function M:diff_topology(class, instance, entries)
    assert(type(class) == "string" and class ~= "", "class required")
    assert(type(instance) == "string" and instance ~= "", "instance required")
    assert(type(entries) == "table", "entries must be a list")

    local instance_key = class .. "/" .. instance
    local kb_name      = class .. "_" .. instance

    -- 1. Compute desired leaves from the announce.
    local desired = {}
    for _, e in ipairs(entries) do
        if e.kind == "stream" or e.kind == "status" then
            local field = tail_to_field(e.path)
            desired[e.path] = {
                tail       = e.path,
                full_key   = class .. "/" .. instance .. "/" .. e.path,
                kind       = e.kind,
                length     = e.length,
                desc       = e.desc,
                ltree_path = string.format("%s.%s.%s", kb_name, e.kind, field),
            }
        else
            io.stderr:write(string.format(
                "PERSISTENCE: skipping entry with unknown kind '%s' (path=%s)\n",
                tostring(e.kind), tostring(e.path)))
        end
    end

    -- 2. Diff desired vs existing (in-memory cache only). On a process
    -- restart, in-memory state is empty so EVERY desired leaf appears as
    -- "added" — which is correct for the caller's sub-opening side (we
    -- DO need to open zenoh subs every restart). The DB-existence check
    -- happens separately in step 4 to suppress the schema INSERT for
    -- leaves the DB already has.
    local state    = self.instances[instance_key]
    local existing = (state and state.leaves) or {}
    local added, removed = {}, {}
    for tail, leaf in pairs(desired) do
        if not existing[tail] then added[tail] = leaf end
    end
    for tail, leaf in pairs(existing) do
        if not desired[tail] then removed[tail] = leaf end
    end

    -- 3. Establish (or update) the instance state so the caller can open
    -- subs immediately. state.constructed stays false until reconcile_schema
    -- finishes — but the pump dispatches messages from sub queues only
    -- after handle_topology returns, by which time both phases have run.
    state = state or { class = class, instance = instance, kb_name = kb_name }
    state.desired         = desired                  -- handed to reconcile_schema
    state.kb_already      = self:_kb_exists(kb_name) -- captured once per call
    state.pending_added   = added                    -- for reconcile_schema's loop
    state.pending_removed = removed                  -- for diagnostics only
    self.instances[instance_key] = state

    return state, added, removed
end

-- Phase 2: declare construct_kb stream/status fields for the leaves the DB
-- doesn't already have. Slow (~3-5s on a fresh DB). Call AFTER opening
-- zenoh subs so messages buffer in the sub queue while this runs.
function M:reconcile_schema(state)
    assert(state and state.kb_name, "state with kb_name required")
    if state.constructed then return end   -- idempotent

    local kb_name    = state.kb_name
    local added      = state.pending_added or {}
    local removed    = state.pending_removed or {}
    local desired    = state.desired
    local kb_already = state.kb_already

    -- Filter "added in announce" through "already in DB" — on a process
    -- restart, the in-memory cache is empty so `added` covers EVERY desired
    -- leaf, but many already exist in the DB. Calling construct_kb's
    -- add_*_field for those would crash with UNIQUE constraint failed.
    local db_existing = kb_already
        and self:_load_existing_leaves(kb_name, state.class, state.instance)
        or {}

    local schema_added = {}
    for tail, leaf in pairs(added) do
        if not db_existing[tail] then schema_added[tail] = leaf end
    end

    if next(schema_added) or not kb_already then
        io.stderr:write(string.format(
            "PERSISTENCE: schema reconcile kb=%s (+%d new leaves%s%s)\n",
            kb_name, count_keys(schema_added),
            kb_already and "" or ", new kb",
            (kb_already and count_keys(added) > count_keys(schema_added))
                and string.format(", %d already in DB",
                    count_keys(added) - count_keys(schema_added))
                or ""))

        local cdt = CDT.new(self.db_path, self.database, nil, true)   -- upload_flag=true: never DROP
        if kb_already then
            -- A fresh CDT instance has empty in-memory path tracking. To call
            -- select_kb on a kb that already exists in kb_info, mirror what
            -- add_kb does internally — minus the kb_info INSERT, which would
            -- create a duplicate row. This is a deliberate bypass of the
            -- public add_kb (which errors on existing kbs).
            cdt.kb.path[kb_name]        = { kb_name }
            cdt.kb.path_values[kb_name] = {}
        else
            cdt:add_kb(kb_name, "auto-declared from persistence_topology announce")
        end
        cdt:select_kb(kb_name)
        for _tail, leaf in pairs(schema_added) do
            local desc  = leaf.desc or leaf.tail
            local field = tail_to_field(leaf.tail)
            if leaf.kind == "stream" then
                cdt:add_stream_field(field, leaf.length or 100, desc)
            elseif leaf.kind == "status" then
                cdt:add_status_field(field, {}, desc, { value = nil })
            end
        end
        cdt:check_installation()
        cdt:disconnect()
    end

    if next(removed) then
        io.stderr:write(string.format(
            "PERSISTENCE: kb=%s — %d leaves removed from announce (data preserved)\n",
            kb_name, count_keys(removed)))
    end

    state.leaves         = desired
    state.constructed    = true
    state.pending_added  = nil
    state.pending_removed = nil
end

-- Compatibility wrapper for any caller that still expects the original
-- single-call apply_topology. New code should use diff_topology +
-- reconcile_schema explicitly so subs can open between the two phases.
function M:apply_topology(class, instance, entries)
    local state, added, removed = self:diff_topology(class, instance, entries)
    self:reconcile_schema(state)
    return state, added, removed
end

-- Dispatch a received Zenoh sample on a known leaf.
function M:dispatch(leaf_info, payload)
    local ok, data = pcall(cjson.decode, payload)
    if not ok or type(data) ~= "table" then
        io.stderr:write(string.format(
            "PERSISTENCE: bad JSON on %s: %s\n",
            leaf_info.full_key, tostring(data)))
        return false
    end
    if leaf_info.kind == "stream" then
        local ok2, err = pcall(function()
            self.rt:push_stream_data(leaf_info.ltree_path, data)
        end)
        if not ok2 then
            io.stderr:write(string.format(
                "PERSISTENCE: push_stream_data %s: %s\n",
                leaf_info.ltree_path, tostring(err)))
            return false
        end
        return true
    elseif leaf_info.kind == "status" then
        local ok2, err = pcall(function()
            self.rt:set_status_data(leaf_info.ltree_path, data)
        end)
        if not ok2 then
            io.stderr:write(string.format(
                "PERSISTENCE: set_status_data %s: %s\n",
                leaf_info.ltree_path, tostring(err)))
            return false
        end
        return true
    end
    return false
end

function M:close()
    if self.rt then
        self.rt:disconnect()
        self.rt = nil
    end
end

return M
