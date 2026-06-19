-- tests/test_discord_webhook.lua — discord_webhook unit tests.
--
-- Uses the `_post` injection seam (same shape as the Python `_post` ctor
-- parameter) so the tests run offline. Real-network smoke is a separate
-- script that needs DISCORD_WEBHOOK_URL.
--
-- Run from this directory:
--   LUA_PATH="../lib/?.lua;;" luajit test_discord_webhook.lua

local discord = require("discord_webhook")
local cjson   = require("cjson")

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok  " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

-- Capture seen post calls so each test can inspect them.
local function recording_post(seen, ok, err)
    return function(url, payload_json, timeout_s)
        seen[#seen + 1] = {
            url = url, payload = cjson.decode(payload_json),
            timeout = timeout_s,
        }
        return ok, err
    end
end

print("[1] happy path — content under 2000 chars, post returns ok")
do
    local seen = {}
    local logs = {}
    local ok, err = discord.send("https://example.invalid/x", "hello", {
        username = "bot1", _post = recording_post(seen, true, nil),
        logger = function(s) logs[#logs+1] = s end,
    })
    check(ok and err == nil, "returns (true, nil)")
    check(#seen == 1, "transport called exactly once")
    check(seen[1].url == "https://example.invalid/x", "url passed through")
    check(seen[1].payload.content == "hello", "content passed through")
    check(seen[1].payload.username == "bot1", "username passed through")
    check(#logs >= 1, "at least one log line emitted")
end

print("[2] empty content — no transport call, returns (false, ...)")
do
    local seen, logs = {}, {}
    local ok, err = discord.send("https://example.invalid/x", "", {
        _post = recording_post(seen, true, nil),
        logger = function(s) logs[#logs+1] = s end,
    })
    check(not ok, "returns false")
    check(err == "content is empty", "returns error message")
    check(#seen == 0, "transport NOT called")
end

print("[3] empty webhook url — no transport call, returns (false, ...)")
do
    local seen = {}
    local ok, err = discord.send("", "hi", { _post = recording_post(seen, true, nil) })
    check(not ok, "returns false")
    check(err == "webhook_url is empty", "returns error message")
    check(#seen == 0, "transport NOT called")
end

print("[4] over-limit content — truncated with ellipsis, logged")
do
    local seen, logs = {}, {}
    local long = string.rep("a", 2500)
    local ok, err = discord.send("https://example.invalid/x", long, {
        _post = recording_post(seen, true, nil),
        logger = function(s) logs[#logs+1] = s end,
    })
    check(ok and err == nil, "returns (true, nil)")
    check(#seen == 1, "transport called once")
    check(#seen[1].payload.content == discord.CONTENT_MAX,
        string.format("content trimmed to exactly %d chars", discord.CONTENT_MAX))
    check(seen[1].payload.content:sub(-3) == "...", "ellipsis appended")
    local truncated_logged = false
    for _, line in ipairs(logs) do
        if line:find("truncating", 1, true) then truncated_logged = true end
    end
    check(truncated_logged, "truncation logged")
end

print("[5] transport error propagates")
do
    local seen = {}
    local ok, err = discord.send("https://example.invalid/x", "hi", {
        _post = recording_post(seen, false, "HTTP 404 Not Found: webhook deleted"),
    })
    check(not ok, "returns false")
    check(err == "HTTP 404 Not Found: webhook deleted",
        "error message propagates verbatim")
end

print("[6] default username when not specified")
do
    local seen = {}
    discord.send("https://example.invalid/x", "hi", {
        _post = recording_post(seen, true, nil),
    })
    check(seen[1].payload.username == discord.DEFAULT_USERNAME,
        "default username applied")
end

if failures == 0 then
    print("\nALL OK")
    os.exit(0)
else
    print(string.format("\n%d FAIL", failures))
    os.exit(1)
end
