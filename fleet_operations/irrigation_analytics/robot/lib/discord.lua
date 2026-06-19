-- discord.lua — thin wrapper over notification_service/lib/discord_webhook.
--
-- The wrapper exists so KB1 can opt-out (DISCORD_WEBHOOK_URL unset →
-- log-only, no network). Also defaults the username + adds a [shadow] tag.

local M = {}

-- Optional dependency — only required when we actually try to send.
local discord_webhook
local function load_webhook()
    if discord_webhook then return discord_webhook end
    local ok, mod = pcall(require, "discord_webhook")
    if not ok then return nil, "discord_webhook lib not in package.path: " .. tostring(mod) end
    discord_webhook = mod
    return discord_webhook
end

function M.send(content, opts)
    opts = opts or {}
    local url = opts.webhook_url or os.getenv("DISCORD_WEBHOOK_URL")
    if not url or url == "" then
        return false, "DISCORD_WEBHOOK_URL not set — log-only mode"
    end
    local mod, err = load_webhook()
    if not mod then return false, err end
    local username = opts.username or "kb1_shadow"
    local logger   = opts.logger or function() end
    return mod.send(url, content, {
        username = username,
        timeout_s = opts.timeout_s or 5,
        logger = logger,
    })
end

-- Compact text formatter for a single event. main.lua calls this then
-- M.send(text, …) per event (one Discord message per fire).
function M.format_event(ev, ctx)
    -- ctx: { state, bin_key (opt), schedule, step }
    local hdr = string.format("[KB1 SHADOW] %s (%s)", ev.kind, ev.level)
    local body = ev.msg or ""
    local foot = ""
    if ctx and ctx.state then
        foot = "\nstate=" .. ctx.state
        if ctx.schedule then foot = foot .. " schedule=" .. ctx.schedule end
        if ctx.step     then foot = foot .. " step=" .. tostring(ctx.step) end
        if ctx.bin_key  then foot = foot .. " bin=" .. ctx.bin_key end
    end
    if ev.action then foot = foot .. "\nwould-have: " .. ev.action end
    return hdr .. "\n" .. body .. foot
end

return M
