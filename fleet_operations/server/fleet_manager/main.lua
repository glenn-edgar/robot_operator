-- server/fleet_manager/main.lua — fleet_manager layer of the robot controller.
--
-- The real fleet controller, replacing the throwaway bench_manager stub. It is
-- the first of the controller's eventual five layers (decision #13:
-- zenohd -> fleet_manager -> persistence -> application_logic ->
-- application_gateway, start_order 10/20/30/40/50). This session builds only
-- fleet_manager.
--
-- Responsibilities of this layer:
--   - RPC queryable on fleet/admin/register — record the robot in the
--     registry, reply {ok, controller_id, ts, echo_chip_uid} (decision #30).
--   - 1 Hz heartbeat publisher on fleet/admin/heartbeat {seq, ts}
--     (decision #32) — robots use it for passive disconnect detection.
--   - In-memory registry keyed by chip_uid (lib/registry.lua).
--
-- The controller is passive (decision #29): no validation, no NACK, no
-- uniqueness enforcement. It acks whatever announces itself.
--
-- Env:
--   ZENOH_LOCATOR   default tcp/127.0.0.1:7447
--   CONTROLLER_ID   default "fleet-manager-1"
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

local LOCATOR       = os.getenv("ZENOH_LOCATOR") or "tcp/127.0.0.1:7447"
local CONTROLLER_ID = os.getenv("CONTROLLER_ID") or "fleet-manager-1"
local TICK_US       = 100000   -- 100 ms service loop
local SUMMARY_S     = 30       -- registry summary cadence

local zps   = require("zenoh_pubsub")
local zrpc  = require("zenoh_rpc")
local zt    = require("zenoh_token")
local cjson = require("cjson")
local Registry = require("registry")

local function log(fmt, ...)
    io.stderr:write(string.format(
        "FLEET_MANAGER [%s]: " .. fmt .. "\n", CONTROLLER_ID, ...))
    io.stderr:flush()
end

log("starting (locator=%s)", LOCATOR)

local registry = Registry.new()

-- Pub/sub session — heartbeat publisher.
local ps = zps.PubSub.new({ locators = { LOCATOR }, client_name = "fleet_manager/pub" })
ps:connect()

-- RPC server — register queryable.
local srv = zrpc.Server.new({ locators = { LOCATOR }, client_name = "fleet_manager/srv" })
local register_token = zt.hash("fleet/admin/register")
zt.register(register_token, "fleet/admin/register")
local register_q = srv:register(register_token, 32)
srv:start()

local hb_token = zt.hash("fleet/admin/heartbeat")
zt.register(hb_token, "fleet/admin/heartbeat")

log("register queryable up on fleet/admin/register")
log("heartbeat publisher up on fleet/admin/heartbeat @1 Hz")

-- ---------------------------------------------------------------------------
-- Register query handler
-- ---------------------------------------------------------------------------

local function service_registrations()
    while true do
        local req = register_q:poll()
        if not req then break end

        local now = os.time()
        local ok, dec = pcall(cjson.decode, req:payload())
        local chip_uid = (ok and dec and dec.chip_uid) or ""

        if ok and dec then
            local entry, is_new = registry:upsert({
                chip_uid     = dec.chip_uid,
                class        = dec.class,
                instance     = dec.instance,
                fw_version   = dec.fw_version,
                capabilities = dec.capabilities,
                ts           = dec.ts,
            }, now)
            log("%s %-22s (chip_uid=%s, fw=%s, reg#%d) — registry: %d robot(s)",
                is_new and "NEW   " or "RE-REG",
                entry.namespace, entry.chip_uid,
                tostring(entry.fw_version), entry.register_count,
                registry:count())
        else
            log("register: undecodable payload — acking anyway (passive registry)")
        end

        -- Passive ack (decision #30). No NACK path exists.
        req:reply(cjson.encode({
            ok            = true,
            controller_id = CONTROLLER_ID,
            ts            = now,
            echo_chip_uid = chip_uid,
        }))
    end
end

-- ---------------------------------------------------------------------------
-- Service loop
-- ---------------------------------------------------------------------------

local hb_seq       = 0
local last_hb_t    = 0
local last_summ_t  = os.time()
local transport_up = true   -- tracked so the up/down transition logs once

while true do
    -- Servicing and publishing both touch the zenoh transport, which drops
    -- out from under the controller when the router (zenohd) bounces. Neither
    -- may kill the process — pcall both; the zenoh client reconnects
    -- underneath and the next tick resumes. (The register-RPC side already
    -- tolerates this; an unguarded heartbeat publish previously crashed the
    -- controller on a router bounce.)
    local ok, err = pcall(service_registrations)
    if not ok then
        log("register servicing error (%s) — continuing", tostring(err))
    end

    local now = os.time()

    -- 1 Hz controller heartbeat.
    if now - last_hb_t >= 1 then
        last_hb_t = now
        hb_seq = hb_seq + 1
        local pok, perr = pcall(ps.publish, ps, hb_token,
            cjson.encode({ seq = hb_seq, ts = now }))
        if pok and not transport_up then
            transport_up = true
            log("transport recovered — heartbeat resumed (seq=%d)", hb_seq)
        elseif not pok and transport_up then
            transport_up = false
            log("transport down (%s) — heartbeat paused, retrying",
                tostring(perr))
        end
    end

    -- Periodic registry summary (quiet otherwise).
    if now - last_summ_t >= SUMMARY_S then
        last_summ_t = now
        log("registry summary — %d robot(s):", registry:count())
        registry:each(function(uid, e)
            io.stderr:write(string.format(
                "    %-24s chip_uid=%s reg#%d last_seen=%d\n",
                e.namespace, uid, e.register_count, e.last_seen))
        end)
    end

    ffi.C.usleep(TICK_US)
end
