-- lib/moisture.lua — moisture skill core: uplink records, the per-sensing-
-- point ring buffer, ring access by index, and the per-reading message JSON.
--
-- Engine-agnostic — pure data logic, no chain_tree imports. The chain_tree
-- wiring lives in chains/moisture_user_functions.lua.
--
-- A "slot" is one sensing point (<device>/<location>): a ring of up to
-- RING_CAPACITY uplink records, oldest-first. The robot holds the ring in
-- memory and publishes each new reading as its own small message (a multi-KB
-- blob does not traverse zenoh-pico — confirmed by the real-data smoke). The
-- ring is served by index via the `sample` RPC; it is never one big object.

local cjson = require("cjson")

local M = {}

M.SCHEMA_READING = "moisture.reading/1"
M.RING_CAPACITY  = 256

-- SenseCAP S2105 measurement ids -> field names. The decoder is generic
-- (id + value); naming is the moisture skill's job.
M.MEASUREMENT_NAME = {
    [4108] = "moisture",     -- volumetric water content (m3/m3)
    [4102] = "soil_temp",    -- soil temperature (C)
    [4103] = "ec",           -- soil EC (mS/cm)
}

local UNITS = {
    moisture = "m3/m3", soil_temp = "C", ec = "mS/cm",
    rssi = "dBm", snr = "dB", battery = "%",
}

-- Build a slot entry (one uplink record) from a decoder uplink: map
-- measurement ids to named fields, fold gateway/battery into `link`.
function M.record_from_uplink(up)
    local measurements = {}
    for _, m in ipairs(up.measurements or {}) do
        local name = M.MEASUREMENT_NAME[m.measurement_id]
        if name then measurements[name] = m.value end
    end
    local g = up.gateway or {}
    return {
        received_at  = up.received_at,
        f_cnt        = up.f_cnt,
        measurements = measurements,
        link = {
            gateway_id       = g.gateway_id,
            gateway_count    = g.gateway_count,
            rssi             = g.rssi,
            channel_rssi     = g.channel_rssi,
            snr              = g.snr,
            frequency        = g.frequency,
            spreading_factor = g.spreading_factor,
            bandwidth        = g.bandwidth,
            coding_rate      = g.coding_rate,
            airtime_s        = g.airtime_s,
            battery          = (up.battery_present and up.battery_value) or nil,
        },
    }
end

-- A fresh, empty slot for a sensing point.
function M.new_slot(device, location)
    return { device = device, location = location, ring = {} }
end

-- Append `record` to the slot's ring IFF it is strictly newer than the
-- ring's current newest entry — the timestamp reconcile: a re-fetched uplink
-- (received_at <= newest) is dropped. Evicts the oldest past RING_CAPACITY.
-- Records must be fed oldest-first. Returns true if appended.
--
-- received_at is TTN's RFC3339 UTC string; consistent formatting makes a
-- lexicographic compare equivalent to a chronological one.
function M.ring_append(slot, record)
    local ring = slot.ring
    local newest = ring[#ring]
    if newest and tostring(record.received_at) <= tostring(newest.received_at) then
        return false
    end
    ring[#ring + 1] = record
    while #ring > M.RING_CAPACITY do
        table.remove(ring, 1)
    end
    return true
end

-- The ring entry at `index` — 0 = newest, 1 = next-newest, … — or nil when
-- the index is past the ring's current depth. The `sample` RPC uses this.
function M.ring_at(slot, index)
    local pos = #slot.ring - index
    if pos < 1 then return nil end
    return slot.ring[pos]
end

-- Encode one reading as a small published/replied message: a self-
-- identifying envelope wrapping a single uplink record.
function M.reading_json(class, instance, device, location, record)
    return cjson.encode({
        schema   = M.SCHEMA_READING,
        class    = class,
        instance = instance,
        device   = device,
        location = location,
        units    = UNITS,
        entry    = record,
    })
end

-- ---------------------------------------------------------------------------
-- Ring persistence to disk
--
-- bb._moisture_slots lives in process memory. Without persistence, every
-- container restart fetches the TTN backlog (the join server keeps several
-- days of uplinks) into an EMPTY ring, treats every uplink as "new", and
-- republishes the whole backlog. The persistence stream then fills with
-- duplicates and the real oldest history is evicted.
--
-- Save each slot as a small JSON file on the bind mount. Load on first
-- fetch cycle; subsequent ring_append's natural dedup-by-received_at then
-- drops the TTN backlog overlap.
--
-- File layout:
--   ${FLEET_DATA_DIR}/moisture_rings/<class>_<instance>_<sanitized_sp>.json
-- Contents:
--   { device, location, ring = [...] }   -- same shape as a slot
-- ---------------------------------------------------------------------------

local function root_dir()
    local d = os.getenv("FLEET_DATA_DIR")
    if d and #d > 0 then return d end
    return "./var"
end

local function rings_dir()
    return root_dir() .. "/moisture_rings"
end

-- Sanitize a sensing-point label (device/location) for use in a path.
-- Operator-supplied strings shouldn't normally contain shell metas, but
-- a single defensive pass cheap.
local function sanitize(s)
    return (tostring(s):gsub("[^%w%._%-]", "_"))
end

local function slot_path(identity, device, location)
    return string.format("%s/%s_%s_%s_%s.json",
        rings_dir(),
        sanitize(identity.class), sanitize(identity.instance),
        sanitize(device),         sanitize(location))
end

local function ensure_dir(path)
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
end

-- Write `slot` to its on-disk JSON file. Atomic: writes to <path>.tmp
-- and renames so a process death mid-write cannot leave a half-file.
-- Returns true on success, nil+err on failure.
function M.save_slot(identity, slot)
    if not slot or not slot.device or not slot.location then
        return nil, "save_slot: missing device/location"
    end
    ensure_dir(rings_dir())
    local final = slot_path(identity, slot.device, slot.location)
    local tmp   = final .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then return nil, err end
    local ok_enc, encoded = pcall(cjson.encode, {
        device = slot.device, location = slot.location, ring = slot.ring or {},
    })
    if not ok_enc then
        f:close(); os.remove(tmp)
        return nil, "encode failed: " .. tostring(encoded)
    end
    f:write(encoded)
    f:close()
    local ok, rn_err = os.rename(tmp, final)
    if not ok then return nil, rn_err end
    return true
end

-- Load slot from disk; returns the slot table (with `ring`) or nil if no
-- file or unreadable/malformed. Silent on absence — that's the cold-boot
-- case, not an error.
function M.load_slot(identity, device, location)
    local f = io.open(slot_path(identity, device, location), "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or #content == 0 then return nil end
    local ok, obj = pcall(cjson.decode, content)
    if not ok or type(obj) ~= "table" or type(obj.ring) ~= "table" then
        return nil
    end
    return {
        device   = obj.device   or device,
        location = obj.location or location,
        ring     = obj.ring,
    }
end

-- Load every slot for the configured (device, location) pairs. Missing
-- files are skipped (returns an empty entry — the caller then treats
-- it as a fresh ring on the next fetch).
function M.load_all_slots(identity, device_locations)
    local slots = {}
    if not device_locations then return slots end
    for device, location in pairs(device_locations) do
        local slot = M.load_slot(identity, device, location)
        if slot then
            slots[device .. "/" .. location] = slot
        end
    end
    return slots
end

return M
