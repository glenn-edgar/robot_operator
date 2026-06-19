-- lib/irrigation_client.lua — irrigation-site web client.
--
-- The irrigation controller (LaCima Pi at 192.168.1.146) runs a Flask app
-- with HTTP Digest auth + Flask session cookies. A successful POST takes
-- one curl invocation per call: curl does the 401-challenge→Authorization
-- handshake internally, but the SAME cookie jar must persist across the
-- two requests inside that invocation. Verified live 2026-05-25 with both
-- read (hgetall) and write (hmset) returning 200.
--
-- Two RPC operations on the /ajax/redis_access endpoint cover what we need:
--   hgetall(name)              -> table {field=value, ...}
--   hmset(name, dictionary)    -> "SUCCESS"
--
-- Hardening pattern mirrors cimis_client / rancho_portal:
--   * `-K <cfg>` config file carries url + creds; nothing sensitive on argv
--   * cookie jar in a temp file, cleaned up at end
--   * a curl `-w` marker after the body separates body from HTTP code
--   * never raises; returns (data, ok, err)
--
-- API:
--   M.new{ host, account, password, curl?, timeout_s?, tmp_path? }
--   client:hgetall(table_name)              -> tbl|nil, ok, err
--   client:hmset(table_name, dictionary)    -> reply_str|nil, ok, err

local cjson = require("cjson")

local M = {}
M.__index = M

local STATUS_MARK = "__IRRIG_HTTP_STATUS__"

-- account+password are required for hgetall/hmset but NOT for ping(); the
-- watchdog uses ping() with creds=nil. _post() asserts creds at call time.
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        host      = assert(opts.host, "irrigation_client: host required"),
        account   = opts.account,
        password  = opts.password,
        curl      = opts.curl or "curl",
        timeout_s = opts.timeout_s or 15,
        tmp_path  = opts.tmp_path,        -- nil => os.tmpname()
    }, M)
end

-- Liveness probe — unauthenticated HTTP GET. Returns (ok, http_code, err).
-- "ok" means we got ANY HTTP response (a 401 from Digest still proves the
-- server is up). Connection failure / timeout / DNS error -> (false, nil).
function M:ping(timeout_s)
    local cmd = string.format(
        "%s -sS -o /dev/null -m %d -w '%%{http_code}' 'http://%s/' 2>/dev/null",
        self.curl, timeout_s or 3, self.host)
    local pipe = io.popen(cmd, "r")
    local raw = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    local code = tonumber(raw)
    if not code or code == 0 then
        return false, nil, "no response (curl http_code=" .. tostring(raw) .. ")"
    end
    return true, code, nil
end

local function write_k(path, lines)
    local fh, oerr = io.open(path, "w")
    if not fh then
        return false, "irrigation_client: cannot open " .. path
                      .. ": " .. tostring(oerr)
    end
    for _, line in ipairs(lines) do fh:write(line, "\n") end
    fh:close()
    return true
end

local function run_curl(curl_bin, timeout_s, k_cfg)
    local w_fmt = string.format("\\n%s:%%{http_code}", STATUS_MARK)
    local cmd = string.format(
        "%s -sS -m %d -K '%s' -w '%s' 2>/dev/null",
        curl_bin, timeout_s, k_cfg, w_fmt)
    local pipe = io.popen(cmd, "r")
    local raw  = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    local body, status = raw:match("^(.*)\n" .. STATUS_MARK .. ":(%d+)$")
    if not status then
        return "", 0, false,
            "irrigation_client: no response (is curl installed?)"
    end
    local code = tonumber(status)
    if code == 0 then
        return "", 0, false,
            "irrigation_client: connection failed (curl http_code 000)"
    end
    if code < 200 or code >= 300 then
        return body, code, false,
            string.format("irrigation_client: HTTP %d: %s", code, body:sub(1, 200))
    end
    return body, code, true, nil
end

-- POST a JSON body to /ajax/redis_access. Returns (decoded_reply, ok, err).
-- The reply is JSON (the server's flask jsonify) so we decode it for the
-- caller. The cookie jar is created+deleted per call; one call = one full
-- digest+session round-trip.
function M:_post(body_table)
    assert(self.account and self.password,
        "irrigation_client: account+password required for _post (hgetall/hmset)")
    local body = cjson.encode(body_table)
    local jar  = self.tmp_path or os.tmpname()
    local cfg  = jar .. ".k"

    local function cleanup()
        os.remove(jar); os.remove(cfg)
    end

    local ok, err = write_k(cfg, {
        string.format('url = "http://%s/ajax/redis_access"', self.host),
        string.format('user = "%s:%s"', self.account, self.password),
        'digest',
        string.format('cookie-jar = "%s"', jar),
        string.format('cookie = "%s"', jar),
        'header = "Content-Type: application/json"',
        string.format('data = "%s"', body:gsub('\\', '\\\\'):gsub('"', '\\"')),
    })
    if not ok then cleanup(); return nil, false, err end

    local raw, _code, ok2, err2 = run_curl(self.curl, self.timeout_s, cfg)
    cleanup()
    if not ok2 then return nil, false, err2 end

    local dec_ok, decoded = pcall(cjson.decode, raw)
    if not dec_ok then
        return nil, false,
            "irrigation_client: bad JSON reply: " .. raw:sub(1, 200)
    end
    return decoded, true, nil
end

function M:hgetall(table_name)
    return self:_post{
        name      = table_name,
        type      = "Redis_Hash_Dictionary",
        operation = "hgetall",
    }
end

function M:hmset(table_name, dictionary)
    return self:_post{
        name             = table_name,
        type             = "Redis_Hash_Dictionary",
        operation        = "hmset",
        dictionary_table = dictionary,
    }
end

return M
