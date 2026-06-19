-- lib/cimis_client.lua — CIMIS Web API HTTP client (HTTPS GET via curl).
--
-- LuaJIT port of the Python skill's api.py (skills/cimis/api.py). The CIMIS
-- API expects the appKey as a query parameter — so the URL itself carries
-- the secret. To keep the appKey out of `ps` listings, the whole URL is
-- written into a transient curl `-K` config file (`url = "..."`) along with
-- the Accept header, and curl is invoked with NO URL on the command line.
-- The config file is removed immediately after the call. (For a hardened
-- deploy, run the robot under `umask 077` so that file is created 0600.)
--
-- The Python skill's continue.md flags a known gap: et.water.ca.gov's WAF
-- occasionally returns an HTML "Request Rejected" page as HTTP 200, which
-- the Python silently treats as a 0-record response. This port detects it:
-- a 2xx response whose body opens with `<` (HTML, not JSON) is surfaced as
-- ("", false, "WAF rejection: ...").
--
--   M.new{ app_key, api_base?, curl?, timeout_s?, tmp_path? }
--   client:request_url(targets, data_items, start_date, end_date, units?)
--     -> URL string. CARRIES THE APPKEY — never log.
--   client:fetch(targets, data_items, start_date, end_date, units?)
--     -> body, ok, err

local M = {}
M.__index = M

local DEFAULT_API_BASE = "https://et.water.ca.gov/api/data"

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        app_key   = assert(opts.app_key, "cimis_client: app_key required"),
        api_base  = opts.api_base or DEFAULT_API_BASE,
        curl      = opts.curl or "curl",
        timeout_s = opts.timeout_s or 30,
        tmp_path  = opts.tmp_path,            -- nil => os.tmpname()
    }, M)
end

-- Build the query URL. The CIMIS parameter values we send are restricted to
-- digits, hyphens, commas, ISO dates and UUID/alphanumeric appKey — none
-- require percent-encoding for the API. Carries the secret; do not log.
function M:request_url(targets, data_items, start_date, end_date, units)
    return string.format(
        "%s?appKey=%s&targets=%s&dataItems=%s&startDate=%s&endDate=%s&unitOfMeasure=%s",
        self.api_base, self.app_key, targets, data_items,
        start_date, end_date, units or "E")
end

-- `-w` format: literal "\n", then a marker and the HTTP status. Parsed back
-- off the response below — same shape as ttn_client.
local CURL_W = [[\n__CIMIS_HTTP_STATUS__:%{http_code}]]

-- GET one CIMIS window. Returns (body, true, nil) on success, or
-- ("", false, err) on transport / HTTP / WAF failure — never raises.
function M:fetch(targets, data_items, start_date, end_date, units)
    local url = self:request_url(targets, data_items, start_date, end_date, units)

    local cfg = self.tmp_path or os.tmpname()
    local fh, oerr = io.open(cfg, "w")
    if not fh then
        return "", false, "cimis_client: cannot open temp config: " .. tostring(oerr)
    end
    -- url= and header= both in the config file → the secret-bearing URL
    -- never appears on the command line.
    fh:write(string.format('url = "%s"\n', url))
    fh:write('header = "Accept: application/json"\n')
    fh:close()

    local cmd = string.format(
        "%s -s -m %d -K '%s' -w '%s' 2>/dev/null",
        self.curl, self.timeout_s, cfg, CURL_W)
    local pipe = io.popen(cmd, "r")
    local raw = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    os.remove(cfg)

    local body, status = raw:match("^(.*)\n__CIMIS_HTTP_STATUS__:(%d+)$")
    if not status then
        return "", false, "cimis_client: no response (is curl installed?)"
    end
    local code = tonumber(status)
    if code == 0 then
        return "", false, "cimis_client: connection failed (curl http_code 000)"
    end
    if code < 200 or code >= 300 then
        return "", false,
            string.format("cimis_client: HTTP %d: %s", code, body:sub(1, 200))
    end
    -- WAF detection. CIMIS only ever returns JSON; a body opening with `<`
    -- is the WAF's "Request Rejected" HTML page returned as 200. Surface as
    -- an error rather than letting the decoder silently see 0 records.
    local lead = body:match("^%s*(.)") or ""
    if lead == "<" then
        return "", false,
            "cimis_client: WAF rejection (HTML response, not JSON): "
            .. body:sub(1, 200)
    end
    return body, true, nil
end

return M
