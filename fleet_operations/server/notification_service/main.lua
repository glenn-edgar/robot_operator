-- server/notification_service/main.lua — layer-60 push-notification service.
--
-- Subscribes to the well-known shared digest channel
-- `fleet/notify/digest/daily`; for each event, POSTs the body to the
-- configured Discord webhook URL. One-event-one-webhook in v1 (severity
-- routing, dedup, retry, ntfy/Slack arrive in v2 — see
-- discord-integration-architecture-2026-05-23 for the locked plan).
--
-- Robot owns content, service owns transport: the payload arrives as
-- {schema, class, instance, body} — the service POSTs `body` as-is, with a
-- short `[class/instance]` prefix to help operators identify the source.
-- The service never queries persistence, never formats, never decides what
-- is worth sending.
--
-- Env:
--   ZENOH_LOCATOR         default tcp/127.0.0.1:7447
--   SERVICE_ID            default "notification-1"
--   DISCORD_WEBHOOK_URL   REQUIRED — gitignored in secrets/discord.env
--   NOTIFY_USERNAME       optional, default "fleet_design"
--
-- Launch via ./run.sh — it sources secrets/discord.env and sets LUA_CPATH /
-- LUA_PATH / LD_LIBRARY_PATH.

local ffi = require("ffi")
ffi.cdef[[
    int usleep(unsigned int usec);
    typedef void (*sighandler_t)(int);
    sighandler_t signal(int signum, sighandler_t handler);
]]
ffi.C.signal(13, ffi.cast("sighandler_t", 1))  -- ignore SIGPIPE

local script_dir = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
package.path = script_dir .. "lib/?.lua;" .. package.path

local LOCATOR    = os.getenv("ZENOH_LOCATOR")       or "tcp/127.0.0.1:7447"
local SERVICE_ID = os.getenv("SERVICE_ID")          or "notification-1"
local WEBHOOK    = os.getenv("DISCORD_WEBHOOK_URL") or ""
local USERNAME   = os.getenv("NOTIFY_USERNAME")     or "fleet_design"
local TICK_US    = 100000   -- 100 ms drain cadence
local SUMMARY_S  = 60

local zps     = require("zenoh_pubsub")
local zt      = require("zenoh_token")
local cjson   = require("cjson")
local discord = require("discord_webhook")

local function log(fmt, ...)
    io.stderr:write(string.format(
        "NOTIFY [%s]: " .. fmt .. "\n", SERVICE_ID, ...))
    io.stderr:flush()
end

-- Webhook may be empty (eg. Docker Desktop WSL2 read-only bind-mount staleness
-- prevents /secrets/discord.env from appearing inside the container). Don't
-- crash — log it loudly and degrade to no-op delivery so the rest of the
-- container (zenohd / fleet_manager / persistence / gateway) stays up.
-- Under tini's exit-on-first-child-crash policy, FATAL-exiting here used to
-- knock the whole container into a restart loop every ~90 s.
local NOOP_DELIVERY = (WEBHOOK == "")
if NOOP_DELIVERY then
    log("WARN DISCORD_WEBHOOK_URL not set — running in no-op delivery mode")
    log("  (digests will be received and acknowledged but NOT POSTed to Discord)")
else
    -- Mask the webhook URL — keep the host + path-prefix, drop the token suffix.
    local mask = WEBHOOK:match("^(https?://[^/]+/[^/]+/[^/]+/)") or "(mask-failed)"
    log("webhook configured: %s…", mask)
end
log("starting (locator=%s, username=%s)", LOCATOR, USERNAME)

local ps = zps.PubSub.new({ locators = { LOCATOR }, client_name = SERVICE_ID })
ps:connect()

local DIGEST_TOPIC = "fleet/notify/digest/daily"
local digest_tok = zt.hash(DIGEST_TOPIC)
zt.register(digest_tok, DIGEST_TOPIC)
local digest_sub = ps:subscribe(digest_tok, 32)
log("subscribed to %s", DIGEST_TOPIC)

local sent_ok, sent_fail = 0, 0

local function handle_digest(payload)
    local ok, obj = pcall(cjson.decode, payload)
    if not ok or type(obj) ~= "table" then
        log("bad digest JSON: %s", tostring(obj))
        sent_fail = sent_fail + 1
        return
    end
    if type(obj.body) ~= "string" or obj.body == "" then
        log("digest missing/empty body field (class=%s, instance=%s)",
            tostring(obj.class), tostring(obj.instance))
        sent_fail = sent_fail + 1
        return
    end
    -- Short source prefix so a Discord reader can see who published it.
    local class    = tostring(obj.class    or "?")
    local instance = tostring(obj.instance or "?")
    local content  = string.format("[%s/%s]\n%s", class, instance, obj.body)

    if NOOP_DELIVERY then
        sent_ok = sent_ok + 1
        log("digest received [NO-OP, webhook unset]: %s/%s (%d chars)",
            class, instance, #content)
        return
    end
    local ok_send, err = discord.send(WEBHOOK, content, {
        username = USERNAME,
        logger   = function(s) log("%s", s) end,
    })
    if ok_send then
        sent_ok = sent_ok + 1
        log("digest delivered: %s/%s (%d chars)",
            class, instance, #content)
    else
        sent_fail = sent_fail + 1
        log("digest delivery FAILED: %s/%s — %s",
            class, instance, tostring(err))
    end
end

local last_summary = os.time()
while true do
    local m = digest_sub:poll()
    while m do
        handle_digest(m.payload)
        m = digest_sub:poll()
    end
    local now = os.time()
    if now - last_summary >= SUMMARY_S then
        last_summary = now
        log("alive: %d delivered, %d failed", sent_ok, sent_fail)
    end
    ffi.C.usleep(TICK_US)
end
