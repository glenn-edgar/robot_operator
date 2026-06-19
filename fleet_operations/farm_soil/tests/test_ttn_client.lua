-- tests/test_ttn_client.lua — unit tests for lib/ttn_client.lua.
-- Run:  luajit tests/test_ttn_client.lua   (from the farm_soil directory)
--
-- Covers URL building (pure) and the fetch error path (curl against a
-- refused port). The success path is exercised by the live smoke run
-- against real TTN, per the skills convention.

package.path = "/home/gedgar/motioncore-prototype/fleet_design/farm_soil/lib/?.lua;"
            .. package.path

local ttn = require("ttn_client")

local fails = 0
local function check(label, got, want)
    if got == want then
        print("  ok   " .. label)
    else
        fails = fails + 1
        print(string.format("  FAIL %s — got %s want %s",
            label, tostring(got), tostring(want)))
    end
end

print("== request_url ==")
do
    local c = ttn.new{
        url_base     = "https://nam1.cloud.thethings.network/api/v3/as/applications/",
        app_name     = "seeedec",
        url_after    = "/packages/storage/uplink_message?",
        bearer_token = "SECRET_TOKEN_VALUE",
        limit        = 200,
    }
    check("url is built correctly",
        c:request_url("2026-05-22T00:00:00Z"),
        "https://nam1.cloud.thethings.network/api/v3/as/applications/seeedec"
        .. "/packages/storage/uplink_message?limit=200&after=2026-05-22T00:00:00Z")
    check("url carries no token",
        c:request_url("2026-05-22T00:00:00Z"):find("SECRET_TOKEN_VALUE", 1, true), nil)
end

print("== fetch — error path ==")
do
    -- Port 1 refuses; curl reports http_code 000. fetch must return cleanly.
    local c = ttn.new{
        url_base = "http://127.0.0.1:1/", app_name = "x", url_after = "?",
        bearer_token = "SECRET_TOKEN_VALUE", limit = 1, timeout_s = 3,
    }
    local body, ok, err = c:fetch("2026-01-01T00:00:00Z")
    check("refused connection: ok = false", ok, false)
    check("refused connection: body empty", body, "")
    check("refused connection: err is a string", type(err) == "string" and #err > 0, true)
end

if fails == 0 then
    print("\nALL PASS")
else
    print("\n" .. fails .. " FAILURE(S)")
    os.exit(1)
end
