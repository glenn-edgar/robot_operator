-- tests/test_portal_smoke.lua — live smoke against the real Rancho portal.
--
-- Reads RANCHO_WATER_ACCOUNT / RANCHO_WATER_PASSWORD from env (source
-- farm_soil/secrets/ttn.env first) and fetches yesterday's usage. Prints
-- a short summary so a human can eyeball correctness. NOT a unit test;
-- this hits production every run.
--
-- Run:
--   set -a; . farm_soil/secrets/ttn.env; set +a
--   LUA_PATH="../lib/?.lua;;" luajit test_portal_smoke.lua

local portal = require("rancho_portal")

local account = os.getenv("RANCHO_WATER_ACCOUNT_NUMBER") or "3047791"
local user    = assert(os.getenv("RANCHO_WATER_ACCOUNT"),
                       "RANCHO_WATER_ACCOUNT not set")
local pass    = assert(os.getenv("RANCHO_WATER_PASSWORD"),
                       "RANCHO_WATER_PASSWORD not set")

-- Yesterday in ISO. `date -d 'yesterday' +%Y-%m-%d` is one shell out away;
-- the Lua side stays trivial.
local f = io.popen("date -d 'yesterday' +%Y-%m-%d")
local iso = f:read("*l")
f:close()

print(string.format("test: fetching %s for account %s", iso, account))

local client = portal.new{
    account_number = account,
    username       = user,
    password       = pass,
}
local body, ok, err = client:fetch_day(iso)
if not ok then
    print("FAIL: " .. tostring(err))
    os.exit(1)
end

print(string.format("OK — %d bytes of JSON", #body))
-- Cheap correctness check: looks like a usage payload?
for _, field in ipairs({"AccountNumber", "Usage", "TotalGallons", "LeakDetected"}) do
    if not body:find('"' .. field .. '"', 1, true) then
        print("WARN: response missing field " .. field)
    end
end
print("first 600 chars:")
print(body:sub(1, 600))
