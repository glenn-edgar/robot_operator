-- robot_common/lib/app_heartbeat.lua — application-KB heartbeat stamp.
--
-- An application KB records its health here once per work cycle; KB0's
-- PUBLISH_ROBOT_HEARTBEAT rolls every app KB's stamp into the robot's
-- published heartbeat. It is all one process — the "heartbeat" is a
-- blackboard stamp, not a message.
--
--   bb.app_heartbeats[kb_name] = { ts, health, detail, interval_s }
--     ts          handle.timestamp at the stamp (monotonic seconds)
--     health      "ok" | "degraded"
--     detail      short human-readable string
--     interval_s  the KB's work cadence — KB0 flags the entry stale past ~3x
--
-- Every app KB calls stamp() each cycle (the moisture KB after a fetch, etc.).
-- KB0 reads the table; it never writes it.

local M = {}

function M.stamp(handle, kb_name, health, detail, interval_s)
    local bb = handle.blackboard
    bb.app_heartbeats = bb.app_heartbeats or {}
    bb.app_heartbeats[kb_name] = {
        ts         = handle.timestamp or 0,
        health     = health,
        detail     = detail,
        interval_s = interval_s,
    }
end

return M
