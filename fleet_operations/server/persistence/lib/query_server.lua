-- server/persistence/lib/query_server.lua — RPC dispatcher for the
-- persistence query API. See QUERY_API.md for the contract.
--
-- This module is pure dispatch + envelope: zero Zenoh / FFI / file I/O.
-- Driver (main.lua) owns the RPC server, polls the queue, and calls
-- :handle(payload_str) -> reply_payload_str on every request.

local cjson = require("cjson")

-- Empty Lua tables encode as `[]` not `{}`. All v1 ops that can return
-- empty values return them as arrays (stream rows, list_kbs, list_leaves).
-- No op returns a semantically-empty object.
cjson.encode_empty_table_as_object(false)

local M = {}
M.__index = M

local SCHEMA_VERSION = "persistence_query/1"

-- Normalize a leaf path. Spec accepts both `cimis/station/sample` and
-- `cimis.station.sample`. Internal leaf tables are keyed by the `/` form
-- (matches what the robot announces), so normalize towards that.
local function normalize_tail(path)
    if type(path) ~= "string" or path == "" then return nil end
    return (path:gsub("%.", "/"))
end

local function ok_reply(data, next_page, stats)
    local r = { ok = true, data = data }
    if next_page then r.next_page = next_page end
    if stats     then r.stats     = stats     end
    return r
end

local function err_reply(code, msg)
    return { ok = false, error = { code = code, msg = msg or code } }
end

-- ------------------------------------------------------------------
-- Constructor
-- ------------------------------------------------------------------

function M.new(persistence, opts)
    assert(persistence, "persistence required")
    opts = opts or {}
    return setmetatable({
        p               = persistence,
        max_page_rows   = opts.max_page_rows   or 100,
        max_reply_bytes = opts.max_reply_bytes or 4096,
        log_fn          = opts.log_fn,   -- optional: function(fmt, ...)
    }, M)
end

function M:_log(fmt, ...)
    if self.log_fn then self.log_fn(fmt, ...) end
end

-- ------------------------------------------------------------------
-- Leaf lookup helper
-- ------------------------------------------------------------------

-- Find the instance state for a kb_name. p.instances is keyed by
-- "<class>/<instance>" not kb_name, so we scan. Caches as we go.
function M:_state_for_kb(kb_name)
    if self._kb_index and self._kb_index[kb_name] then
        return self._kb_index[kb_name]
    end
    self._kb_index = self._kb_index or {}
    for _, st in pairs(self.p.instances) do
        self._kb_index[st.kb_name] = st
    end
    return self._kb_index[kb_name]
end

-- Resolve (kb_name, path) -> leaf info, or (nil, err_reply).
function M:_resolve_leaf(args, expect_kind)
    if type(args) ~= "table" then
        return nil, err_reply("bad_request", "args must be an object")
    end
    local kb_name = args.kb_name
    local path    = args.path
    if type(kb_name) ~= "string" or kb_name == "" then
        return nil, err_reply("bad_request", "kb_name required")
    end
    local tail = normalize_tail(path)
    if not tail then
        return nil, err_reply("bad_request", "path required")
    end
    local st = self:_state_for_kb(kb_name)
    if not st then
        return nil, err_reply("not_found", "unknown kb_name: " .. kb_name)
    end
    local leaf = st.leaves and st.leaves[tail]
    if not leaf then
        return nil, err_reply("not_found",
            string.format("path '%s' not declared on kb '%s'", tail, kb_name))
    end
    if expect_kind and leaf.kind ~= expect_kind then
        return nil, err_reply("bad_request",
            string.format("path '%s' is kind '%s', expected '%s'",
                tail, leaf.kind, expect_kind))
    end
    return leaf
end

-- ------------------------------------------------------------------
-- Op handlers — v1 surface
-- ------------------------------------------------------------------

-- latest(kb_name, path) → status row or null.
function M:op_latest(args)
    local leaf, errr = self:_resolve_leaf(args, "status")
    if not leaf then return errr end
    local ok, data = pcall(function()
        return self.p.rt:get_status_data(leaf.ltree_path)
    end)
    if not ok then
        self:_log("op_latest %s: %s", leaf.ltree_path, tostring(data))
        return err_reply("internal", "get_status_data failed")
    end
    -- `data` may be nil (no value yet) or a structured object.
    return ok_reply(data == nil and cjson.null or data)
end

