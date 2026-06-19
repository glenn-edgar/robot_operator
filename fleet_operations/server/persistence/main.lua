-- server/persistence/main.lua — layer-30 persistence service driver.
--
-- Subscribes to the well-known discovery channel
-- `fleet/admin/persistence_topology_announce`; for each topology announce,
-- runs construct_kb idempotently and opens a specific Zenoh subscription per
-- leaf (per-announced-path: the token-hashed binding does not support
-- wildcard subs). Each leaf sub feeds push_stream_data or set_status_data.
--
-- Env:
--   ZENOH_LOCATOR    default tcp/127.0.0.1:7447
--   SERVICE_ID       default "persistence-1"
--   PERSISTENCE_DB   default /tmp/persistence.db
--
-- Launch via ./run.sh — it sets LUA_CPATH / LUA_PATH / LD_LIBRARY_PATH.

local ffi = require("ffi")
ffi.cdef[[
    int usleep(unsigned int usec);
    typedef void (*sighandler_t)(int);
    sighandler_t signal(int signum, sighandler_t handler);
]]
ffi.C.signal(13, ffi.cast("sighandler_t", 1))  -- ignore SIGPIPE

local script_dir = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
package.path = script_dir .. "lib/?.lua;" .. package.path

local LOCATOR     = os.getenv("ZENOH_LOCATOR")  or "tcp/127.0.0.1:7447"
local SERVICE_ID  = os.getenv("SERVICE_ID")     or "persistence-1"
local DB_PATH     = os.getenv("PERSISTENCE_DB") or "/tmp/persistence.db"
local TICK_US     = 100000   -- 100 ms drain cadence
local SUMMARY_S   = 30       -- periodic instance summary

local zps   = require("zenoh_pubsub")
local zrpc  = require("zenoh_rpc")
local zt    = require("zenoh_token")
local cjson = require("cjson")
local Persistence = require("persistence")
local QueryServer = require("query_server")

local function log(fmt, ...)
    io.stderr:write(string.format(
        "PERSISTENCE [%s]: " .. fmt .. "\n", SERVICE_ID, ...))
    io.stderr:flush()
end

log("starting (db=%s, locator=%s)", DB_PATH, LOCATOR)

-- WSL2 /tmp gotcha: the construct_kb stream pre-allocation (~800 single-
-- statement INSERTs) deterministically hits SQLITE_IOERR_WRITE (ext 5898)
-- when the DB lives directly in /tmp on this WSL2 install — even though
-- bare SQLite writes to /tmp work fine. A subdir under /tmp works (e.g.,
-- /tmp/persistence_clean/); only the bare /tmp dir is poisoned. Suspect
-- fsync-on-directory flakiness when /tmp has many entries (1.6k+ X11/ICE
-- sockets). Loud warn so future operators don't lose an hour to it.
if DB_PATH:match("^/tmp/[^/]+%.db$") then
    log("WARN db_path is directly in /tmp — known WSL2 fsync hazard; " ..
        "use a subdir (/tmp/<name>/db) or default ($REPO_ROOT/var/)")
end

local p = Persistence.new(DB_PATH)

local ps = zps.PubSub.new({ locators = { LOCATOR }, client_name = SERVICE_ID })
ps:connect()

-- Discovery channel — every robot publishes its topology here on
-- namespace_up. Payload carries class+instance so we demux.
local DISCO_TOPIC = "fleet/admin/persistence_topology_announce"
local disco_tok = zt.hash(DISCO_TOPIC)
zt.register(disco_tok, DISCO_TOPIC)
local disco_sub = ps:subscribe(disco_tok, 32)
log("discovery sub up on %s", DISCO_TOPIC)

-- RPC server — single well-known token for the persistence query API.
-- See QUERY_API.md. Op dispatched inside the JSON payload by QueryServer.
--
-- POISON-KEY GOTCHA: the string "fleet/admin/persistence_query" triggers a
-- bug in this build of zenoh-pico (commit 88e0ba3) — server-side
-- z_query_reply returns OK but the reply never reaches the client (5-sec
-- timeout). Verified by 5x deterministic isolated repro: same minimal RPC
-- server, same client, ONLY this exact string fails. Five other tested
-- keys including all other `fleet/admin/*` topics route cleanly. Rename
-- only fixes the query topic; the announce topic stays on `fleet/admin/*`
-- for consistency with the existing topology_announce topic.
local RPC_TOPIC      = "fleet/persistence/query"
local ANNOUNCE_TOPIC = "fleet/admin/persistence_service_announce"

local rpc_srv = zrpc.Server.new({
    locators = { LOCATOR }, client_name = "persistence_query_server",
})
local rpc_tok = zt.hash(RPC_TOPIC)
zt.register(rpc_tok, RPC_TOPIC)
local rpc_queue = rpc_srv:register(rpc_tok, 32)
rpc_srv:start()
log("query RPC up on %s", RPC_TOPIC)

