-- registry.lua — in-memory robot registry for the fleet_manager layer.
--
-- The fleet controller is a passive registry (decision #29): it records what
-- announces itself, with no validation, NACK, or uniqueness enforcement — the
-- robot is sovereign.
--
-- Keyed by chip_uid. Identity is <class>/<instance> (decision #2) and the
-- hardware UID is metadata (decision #8) — but chip_uid is the stable
-- per-unit key the registry dedups on across re-registrations (a robot that
-- reconnects re-announces and must not create a second row).
--
-- This module is the seam for decision #15 (SQLite registry.db): swapping the
-- in-memory dict for SQLite-backed storage is local to this file — callers
-- only use :upsert / :get / :count / :each.

local M = {}
M.__index = M

function M.new()
    return setmetatable({ _by_uid = {}, _count = 0 }, M)
end

-- Record a registration. rec fields (from the register RPC payload):
--   chip_uid, class, instance, fw_version, capabilities, ts
-- `now` is controller wall-clock epoch seconds.
-- Returns (entry, is_new).
function M:upsert(rec, now)
    local uid = rec.chip_uid or "?"
    local e = self._by_uid[uid]
    local is_new = (e == nil)
    if is_new then
        e = { chip_uid = uid, first_seen = now, register_count = 0 }
        self._by_uid[uid] = e
        self._count = self._count + 1
    end
    e.class          = rec.class
    e.instance       = rec.instance
    e.namespace      = tostring(rec.class) .. "/" .. tostring(rec.instance)
    e.fw_version     = rec.fw_version
    e.capabilities   = rec.capabilities
    e.robot_ts       = rec.ts          -- robot's own wall-clock at announce
    e.last_seen      = now
    e.register_count = e.register_count + 1
    return e, is_new
end

function M:get(uid) return self._by_uid[uid] end

function M:count() return self._count end

-- Iterate entries: fn(chip_uid, entry). Order is unspecified.
function M:each(fn)
    for uid, e in pairs(self._by_uid) do fn(uid, e) end
end

return M
