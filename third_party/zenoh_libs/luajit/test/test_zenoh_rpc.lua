#!/usr/bin/env luajit
--[[
  test_zenoh_rpc.lua — integration test for the LuaJIT FFI binding to
  libzenoh_rpc (client side).

  We need a queryable on the other end. The C-side test exercises both
  client and server in the same process; from LuaJIT we only test the
  client, so we spawn the C-side rpc test binary as a background server
  if available. Otherwise we just verify timeout behaviour against a
  zenohd that has no matching queryables.

  Env vars:
    ZENOH_LOCATOR   default "udp/127.0.0.1:17447"
]]

package.path = package.path .. ";./?.lua"
local zrpc = require("lib.zenoh_rpc")
local zt   = require("lib.zenoh_token")

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

print("=== zenoh_rpc LuaJIT tests (locator=" .. LOCATOR .. ") ===")

test("Client.new + destroy (no connect)", function()
    local cli = zrpc.Client.new({ locators = { LOCATOR } })
    cli:destroy()
end)

test("Client: empty locators rejected", function()
    expect(not pcall(zrpc.Client.new, {}), "empty opts rejected")
end)

test("Client: connect + disconnect", function()
    local cli = zrpc.Client.new({ locators = { LOCATOR } })
    cli:connect()
    cli:disconnect()
    cli:destroy()
end)

test("Client:call against unregistered method raises", function()
    local cli = zrpc.Client.new({ locators = { LOCATOR } })
    cli:connect()
    local bogus = zt.hash("luajit/no/such/method")
    local ok, err = pcall(cli.call, cli, bogus, "", 300)
    expect(not ok, "call should raise (no queryable matches)")
    -- zenohd may respond with response-final-only ("no reply") or we may
    -- hit timeout — accept either.
    local s = tostring(err)
    expect(s:match("timeout") or s:match("no reply"),
           "error mentions timeout or no reply, got: " .. s)
    cli:disconnect()
    cli:destroy()
end)

-- ------------------------------------------------------------------
--  Server-side queue+poll
-- ------------------------------------------------------------------

local function sleep_ms(ms) os.execute(string.format("sleep %f", ms / 1000.0)) end

test("Server end-to-end queue+poll round trip", function()
    -- Single-threaded Lua can't both call() and poll() in one process,
    -- so we spawn a tiny client subprocess via io.popen, then poll +
    -- reply from the parent. The subprocess writes its reply to a file
    -- we read at the end.
    local srv = zrpc.Server.new({ locators = { LOCATOR } })
    local method = zt.hash("luajit/rpc/echo")
    local q = srv:register(method, 32)
    srv:start()
    sleep_ms(200)   -- queryable propagation

    local REPLY_FILE = "/tmp/zenoh_rpc_lj_reply.out"
    os.execute("rm -f " .. REPLY_FILE)

    -- Write the client driver to a tmp file (avoids shell quoting hell).
    local CLIENT_SCRIPT = "/tmp/zenoh_rpc_lj_client.lua"
    local f = io.open(CLIENT_SCRIPT, "w")
    f:write(string.format([[
package.path = package.path .. ";./?.lua"
local zrpc = require("lib.zenoh_rpc")
local cli  = zrpc.Client.new({ locators = { %q } })
cli:connect()
local r = cli:call(%d, "hello-from-client", 5000)
io.open(%q, "w"):write(r):close()
cli:disconnect(); cli:destroy()
]], LOCATOR, method, REPLY_FILE))
    f:close()

    -- Spawn it in the background, inheriting our LD_LIBRARY_PATH and cwd.
    local ld_path = os.getenv("LD_LIBRARY_PATH") or ""
    local ztop   = os.getenv("PWD") or "."
    local cmd = string.format(
        "(cd %s && LD_LIBRARY_PATH=%s luajit %s >/dev/null 2>&1) &",
        ztop, ld_path, CLIENT_SCRIPT)
    os.execute(cmd)

    -- Poll server-side and reply
    local replied = false
    for _ = 1, 250 do
        local req = q:poll()
        if req then
            expect_eq(req:token(), method, "token matches")
            expect_eq(req:payload(), "hello-from-client", "payload matches")
            req:reply("echo:" .. req:payload())
            replied = true
            break
        end
        sleep_ms(20)
    end
    expect(replied, "server received and replied")

    -- Wait for client subprocess to write the reply file
    local reply = nil
    for _ = 1, 250 do
        local rf = io.open(REPLY_FILE, "r")
        if rf then reply = rf:read("*a"); rf:close(); break end
        sleep_ms(20)
    end
    expect_eq(reply, "echo:hello-from-client", "client got echo reply")

    srv:stop()
    srv:destroy()
end)

test("Server: poll on empty queue returns nil", function()
    local srv = zrpc.Server.new({ locators = { LOCATOR } })
    local q = srv:register(zt.hash("luajit/rpc/empty"), 8)
    srv:start()
    sleep_ms(100)
    expect_eq(q:poll(), nil, "empty queue → nil")
    srv:stop()
    srv:destroy()
end)

print()
print(string.format("zenoh_rpc tests: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
