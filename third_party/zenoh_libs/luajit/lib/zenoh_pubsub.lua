--[[
  zenoh_pubsub.lua — LuaJIT FFI binding for libzenoh_pubsub

  Subscriber model:
    Uses the queue+poll C API (zenoh_pubsub_subscribe_queue + zenoh_pubsub_poll).
    NO Lua callbacks on foreign threads — incoming messages buffer C-side on
    zenoh-pico's read thread, and Lua drains them with poll() from its main
    loop. This is the LuaJIT-safe pattern per feedback_luajit_signal_safety.

  Usage:
    local zps  = require("lib.zenoh_pubsub")
    local zt   = require("lib.zenoh_token")

    local ps = zps.PubSub.new({
        locators = { "udp/127.0.0.1:7447" },
        mode     = "client",
    })
    ps:connect()

    local sub = ps:subscribe(zt.hash("sensor/temp"), 64)   -- depth=64

    ps:publish(zt.hash("sensor/temp"), '{"value":23.5}')

    -- Main loop drains the queue
    while running do
        local msg = sub:poll()        -- returns {token, payload} or nil
        if msg then
            print("got", msg.token, msg.payload)
        else
            os.execute("sleep 0.01")
        end
    end

    ps:unsubscribe(sub)
    ps:disconnect()
    ps:destroy()
]]

local ffi = require("ffi")

-- ------------------------------------------------------------------
--  C declarations
-- ------------------------------------------------------------------

ffi.cdef[[
typedef enum {
    ZPS_OK = 0,
    ZPS_ERR_INVALID_ARG,
    ZPS_ERR_CONNECTION,
    ZPS_ERR_TIMEOUT,
    ZPS_ERR_MEMORY,
    ZPS_ERR_NOT_CONNECTED,
    ZPS_ERR_ZENOH,
    ZPS_EMPTY
} zps_status_t;

const char *zps_status_str(zps_status_t st);

typedef struct {
    const char *const *locators;
    size_t             n_locators;
    const char *const *listen_locators;
    size_t             n_listen;
    const char        *mode;
    bool               enable_scout;
    const char        *client_name;
} ZenohPubSubConfig;

void zenoh_pubsub_config_defaults(ZenohPubSubConfig *cfg);

typedef struct ZenohPubSub    ZenohPubSub;
typedef struct ZenohPubSubSub ZenohPubSubSub;

zps_status_t zenoh_pubsub_create(ZenohPubSub **out, const ZenohPubSubConfig *cfg);
void         zenoh_pubsub_destroy(ZenohPubSub *ps);
zps_status_t zenoh_pubsub_connect(ZenohPubSub *ps);
zps_status_t zenoh_pubsub_disconnect(ZenohPubSub *ps);

zps_status_t zenoh_pubsub_publish(ZenohPubSub *ps, uint32_t token,
                                  const uint8_t *payload, size_t len);

/* Queue-mode subscribe (LuaJIT-safe; no FFI callback) */
zps_status_t zenoh_pubsub_subscribe_queue(ZenohPubSub *ps, uint32_t token,
                                          size_t queue_depth,
                                          ZenohPubSubSub **out);
zps_status_t zenoh_pubsub_poll(ZenohPubSubSub *sub,
                               uint32_t *out_token,
                               uint8_t  **out_payload,
                               size_t   *out_len);
size_t       zenoh_pubsub_pending(ZenohPubSubSub *sub);
size_t       zenoh_pubsub_dropped(ZenohPubSubSub *sub);
void         zenoh_pubsub_reset_dropped(ZenohPubSubSub *sub);
zps_status_t zenoh_pubsub_unsubscribe(ZenohPubSub *ps, ZenohPubSubSub *sub);

void  free(void *);
]]

local C = ffi.load("zenoh_pubsub")

local function check(st, where)
    if st ~= C.ZPS_OK then
        error((where or "zenoh_pubsub") .. ": " ..
              ffi.string(C.zps_status_str(st)), 2)
    end
end

-- ------------------------------------------------------------------
--  Subscription class
-- ------------------------------------------------------------------

local Sub = {}
Sub.__index = Sub

function Sub:poll()
    local tok = ffi.new("uint32_t[1]")
    local pp  = ffi.new("uint8_t*[1]")
    local lp  = ffi.new("size_t[1]")
    local st  = C.zenoh_pubsub_poll(self._handle, tok, pp, lp)
    if st == C.ZPS_EMPTY then return nil end
    if st ~= C.ZPS_OK then
        error("poll: " .. ffi.string(C.zps_status_str(st)), 2)
    end
    local payload = pp[0] ~= nil and ffi.string(pp[0], lp[0]) or ""
    if pp[0] ~= nil then C.free(pp[0]) end
    return { token = tonumber(tok[0]), payload = payload }
