-- ws_command.lua — POST to the irrigation controller's mode_change endpoint.
--
-- Wire format (verified 2026-06-01 from /control/control page source):
--   POST http://192.168.1.146/ajax/mode_change
--   Auth: HTTP Digest, admin:password from Redis db=5/web/users
--   Content-Type: application/json
--   Body: {"command":"SKIP_STATION","schedule_name":"","step":"","run_time":""}
--
-- The controller's web app advances its own irrigation queue when it
-- accepts SKIP_STATION (case 1 in the JS switch). Other commands the
-- robot may issue: CLOSE_MASTER_VALVE (for master-side faults).
-- CLEAR ("Stop Irrigation / Empty Queue", case 0) is explicitly NOT
-- emitted by the robot — Glenn's instruction 2026-06-01.
--
-- Transport: curl shell-out with --digest. Subprocess overhead is fine
-- because hard-kill events fire at most a few times per night, and curl
-- handles MD5 digest auth natively (LuaSec doesn't).
--
-- Safety knob: SKIP_LIVE env. Default OFF → log "would-POST" only. Flip
-- to "1" / "true" / "yes" once dry-run output looks correct.

local M = {}

local CONTROLLER_HOST = os.getenv("CONTROLLER_HOST") or "192.168.1.146"
local AJAX_PATH       = "/ajax/mode_change"
local CURL_TIMEOUT_S  = 8

-- Cache the admin password fetched from Redis. nil until first lookup.
local _credentials_cache = nil

local function shell_quote(s)
    -- Single-quote and escape any embedded single quotes.
    return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

-- Pull the controller-admin credentials once from Redis db=5/web/users.
-- Returns (username, password, err). Uses the same ssh+python pattern as
-- controller.lua so the robot doesn't need redis-cli locally.
local function load_credentials()
    if _credentials_cache then
        return _credentials_cache.user, _credentials_cache.pass, nil
    end
    local cmd = [[ssh pi@irrigation 'python3 -c "
import redis, json
r = redis.Redis(db=5)
h = r.hgetall(\"web\")
users = json.loads(h[b\"users\"].decode())
for u, p in users.items():
    print(u + \":\" + p)
    break
" ' 2>/dev/null]]
    local pipe = io.popen(cmd, "r")
    if not pipe then return nil, nil, "io.popen failed" end
    local raw = pipe:read("*a") or ""
    pipe:close()
    local user, pass = raw:match("^([^:]+):([^\n]+)")
    if not user or not pass then
        return nil, nil, "could not parse credentials from: " .. raw:sub(1, 80)
    end
    _credentials_cache = { user = user, pass = pass }
    return user, pass, nil
end

local function live_mode()
    local v = os.getenv("SKIP_LIVE")
    if not v then return false end
    v = v:lower()
    return v == "1" or v == "true" or v == "yes" or v == "on"
end

-- POST a mode-change to the controller.
-- command: one of "SKIP_STATION", "CLOSE_MASTER_VALVE" (other values
--          accepted but be sure the controller knows them).
-- opts (optional): { schedule_name, step, run_time, logger }
-- Returns (ok, http_code, err).
--   ok=true, http_code=200..299 → controller accepted
--   ok=false, err="dry_run"     → SKIP_LIVE is off (informational)
--   ok=false, err=...           → real failure
function M.post(command, opts)
    opts = opts or {}
    if not command or command == "" then
        return false, nil, "command empty"
    end
    local logger = opts.logger or function() end

    local body = string.format(
        [[{"command":"%s","schedule_name":"%s","step":"%s","run_time":"%s"}]],
        command,
        opts.schedule_name or "",
        opts.step          or "",
        opts.run_time      or "")

    if not live_mode() then
        logger(string.format("dry_run: WOULD POST %s %s body=%s",
            CONTROLLER_HOST, AJAX_PATH, body))
        return false, nil, "dry_run"
    end

    local user, pass, cerr = load_credentials()
    if not user then return false, nil, "credentials: " .. tostring(cerr) end

    local url = string.format("http://%s%s", CONTROLLER_HOST, AJAX_PATH)
    -- -s silent, -S show errors, --digest+--user for HTTP Digest auth,
    -- -w "%{http_code}" appends the HTTP status to stdout for capture.
    -- -b '' enables the cookie engine in-memory: Flask's HTTPDigestAuth
    -- binds the WWW-Authenticate nonce to the session cookie, so the
    -- second leg of the digest handshake must echo the cookie back or
    -- the server can't find the nonce and returns 401.
    local cmd = string.format(
        "curl -sS --digest -u %s -b '' --max-time %d " ..
        "-H 'Content-Type: application/json' " ..
        "-X POST -d %s -o /dev/null -w '%%{http_code}' %s 2>&1",
        shell_quote(user .. ":" .. pass),
        CURL_TIMEOUT_S,
        shell_quote(body),
        shell_quote(url))

    local pipe = io.popen(cmd, "r")
    if not pipe then return false, nil, "io.popen failed" end
    local out = pipe:read("*a") or ""
    pipe:close()
    -- curl's -w '%{http_code}' writes the 3-digit code at end. Anything
    -- else on stdout (with -sS we should only see errors here) is failure.
    local code = tonumber(out:match("(%d%d%d)$"))
    if not code then
        return false, nil, "curl: no http_code in output: " .. out:sub(1, 200)
    end
    if code >= 200 and code < 300 then
        logger(string.format("POST %s %s → %d", CONTROLLER_HOST, command, code))
        return true, code, nil
    end
    return false, code, string.format("http %d (body=%s)", code, body)
end

-- Expose for tests.
M._live_mode = live_mode
M._load_credentials = load_credentials

return M
