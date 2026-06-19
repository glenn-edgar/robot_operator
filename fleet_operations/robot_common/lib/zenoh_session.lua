-- zenoh_session.lua — thin wrapper over libzenoh_pubsub for fake_robot
--
-- Adds on top of the C binding:
--   - topic-string API (token hashing hidden)
--   - per-subscription opaque user data
--   - poll_all() that aggregates queue drains across all subs
--
-- Caller is responsible for putting the zenoh binding's lib/ dir on
-- package.path and the .so dir on LD_LIBRARY_PATH.

local zps = require("zenoh_pubsub")
local zt  = require("zenoh_token")

local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local locators = opts.locators
    if not locators and opts.locator then locators = { opts.locator } end
    if not locators or #locators == 0 then
        error("zenoh_session: locator(s) required")
    end

    return setmetatable({
        _locators    = locators,
        _mode        = opts.mode or "client",
        _client_name = opts.client_name,
        _ps          = nil,
        _open        = false,
        _subs        = {},   -- list of { sub, topic, token, user }
    }, M)
end

function M:open()
    if self._open then return end
    self._ps = zps.PubSub.new({
        locators    = self._locators,
        mode        = self._mode,
        client_name = self._client_name,
    })
    self._ps:connect()
    self._open = true
end

function M:close()
    if not self._open then return end
    for _, rec in ipairs(self._subs) do
        if rec.sub then
            pcall(function() self._ps:unsubscribe(rec.sub) end)
            rec.sub = nil
        end
    end
    self._subs = {}
    self._ps:disconnect()
    self._ps:destroy()
    self._ps   = nil
    self._open = false
end

function M:is_open() return self._open end

function M:publish(topic, payload)
    if not self._open then error("zenoh_session: not open", 2) end
    local token = zt.hash(topic)
    zt.register(token, topic)        -- best-effort, duplicates silently ignored
    self._ps:publish(token, payload or "")
end

function M:subscribe(topic, user, queue_depth)
    if not self._open then error("zenoh_session: not open", 2) end
    local token = zt.hash(topic)
    zt.register(token, topic)
    local sub = self._ps:subscribe(token, queue_depth or 64)
    local rec = { sub = sub, topic = topic, token = token, user = user }
    table.insert(self._subs, rec)
    return rec
end

function M:unsubscribe(rec)
    if not rec or not rec.sub then return end
    self._ps:unsubscribe(rec.sub)
    rec.sub = nil
    for i, r in ipairs(self._subs) do
        if r == rec then table.remove(self._subs, i); break end
    end
end

-- Drain every subscription's queue. Returns a list of
--   { topic = <string>, payload = <string>, user = <opaque> }
-- in arrival order per-subscription (round-robin across subs).
function M:poll_all()
    local out = {}
    for _, rec in ipairs(self._subs) do
        if rec.sub then
            while true do
                local msg = rec.sub:poll()
                if not msg then break end
                out[#out + 1] = {
                    topic   = rec.topic,
                    payload = msg.payload,
                    user    = rec.user,
                }
            end
        end
    end
    return out
end

function M:pending()
    local total = 0
    for _, rec in ipairs(self._subs) do
        if rec.sub then total = total + rec.sub:pending() end
    end
    return total
end

return M
