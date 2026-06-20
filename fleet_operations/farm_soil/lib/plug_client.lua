-- lib/plug_client.lua — Voice Monkey trigger client.
--
-- The irrigation Pi (192.168.1.146) is powered by an Amazon Basics smart
-- plug. That plug has NO local/LAN API — it is only reachable through
-- Amazon/Alexa. We drive it via Voice Monkey, a free Alexa skill that
-- exposes an HTTPS "trigger" webhook. In the Alexa app an operator wires a
-- Routine once:
--     "When <trigger device> activates  ->  turn ON <the plug>"
-- Firing the webhook below runs that routine and powers the plug on.
--
-- v3 trigger API (https://voicemonkey.io/docs/api/trigger.html):
--     GET https://api-v3.voicemonkey.io/trigger?token=<secret>&device=<id>
--     -> 200 {"success":true,"data":"OK"}
--
-- The token is a secret — treat it like a password. It is carried in a
-- transient `curl -K` config file (never on argv), the same hardening as
-- cimis_client / irrigation_client; `--data-urlencode` keeps token+device
-- safely encoded. The device id is deployment data (useless without the
-- token) and is passed in by the caller from class_spec.
--
-- Fire-and-forget: Alexa cannot report the plug's real state back, so a
-- returned ok=true means only that Amazon ACCEPTED the trigger — not that
-- the Pi powered up. The watchdog closes that loop by re-probing the Pi.
-- (If the Pi is down for a non-power reason, "turn ON" is a harmless no-op
-- and the watchdog falls through to the Discord nag — graceful degradation.)
--
-- API:
--   M.new{ token, device, base_url?, curl?, timeout_s?, tmp_path? }
--   client:trigger()   -> ok(bool), err(string|nil)

local cjson = require("cjson")

local M = {}
M.__index = M

local DEFAULT_BASE_URL = "https://api-v3.voicemonkey.io/trigger"
local STATUS_MARK      = "__VM_HTTP_STATUS__"

function M.new(opts)
    opts = opts or {}
    local token  = opts.token
    assert(token and token ~= "",   "plug_client: token required")
    local device = opts.device
    assert(device and device ~= "", "plug_client: device required")
    return setmetatable({
        token     = token,
        device    = device,
        base_url  = opts.base_url or DEFAULT_BASE_URL,
        curl      = opts.curl or "curl",
        timeout_s = opts.timeout_s or 15,
        tmp_path  = opts.tmp_path,        -- nil => os.tmpname()
    }, M)
end

local function write_k(path, lines)
    local fh, oerr = io.open(path, "w")
    if not fh then
        return false, "plug_client: cannot open " .. path
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
        return "", 0, false, "plug_client: no response (is curl installed?)"
    end
    local code = tonumber(status)
    if code == 0 then
        return "", 0, false, "plug_client: connection failed (curl http_code 000)"
    end
    if code < 200 or code >= 300 then
        return body, code, false,
            string.format("plug_client: HTTP %d: %s", code, body:sub(1, 200))
    end
    return body, code, true, nil
end

-- Fire the Voice Monkey trigger (runs the Alexa "turn ON" routine).
-- Returns (ok, err). ok means Amazon accepted the trigger.
function M:trigger()
    local cfg = (self.tmp_path or os.tmpname()) .. ".k"
    local function cleanup() os.remove(cfg) end

    local ok, werr = write_k(cfg, {
        string.format('url = "%s"', self.base_url),
        'get',
        string.format('data-urlencode = "token=%s"', self.token),
        string.format('data-urlencode = "device=%s"', self.device),
    })
    if not ok then cleanup(); return false, werr end

    local raw, _code, cok, cerr = run_curl(self.curl, self.timeout_s, cfg)
    cleanup()
    if not cok then return false, cerr end

    -- Body is {"success":true,"data":"OK"}; an explicit success=false is a
    -- 200 with a logical rejection (bad device id, etc.) — treat as failure.
    local dok, dec = pcall(cjson.decode, raw)
    if dok and type(dec) == "table" and dec.success == false then
        return false, "plug_client: trigger rejected: " .. raw:sub(1, 200)
    end
    return true, nil
end

return M
