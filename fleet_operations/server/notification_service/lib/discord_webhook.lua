-- server/notification_service/lib/discord_webhook.lua
--
-- Port of robot_person/skills/discord/{webhook_client.py,main.py}. One HTTPS
-- POST per call: JSON body with {content, username}, expects HTTP 2xx (204
-- in practice; 200 if Discord's wait=true is set, which we don't).
--
-- Two gotchas carried over from the Python:
--   * Cloudflare edge rejects the default LuaSec User-Agent with HTTP 403
--     (error 1010). Send an identified UA per Discord's webhook guidelines.
--   * Discord caps message content at 2000 chars. Longer content is
--     truncated with a trailing ellipsis; truncation is logged so the caller
--     can decide whether to split.
--
-- Returns (ok :: bool, err_msg :: string|nil). Never raises — network and
-- HTTP errors come back as the err_msg.
--
-- `opts._post` is the test-injection seam: a function with the same shape as
-- the default https POST, called instead of touching the network. Mirrors
-- the Python `_post` constructor parameter.

local cjson = require("cjson")

local M = {}

M.CONTENT_MAX = 2000
M.DEFAULT_USERNAME = "farm_robot"
M.USER_AGENT = "fleet_design-notification_service/1.0 (+https://example.invalid)"
M.DEFAULT_TIMEOUT_S = 5

-- Default transport: LuaSec sync request with a string body source.
--
-- LuaSec's https.request returns 4 values (r, c, h, sline):
--   * on success:  r == 1, c == HTTP status code (e.g. 204), h headers
--   * on failure:  r == nil, c is the error message string
-- pcall wraps that, so we unpack as (ok, r, c, h, sline).
local function default_post(webhook_url, payload_json, timeout_s)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local prev_timeout = https.TIMEOUT
    https.TIMEOUT = timeout_s or M.DEFAULT_TIMEOUT_S
    local sink_t = {}
    local ok, r, c, _h, sline = pcall(function()
        return https.request({
            url     = webhook_url,
            method  = "POST",
            headers = {
                ["Content-Type"]   = "application/json",
                ["User-Agent"]     = M.USER_AGENT,
                ["Content-Length"] = tostring(#payload_json),
            },
            source = ltn12.source.string(payload_json),
            sink   = ltn12.sink.table(sink_t),
        })
    end)
    https.TIMEOUT = prev_timeout
    if not ok then
        return false, "transport error: " .. tostring(r)
    end
    if r == nil then
        return false, "URL error: " .. tostring(c)
    end
    if type(c) == "number" and c >= 200 and c < 300 then
        return true, nil
    end
    local body_str = table.concat(sink_t)
    return false, string.format("HTTP %s %s: %s",
        tostring(c), tostring(sline or ""):sub(1, 80),
        body_str:sub(1, 240))
end

-- Build the {content, username} table Discord expects. Truncates over-long
-- content; logs truncation via opts.logger so the caller knows the message
-- was clipped.
local function build_payload(content, opts)
    local logger = opts.logger or function() end
    if #content > M.CONTENT_MAX then
        logger(string.format(
            "discord: content %d chars > %d, truncating",
            #content, M.CONTENT_MAX))
        content = content:sub(1, M.CONTENT_MAX - 3) .. "..."
    end
    return {
        content  = content,
        username = opts.username or M.DEFAULT_USERNAME,
    }
end

-- Send one Discord message. Public API.
function M.send(webhook_url, content, opts)
    opts = opts or {}
    local logger = opts.logger or function() end
    if not webhook_url or webhook_url == "" then
        return false, "webhook_url is empty"
    end
    if not content or content == "" then
        logger("discord: send refused — content is empty")
        return false, "content is empty"
    end
    local payload = build_payload(content, opts)
    local payload_json = cjson.encode(payload)
    logger(string.format(
        "discord: POSTing %d chars as %q",
        #payload.content, payload.username))
    local post = opts._post or default_post
    local ok, err = post(webhook_url, payload_json, opts.timeout_s)
    if ok then
        logger("discord: 2xx OK (message sent)")
    else
        logger("discord: send FAILED — " .. tostring(err))
    end
    return ok, err
end

return M
