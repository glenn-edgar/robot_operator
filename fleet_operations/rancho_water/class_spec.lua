-- class_spec.lua — rancho_water class spec.
--
-- The robot's job: once per Pacific civil day at-or-after `digest.hour_pacific`,
-- log in to myaccount.ranchowater.com, fetch yesterday's hourly usage, format
-- it as a fixed-width table + total, publish on fleet/notify/digest/daily.
-- The persistence layer also stores the raw JSON per day for later dashboard
-- visualization.

local M = {}

M.capabilities = {
    "heartbeat",
    "water_usage",
}

M.app_kbs = { "daily_pull" }

-- Rancho portal config. Account number is hardcoded for this single-instance
-- deployment; if we ever support multi-tenant we move it to identity or env.
-- The login username + password live in env vars sourced from
-- ../farm_soil/secrets/ttn.env (RANCHO_WATER_ACCOUNT / RANCHO_WATER_PASSWORD).
-- The account number defaults here but can be overridden via env so we don't
-- have to edit class_spec to onboard a second meter.
M.rancho = {
    account_number = os.getenv("RANCHO_WATER_ACCOUNT_NUMBER") or "3047791",
    timeout_s      = 30,
}

-- Daily-digest gate config — same shape as farm_soil.M.digest, same pattern.
-- 09:00 Pacific (after Rancho's overnight finalize) — user-specified.
-- retry_s = 15 min: if Rancho hasn't finalized yesterday by 09:00, retry
-- 15 min later until they have.
M.digest = {
    hour_pacific = 9,
    retry_s      = 900,
}

-- Persistence-topology declaration — same shape as farm_soil. Two leaves
-- under <namespace>/usage:
--   * sample  — per-day stream (kept ~3 months so the dashboard can chart
--               history); one publish per finalized day.
--   * latest  — UPSERT status with the freshest day's full JSON.
function M.persistence_topology()
    return {
        { path   = "usage/sample",
          kind   = "stream",
          length = 90,
          desc   = "Rancho daily water-usage JSON, one per finalized day" },
        { path = "usage/latest",
          kind = "status",
          desc = "Rancho most-recent finalized day (full JSON)" },
        { path = "heartbeat",
          kind = "status",
          desc = "robot rolled-up heartbeat" },
    }
end

-- Publish persistence_topology on namespace_up + periodically (so a
-- late-joining persistence service catches it within the cadence). Same
-- shape as farm_soil's variant — could share via robot_common later.
function M.publish_persistence_topology(ps, identity, silent)
    local cjson = require("cjson")
    local topo = M.persistence_topology()
    local payload = cjson.encode({
        schema   = "persistence_topology/1",
        class    = identity.class,
        instance = identity.instance,
        entries  = topo,
    })
    local function pub(key)
        local ok, err = pcall(function() ps:publish(key, payload) end)
        if not ok then
            io.stderr:write(string.format(
                "RANCHO_WATER [%s]: persistence_topology publish to %s failed: %s\n",
                identity.namespace, key, tostring(err)))
        end
        return ok
    end
    local ok1 = pub(identity.namespace .. "/persistence_topology")
    local ok2 = pub("fleet/admin/persistence_topology_announce")
    if ok1 and ok2 and not silent then
        io.stderr:write(string.format(
            "RANCHO_WATER [%s]: persistence_topology published (%d entries, 2 channels)\n",
            identity.namespace, #topo))
    end
    return ok1 and ok2
end

M.PERSISTENCE_TOPOLOGY_REPUBLISH_S = 30

-- Class hook, run after KB0 publishes the core namespace leaves.
function M.on_namespace_up(ps, identity, bb)
    M.publish_persistence_topology(ps, identity, false)
end

return M