-- list_kbs() → list of kbs persistence currently knows about.
function M:op_list_kbs(_args)
    local out = {}
    for _, st in pairs(self.p.instances) do
        local n = 0
        if st.leaves then for _ in pairs(st.leaves) do n = n + 1 end end
        out[#out + 1] = {
            kb_name    = st.kb_name,
            class      = st.class,
            instance   = st.instance,
            leaf_count = n,
        }
    end
    table.sort(out, function(a, b) return a.kb_name < b.kb_name end)
    return ok_reply(out)
end

-- ------------------------------------------------------------------
-- Slice 2 ops: stream / latest_stream / list_leaves
-- ------------------------------------------------------------------

-- Pagination cursor for `stream`. Format: "<order>:<after_id>" — opaque
-- to the client. ID-based (not recorded_at): IDs are monotonic with
-- insertion, so a cursor of `id < last_id` resumes cleanly even if a
-- concurrent write lands during pagination (no dup, no skip).
local function make_cursor(order, after_id)
    return string.format("%s:%d", order, after_id)
end

local function parse_cursor(s)
    if type(s) ~= "string" then return nil end
    local order, after_id = s:match("^(%a+):(%d+)$")
    if not order or (order ~= "asc" and order ~= "desc") then return nil end
    return order, tonumber(after_id)
end

