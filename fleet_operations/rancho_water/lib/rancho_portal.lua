-- lib/rancho_portal.lua — Rancho Water customer-portal client.
--
-- Shellouts to curl, mirroring the secret-in-K-config pattern used by
-- ttn_client / cimis_client. Three HTTP steps per fetch_day call:
--   (1) GET  /secure/                                         -> login form
--                                                                + cookies
--   (2) POST /default.aspx?ReturnUrl=%2fsecure%2f             -> .ASPXAUTH
--   (3) POST /api/usage/get/  {AccountNumber, Date, UsagePreference}
--                                                             -> usage JSON
--
-- The login form ships __VIEWSTATE / __VIEWSTATEGENERATOR / __EVENTVALIDATION
-- hidden fields that ASP.NET requires round-tripped — we extract them from
-- the step-1 HTML and include them in the step-2 POST. Cookie jar is a
-- short-lived temp file, removed at the end of the call. The password is
-- written into a curl -K config file (also short-lived), never argv —
-- same hardening as the TTN/CIMIS clients.
--
-- API surface:
--   M.new{ account_number, username, password,
--          curl?, timeout_s?, tmp_path? }
--   client:fetch_day(date_iso)   -- date_iso = "YYYY-MM-DD"
--     -> body_string, ok, err
--
-- Login session lifetime is not assumed — every fetch_day re-logs-in. The
-- whole dance is ~3 HTTP requests, which at once-per-day is trivial.
--
-- Discoveries the script.js / portal HTML revealed (verified live
-- 2026-05-24):
--   * Username field: ctl00$ContentPlaceHolder1$txtUsername
--   * Password field: ctl00$ContentPlaceHolder1$txtPassword
--   * Submit button:  ctl00$ContentPlaceHolder1$btnSignIn  (value "Sign In")
--   * Date format in the body: MM/DD/YYYY
--   * UsagePreference: "Gallons" | "HCF"
--   * Endpoint: /api/usage/get/ requires PascalCase keys ("AccountNumber",
--     "Date", "UsagePreference"). Lowercase variants return a SQL-param
--     missing error.

local M = {}
M.__index = M

local BASE      = "https://myaccount.ranchowater.com"
local ENTRY_URL = BASE .. "/secure/"
local LOGIN_URL = BASE .. "/default.aspx?ReturnUrl=%2fsecure%2f"
local USAGE_URL = BASE .. "/api/usage/get/"

local UA = "fleet_design-rancho_water/1.0 (+contact: glenn-edgar@onyxengr.com)"
local STATUS_MARK = "__HTTP_STATUS__"

function M.new(opts)
    opts = opts or {}
    return setmetatable({
        account_number = assert(opts.account_number,
                                "rancho_portal: account_number required"),
        username       = assert(opts.username,
                                "rancho_portal: username required"),
        password       = assert(opts.password,
                                "rancho_portal: password required"),
        curl           = opts.curl or "curl",
        timeout_s      = opts.timeout_s or 30,
        tmp_path       = opts.tmp_path,        -- nil => os.tmpname()
    }, M)
end

-- "YYYY-MM-DD" -> "MM/DD/YYYY".
local function iso_to_us(iso)
    local y, m, d = iso:match("^(%d+)%-(%d+)%-(%d+)$")
    if not y then error("rancho_portal: bad ISO date " .. tostring(iso)) end
    return string.format("%s/%s/%s", m, d, y)
end

-- Extract a hidden input's value from rendered HTML. ASP.NET emits these
-- inputs in either order (name-before-value or value-before-name); try both.
local function extract_hidden(html, name)
    local pat1 = '<input[^>]*name="' .. name .. '"[^>]*value="([^"]*)"'
    local v = html:match(pat1)
    if v then return v end
    local pat2 = '<input[^>]*value="([^"]*)"[^>]*name="' .. name .. '"'
    return html:match(pat2)
end

-- Run one curl command with the configured `-K` config file. Returns
-- (body, status_int, ok, err). The status marker is appended via -w so we
-- can separate the body and the HTTP status from the same stream — same
-- pattern as ttn_client / cimis_client.
local function run_curl(curl_bin, timeout_s, k_config_path)
    local w_fmt = string.format("\\n%s:%%{http_code}", STATUS_MARK)
    local cmd = string.format(
        "%s -sS -L -m %d -K '%s' -w '%s' 2>/dev/null",
        curl_bin, timeout_s, k_config_path, w_fmt)
    local pipe = io.popen(cmd, "r")
    local raw = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    local body, status = raw:match("^(.*)\n" .. STATUS_MARK .. ":(%d+)$")
    if not status then
        return "", 0, false,
            "rancho_portal: no response (is curl installed?)"
    end
    local code = tonumber(status)
    if code == 0 then
        return "", 0, false,
            "rancho_portal: connection failed (curl http_code 000)"
    end
    if code < 200 or code >= 400 then
        return body, code, false,
            string.format("rancho_portal: HTTP %d", code)
    end
    return body, code, true, nil
