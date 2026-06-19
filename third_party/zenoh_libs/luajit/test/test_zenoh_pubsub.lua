#!/usr/bin/env luajit
--[[
  test_zenoh_pubsub.lua — integration test for the LuaJIT FFI binding to
  libzenoh_pubsub.

  Requires a running zenohd reachable at the locator below (default
  udp/127.0.0.1:17447). The C-side test fixture starts one with:

    docker run -d --name zenoh-test \
        -p 17447:7447/tcp -p 17447:7447/udp \
        eclipse/zenoh:latest \
        --listen tcp/0.0.0.0:7447 \
        --listen udp/0.0.0.0:7447

  Env vars:
    ZENOH_LOCATOR   default "udp/127.0.0.1:17447"
]]

package.path = package.path .. ";./?.lua"
local zps = require("lib.zenoh_pubsub")
local zt  = require("lib.zenoh_token")

local LOCATOR = os.getenv("ZENOH_LOCATOR") or "udp/127.0.0.1:17447"

local pass, fail = 0, 0
local function test(name, fn)
    io.write(string.format("  %-50s ", name))
    local ok, err = pcall(fn)
    if ok then pass = pass + 1; print("PASS")
    else fail = fail + 1; print("FAIL: " .. tostring(err)) end
end
local function expect(cond, msg) if not cond then error(msg or "assertion failed", 2) end end
local function expect_eq(a, b, msg)
    if a ~= b then
        error(string.format("%s: expected %s, got %s", msg or "mismatch", tostring(b), tostring(a)), 2)
    end
end

local function sleep_ms(ms)
    os.execute(string.format("sleep %f", ms / 1000.0))
end

print("=== zenoh_pubsub LuaJIT tests (locator=" .. LOCATOR .. ") ===")

test("PubSub.new + destroy (no connect)", function()
    local ps = zps.PubSub.new({ locators = { LOCATOR } })
    ps:destroy()
end)

test("PubSub: empty locators rejected", function()
    expect(not pcall(zps.PubSub.new, {}), "empty opts rejected")
    expect(not pcall(zps.PubSub.new, { locators = {} }), "empty locators rejected")
end)

test("PubSub: connect + disconnect", function()
    local ps = zps.PubSub.new({ locators = { LOCATOR } })
    ps:connect()
    ps:disconnect()
    ps:destroy()
end)

test("PubSub: end-to-end pub/sub round trip", function()
    -- Two sessions on the same zenohd: one publishes, one subscribes
    local pub = zps.PubSub.new({ locators = { LOCATOR } })
    local sub = zps.PubSub.new({ locators = { LOCATOR } })
    pub:connect(); sub:connect()

    local topic = zt.hash("e2e/luajit/round_trip")
    local s = sub:subscribe(topic, 16)

    sleep_ms(200)   -- declaration propagation

    pub:publish(topic, "alpha")
    pub:publish(topic, "beta")
    pub:publish(topic, "gamma")

    sleep_ms(300)   -- delivery

    -- Drain queue
    local got = {}
    while true do
        local msg = s:poll()
        if not msg then break end
        expect_eq(msg.token, topic, "token matches")
        got[#got + 1] = msg.payload
    end
    expect_eq(#got, 3, "received 3 messages")
    expect_eq(got[1], "alpha", "first")
    expect_eq(got[2], "beta",  "second")
    expect_eq(got[3], "gamma", "third")
    expect_eq(s:pending(), 0,  "queue drained")
    expect_eq(s:dropped(), 0,  "no overflow")

    sub:unsubscribe(s)
    pub:disconnect(); sub:disconnect()
    pub:destroy();    sub:destroy()
end)

test("PubSub: poll on empty queue returns nil", function()
    local pub = zps.PubSub.new({ locators = { LOCATOR } })
    pub:connect()
    local topic = zt.hash("e2e/luajit/empty")
    local s = pub:subscribe(topic, 8)
    sleep_ms(100)
    expect_eq(s:poll(), nil, "empty queue → nil")
    pub:unsubscribe(s)
    pub:disconnect()
    pub:destroy()
end)

test("PubSub: queue overflow drops oldest", function()
    local pub = zps.PubSub.new({ locators = { LOCATOR } })
    local sub = zps.PubSub.new({ locators = { LOCATOR } })
    pub:connect(); sub:connect()

    local topic = zt.hash("e2e/luajit/overflow")
    local s = sub:subscribe(topic, 4)   -- depth=4
    sleep_ms(200)

    -- Publish 10 messages without draining
    for i = 1, 10 do
        pub:publish(topic, "msg" .. i)
    end
    sleep_ms(500)

    -- After the dust settles, queue should hold at most 4 messages
    expect(s:pending() <= 4, "queue clamped to depth")
    -- Drain
    local count = 0
    while s:poll() do count = count + 1 end
    expect(count <= 4 and count > 0, "drained between 1 and 4 messages")
    expect(s:dropped() > 0, "some messages dropped due to overflow")

    sub:unsubscribe(s)
    pub:disconnect(); sub:disconnect()
    pub:destroy();    sub:destroy()
end)

print()
print(string.format("zenoh_pubsub tests: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
