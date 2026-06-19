--[[
  zenoh_rpc.lua — LuaJIT FFI binding for libzenoh_rpc

  Two roles:

  Client side — synchronous _call(). The C library blocks the calling
  thread on pthread_cond_timedwait; no Lua callback runs on a foreign
  thread.

      local cli = zrpc.Client.new({ locators = { "udp/127.0.0.1:7447" } })
      cli:connect()
      local reply = cli:call(zt.hash("math.add"), '{"a":5,"b":3}', 5000)
      cli:disconnect(); cli:destroy()

  Server side — queue+poll. zenoh-pico's read thread pushes incoming
  queries onto a C-side ring buffer; Lua polls from the main loop. NO
  Lua callbacks on foreign threads (same pattern as pub_sub).

      local srv = zrpc.Server.new({ locators = { "udp/127.0.0.1:7447" } })
      local q   = srv:register(zt.hash("math.add"), 32)  -- queue depth 32
      srv:start()
      while running do
          local req = q:poll()
          if req then
              -- req.token, req.payload (string)
              local ok, response = pcall(handle_math_add, req.payload)
              if ok then req:reply(response)
              else        req:reply_error(tostring(response)) end
          else
              os.execute("sleep 0.01")
          end
      end
      srv:stop(); srv:destroy()
]]

local ffi = require("ffi")

ffi.cdef[[
typedef enum {
    ZRPC_OK = 0,
    ZRPC_ERR_INVALID_ARG,
    ZRPC_ERR_CONNECTION,
    ZRPC_ERR_TIMEOUT,
    ZRPC_ERR_MEMORY,
    ZRPC_ERR_NOT_CONNECTED,
    ZRPC_ERR_NO_REPLY,
    ZRPC_ERR_HANDLER,
    ZRPC_ERR_ZENOH
} zrpc_status_t;

const char *zrpc_status_str(zrpc_status_t st);

typedef struct {
    const char *const *locators;
    size_t             n_locators;
    const char        *mode;
    bool               enable_scout;
    const char        *client_name;
} ZenohRpcConfig;

void zenoh_rpc_config_defaults(ZenohRpcConfig *cfg);

typedef struct ZenohRpcClient ZenohRpcClient;
typedef struct ZenohRpcServer ZenohRpcServer;
typedef struct ZenohRpcServerQueue ZenohRpcServerQueue;
typedef struct ZenohRpcRequest ZenohRpcRequest;

zrpc_status_t zenoh_rpc_client_create(ZenohRpcClient **out, const ZenohRpcConfig *cfg);
void          zenoh_rpc_client_destroy(ZenohRpcClient *cli);
zrpc_status_t zenoh_rpc_client_connect(ZenohRpcClient *cli);
zrpc_status_t zenoh_rpc_client_disconnect(ZenohRpcClient *cli);

zrpc_status_t zenoh_rpc_client_call(ZenohRpcClient *cli,
                                    uint32_t token,
                                    const uint8_t *req, size_t req_len,
                                    uint32_t timeout_ms,
                                    uint8_t **resp, size_t *resp_len);

/* Server side */
zrpc_status_t zenoh_rpc_server_create(ZenohRpcServer **out, const ZenohRpcConfig *cfg);
void          zenoh_rpc_server_destroy(ZenohRpcServer *srv);
zrpc_status_t zenoh_rpc_server_start(ZenohRpcServer *srv);
zrpc_status_t zenoh_rpc_server_stop(ZenohRpcServer *srv);

zrpc_status_t zenoh_rpc_server_register_queue(ZenohRpcServer *srv,
                                              uint32_t token,
                                              size_t queue_depth,
                                              ZenohRpcServerQueue **out_q);
zrpc_status_t zenoh_rpc_server_poll(ZenohRpcServerQueue *q,
                                    ZenohRpcRequest **out_req);
size_t        zenoh_rpc_server_pending(ZenohRpcServerQueue *q);
size_t        zenoh_rpc_server_dropped(ZenohRpcServerQueue *q);

uint32_t       zenoh_rpc_request_token(const ZenohRpcRequest *req);
const uint8_t *zenoh_rpc_request_payload(const ZenohRpcRequest *req);
size_t         zenoh_rpc_request_payload_len(const ZenohRpcRequest *req);

zrpc_status_t  zenoh_rpc_request_reply(ZenohRpcRequest *req,
                                       const uint8_t *payload, size_t len);
zrpc_status_t  zenoh_rpc_request_reply_error(ZenohRpcRequest *req,
                                             const char *errmsg);
void           zenoh_rpc_request_drop(ZenohRpcRequest *req);

void  free(void *);
]]