end

function Sub:pending() return tonumber(C.zenoh_pubsub_pending(self._handle)) end
function Sub:dropped() return tonumber(C.zenoh_pubsub_dropped(self._handle)) end
function Sub:reset_dropped() C.zenoh_pubsub_reset_dropped(self._handle) end

-- ------------------------------------------------------------------
--  PubSub class
-- ------------------------------------------------------------------

local PubSub = {}
PubSub.__index = PubSub

--- Create a new PubSub session.
-- @param opts table with:
--   locators (table of strings)        — required (or listen_locators)
--   listen_locators (table of strings) — optional
--   mode (string)                       — "client" or "peer" (default "client")
--   enable_scout (bool)                 — default false
--   client_name (string)                — optional
function PubSub.new(opts)
    opts = opts or {}

    local self = setmetatable({}, PubSub)
    self._subs = {}    -- active subscriptions; prevents GC of handles

    -- Keep Lua references to all string buffers so they're not GC'd
    -- while the C config struct holds pointers into them.
    self._keep = {}

    local function build_cstr_array(strs)
        if not strs or #strs == 0 then return nil, 0 end
        local arr = ffi.new("const char *[?]", #strs)
        for i = 1, #strs do
            -- ffi.string would copy; we need to keep the original Lua string
            -- alive AND give zenoh-pico the C pointer to it.
            local s = strs[i]
            local cs = ffi.cast("const char *", s)
            arr[i - 1] = cs
            table.insert(self._keep, s)
            table.insert(self._keep, cs)
        end
        table.insert(self._keep, arr)
        return arr, #strs
    end

    local cfg = ffi.new("ZenohPubSubConfig")
    C.zenoh_pubsub_config_defaults(cfg)

    local locs_arr,   locs_n   = build_cstr_array(opts.locators)
    local listen_arr, listen_n = build_cstr_array(opts.listen_locators)
    cfg.locators        = locs_arr
    cfg.n_locators      = locs_n
    cfg.listen_locators = listen_arr
    cfg.n_listen        = listen_n
    cfg.mode            = opts.mode         or "client"
    cfg.enable_scout    = opts.enable_scout or false
    cfg.client_name     = opts.client_name
    table.insert(self._keep, cfg.mode)
    if cfg.client_name then table.insert(self._keep, cfg.client_name) end

    local h = ffi.new("ZenohPubSub*[1]")
    check(C.zenoh_pubsub_create(h, cfg), "PubSub.new")
    self._handle = h[0]
    self._connected = false
    return self
end

function PubSub:connect()
    check(C.zenoh_pubsub_connect(self._handle), "PubSub:connect")
    self._connected = true
end

function PubSub:disconnect()
    if self._connected then
        check(C.zenoh_pubsub_disconnect(self._handle), "PubSub:disconnect")
        self._connected = false
    end
end

function PubSub:destroy()
    if self._handle ~= nil then
        if self._connected then self:disconnect() end
        C.zenoh_pubsub_destroy(self._handle)
        self._handle = nil
    end
end

function PubSub:publish(token, payload)
    if type(token) ~= "number" then
        error("PubSub:publish: token must be a number", 2)
    end
    if payload == nil then payload = "" end
    if type(payload) ~= "string" then
        error("PubSub:publish: payload must be a string", 2)
    end
    local buf = ffi.cast("const uint8_t *", payload)
    check(C.zenoh_pubsub_publish(self._handle, token, buf, #payload),
          "PubSub:publish")
end

--- Subscribe to a token with queue-based delivery.
-- @param token       uint32 token
-- @param queue_depth optional, defaults to 64
-- @return Sub object — call :poll() to drain
function PubSub:subscribe(token, queue_depth)
    if type(token) ~= "number" then
        error("PubSub:subscribe: token must be a number", 2)
    end
    queue_depth = queue_depth or 64
    local h = ffi.new("ZenohPubSubSub*[1]")
    check(C.zenoh_pubsub_subscribe_queue(self._handle, token, queue_depth, h),
          "PubSub:subscribe")
    local sub = setmetatable({ _handle = h[0], _ps = self }, Sub)
    self._subs[sub] = true
    return sub
end

function PubSub:unsubscribe(sub)
    if not sub or not sub._handle then return end
    check(C.zenoh_pubsub_unsubscribe(self._handle, sub._handle),
          "PubSub:unsubscribe")
    sub._handle = nil
    self._subs[sub] = nil
end

return { PubSub = PubSub, Sub = Sub, _C = C }
