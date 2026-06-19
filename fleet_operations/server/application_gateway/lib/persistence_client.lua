-- server/application_gateway/lib/persistence_client.lua
--
-- Typed wrapper around the persistence query RPC. Opens one zenoh_rpc
-- Client at construction; each method encodes a request, calls, decodes.
-- All errors surface as `nil, err_table` where err_table is the server's
-- {code, msg} envelope OR a synthetic table for transport failures.

local cjson = require("cjson")
local zrpc  = require("zenoh_rpc")
local zt    = require("zenoh_token")

local M = {}
M.__index = M

local DEFAULT_TOPIC = "fleet/persistence/query"

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({
        topic       = opts.topic    or DEFAULT_TOPIC,
        timeout_ms  = opts.timeout_ms or 5000,
        locator     = opts.locator  or "tcp/127.0.0.1:7447",
        client_name = opts.client_name or "application_gateway",
    }, M)

    self._tok = zt.hash(self.topic)
    zt.register(self._tok, self.topic)

    self._cli = zrpc.Client.new({
        locators    = { self.locator },
        client_name = self.client_name,
    })
    self._cli:connect()
    return self
end

function M:close()
    if self._cli then
        pcall(self._cli.disconnect, self._cli)
        pcall(self._cli.destroy,    self._cli)
        self._cli = nil
    end
end

-- Make one RPC call. Returns (data, nil) on ok; (nil, err) on error.
-- `err` is { code = "...", msg = "..." } whether server-side or transport.
function M:_call(op, args, page)
    local req = { op = op, args = args or {} }
    if page then req.page = page end
    local ok, reply_json = pcall(self._cli.call, self._cli, self._tok,
        cjson.encode(req), self.timeout_ms)
    if not ok then
        return nil, { code = "transport", msg = tostring(reply_json) }
    end
    local dec_ok, decoded = pcall(cjson.decode, reply_json)
    if not dec_ok then
        return nil, { code = "decode", msg = "reply not JSON" }
    end
    if not decoded.ok then
        return nil, decoded.error or { code = "unknown", msg = "no error obj" }
    end
    return decoded, nil   -- caller picks data / next_page off the table
end

-- Typed wrappers.
function M:list_kbs()
    return self:_call("list_kbs", {})
end
function M:list_leaves(kb_name)
    return self:_call("list_leaves", { kb_name = kb_name })
end
function M:latest(kb_name, path)
    return self:_call("latest", { kb_name = kb_name, path = path })
end
function M:latest_stream(kb_name, path)
    return self:_call("latest_stream", { kb_name = kb_name, path = path })
end
function M:stream(kb_name, path, opts)
    opts = opts or {}
    local args = { kb_name = kb_name, path = path }
    if opts.limit    then args.limit    = opts.limit    end
    if opts.order    then args.order    = opts.order    end
    if opts.since_ts then args.since_ts = opts.since_ts end
    if opts.until_ts then args.until_ts = opts.until_ts end
    return self:_call("stream", args, opts.page)
end

return M
