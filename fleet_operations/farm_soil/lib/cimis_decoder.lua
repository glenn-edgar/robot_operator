-- lib/cimis_decoder.lua — parser for CIMIS /api/data JSON responses.
--
-- LuaJIT port of the Python skill's decoder.py. Pure parsing — no engine
-- imports, no skill imports. Response shape (per et.water.ca.gov docs):
--
--   {"Data": {"Providers": [
--     {"Name": "cimis", "Type": "station"|"spatial",
--      "Records": [{
--         "Date": "2026-05-04",
--         "Station": "237",                                       (station)
--         "Coordinates": {"Latitude":"...","Longitude":"..."},    (spatial coord)
--         "ZipCodes": "92562",                                    (spatial zip)
--         "DayAsceEto": {"Value":"0.20","Qc":"Y","Unit":"Inches"},
--         ...other Day* / Hly* fields...
--      }]}
--   ]}}
--
-- Each Day*/Hly* key is one measurement; one record per (target, date, item).
-- Output row shape:
--
--   { target_kind = "station"|"spatial",   -- provider type
--     target      = string,                 -- station id, "lat,lng", or zip
--     date        = "YYYY-MM-DD",
--     item        = string,                 -- CIMIS PascalCase key
--     value       = number | nil,           -- nil on blank / non-numeric
--     unit        = string | nil,
--     qc          = string | nil }
--
-- Containment, not raises: a malformed body returns {}.

local cjson = require("cjson")

local M = {}

-- cjson decodes JSON null to a sentinel, not Lua nil. Treat both as absent.
local JNULL = cjson.null

local function field(t, k)
    if type(t) ~= "table" then return nil end
    local v = t[k]
    if v == nil or v == JNULL then return nil end
    return v
end

local function to_number(v)
    if v == nil or v == "" then return nil end
    return tonumber(v)
end

local function target_from_record(rec, ptype)
    if ptype == "station" then
        local s = field(rec, "Station")
        return s and tostring(s) or nil
    end
    if ptype == "spatial" then
        -- Coordinate-based spatial: response carries Coordinates.
        local coords = field(rec, "Coordinates")
        if type(coords) == "table" then
            local lat = field(coords, "Latitude")
            local lng = field(coords, "Longitude")
            if lat ~= nil and lng ~= nil then
                return tostring(lat) .. "," .. tostring(lng)
            end
        end
        -- Zip-based spatial: response carries ZipCodes.
        local zips = field(rec, "ZipCodes")
        if zips and zips ~= "" then return tostring(zips) end
        return nil
    end
    return nil
end

-- Parse a CIMIS JSON response body into a flat list of records.
function M.parse_response(body)
    if type(body) ~= "string" or body == "" then return {} end
    local ok, obj = pcall(cjson.decode, body)
    if not ok or type(obj) ~= "table" then return {} end
    local data = field(obj, "Data")
    if type(data) ~= "table" then return {} end
    local providers = field(data, "Providers")
    if type(providers) ~= "table" then return {} end

    local out = {}
    for _, prov in ipairs(providers) do
        if type(prov) == "table" then
            local ptype   = field(prov, "Type")
            local records = field(prov, "Records")
            if ptype and type(records) == "table" then
                for _, rec in ipairs(records) do
                    if type(rec) == "table" then
                        local date   = field(rec, "Date")
                        local target = target_from_record(rec, ptype)
                        if date and target then
                            for key, val in pairs(rec) do
                                if type(key) == "string"
                                   and (key:sub(1, 3) == "Day"
                                        or key:sub(1, 3) == "Hly")
                                   and type(val) == "table" then
                                    out[#out + 1] = {
                                        target_kind = ptype,
                                        target      = target,
                                        date        = date,
                                        item        = key,
                                        value       = to_number(field(val, "Value")),
                                        unit        = field(val, "Unit"),
                                        qc          = field(val, "Qc"),
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

return M