-- stream(kb_name, path, since_ts?, until_ts?, limit?, order?) with cursor.
function M:op_stream(args, page)
    local leaf, errr = self:_resolve_leaf(args, "stream")
    if not leaf then return errr end

    -- Resolve order + after_id. Cursor wins over args (so a paginated
    -- call can't accidentally switch direction mid-walk).
    local order = "desc"
    local after_id
    if page ~= nil and page ~= "" then
        local o, aid = parse_cursor(page)
        if not o then return err_reply("bad_request", "invalid page cursor") end
        order, after_id = o, aid
    elseif args.order ~= nil then
        if args.order ~= "asc" and args.order ~= "desc" then
            return err_reply("bad_request", "order must be 'asc' or 'desc'")
        end
        order = args.order
    end

    -- Resolve + cap limit.
    local limit = args.limit
    if limit ~= nil then
        if type(limit) ~= "number" or limit < 1 then
            return err_reply("bad_request", "limit must be a positive integer")
        end
        limit = math.min(math.floor(limit), self.max_page_rows)
    else
        limit = self.max_page_rows
    end

    -- Time-range filters are optional; pass through verbatim.
    if args.since_ts ~= nil and type(args.since_ts) ~= "number"
       and type(args.since_ts) ~= "string" then
        return err_reply("bad_request", "since_ts must be number or string")
    end
    if args.until_ts ~= nil and type(args.until_ts) ~= "number"
       and type(args.until_ts) ~= "string" then
        return err_reply("bad_request", "until_ts must be number or string")
    end

    local read_opts = {
        order           = order:upper(),
        order_by        = "id",
        limit           = limit + 1,   -- +1 → detect more-available
        after_id        = after_id,
        recorded_after  = args.since_ts,
        recorded_before = args.until_ts,
    }

    local rok, rows = pcall(function()
        return self.p.rt:list_stream_data(leaf.ltree_path, read_opts)
    end)
    if not rok then
        self:_log("op_stream %s: %s", leaf.ltree_path, tostring(rows))
        return err_reply("internal", "list_stream_data failed")
    end

    local more_available = #rows > limit
    if more_available then rows[#rows] = nil end

    local data = {}
    for _, r in ipairs(rows) do
        data[#data + 1] = {
            id          = r.id,
            recorded_at = r.recorded_at,
            value       = r.data,
        }
    end

    local reply = ok_reply(data)
    if more_available and #data > 0 then
        reply.next_page = make_cursor(order, data[#data].id)
    end

    -- Empty result is a valid reply; nothing to trim.
    if #data == 0 then return reply end

    -- Iterative size-trim. Encode here so we can drop trailing rows on
    -- overflow; the dispatcher re-encodes for the wire (cheap for ≤4 KB).
    while #data > 0 do
        local enc_ok, encoded = pcall(cjson.encode, reply)
        if not enc_ok then return err_reply("internal", "encode failed") end
        if #encoded <= self.max_reply_bytes then return reply end
        data[#data] = nil
        if #data > 0 then
            reply.next_page = make_cursor(order, data[#data].id)
        else
            reply.next_page = nil
        end
    end
    -- First (and only) row already exceeds the cap — the caller is
    -- storing oversized values; surface as a schema bug not a silent trunc.
    return err_reply("payload_too_big",
        "first stream row exceeds max_reply_bytes")
end

-- latest_stream(kb_name, path) — newest valid stream row or null.
function M:op_latest_stream(args)
    local leaf, errr = self:_resolve_leaf(args, "stream")
    if not leaf then return errr end
    local ok, row = pcall(function()
        return self.p.rt:get_latest_stream_data(leaf.ltree_path)
    end)
    if not ok then
        self:_log("op_latest_stream %s: %s", leaf.ltree_path, tostring(row))
        return err_reply("internal", "get_latest_stream_data failed")
    end
    if not row then return ok_reply(cjson.null) end
    return ok_reply({
        id          = row.id,
        recorded_at = row.recorded_at,
        value       = row.data,
    })
end

-- list_leaves(kb_name) — topology for one kb (paths + kinds).
function M:op_list_leaves(args)
    if type(args) ~= "table" then
        return err_reply("bad_request", "args must be an object")
    end
    if type(args.kb_name) ~= "string" or args.kb_name == "" then
        return err_reply("bad_request", "kb_name required")
    end
    local st = self:_state_for_kb(args.kb_name)
    if not st then
        return err_reply("not_found", "unknown kb_name: " .. args.kb_name)
    end
    local out = {}
    if st.leaves then
        for _, leaf in pairs(st.leaves) do
            local row = { path = leaf.tail, kind = leaf.kind }
            if leaf.length then row.length = leaf.length end
            if leaf.desc   then row.desc   = leaf.desc   end
            out[#out + 1] = row
        end
        table.sort(out, function(a, b) return a.path < b.path end)
    end
    return ok_reply(out)
end

-- ------------------------------------------------------------------
-- Dispatcher + envelope
-- ------------------------------------------------------------------

local DISPATCH = {
    latest         = "op_latest",
    list_kbs       = "op_list_kbs",
    stream         = "op_stream",
    latest_stream  = "op_latest_stream",
    list_leaves    = "op_list_leaves",
}

function M:handle(req_payload)
    -- Decode
    if type(req_payload) ~= "string" or req_payload == "" then
        return cjson.encode(err_reply("bad_request", "empty request"))
    end
    local ok, req = pcall(cjson.decode, req_payload)
    if not ok or type(req) ~= "table" then
        return cjson.encode(err_reply("bad_request", "invalid JSON"))
    end
    -- Dispatch
    local op = req.op
    if type(op) ~= "string" then
        return cjson.encode(err_reply("bad_request", "op required"))
    end
    local fn_name = DISPATCH[op]
    if not fn_name then
        return cjson.encode(err_reply("unsupported_op", "unknown op: " .. op))
    end
    local handler_ok, reply = pcall(self[fn_name], self, req.args or {}, req.page)
    if not handler_ok then
        self:_log("dispatch %s raised: %s", op, tostring(reply))
        return cjson.encode(err_reply("internal", "handler raised"))
    end
    -- Encode + size-cap
    local enc_ok, encoded = pcall(cjson.encode, reply)
    if not enc_ok then
        return cjson.encode(err_reply("internal", "encode failed: " .. tostring(encoded)))
    end
    if #encoded > self.max_reply_bytes then
        return cjson.encode(err_reply("payload_too_big",
            string.format("reply %d > max_reply_bytes %d",
                #encoded, self.max_reply_bytes)))
    end
    return encoded
end

-- ------------------------------------------------------------------
-- Service announce builder — driver encodes + publishes.
-- ------------------------------------------------------------------

-- opts = { service_id, rpc_token_key, republish_s }
function M:announce_payload(opts)
    assert(opts and opts.service_id     , "service_id required")
    assert(opts.rpc_token_key           , "rpc_token_key required")
    assert(opts.republish_s             , "republish_s required")
    local kbs = {}
    for _, st in pairs(self.p.instances) do
        kbs[#kbs + 1] = {
            kb_name  = st.kb_name,
            class    = st.class,
            instance = st.instance,
        }
    end
    table.sort(kbs, function(a, b) return a.kb_name < b.kb_name end)
    return {
        schema          = "persistence_service/1",
        service_id      = opts.service_id,
        rpc_token_key   = opts.rpc_token_key,
        republish_s     = opts.republish_s,
        max_page_rows   = self.max_page_rows,
        max_reply_bytes = self.max_reply_bytes,
        query_schema    = SCHEMA_VERSION,
        kbs             = kbs,
    }
end

return M
