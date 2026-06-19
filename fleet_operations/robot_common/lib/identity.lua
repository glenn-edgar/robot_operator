-- identity.lua — load robot identity from env + persist chip_uid state file
--
-- Required env: ROBOT_CLASS, ROBOT_INSTANCE
-- Optional env: IDENTITY_DIR (default "./identity")

local ffi   = require("ffi")
local bit   = require("bit")
local cjson = require("cjson")

ffi.cdef[[
    int mkdir(const char *pathname, unsigned int mode);
]]

local M = {}

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, "w")
    if not f then
        error("identity: cannot write " .. path .. ": " .. tostring(err))
    end
    f:write(data)
    f:close()
end

local function gen_chip_uid()
    local f = assert(io.open("/dev/urandom", "rb"),
                     "identity: cannot open /dev/urandom")
    local raw = f:read(16)
    f:close()
    local b = { raw:byte(1, 16) }
    b[7] = bit.bor(bit.band(b[7], 0x0F), 0x40)  -- UUID v4 version nibble
    b[9] = bit.bor(bit.band(b[9], 0x3F), 0x80)  -- RFC 4122 variant
    return string.format(
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8],
        b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16])
end

local function ensure_dir(path)
    ffi.C.mkdir(path, 0x1ED)  -- 0755; existing-dir EEXIST is ignored
end

function M.load(opts)
    opts = opts or {}
    local fw_version = opts.fw_version or "unknown"

    local class = os.getenv("ROBOT_CLASS")
    if not class or class == "" then
        error("identity: ROBOT_CLASS env var is required")
    end
    local instance = os.getenv("ROBOT_INSTANCE")
    if not instance or instance == "" then
        error("identity: ROBOT_INSTANCE env var is required")
    end

    local dir = os.getenv("IDENTITY_DIR")
    if not dir or dir == "" then dir = "./identity" end
    ensure_dir(dir)

    local state_path = dir .. "/state.json"
    local raw = read_file(state_path)
    local state
    if raw then
        local ok, decoded = pcall(cjson.decode, raw)
        if not ok or type(decoded) ~= "table" then
            error("identity: malformed state.json at " .. state_path)
        end
        state = decoded
    else
        state = {}
    end

    if not state.chip_uid or state.chip_uid == "" then
        state.chip_uid  = gen_chip_uid()
        state.first_seen = os.time()
        state.fw_version = fw_version
        write_file(state_path, cjson.encode(state))
    end

    return {
        class      = class,
        instance   = instance,
        namespace  = class .. "/" .. instance,
        chip_uid   = state.chip_uid,
        first_seen = state.first_seen,
        fw_version = state.fw_version,
        dir        = dir,
    }
end

return M
