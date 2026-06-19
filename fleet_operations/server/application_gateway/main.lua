-- server/application_gateway/main.lua — HTTP-over-JSON gateway in front
-- of the persistence query RPC. Serves a small dashboard from static/
-- and exposes JSON endpoints under /api.
--
-- Env: ZENOH_LOCATOR (default tcp/127.0.0.1:7447),
--      GATEWAY_HOST  (default 127.0.0.1),
--      GATEWAY_PORT  (default 8080).
--
-- Single-process serial server: one viewer at a time is fine. Front-end
-- and back-end share the same origin, so no CORS plumbing.

local cjson = require("cjson")
local http  = require("http_server")
local PC    = require("persistence_client")
local irrigation = require("irrigation_dashboard")

-- Stay consistent with the persistence query server: empty Lua tables
-- mean empty arrays in our JSON, not empty objects.
cjson.encode_empty_table_as_object(false)

local LOCATOR = os.getenv("ZENOH_LOCATOR") or "tcp/127.0.0.1:7447"
local HOST    = os.getenv("GATEWAY_HOST")  or "127.0.0.1"
local PORT    = tonumber(os.getenv("GATEWAY_PORT")) or 8080

local function log(fmt, ...)
    io.stderr:write(string.format("APPGW: " .. fmt .. "\n", ...))
end

log("starting (locator=%s, http=%s:%d)", LOCATOR, HOST, PORT)

local pc = PC.new({
    locator = LOCATOR, timeout_ms = 5000,
    client_name = "application_gateway",
})

-- Resolve where static/ and index.html live (script-relative).
local SCRIPT_DIR = arg[0]:match("(.*)/[^/]+$") or "."
local STATIC_DIR = SCRIPT_DIR .. "/static"

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end

local function json(body, code)
    return code or 200,
           { "Content-Type: application/json" },
           cjson.encode(body)
end

local function err_response(err)
    -- Map RPC error codes to HTTP statuses.
    local map = {
        not_found       = 404,
        bad_request     = 400,
        unsupported_op  = 400,
        payload_too_big = 413,
        transport       = 502,
        decode          = 502,
    }
    local code = map[err.code or ""] or 500
    return code, { "Content-Type: application/json" },
           cjson.encode({ ok = false, error = err })
end

-- Helper: composite kb_name from (class, instance), matching the
-- persistence layer's convention.
local function kb_name(class, instance)
    return class .. "_" .. instance
end

-- A path arrives as a single URL segment, possibly already URL-decoded
-- to e.g. `cimis/station/sample`. We pass it through to the RPC verbatim.
-- The query server normalizes `/` and `.` interchangeably.

local srv = http.new({ host = HOST, port = PORT, log_fn = log })

-- Root lands on the irrigation dashboard (this is the irrigation complex).
-- The generic multi-robot fleet view stays reachable at /fleet.
srv:route("GET", "/", function(_req)
    return 302, { "Location: /irrigation" }, ""
end)

-- Generic fleet dashboard (the multi-robot SPA).
srv:route("GET", "/fleet", function(_req)
    local body = read_file(STATIC_DIR .. "/index.html")
    if not body then return 500, {}, "index.html not found\n" end
    return 200, { "Content-Type: text/html; charset=utf-8" }, body
end)

-- Static: any other file under /static/<name> (no traversal — strip `..`).
srv:route("GET", "/static/:name", function(req)
    local name = req.params.name:gsub("%.%.", "")
    local body = read_file(STATIC_DIR .. "/" .. name)
    if not body then return 404, {}, "not found\n" end
    local ext = name:match("%.(%w+)$") or ""
    local ct  = ({ html = "text/html", css = "text/css",
                   js   = "application/javascript",
                   json = "application/json" })[ext] or "text/plain"
    return 200, { "Content-Type: " .. ct }, body
end)

-- /api/robots — list_kbs() passthrough.
srv:route("GET", "/api/robots", function(_req)
    local r, err = pc:list_kbs()
    if not r then return err_response(err) end
    return json({ ok = true, data = r.data })
end)

-- /api/robots/:class/:inst/leaves — list_leaves(kb)
srv:route("GET", "/api/robots/:class/:inst/leaves", function(req)
    local r, err = pc:list_leaves(kb_name(req.params.class, req.params.inst))
    if not r then return err_response(err) end
    return json({ ok = true, data = r.data })
end)

-- /api/robots/:class/:inst/latest?path=heartbeat — latest(kb, path)
srv:route("GET", "/api/robots/:class/:inst/latest", function(req)
    local path = req.query.path
    if not path or path == "" then
        return err_response({ code = "bad_request", msg = "path required" })
    end
    local r, err = pc:latest(kb_name(req.params.class, req.params.inst), path)
    if not r then return err_response(err) end
    return json({ ok = true, data = r.data })
end)

-- /api/robots/:class/:inst/latest_stream?path=... — latest_stream(kb, path)
srv:route("GET", "/api/robots/:class/:inst/latest_stream", function(req)
    local path = req.query.path
    if not path or path == "" then
        return err_response({ code = "bad_request", msg = "path required" })
    end
    local r, err = pc:latest_stream(
        kb_name(req.params.class, req.params.inst), path)
    if not r then return err_response(err) end
    return json({ ok = true, data = r.data })
end)

-- /api/robots/:class/:inst/stream?path=...&limit=N&order=desc&page=...
srv:route("GET", "/api/robots/:class/:inst/stream", function(req)
    local path = req.query.path
    if not path or path == "" then
        return err_response({ code = "bad_request", msg = "path required" })
    end
    local opts = {
        limit = tonumber(req.query.limit),
        order = req.query.order,
        page  = req.query.page,
    }
    if req.query.since_ts then opts.since_ts = tonumber(req.query.since_ts) end
    if req.query.until_ts then opts.until_ts = tonumber(req.query.until_ts) end
    local r, err = pc:stream(
        kb_name(req.params.class, req.params.inst), path, opts)
    if not r then return err_response(err) end
    local out = { ok = true, data = r.data }
    if r.next_page then out.next_page = r.next_page end
    return json(out)
end)

-- Health.
srv:route("GET", "/healthz", function(_req)
    return 200, { "Content-Type: text/plain" }, "ok\n"
end)

-- Irrigation dashboard (read views first; write views land later).
irrigation.register_routes(srv)

srv:serve()
pc:close()
