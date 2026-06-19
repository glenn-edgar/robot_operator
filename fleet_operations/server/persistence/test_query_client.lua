-- test_query_client.lua — smoke client for the persistence query RPC.
--
-- Subscribes to fleet/admin/persistence_service_announce to discover the
-- service, then calls list_kbs() and latest(kb_name, "heartbeat") against
-- every kb it learns about, and prints results.
--
-- Env: ZENOH_LOCATOR    (default tcp/127.0.0.1:7447)
--      DISCO_TIMEOUT_S  (default 10)

local ffi = require("ffi")
ffi.cdef[[ int usleep(unsigned int usec); ]]

local LOCATOR        = os.getenv("ZENOH_LOCATOR")    or "tcp/127.0.0.1:7447"
local DISCO_TIMEOUT  = tonumber(os.getenv("DISCO_TIMEOUT_S")) or 10
local TICK_US        = 50000   -- 50 ms

local zps   = require("zenoh_pubsub")
local zrpc  = require("zenoh_rpc")
local zt    = require("zenoh_token")
local cjson = require("cjson")

local function log(fmt, ...) print(string.format(fmt, ...)) end

local function rpc_call(cli, token_key, request_tbl, timeout_ms)
    local tok = zt.hash(token_key)
    zt.register(tok, token_key)
    local req_json = cjson.encode(request_tbl)
    local ok, reply = pcall(cli.call, cli, tok, req_json, timeout_ms or 5000)
    if not ok then return nil, tostring(reply) end
    local dec_ok, decoded = pcall(cjson.decode, reply)
    if not dec_ok then return nil, "reply not JSON: " .. tostring(decoded) end
    return decoded
end

-- ---------------------------------------------------------------------------
-- 1. Subscribe to announce, wait for one announce
-- ---------------------------------------------------------------------------
local ps = zps.PubSub.new({ locators = { LOCATOR }, client_name = "qtest-sub" })
ps:connect()

local DISCO = "fleet/admin/persistence_service_announce"
local disco_tok = zt.hash(DISCO)
zt.register(disco_tok, DISCO)
local sub = ps:subscribe(disco_tok, 8)

log("waiting up to %ds for an announce on %s ...", DISCO_TIMEOUT, DISCO)
local announce = nil
local deadline = os.time() + DISCO_TIMEOUT
while os.time() < deadline do
    local m = sub:poll()
    if m then
        local ok, obj = pcall(cjson.decode, m.payload)
        if ok and type(obj) == "table" then
            announce = obj
            break
        end
    end
    ffi.C.usleep(TICK_US)
end
ps:unsubscribe(sub)

if not announce then
    log("FAIL: no announce received in %ds", DISCO_TIMEOUT)
    os.exit(1)
end

log("== service announce ==")
log("  schema        : %s", announce.schema)
log("  service_id    : %s", announce.service_id)
log("  rpc_token_key : %s", announce.rpc_token_key)
log("  republish_s   : %s", tostring(announce.republish_s))
log("  max_page_rows : %s / max_reply_bytes: %s",
    tostring(announce.max_page_rows), tostring(announce.max_reply_bytes))
