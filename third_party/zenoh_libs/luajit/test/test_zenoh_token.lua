#!/usr/bin/env luajit
--[[
  test_zenoh_token.lua — integration test for the LuaJIT FFI binding to
  libzenoh_token. No zenohd needed.
]]

package.path = package.path .. ";./?.lua"
local zt = require("lib.zenoh_token")

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

print("=== zenoh_token LuaJIT tests ===")

test("hash empty string", function()
    expect_eq(zt.hash(""), 0x811c9dc5, "empty FNV1a offset basis")
end)

test("hash 'a'", function()
    expect_eq(zt.hash("a"), 0xe40c292c, "single char vector")
end)

test("hash 'foobar'", function()
    expect_eq(zt.hash("foobar"), 0xbf9cf968, "foobar vector")
end)

test("hash is deterministic", function()
    expect_eq(zt.hash("robot/42/telemetry"), zt.hash("robot/42/telemetry"), "deterministic")
end)

test("hash distinct strings differ", function()
    expect(zt.hash("a") ~= zt.hash("b"), "a vs b")
end)

test("hash rejects non-string", function()
    local ok = pcall(zt.hash, nil)
    expect(not ok, "nil should error")
end)

test("hash_list batch matches scalar hash", function()
    local topics = { "sensor/temp", "sensor/hum", "sensor/baro" }
    local tokens = zt.hash_list(topics)
    expect_eq(#tokens, 3, "length")
    for i = 1, 3 do
        expect_eq(tokens[i], zt.hash(topics[i]), "list[" .. i .. "] matches scalar")
    end
end)

test("hash_list of zero length", function()
    local tokens = zt.hash_list({})
    expect_eq(#tokens, 0, "empty list returns empty")
end)

test("hash_list rejects non-table", function()
    expect(not pcall(zt.hash_list, "x"), "string rejected")
    expect(not pcall(zt.hash_list, 42),  "number rejected")
end)

test("hash_list rejects non-string entries", function()
    expect(not pcall(zt.hash_list, {"ok", 42, "ok"}), "mixed list rejected")
end)

test("register + lookup round trip", function()
    zt.registry_clear()
    local t = "robot/42/cmd"
    local h = zt.hash(t)
    expect_eq(zt.register(h, t), true, "register")
    expect_eq(zt.lookup(h), t, "lookup")
    expect_eq(zt.registry_size(), 1, "size 1")
end)

test("register same pair twice is no-op", function()
    zt.registry_clear()
    local t = "topic/x"
    local h = zt.hash(t)
    expect_eq(zt.register(h, t), true, "first")
    expect_eq(zt.register(h, t), true, "second (no-op, returns true)")
    expect_eq(zt.registry_size(), 1, "size still 1")
end)

test("register collision returns false", function()
    zt.registry_clear()
    expect_eq(zt.register(0xCAFEBABE, "topic_a"), true,  "first")
    expect_eq(zt.register(0xCAFEBABE, "topic_b"), false, "collision rejected (returns false)")
end)

test("lookup unregistered returns nil", function()
    zt.registry_clear()
    expect_eq(zt.lookup(0x12345678), nil, "unregistered lookup is nil")
end)

test("registry growth — register 200 entries", function()
    zt.registry_clear()
    local toks = {}
    for i = 0, 199 do
        local s = "topic/" .. i
        toks[i] = zt.hash(s)
        local ok = pcall(zt.register, toks[i], s)
        -- Allow occasional collision; only ZT_ERR_DUPLICATE is acceptable failure
        if not ok then expect(false, "unexpected error during growth") end
    end
    for i = 0, 199 do
        expect(zt.lookup(toks[i]) ~= nil, "lookup after growth")
    end
    zt.registry_clear()
    expect_eq(zt.registry_size(), 0, "clear empties registry")
end)

print()
print(string.format("zenoh_token tests: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
