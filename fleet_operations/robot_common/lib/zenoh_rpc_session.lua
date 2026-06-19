-- zenoh_rpc_session.lua — thin wrapper over libzenoh_rpc's Client for fake_robot
--
-- Symmetric to lib/zenoh_session.lua but for the request-response (query/reply)
-- side. Hashes topic strings internally and converts the underlying binding's
-- raise-on-timeout to a (nil, err) return so chain_tree user fns can branch
-- cleanly without pcall boilerplate.

local zrpc = require("zenoh_rpc")
local zt   = require("zenoh_token")

local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local locators = opts.locators
    if not locators and opts.locator then locators = { opts.locator } end
    if not locators or #locators == 0 then
        error("zenoh_rpc_session: locator(s) required")
    end

    return setmetatable({
        _locators    = locators,
        _mode        = opts.mode or "client",
        _client_name = opts.client_name,
        _cli         = nil,
        _open        = false,
    }, M)
end

function M:open()
    if self._open then return end
    self._cli = zrpc.Client.new({
        locators    = self._locators,
        mode        = self._mode,
        client_name = self._client_name,
    })
    self._cli:connect()
    self._open = true
end

function M:close()
    if not self._open then return end
    self._cli:disconnect()
    self._cli:destroy()
    self._cli  = nil
    self._open = false
end

function M:is_open() return self._open end

-- Synchronous RPC call. Returns (reply_string, nil) on success or
-- (nil, err_string) on timeout / handler error / transport error.
-- Blocks the calling thread for up to timeout_ms (default 5000).
function M:call(topic, payload, timeout_ms)
    if not self._open then return nil, "rpc_session: not open" end
    local token = zt.hash(topic)
    zt.register(token, topic)
    local ok, result = pcall(function()
        return self._cli:call(token, payload or "", timeout_ms or 5000)
    end)
    if ok then return result, nil end
    return nil, tostring(result)
end

return M
