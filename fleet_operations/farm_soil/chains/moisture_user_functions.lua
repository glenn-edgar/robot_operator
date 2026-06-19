-- chains/moisture_user_functions.lua — ct_* user fns for the moisture KB.
--
-- MOISTURE_FETCH (a one-shot leaf): fetch the TTN lookback window, decode,
-- and for each NEW uplink — append it to the per-sensing-point in-memory
-- ring AND publish it as its own small `latest` message. Per-sample, never
-- a blob: a multi-KB payload does not traverse zenoh-pico (confirmed by the
-- real-data smoke), but a ~500 B reading does.
--
-- Also exports handle_sample_request(handle, payload) — main.lua's pump
-- calls it for the `sample` RPC: a consumer pulls one ring entry by index
-- (0 = newest) for ad-hoc queries and gap backfill.
--
-- The robot holds the rings in the blackboard (bb._moisture_slots). Nothing
-- is read back from zenohd.
--
-- Containment (the robustness requirement): a TTN fetch error is a return
-- value, not a raise — the leaf logs and skips the cycle. Zenoh publishes
-- are pcall-wrapped — a zenohd outage cannot crash the KB or the pump.
--
-- Config — from class_spec, attached to the blackboard by main.lua:
--   bb._class_spec.ttn = { url_base, app_name, url_after, lookback_hours, limit }
--   bb._class_spec.device_locations = { [device_id] = location, ... }
-- Secret: TTN_BEARER_TOKEN from the environment (run.sh sources secrets/).

local cjson      = require("cjson")
local ttn_client = require("ttn_client")
local decoder    = require("decoder")
local moisture   = require("moisture")
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

-- The moisture KB's fetch cadence (matches FETCH_INTERVAL_S in
-- chains/moisture.lua). KB0 uses it as the heartbeat-staleness yardstick.
local FETCH_INTERVAL_S = 3600

local function log(id, fmt, ...)
    io.stderr:write(string.format(
        "moisture [%s]: " .. fmt .. "\n", id.namespace, ...))
end

-- RFC3339 UTC timestamp `lookback_hours` before now — the TTN `after` arg.
local function after_iso(lookback_hours)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - lookback_hours * 3600)
end

-- Publish one reading as a small message on the sensing point's `latest`
-- key. pcall-wrapped — a publish failure is contained and logged; the ring
-- keeps the record, and the `sample` RPC can still serve it. Returns true
-- on success.
local function publish_reading(id, ps, device, location, record)
    local key = id.namespace .. "/" .. device .. "/" .. location .. "/latest"
    local msg = moisture.reading_json(id.class, id.instance, device, location, record)
    local ok, err = pcall(function() ps:publish(key, msg) end)
    if not ok then
        log(id, "publish failed for %s/%s (%s)", device, location, tostring(err))
    end
    return ok
end

M.one_shot.MOISTURE_FETCH = function(handle, node)
    local bb = handle.blackboard
    local id, cs, ps = bb._identity, bb._class_spec, bb._pubsub
    local ttn_cfg = cs.ttn or {}

    local token = os.getenv("TTN_BEARER_TOKEN")
    if not token or token == "" then
        log(id, "TTN_BEARER_TOKEN not set — skipping fetch")
        app_heartbeat.stamp(handle, "moisture", "degraded",
            "TTN_BEARER_TOKEN not set", FETCH_INTERVAL_S)
        return
    end

    bb._moisture_slots = bb._moisture_slots or {}
    local slots = bb._moisture_slots
    -- First fetch after a process boot: hydrate the rings from the bind
    -- mount. Without this, every container restart treats the TTN backlog
    -- as all-new (the in-memory ring is empty) and republishes ~10x
    -- duplicates of the same f_cnts, evicting the real history from the
    -- persistence ring. With hydration, ring_append's received_at dedup
    -- naturally drops the overlap.
    if not bb._moisture_hydrated then
        local loaded = moisture.load_all_slots(id, cs.device_locations)
        for sp, slot in pairs(loaded) do
            if not slots[sp] then slots[sp] = slot end
        end
        bb._moisture_hydrated = true
        local n = 0; for _ in pairs(loaded) do n = n + 1 end
        if n > 0 then
            log(id, "hydrated %d ring(s) from disk", n)
        end
    end

    -- Fetch the lookback window. ttn_client returns errors, never raises.
    local client = ttn_client.new{
        url_base     = ttn_cfg.url_base,
        app_name     = ttn_cfg.app_name,
        url_after    = ttn_cfg.url_after,
        bearer_token = token,
        limit        = ttn_cfg.limit or 200,
    }
    local body, ok, err = client:fetch(after_iso(ttn_cfg.lookback_hours or 24))
    if not ok then
        log(id, "TTN fetch failed (%s) — skipping cycle", tostring(err))
        app_heartbeat.stamp(handle, "moisture", "degraded",
            "TTN fetch failed", FETCH_INTERVAL_S)
        return
    end

    -- Decode; feed the rings oldest-first (TTN returns ascending, sort to
    -- be sure). Each genuinely-new uplink is ringed AND published per-sample.
    local uplinks = decoder.parse_uplinks(body)
    table.sort(uplinks, function(a, b)
        return tostring(a.received_at) < tostring(b.received_at)
    end)

    local locations = cs.device_locations or {}
    local appended, published = 0, 0
    for _, up in ipairs(uplinks) do
        local device   = up.device_id
        local location = locations[device] or "unknown"
        local sp = device .. "/" .. location
        local slot = slots[sp]
        if not slot then
            slot = moisture.new_slot(device, location)
            slots[sp] = slot
        end
        local record = moisture.record_from_uplink(up)
        if moisture.ring_append(slot, record) then
            appended = appended + 1
            -- Persist the slot after every accepted append. Cheap (a few
            -- hundred KB JSON write at most), and guarantees the next
            -- restart sees this uplink already in the ring so we won't
            -- republish it. pcall-wrapped: a disk error is non-fatal.
            local sok, serr = pcall(moisture.save_slot, id, slot)
            if not sok then
                log(id, "ring save failed for %s/%s: %s", device, location, tostring(serr))
            end
            if publish_reading(id, ps, device, location, record) then
                published = published + 1
            end
        end
    end

    log(id, "fetch ok — %d uplinks, %d new readings, %d published",
        #uplinks, appended, published)
    app_heartbeat.stamp(handle, "moisture", "ok",
        string.format("%d uplinks, %d new", #uplinks, appended), FETCH_INTERVAL_S)
end

-- `sample` RPC handler — main.lua's pump calls this with the request
-- payload. Request JSON: { device, location, index } (index 0 = newest).
-- Reply JSON: a reading message, or {..., end=true} past the ring depth, or
-- {error=...} for a malformed request / unknown sensing point. One entry per
-- request — every reply stays small.
function M.handle_sample_request(handle, req_payload)
    local id = handle.blackboard._identity
    local ok, q = pcall(cjson.decode, req_payload or "")
    if not ok or type(q) ~= "table" or not q.device or not q.location then
        return cjson.encode({ error = "bad request — need {device, location, index}" })
    end
    local index = tonumber(q.index) or 0
    local slot  = (handle.blackboard._moisture_slots or {})[q.device .. "/" .. q.location]
    if not slot then
        return cjson.encode({ error = "no such sensing point",
                              device = q.device, location = q.location })
    end
    local record = moisture.ring_at(slot, index)
    if not record then
        return cjson.encode({ device = q.device, location = q.location,
                              index = index, ["end"] = true })
    end
    return moisture.reading_json(id.class, id.instance, q.device, q.location, record)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