log("  query_schema  : %s", announce.query_schema)
log("  kbs (%d):", #(announce.kbs or {}))
for _, kb in ipairs(announce.kbs or {}) do
    log("    %s  (class=%s instance=%s)", kb.kb_name, kb.class, kb.instance)
end

if not announce.rpc_token_key then
    log("FAIL: announce has no rpc_token_key")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- 2. Open RPC client + call list_kbs()
-- ---------------------------------------------------------------------------
local cli = zrpc.Client.new({ locators = { LOCATOR }, client_name = "qtest-cli" })
cli:connect()

log("\n== list_kbs() ==")
local r, err = rpc_call(cli, announce.rpc_token_key, { op = "list_kbs", args = {} })
if not r then
    log("FAIL: list_kbs raised: %s", err); os.exit(1)
end
if not r.ok then
    log("FAIL: list_kbs returned error: %s / %s",
        r.error and r.error.code, r.error and r.error.msg); os.exit(1)
end
log("  ok, %d kb(s):", #r.data)
for _, kb in ipairs(r.data) do
    log("    %s (class=%s instance=%s leaf_count=%d)",
        kb.kb_name, kb.class, kb.instance, kb.leaf_count)
end

-- ---------------------------------------------------------------------------
-- 3. For each kb, call latest("heartbeat") — the one path every robot has.
-- ---------------------------------------------------------------------------
log("\n== latest(kb_name, 'heartbeat') for each kb ==")
local fail_count = 0
for _, kb in ipairs(r.data) do
    local r2, e2 = rpc_call(cli, announce.rpc_token_key, {
        op = "latest", args = { kb_name = kb.kb_name, path = "heartbeat" },
    })
    if not r2 then
        log("  %s heartbeat: RAISED %s", kb.kb_name, e2)
        fail_count = fail_count + 1
    elseif not r2.ok then
        log("  %s heartbeat: ERR %s / %s",
            kb.kb_name, r2.error.code, r2.error.msg)
        fail_count = fail_count + 1
    elseif r2.data == nil or r2.data == cjson.null then
        log("  %s heartbeat: null (no data yet)", kb.kb_name)
    else
        local val = r2.data
        log("  %s heartbeat: state=%s ts=%s apps=%s",
            kb.kb_name,
            tostring(val.state),
            tostring(val.ts),
            val.apps and ("[" .. table.concat((function()
                local n = {}; for k, v in pairs(val.apps) do
                    n[#n+1] = k .. "=" .. tostring(v.health or v.state or "?")
                end; return n
            end)(), ",") .. "]") or "?")
    end
end

-- ---------------------------------------------------------------------------
-- 4. Slice-2 ops: list_leaves / latest_stream / stream + pagination
-- ---------------------------------------------------------------------------
log("\n== list_leaves() for each kb ==")
local stream_leaf_by_kb = {}   -- kb_name -> first stream leaf path, for next step
for _, kb in ipairs(r.data) do
    local rl = rpc_call(cli, announce.rpc_token_key,
        { op = "list_leaves", args = { kb_name = kb.kb_name } })
    if not rl or not rl.ok then
        log("  %s: FAIL %s", kb.kb_name,
            (rl and rl.error and rl.error.code) or "rpc raised")
        fail_count = fail_count + 1
    else
        local n_stream, n_status = 0, 0
        local picked_stream
        for _, leaf in ipairs(rl.data) do
            if leaf.kind == "stream" then
                n_stream = n_stream + 1
                -- Prefer cimis/station/sample (predictable test data); else
                -- accept the first stream leaf alphabetically.
                if leaf.path == "cimis/station/sample" then
                    picked_stream = leaf.path
                end
                if not picked_stream and not stream_leaf_by_kb[kb.kb_name] then
                    stream_leaf_by_kb[kb.kb_name] = leaf.path
                end
            elseif leaf.kind == "status" then
                n_status = n_status + 1
            end
        end
        if picked_stream then stream_leaf_by_kb[kb.kb_name] = picked_stream end
        log("  %s: %d stream + %d status leaves; picked stream=%s",
            kb.kb_name, n_stream, n_status,
            tostring(stream_leaf_by_kb[kb.kb_name]))
    end
end

log("\n== latest_stream(kb_name, <picked>) ==")
for kb_name, path in pairs(stream_leaf_by_kb) do
    local rls = rpc_call(cli, announce.rpc_token_key,
        { op = "latest_stream", args = { kb_name = kb_name, path = path } })
    if not rls or not rls.ok then
        log("  %s %s: FAIL %s", kb_name, path,
            (rls and rls.error and rls.error.code) or "rpc raised")
        fail_count = fail_count + 1
    elseif rls.data == cjson.null then
        log("  %s %s: null (no rows yet)", kb_name, path)
    else
        log("  %s %s: id=%s recorded_at=%s value=%s",
            kb_name, path, tostring(rls.data.id),
            tostring(rls.data.recorded_at),
            cjson.encode(rls.data.value):sub(1, 80))
    end
end

log("\n== stream(...) pagination round-trip ==")
for kb_name, path in pairs(stream_leaf_by_kb) do
    local total, pages = 0, 0
    local cursor
    local LIMIT = 3
    local MAX_PAGES = 50   -- safety bound
    local seen_ids = {}
    repeat
        pages = pages + 1
        if pages > MAX_PAGES then
            log("  %s %s: aborted after %d pages (runaway?)", kb_name, path, pages - 1)
            fail_count = fail_count + 1
            break
        end
        local req = { op = "stream", args = {
            kb_name = kb_name, path = path,
            limit = LIMIT, order = "desc",
        }}
        if cursor then req.page = cursor end
        local rs = rpc_call(cli, announce.rpc_token_key, req)
        if not rs or not rs.ok then
            log("  %s %s: FAIL on page %d: %s", kb_name, path, pages,
                (rs and rs.error and rs.error.code) or "rpc raised")
            fail_count = fail_count + 1
            break
        end
        for _, row in ipairs(rs.data) do
            total = total + 1
            if seen_ids[row.id] then
                log("  %s %s: DUP row id=%d at page %d", kb_name, path, row.id, pages)
                fail_count = fail_count + 1
            end
            seen_ids[row.id] = true
        end
        cursor = rs.next_page
    until not cursor
    log("  %s %s: walked %d row(s) in %d page(s)", kb_name, path, total, pages)
end

-- ---------------------------------------------------------------------------
-- 5. Negative checks — ensure error envelope works
-- ---------------------------------------------------------------------------
log("\n== negative checks ==")

local r3 = rpc_call(cli, announce.rpc_token_key, { op = "nope", args = {} })
log("  unknown op       -> ok=%s code=%s",
    tostring(r3 and r3.ok), r3 and r3.error and r3.error.code)
if not (r3 and r3.ok == false and r3.error.code == "unsupported_op") then
    fail_count = fail_count + 1
end

local r4 = rpc_call(cli, announce.rpc_token_key,
    { op = "latest", args = { kb_name = "no_such_kb_xyz", path = "heartbeat" } })
log("  unknown kb_name  -> ok=%s code=%s",
    tostring(r4 and r4.ok), r4 and r4.error and r4.error.code)
if not (r4 and r4.ok == false and r4.error.code == "not_found") then
    fail_count = fail_count + 1
end

local r5 = rpc_call(cli, announce.rpc_token_key,
    { op = "latest", args = {} })
log("  missing args     -> ok=%s code=%s",
    tostring(r5 and r5.ok), r5 and r5.error and r5.error.code)
if not (r5 and r5.ok == false and r5.error.code == "bad_request") then
    fail_count = fail_count + 1
end

-- Stream with garbage cursor — should be bad_request, not internal.
local first_kb = (r.data[1] and r.data[1].kb_name) or nil
if first_kb and stream_leaf_by_kb[first_kb] then
    local r6 = rpc_call(cli, announce.rpc_token_key, {
        op = "stream", args = { kb_name = first_kb,
                                path = stream_leaf_by_kb[first_kb] },
        page = "not-a-real-cursor",
    })
    log("  invalid cursor   -> ok=%s code=%s",
        tostring(r6 and r6.ok), r6 and r6.error and r6.error.code)
    if not (r6 and r6.ok == false and r6.error.code == "bad_request") then
        fail_count = fail_count + 1
    end

    -- Stream on a status path — should be bad_request (wrong kind).
    local r7 = rpc_call(cli, announce.rpc_token_key, {
        op = "stream", args = { kb_name = first_kb, path = "heartbeat" },
    })
    log("  stream on status -> ok=%s code=%s",
        tostring(r7 and r7.ok), r7 and r7.error and r7.error.code)
    if not (r7 and r7.ok == false and r7.error.code == "bad_request") then
        fail_count = fail_count + 1
    end
end

cli:disconnect(); cli:destroy()

if fail_count > 0 then
    log("\nFAIL: %d check(s) failed", fail_count)
    os.exit(1)
end
log("\nOK: all checks passed")
