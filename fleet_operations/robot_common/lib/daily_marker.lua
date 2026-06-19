-- robot_common/lib/daily_marker.lua — persist a "did we do X today?" date
-- across robot restarts.
--
-- Daily-gated work (digest publish, rancho_water daily_pull, etc.) tracks
-- "already published today" in the blackboard. The blackboard is in-memory
-- and dies on restart, so a container that restarts after today's work
-- already went out re-publishes on the next in-window tick — Discord spam,
-- duplicate persistence entries.
--
-- This module mirrors that BB state to a tiny per-marker file on the bind
-- mount. On each gate evaluation, we read the file first (cheaper than
-- a Zenoh RPC, idempotent across restarts). On successful publish, we
-- write the file.
--
-- File path:
--   ${FLEET_DATA_DIR}/daily_markers/<class>_<instance>_<key>.txt
-- Content:
--   single line, ISO date "YYYY-MM-DD"
--
-- FLEET_DATA_DIR is set by the container supervisor (/var/fleet). For bench
-- runs without that env, we fall back to ./var (cwd-relative) which is
-- where bench artefacts already live per the no-/tmp rule.

local M = {}

local function root_dir()
    local d = os.getenv("FLEET_DATA_DIR")
    if d and #d > 0 then return d end
    return "./var"
end

local function marker_dir()
    return root_dir() .. "/daily_markers"
end

local function marker_path(identity, key)
    return string.format("%s/%s_%s_%s.txt",
        marker_dir(), identity.class, identity.instance, key)
end

local function ensure_dir(path)
    -- mkdir -p; on failure we let the subsequent open fail naturally.
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
end

-- Returns the date string previously persisted, or nil if no marker.
function M.read(identity, key)
    local f = io.open(marker_path(identity, key), "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    if not s then return nil end
    s = s:match("^%s*(.-)%s*$")
    if #s == 0 then return nil end
    return s
end

-- Persist `date_str` as today's marker. Idempotent.
function M.write(identity, key, date_str)
    ensure_dir(marker_dir())
    local path = marker_path(identity, key)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(date_str, "\n")
    f:close()
    return true
end

-- Convenience: did we already do `key` on `today`?
function M.already_done_today(identity, key, today)
    return M.read(identity, key) == today
end

return M
