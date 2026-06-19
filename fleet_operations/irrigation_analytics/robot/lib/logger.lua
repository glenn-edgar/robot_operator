-- logger.lua — JSON-per-line writer.
--
-- Two streams:
--   kb1.log         every poll cycle (state, samples, mode decisions)
--   kb1_events.log  Discord events sent + would-have-been-actions
--
-- Format: one JSON object per line, with leading ISO timestamp field "t".
-- Designed for grep / awk / `cat | jq` review in future sessions.
--
-- Append mode. Caller passes the destination filename + the event dict.

local cjson = require("cjson")

local M = {}

local function iso_now()
    local t = os.time()
    local frac_ms = math.floor((os.clock() * 1000) % 1000)
    -- os.clock is process CPU time, not wall clock — use os.date for wall.
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- Open in append mode; caller may keep the handle and call write() repeatedly.
function M.open(path)
    local fh, err = io.open(path, "a")
    if not fh then return nil, err end
    fh:setvbuf("line")    -- flush every newline
    return setmetatable({ fh = fh, path = path }, { __index = M })
end

function M:write(record)
    if not self.fh then return false, "logger closed" end
    record.t = record.t or iso_now()
    local line = cjson.encode(record)
    self.fh:write(line, "\n")
    return true
end

function M:close()
    if self.fh then self.fh:close(); self.fh = nil end
end

return M
