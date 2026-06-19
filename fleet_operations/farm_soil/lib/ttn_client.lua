-- lib/ttn_client.lua — TTN v3 storage API client (HTTPS GET via curl).
--
-- LuaJIT has no stdlib HTTPS client. This shells out to `curl` (universally
-- present, handles TLS) for the once-an-hour storage GET. Engine-agnostic;
-- returns the raw response body — parsing lives in decoder.lua.
--
-- The bearer token is written to a transient curl config file and passed
-- with `-K`, NOT on the command line — so it never appears in `ps`. The
-- config file is removed immediately after the call. (For a hardened
-- deploy, run the robot under `umask 077` so that file is created 0600,
-- or point `opts.tmp_path` at a private location.)
--
--   M.new{ url_base, app_name, url_after, bearer_token, limit?, curl?,
--          timeout_s?, tmp_path? }
--   client:request_url(after)  -> URL string (carries no token — safe to log)
--   client:fetch(after)        -> body, ok, err

local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        url_base     = assert(opts.url_base,     "ttn_client: url_base required"),
        app_name     = assert(opts.app_name,     "ttn_client: app_name required"),
        url_after    = assert(opts.url_after,    "ttn_client: url_after required"),
        bearer_token = assert(opts.bearer_token, "ttn_client: bearer_token required"),
        limit        = opts.limit or 200,
        curl         = opts.curl or "curl",
        timeout_s    = opts.timeout_s or 30,
        tmp_path     = opts.tmp_path,            -- nil => os.tmpname()
    }, M)
end

-- The storage query URL. Carries no credential — safe to log.
function M:request_url(after)
    return string.format("%s%s%slimit=%d&after=%s",
        self.url_base, self.app_name, self.url_after, self.limit, after)
end

-- `-w` format: the literal two chars \n (curl turns it into a newline),
-- then a marker and the HTTP status. Parsed back off the response below.
local CURL_W = [[\n__TTN_HTTP_STATUS__:%{http_code}]]

-- GET uplinks received after `after` (an RFC3339 timestamp).
-- Returns (body, true, nil) on HTTP 2xx, or ("", false, err) on any
-- transport or HTTP failure — never raises.
function M:fetch(after)
    local url = self:request_url(after)

    local cfg = self.tmp_path or os.tmpname()
    local fh, oerr = io.open(cfg, "w")
    if not fh then
        return "", false, "ttn_client: cannot open temp config: " .. tostring(oerr)
    end
    fh:write(string.format('header = "Authorization: Bearer %s"\n', self.bearer_token))
    fh:write('header = "Accept: text/event-stream"\n')
    fh:close()

    -- cfg / CURL_W / url single-quoted: url carries shell-special '&'.
    local cmd = string.format(
        "%s -s -m %d -K '%s' -w '%s' '%s' 2>/dev/null",
        self.curl, self.timeout_s, cfg, CURL_W, url)
    local pipe = io.popen(cmd, "r")
    local raw = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    os.remove(cfg)

    local body, status = raw:match("^(.*)\n__TTN_HTTP_STATUS__:(%d+)$")
    if not status then
        return "", false, "ttn_client: no response (is curl installed?)"
    end
    local code = tonumber(status)
    if code == 0 then
        return "", false, "ttn_client: connection failed (curl http_code 000)"
    end
    if code < 200 or code >= 300 then
        return "", false,
            string.format("ttn_client: HTTP %d: %s", code, body:sub(1, 200))
    end
    return body, true, nil
end

return M
