-- server/application_gateway/lib/http_server.lua
--
-- Minimal HTTP/1.1 server (GET + POST) on top of LuaSocket. Single-process,
-- serial request handling: fine for a small dashboard with one or two
-- viewers; not for production load. Keeps the dependency surface tiny
-- (no framework, no async runtime).
--
-- POST bodies: if Content-Length is set, the body is read into req.body
-- (raw bytes). If Content-Type is application/x-www-form-urlencoded,
-- the body is parsed into req.form (table of decoded fields).
--
-- Usage:
--   local http = require("http_server")
--   local srv = http.new({ host = "127.0.0.1", port = 8080 })
--   srv:route("GET", "/api/robots",
--             function(req) return 200, {"content-type:application/json"}, body end)
--   srv:serve()    -- blocks
--
-- Routes are matched by HTTP method + path. Path patterns use a Lua-
-- pattern with `:name` captured segments rewritten to `([^/]+)`.

local socket = require("socket")

local M = {}
M.__index = M

local STATUS_TEXT = {
    [200] = "OK",
    [204] = "No Content",
    [302] = "Found",
    [303] = "See Other",
    [400] = "Bad Request",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [413] = "Payload Too Large",
    [500] = "Internal Server Error",
}

local function status_line(code)
    return string.format("HTTP/1.1 %d %s\r\n", code, STATUS_TEXT[code] or "OK")
end

-- Compile a `/api/robots/:class/:inst` path pattern into a Lua-pattern
-- + ordered list of capture names.
local function compile_pattern(path)
    local names = {}
    local pat = path:gsub(":([%w_]+)", function(name)
        names[#names + 1] = name
        return "([^/]+)"
    end)
    return "^" .. pat .. "$", names
end

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        host     = opts.host     or "127.0.0.1",
        port     = opts.port     or 8080,
        log_fn   = opts.log_fn,
        routes   = {},      -- list of {method, pattern, names, handler}
        running  = false,
    }, M)
end

function M:_log(fmt, ...)
    if self.log_fn then self.log_fn(fmt, ...) end
end

function M:route(method, path, handler)
    local pat, names = compile_pattern(path)
    self.routes[#self.routes + 1] = {
        method = method, pattern = pat, names = names, handler = handler,
    }
end

-- Parse query string `a=1&b=2` -> table.
local function parse_query(qs)
    local out = {}
    if not qs or qs == "" then return out end
    for kv in qs:gmatch("[^&]+") do
        local k, v = kv:match("^([^=]+)=(.*)$")
        if k then
            -- naive URL-decode: %xx and +
            v = v:gsub("+", " "):gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
            out[k] = v
        else
            out[kv] = ""
        end
    end
    return out
end

-- URL-decode a path segment (e.g. `cimis%2Fstation%2Fsample`).
local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Read request line + headers from a client socket; return parsed req or nil.
local function read_request(client)
    local req_line, err = client:receive("*l")
    if not req_line then return nil, err end
    local method, target, _ver = req_line:match("^(%S+)%s+(%S+)%s+(%S+)$")
    if not method then return nil, "malformed request line" end
    local path, qs = target:match("^([^?]+)%??(.*)$")
    local headers = {}
    while true do
        local line, lerr = client:receive("*l")
        if not line then return nil, lerr end
        if line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    -- Read POST/PUT body if Content-Length is present.
    local body, form = nil, nil
    local cl = tonumber(headers["content-length"] or "")
    if cl and cl > 0 then
        if cl > 1024 * 1024 then return nil, "body too large" end
        local b, berr = client:receive(cl)
        if not b then return nil, "body read: " .. tostring(berr) end
        body = b
        local ct = (headers["content-type"] or ""):lower()
        if ct:find("application/x%-www%-form%-urlencoded") then
            form = parse_query(body)
        end
    end
    return {
        method  = method,
        path    = path,
        query   = parse_query(qs),
        headers = headers,
        body    = body,
        form    = form,
    }
end

-- Try each route in order; first match wins. Returns (code, headers, body).
function M:_dispatch(req)
    -- 1. Find a path-matching route (any method).
    local path_match
    for _, r in ipairs(self.routes) do
        local caps = { req.path:match(r.pattern) }
        if #caps > 0 or (req.path == r.pattern:sub(2, -2) and #r.names == 0) then
            -- Treat exact-no-capture path as a no-capture match too.
            if r.method == req.method then
                local params = {}
                for i, name in ipairs(r.names) do
                    params[name] = url_decode(caps[i] or "")
                end
                req.params = params
                local ok, code, headers, body = pcall(r.handler, req)
                if not ok then
                    self:_log("handler %s %s raised: %s",
                        req.method, req.path, tostring(code))
                    return 500, {}, "internal error\n"
                end
                return code, headers, body
            else
                path_match = true
            end
        end
    end
    if path_match then return 405, {}, "method not allowed\n" end
    return 404, {}, "not found\n"
end

local function send_response(client, code, headers, body)
    body = body or ""
    headers = headers or {}
    local lines = { status_line(code) }
    local has_ct, has_cl = false, false
    for _, h in ipairs(headers) do
        lines[#lines + 1] = h .. "\r\n"
        local lc = h:lower()
        if lc:find("^content%-type:") then has_ct = true end
        if lc:find("^content%-length:") then has_cl = true end
    end
    if not has_ct then lines[#lines + 1] = "Content-Type: text/plain\r\n" end
    if not has_cl then
        lines[#lines + 1] = "Content-Length: " .. #body .. "\r\n"
    end
    lines[#lines + 1] = "Connection: close\r\n\r\n"
    client:send(table.concat(lines))
    if #body > 0 then client:send(body) end
end

function M:serve()
    local srv, err = socket.bind(self.host, self.port)
    if not srv then error("bind failed: " .. tostring(err)) end
    self._server = srv
    self.running = true
    self:_log("HTTP_SERVER: listening on %s:%d", self.host, self.port)
    while self.running do
        local client = srv:accept()
        if client then
            client:settimeout(5)
            local req, rerr = read_request(client)
            if req then
                local code, headers, body = self:_dispatch(req)
                self:_log("HTTP %s %s -> %d", req.method, req.path, code)
                send_response(client, code, headers, body)
            else
                self:_log("HTTP read failed: %s", tostring(rerr))
            end
            client:close()
        end
    end
end

function M:stop()
    self.running = false
    if self._server then self._server:close() end
end

return M