local qs = QueryServer.new(p, {
    max_page_rows   = 100,
    max_reply_bytes = 4096,
    log_fn          = log,
})

local announce_tok = zt.hash(ANNOUNCE_TOPIC)
zt.register(announce_tok, ANNOUNCE_TOPIC)

local function publish_service_announce()
    local payload = cjson.encode(qs:announce_payload({
        service_id    = SERVICE_ID,
        rpc_token_key = RPC_TOPIC,
        republish_s   = SUMMARY_S,
    }))
    local okp, err = pcall(function() ps:publish(announce_tok, payload) end)
    if not okp then
        log("service announce publish failed: %s", tostring(err))
    end
end

publish_service_announce()
local last_announce = os.time()
log("service announce up on %s", ANNOUNCE_TOPIC)

-- Data subs: keyed by Zenoh full_key so a topology change can close removed
-- leaves' subs efficiently. Each value is { sub, leaf }.
local data_subs = {}

local function open_added_subs(state, added)
    local n = 0
    for _tail, leaf in pairs(added) do
        local tok = zt.hash(leaf.full_key)
        zt.register(tok, leaf.full_key)
        local sub = ps:subscribe(tok, 64)
        data_subs[leaf.full_key] = { sub = sub, leaf = leaf }
        n = n + 1
    end
    if n > 0 then
        log("opened %d data sub(s) for %s/%s (kb=%s)",
            n, state.class, state.instance, state.kb_name)
    end
end

local function close_removed_subs(state, removed)
    local n = 0
    for _tail, leaf in pairs(removed) do
        local entry = data_subs[leaf.full_key]
        if entry then
            pcall(function() ps:unsubscribe(entry.sub) end)
            data_subs[leaf.full_key] = nil
            n = n + 1
        end
    end
    if n > 0 then
        log("closed %d data sub(s) for %s/%s (data retained in DB)",
            n, state.class, state.instance)
    end
end

local function handle_topology(payload)
    local ok, obj = pcall(cjson.decode, payload)
    if not ok or type(obj) ~= "table" then
        log("bad topology JSON: %s", tostring(obj))
        return
    end
    if type(obj.class) ~= "string" or type(obj.instance) ~= "string"
       or type(obj.entries) ~= "table" then
        log("topology missing class/instance/entries fields")
        return
    end
    local was_new = p.instances[obj.class .. "/" .. obj.instance] == nil
    -- Two-phase: open subs BEFORE the slow schema reconcile so messages
    -- arriving during reconcile (~3-5s on a fresh DB) buffer in the sub
    -- queue (depth 64) instead of being lost. The pump's next iteration
    -- drains the buffered queue after reconcile_schema returns, by which
    -- time push_stream_data / set_status_data have valid tables to write.
    local state, added, removed = p:diff_topology(obj.class, obj.instance, obj.entries)
    if added  and next(added)   then open_added_subs(state, added)    end
    p:reconcile_schema(state)
    if removed and next(removed) then close_removed_subs(state, removed) end
    if was_new then
        -- Fresh kb arrived — refresh the service announce so consumers see
        -- it promptly without waiting for the next periodic republish.
        publish_service_announce()
        last_announce = os.time()
    end
end

-- Pump: drain discovery + RPC queue + each data sub.
local last_summary = os.time()
while true do
    -- Discovery
    local m = disco_sub:poll()
    while m do
        handle_topology(m.payload)
        m = disco_sub:poll()
    end
    -- Query RPC — drain and reply. Handler + reply both pcall-wrapped so a
    -- single faulty request never tears the loop down.
    while true do
        local req = rpc_queue:poll()
        if not req then break end
        local ok_h, reply = pcall(qs.handle, qs, req:payload())
        if ok_h then
            local ok_r, rerr = pcall(function() req:reply(reply) end)
            if not ok_r then
                log("rpc reply send failed: %s", tostring(rerr))
            end
        else
            log("rpc handler raised: %s", tostring(reply))
            pcall(function() req:reply_error(tostring(reply)) end)
        end
    end
    -- Data
    for _key, ds in pairs(data_subs) do
        local dm = ds.sub:poll()
        while dm do
            p:dispatch(ds.leaf, dm.payload)
            dm = ds.sub:poll()
        end
    end
    -- Periodic announce republish
    local now = os.time()
    if now - last_announce >= SUMMARY_S then
        publish_service_announce()
        last_announce = now
    end
    -- Periodic summary
    if now - last_summary >= SUMMARY_S then
        last_summary = now
        local n_inst, n_leaves, n_subs = 0, 0, 0
        for _, st in pairs(p.instances) do
            n_inst = n_inst + 1
            for _ in pairs(st.leaves) do n_leaves = n_leaves + 1 end
        end
        for _ in pairs(data_subs) do n_subs = n_subs + 1 end
        log("alive: %d instances, %d leaves, %d data subs", n_inst, n_leaves, n_subs)
    end
    ffi.C.usleep(TICK_US)
end
