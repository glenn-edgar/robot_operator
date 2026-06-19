--[[
  zenoh_token.lua — LuaJIT FFI binding for libzenoh_token (FNV1a-32 topic tokens)

  Usage:
    local zt = require("lib.zenoh_token")

    local t = zt.hash("robot/42/telemetry")    -- uint32 token

    local toks = zt.hash_list({"sensor/temp", "sensor/hum", "sensor/baro"})

    -- Optional debug registry
    zt.register(t, "robot/42/telemetry")
    print(zt.lookup(t))                         -- "robot/42/telemetry"

    -- Cleanup at shutdown
    zt.registry_clear()

  Notes:
    - Pure C, no callbacks, no threading concerns.
    - Tokens are 32-bit unsigned integers; comparisons and table keys
      use the same uint32_t value.
]]

local ffi = require("ffi")

ffi.cdef[[
typedef enum {
    ZT_OK = 0,
    ZT_ERR_INVALID_ARG,
    ZT_ERR_MEMORY,
    ZT_ERR_DUPLICATE,
    ZT_ERR_NOT_FOUND
} zt_status_t;

const char  *zt_status_str(zt_status_t st);

uint32_t     zt_hash(const char *topic);
zt_status_t  zt_hash_list(const char *const *topics, size_t n, uint32_t *out);

zt_status_t  zt_register(uint32_t token, const char *topic);
const char  *zt_lookup(uint32_t token);
void         zt_registry_clear(void);
size_t       zt_registry_size(void);
]]

local C = ffi.load("zenoh_token")

local M = {}
M._C = C

-- ------------------------------------------------------------------
--  Hash
-- ------------------------------------------------------------------

function M.hash(topic)
    if type(topic) ~= "string" then
        error("zt.hash: topic must be a string", 2)
    end
    return tonumber(C.zt_hash(topic))
end

--- Batch hash a list of strings → uint32 tokens.
-- @param topics table (sequence) of strings
-- @return table (sequence) of uint32 tokens
function M.hash_list(topics)
    if type(topics) ~= "table" then
        error("zt.hash_list: topics must be a table", 2)
    end
    local n = #topics
    if n == 0 then return {} end

    -- Build a C array of const char* + an out buffer of uint32_t
    local cstrs = ffi.new("const char *[?]", n)
    for i = 1, n do
        if type(topics[i]) ~= "string" then
            error("zt.hash_list: entry " .. i .. " is not a string", 2)
        end
        cstrs[i - 1] = topics[i]
    end
    local out = ffi.new("uint32_t[?]", n)
    local st = C.zt_hash_list(cstrs, n, out)
    if st ~= C.ZT_OK then
        error("zt.hash_list failed: " .. ffi.string(C.zt_status_str(st)))
    end
    local result = {}
    for i = 1, n do
        result[i] = tonumber(out[i - 1])
    end
    return result
end

-- ------------------------------------------------------------------
--  Registry (optional)
-- ------------------------------------------------------------------

function M.register(token, topic)
    if type(token) ~= "number" then
        error("zt.register: token must be a number", 2)
    end
    if type(topic) ~= "string" then
        error("zt.register: topic must be a string", 2)
    end
    local st = C.zt_register(token, topic)
    if st == C.ZT_OK then return true end
    if st == C.ZT_ERR_DUPLICATE then return false end
    error("zt.register failed: " .. ffi.string(C.zt_status_str(st)))
end

function M.lookup(token)
    if type(token) ~= "number" then
        error("zt.lookup: token must be a number", 2)
    end
    local p = C.zt_lookup(token)
    if p == nil then return nil end
    return ffi.string(p)
end

function M.registry_clear()
    C.zt_registry_clear()
end

function M.registry_size()
    return tonumber(C.zt_registry_size())
end

return M