local C = ffi.load("zenoh_rpc")

local function check(st, where)
    if st ~= C.ZRPC_OK then
        error((where or "zenoh_rpc") .. ": " ..
              ffi.string(C.zrpc_status_str(st)), 2)
    end
end

local Client = {}
Client.__index = Client

function Client.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Client)
    self._keep = {}

    local function build_cstr_array(strs)
        if not strs or #strs == 0 then return nil, 0 end
        local arr = ffi.new("const char *[?]", #strs)
        for i = 1, #strs do
            local s = strs[i]
            local cs = ffi.cast("const char *", s)
            arr[i - 1] = cs
            table.insert(self._keep, s)
            table.insert(self._keep, cs)
        end
        table.insert(self._keep, arr)
        return arr, #strs
    end

    local cfg = ffi.new("ZenohRpcConfig")
    C.zenoh_rpc_config_defaults(cfg)
    local locs_arr, locs_n = build_cstr_array(opts.locators)
    cfg.locators     = locs_arr
    cfg.n_locators   = locs_n
    cfg.mode         = opts.mode         or "client"
    cfg.enable_scout = opts.enable_scout or false
    cfg.client_name  = opts.client_name
    table.insert(self._keep, cfg.mode)
    if cfg.client_name then table.insert(self._keep, cfg.client_name) end

    local h = ffi.new("ZenohRpcClient*[1]")
    check(C.zenoh_rpc_client_create(h, cfg), "Client.new")
    self._handle = h[0]
    self._connected = false
    return self
end

function Client:connect()
    check(C.zenoh_rpc_client_connect(self._handle), "Client:connect")
    self._connected = true
end

function Client:disconnect()
    if self._connected then
        check(C.zenoh_rpc_client_disconnect(self._handle), "Client:disconnect")
        self._connected = false
    end
end

function Client:destroy()
    if self._handle ~= nil then
        if self._connected then self:disconnect() end
        C.zenoh_rpc_client_destroy(self._handle)
        self._handle = nil
    end
end

--- Synchronous RPC call.
-- @param token       uint32 method token
-- @param req         request payload string (may be "" or nil)
-- @param timeout_ms  timeout in milliseconds (default 5000)
-- @return            reply payload string, or raises on timeout / error
function Client:call(token, req, timeout_ms)
    if type(token) ~= "number" then
        error("Client:call: token must be a number", 2)
    end
    req = req or ""
    if type(req) ~= "string" then
        error("Client:call: req must be a string", 2)
    end
    timeout_ms = timeout_ms or 5000

    local req_buf = (#req > 0) and ffi.cast("const uint8_t *", req) or nil
    local resp_pp = ffi.new("uint8_t*[1]")
    local resp_lp = ffi.new("size_t[1]")
    local st = C.zenoh_rpc_client_call(self._handle, token,
                                       req_buf, #req,
                                       timeout_ms,
                                       resp_pp, resp_lp)
    if st == C.ZRPC_ERR_TIMEOUT then
        if resp_pp[0] ~= nil then C.free(resp_pp[0]) end
        error("Client:call: timeout after " .. timeout_ms .. "ms", 2)
    end
    if st == C.ZRPC_ERR_HANDLER then
        -- Server returned an error reply; payload carries the error string.
        local emsg = resp_pp[0] ~= nil and ffi.string(resp_pp[0], resp_lp[0]) or ""
        if resp_pp[0] ~= nil then C.free(resp_pp[0]) end
        error("Client:call: handler error: " .. emsg, 2)
    end
    check(st, "Client:call")

    local payload = (resp_pp[0] ~= nil and resp_lp[0] > 0)
                       and ffi.string(resp_pp[0], resp_lp[0])
                       or ""
    if resp_pp[0] ~= nil then C.free(resp_pp[0]) end
    return payload
end

-- ------------------------------------------------------------------
--  Server side — queue+poll
-- ------------------------------------------------------------------

local Request = {}
Request.__index = Request

function Request:token()       return tonumber(C.zenoh_rpc_request_token(self._handle)) end
function Request:payload()
    local p = C.zenoh_rpc_request_payload(self._handle)
    local n = tonumber(C.zenoh_rpc_request_payload_len(self._handle))
    if p == nil or n == 0 then return "" end
    return ffi.string(p, n)
end

function Request:reply(payload)
    if self._consumed then error("Request:reply: already replied/dropped", 2) end
    payload = payload or ""
    if type(payload) ~= "string" then
        error("Request:reply: payload must be a string", 2)
    end
    local buf = (#payload > 0) and ffi.cast("const uint8_t *", payload) or nil
    local st = C.zenoh_rpc_request_reply(self._handle, buf, #payload)
    self._consumed = true
    self._handle = nil
    if st ~= C.ZRPC_OK then
        error("Request:reply: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
end

function Request:reply_error(msg)
    if self._consumed then error("Request:reply_error: already replied/dropped", 2) end
    msg = msg or "error"
    if type(msg) ~= "string" then msg = tostring(msg) end
    local st = C.zenoh_rpc_request_reply_error(self._handle, msg)
    self._consumed = true
    self._handle = nil
    if st ~= C.ZRPC_OK then
        error("Request:reply_error: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
end

function Request:drop()
    if self._consumed then return end
    C.zenoh_rpc_request_drop(self._handle)
    self._consumed = true
    self._handle = nil
end

-- Queue handle wrapping ZenohRpcServerQueue
local Queue = {}
Queue.__index = Queue

function Queue:poll()
    local h = ffi.new("ZenohRpcRequest*[1]")
    local st = C.zenoh_rpc_server_poll(self._handle, h)
    if st == C.ZRPC_ERR_NO_REPLY then return nil end
    if st ~= C.ZRPC_OK then
        error("Queue:poll: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
    return setmetatable({ _handle = h[0], _consumed = false }, Request)
end

function Queue:pending() return tonumber(C.zenoh_rpc_server_pending(self._handle)) end
function Queue:dropped() return tonumber(C.zenoh_rpc_server_dropped(self._handle)) end

-- Server class
local Server = {}
Server.__index = Server

function Server.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Server)
    self._keep = {}
    self._queues = {}    -- prevent GC of queue handles

    local function build_cstr_array(strs)
        if not strs or #strs == 0 then return nil, 0 end
        local arr = ffi.new("const char *[?]", #strs)
        for i = 1, #strs do
            local s = strs[i]
            local cs = ffi.cast("const char *", s)
            arr[i - 1] = cs
            table.insert(self._keep, s)
            table.insert(self._keep, cs)
        end
        table.insert(self._keep, arr)
        return arr, #strs
    end

    local cfg = ffi.new("ZenohRpcConfig")
    C.zenoh_rpc_config_defaults(cfg)
    local locs_arr, locs_n = build_cstr_array(opts.locators)
    cfg.locators     = locs_arr
    cfg.n_locators   = locs_n
    cfg.mode         = opts.mode         or "client"
    cfg.enable_scout = opts.enable_scout or false
    cfg.client_name  = opts.client_name
    table.insert(self._keep, cfg.mode)
    if cfg.client_name then table.insert(self._keep, cfg.client_name) end

    local h = ffi.new("ZenohRpcServer*[1]")
    local st = C.zenoh_rpc_server_create(h, cfg)
    if st ~= C.ZRPC_OK then
        error("Server.new: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
    self._handle  = h[0]
    self._running = false
    return self
end

function Server:register(token, queue_depth)
    if type(token) ~= "number" then
        error("Server:register: token must be a number", 2)
    end
    queue_depth = queue_depth or 32
    local h = ffi.new("ZenohRpcServerQueue*[1]")
    local st = C.zenoh_rpc_server_register_queue(self._handle, token, queue_depth, h)
    if st ~= C.ZRPC_OK then
        error("Server:register: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
    local q = setmetatable({ _handle = h[0], _server = self }, Queue)
    table.insert(self._queues, q)
    return q
end

function Server:start()
    local st = C.zenoh_rpc_server_start(self._handle)
    if st ~= C.ZRPC_OK then
        error("Server:start: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
    self._running = true
end

function Server:stop()
    if not self._running then return end
    local st = C.zenoh_rpc_server_stop(self._handle)
    if st ~= C.ZRPC_OK then
        error("Server:stop: " .. ffi.string(C.zrpc_status_str(st)), 2)
    end
    self._running = false
end

function Server:destroy()
    if self._handle ~= nil then
        if self._running then self:stop() end
        C.zenoh_rpc_server_destroy(self._handle)
        self._handle = nil
        self._queues = {}
    end
end

return { Client = Client, Server = Server, Queue = Queue, Request = Request, _C = C }