end

local function write_k(path, lines)
    local fh, oerr = io.open(path, "w")
    if not fh then
        return false, "rancho_portal: cannot open " .. path .. ": " .. tostring(oerr)
    end
    for _, line in ipairs(lines) do fh:write(line, "\n") end
    fh:close()
    return true
end

function M:fetch_day(date_iso)
    local date_us = iso_to_us(date_iso)
    local jar     = self.tmp_path or os.tmpname()
    local k_cfg   = jar .. ".k"

    local function cleanup()
        os.remove(jar)
        os.remove(k_cfg)
    end

    -- ── Step 1: GET the login form. Cookie jar starts here. ──────────
    local ok = write_k(k_cfg, {
        string.format('url = "%s"',         ENTRY_URL),
        string.format('user-agent = "%s"',  UA),
        string.format('cookie-jar = "%s"',  jar),
        string.format('cookie = "%s"',      jar),
    })
    if not ok then cleanup(); return "", false, "step 1 k-config write failed" end

    local html, _code, ok1, err1 = run_curl(self.curl, self.timeout_s, k_cfg)
    if not ok1 then cleanup(); return "", false, "step 1 GET: " .. err1 end

    local vs     = extract_hidden(html, "__VIEWSTATE")     or ""
    local vs_gen = extract_hidden(html, "__VIEWSTATEGENERATOR") or ""
    local ev     = extract_hidden(html, "__EVENTVALIDATION") or ""
    if vs == "" or ev == "" then
        cleanup()
        return "", false, "step 1: could not extract __VIEWSTATE/__EVENTVALIDATION"
    end

    -- ── Step 2: POST the login form. .ASPXAUTH lands in the jar. ─────
    -- All field values via data-urlencode so curl handles the encoding;
    -- the K config keeps the password out of argv.
    --
    -- DO NOT add `request = "POST"`: that flag *forces* POST on the
    -- 302 redirect, but curl does NOT auto-resend the body, so the
    -- followed request lands without Content-Length and Rancho returns
    -- HTTP 411 "Length Required". The data-urlencode lines already make
    -- the FIRST request a POST; curl downgrading the redirect to GET is
    -- exactly the behavior we want.
    ok = write_k(k_cfg, {
        string.format('url = "%s"',                LOGIN_URL),
        string.format('user-agent = "%s"',         UA),
        string.format('referer = "%s"',            ENTRY_URL),
        string.format('cookie-jar = "%s"',         jar),
        string.format('cookie = "%s"',             jar),
        string.format('data-urlencode = "__VIEWSTATE=%s"', vs),
        string.format('data-urlencode = "__VIEWSTATEGENERATOR=%s"', vs_gen),
        string.format('data-urlencode = "__EVENTVALIDATION=%s"', ev),
        string.format(
            'data-urlencode = "ctl00$ContentPlaceHolder1$txtUsername=%s"',
            self.username),
        string.format(
            'data-urlencode = "ctl00$ContentPlaceHolder1$txtPassword=%s"',
            self.password),
        'data-urlencode = "ctl00$ContentPlaceHolder1$btnSignIn=Sign In"',
    })
    if not ok then cleanup(); return "", false, "step 2 k-config write failed" end

    local post_body, _c2, ok2, err2 = run_curl(self.curl, self.timeout_s, k_cfg)
    if not ok2 then cleanup(); return "", false, "step 2 POST: " .. err2 end

    -- Heuristic: a successful login lands on a page WITHOUT the password
    -- field. If we still see it, the credentials were wrong or the form
    -- shape changed.
    if post_body:find("txtPassword", 1, true) then
        cleanup()
        return "", false,
            "step 2: login likely failed — response still contains txtPassword"
    end

    -- ── Step 3: POST the usage endpoint with the session cookie. ─────
    -- Body shape verified live 2026-05-24. PascalCase keys are required.
    local body_json = string.format(
        '{"AccountNumber":"%s","Date":"%s","UsagePreference":"Gallons"}',
        self.account_number, date_us)
    ok = write_k(k_cfg, {
        string.format('url = "%s"',         USAGE_URL),
        string.format('user-agent = "%s"',  UA),
        string.format('cookie = "%s"',      jar),
        'header = "Content-Type: application/json"',
        'request = "POST"',
        string.format('data = "%s"', body_json:gsub('"', '\\"')),
    })
    if not ok then cleanup(); return "", false, "step 3 k-config write failed" end

    local usage_body, code3, ok3, err3 = run_curl(self.curl, self.timeout_s, k_cfg)
    cleanup()
    if not ok3 then return "", false, "step 3 POST: " .. err3 end
    if code3 < 200 or code3 >= 300 then
        return "", false, string.format("step 3: HTTP %d body=%s",
            code3, usage_body:sub(1, 200))
    end
    return usage_body, true, nil
end

return M
