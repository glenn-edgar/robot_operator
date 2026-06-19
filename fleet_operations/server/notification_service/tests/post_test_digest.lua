-- tests/post_test_digest.lua — publish one synthetic digest payload on
-- fleet/notify/digest/daily so the notification_service receives + POSTs it.
--
-- Run from this directory (must be reachable via LD_LIBRARY_PATH / LUA_*
-- env — the same vars that run.sh sets):
--   LUA_PATH=... LUA_CPATH=... LD_LIBRARY_PATH=... \
--     luajit post_test_digest.lua
--
-- Verifies the wire path end-to-end: a producer (this script) → zenoh →
-- notification_service receiver → discord_webhook POST. Body is short and
-- self-identifying so a real Discord delivery is recognizable as a smoke.

local cjson = require("cjson")
local zps   = require("zenoh_pubsub")
local zt    = require("zenoh_token")

local LOCATOR = os.getenv("ZENOH_LOCATOR") or "tcp/127.0.0.1:7447"
local TOPIC   = "fleet/notify/digest/daily"

local ps = zps.PubSub.new({ locators = { LOCATOR }, client_name = "smoke-publisher" })
ps:connect()

local tok = zt.hash(TOPIC)
zt.register(tok, TOPIC)

local body = table.concat({
    "=== farm_soil daily report — 2026-05-24 (SMOKE) ===",
    "",
    "Moisture (per-device latest):",
    "  lacamia1b   0.218  ts=2026-05-24T08:00:00Z  (23 uplinks)",
    "  lacima1c    0.305  ts=2026-05-24T08:00:00Z  (24 uplinks)",
    "  lacima1d    0.142  ts=2026-05-24T08:00:00Z  (24 uplinks)",
    "",
    "ETo (CIMIS):",
    "  2026-05-23   0.183 (in)",
    "  2026-05-22   0.176 (in)",
}, "\n")

local payload = cjson.encode({
    schema   = "fleet.notify.digest/1",
    class    = "farm_soil",
    instance = "smoke",
    body     = body,
})

ps:publish(tok, payload)
io.stderr:write(string.format(
    "smoke-publisher: published %d-byte digest payload on %s\n",
    #payload, TOPIC))

-- Tiny linger so zenoh has time to send before we tear down.
do
    local ffi = require("ffi")
    pcall(ffi.cdef, "int usleep(unsigned int usec);")
    ffi.C.usleep(300000)   -- 300 ms
end

ps:disconnect()
ps:destroy()
io.stderr:write("smoke-publisher: done\n")
