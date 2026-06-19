-- baselines.lua — loader for baselines.json (curve generator output).
--
-- Single-file consumer: read once at startup, return a table keyed by
-- bin_key for O(1) lookup. Robot side compares per-bin reductions or
-- live samples against the stored ref + thresholds.
--
-- Schema produced by explore/generate_curves.py is "baseline.v1".

local cjson = require("cjson")
local M = {}

local SUPPORTED_SCHEMA = "baseline.v1"

-- Canonicalize a compound bin_key by sorting its valve components.
-- Controller emits compound keys in arbitrary order (e.g. past_actions
-- saw "satellite_1:39/satellite_4:6/satellite_4:8" on 2026-06-01 while
-- time_history had "satellite_4:6/satellite_4:8/satellite_1:39"); pure
-- hash lookup against either form silently misses the bin, so a 50-sample
-- pipe break on 4:6/4:8 went undetected and cost ~500 gal city water.
function M.canonicalize_key(bin_key)
    if not bin_key or type(bin_key) ~= "string" then return bin_key end
    if not bin_key:find("/", 1, true) then return bin_key end
    local parts = {}
    for p in bin_key:gmatch("[^/]+") do parts[#parts+1] = p end
    table.sort(parts)
    return table.concat(parts, "/")
end

-- Load baselines.json. Returns (loaded_table, n_long, n_short, err).
-- Re-keys all bins through canonicalize_key on load, so the file can
-- have been written with any valve ordering and lookup still resolves.
function M.load(path)
    local fh, oerr = io.open(path, "r")
    if not fh then return nil, 0, 0, "open: " .. tostring(oerr) end
    local raw = fh:read("*a"); fh:close()
    if not raw or raw == "" then return nil, 0, 0, "empty file" end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then return nil, 0, 0, "decode: " .. tostring(decoded) end
    if decoded.schema ~= SUPPORTED_SCHEMA then
        return nil, 0, 0, "unsupported schema: " .. tostring(decoded.schema)
    end
    if type(decoded.bins) ~= "table" then
        return nil, 0, 0, "missing 'bins' table"
    end
    local rekeyed = {}
    for k, v in pairs(decoded.bins) do
        rekeyed[M.canonicalize_key(k)] = v
    end
    decoded.bins = rekeyed
    local n_long, n_short = 0, 0
    for _, v in pairs(decoded.bins) do
        if v.mode == "long" then n_long = n_long + 1
        elseif v.mode == "short" then n_short = n_short + 1 end
    end
    return decoded, n_long, n_short, nil
end

-- Convenience: pull out the per-bin entry for a given key. Returns nil
-- if missing or if loaded is nil. Caller passes the bin_key as observed
-- from past_actions; we canonicalize before lookup so valve-ordering
-- mismatches between controller streams don't cause silent misses.
function M.lookup(loaded, bin_key)
    if not loaded or not loaded.bins or not bin_key then return nil end
    return loaded.bins[M.canonicalize_key(bin_key)]
end

-- Bool: bin is long-mode and KB3-eligible (low-noise enough to live-monitor).
function M.kb3_eligible(loaded, bin_key)
    local e = M.lookup(loaded, bin_key)
    return e ~= nil and e.mode == "long" and e.kb3_eligible == true
        and e.kb3_threshold ~= nil and e.ref ~= nil
end

return M
