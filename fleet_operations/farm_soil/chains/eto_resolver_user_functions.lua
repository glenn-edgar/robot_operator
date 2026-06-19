-- chains/eto_resolver_user_functions.lua — ct_* user fns for the eto_resolver KB.
--
-- ETO_RESOLVE_TICK runs every retry_s. It walks the priority chain from
-- bb._class_spec.eto_resolver.priority, e.g.
--    { "SE224", "cimis_spatial", "SRUC1", "cimis_station" }
-- and picks the FIRST source for which:
--   * a latest record exists in the blackboard
--   * the record's date == California yesterday
--   * status == "OK"
--   * coverage >= min_coverage (default 0.85; non-Synoptic sources are
--     treated as coverage=1.0 since they don't report it)
--
-- Each tick records all source verdicts into the result envelope so the
-- dashboard can show why a particular source won. Publishes to:
--   <namespace>/eto/daily   — stream (one record per published day)
--   <namespace>/eto/latest  — status (last-write-wins, the freshest day)
--
-- Idempotency: publish once per (date), tracked by state.last_published_date.
-- Robot restart re-publishes for the day (acceptable v1 — the dashboard
-- shows the same data either way; the stream KB de-dups by row identity at
-- the persistence layer is NOT relied on, but a duplicate stream row is
-- harmless to the dashboard).
--
-- Discord push (optional, deferred to follow-up): a body string on the
-- shared notify channel naming which source won and what fell through.
-- Not wired in this slice — Glenn explicitly said "few more changes"
-- before deploy; one of them may be the resolver-notify body.

local cjson         = require("cjson")
local clock         = require("clock")
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

local SCHEMA_ETO       = "irrigation.eto_resolved/1"
local DEFAULT_RETRY_S  = 900
local DEFAULT_MIN_COV  = 0.85

local function log(id, fmt, ...)
    io.stderr:write(string.format(
        "eto_resolver [%s]: " .. fmt .. "\n", id.namespace, ...))
end

-- Map a priority-chain entry to its blackboard state + a normalized accessor.
-- Returns:
--   verdict       = "ok" | "no_record" | "stale" | "sparse" | "low_coverage"
--   eto_in        = number (if ok or low_coverage)
--   date          = ISO (if a record exists)
--   coverage      = number (0..1, optional)
--   n_obs         = number (optional)
--   status_str    = string (PARTIAL/SPARSE/OK if Synoptic)
local function probe_source(bb, source_id, yesterday, min_coverage)
    if source_id == "SE224" or source_id == "SRUC1" then
        local st = (bb._synoptic or {})[source_id]
        local r  = st and st.last_record
        if not r then return { verdict = "no_record" } end
        if r.date ~= yesterday then
            return { verdict = "stale", date = r.date, eto_in = r.eto,
                     coverage = r.coverage, n_obs = r.n_obs, status_str = r.status }
        end
        if r.status ~= "OK" then
            return { verdict = (r.status == "SPARSE") and "sparse" or "low_coverage",
                     date = r.date, eto_in = r.eto, coverage = r.coverage,
                     n_obs = r.n_obs, status_str = r.status }
        end
        if (r.coverage or 1) < min_coverage then
            return { verdict = "low_coverage", date = r.date, eto_in = r.eto,
                     coverage = r.coverage, n_obs = r.n_obs, status_str = r.status }
        end
        return { verdict = "ok", date = r.date, eto_in = r.eto,
                 coverage = r.coverage, n_obs = r.n_obs, status_str = r.status }
    end

    if source_id == "cimis_spatial" or source_id == "cimis_station" then
        local short = (source_id == "cimis_spatial") and "spatial" or "station"
        local cs = (bb._cimis or {})[short]
        local r  = cs and cs.last_record
        if not r then return { verdict = "no_record" } end
        if r.date ~= yesterday then
            return { verdict = "stale", date = r.date, eto_in = r.value }
        end
        if r.value == nil then return { verdict = "no_record", date = r.date } end
        return { verdict = "ok", date = r.date, eto_in = r.value, coverage = 1.0 }
    end

    return { verdict = "no_record" }
end

local function publish_resolution(id, ps, summary)
    local payload = cjson.encode(summary)
    local function pub(leaf)
        local ok, err = pcall(function()
            ps:publish(id.namespace .. "/eto/" .. leaf, payload)
        end)
        if not ok then
            log(id, "publish eto/%s failed: %s", leaf, tostring(err))
        end
    end
    pub("daily")
    pub("latest")
end

M.one_shot.ETO_RESOLVE_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local cs       = bb._class_spec
    local id, ps   = bb._identity, bb._pubsub
    local cfg      = (cs and cs.eto_resolver) or {}
    local priority = cfg.priority or { "SE224", "cimis_spatial", "SRUC1", "cimis_station" }
    local min_cov  = cfg.min_coverage or DEFAULT_MIN_COV
    local retry_s  = cfg.retry_s or DEFAULT_RETRY_S
    local kb_label = "eto_resolver"

    bb._eto_resolver = bb._eto_resolver or {}
    local state = bb._eto_resolver
    local yesterday = clock.california_yesterday()
    local p         = clock.pacific_now()
    local tz        = p.is_dst and "PDT" or "PST"

    -- Probe every source. Record verdicts even on idle cycles so the
    -- dashboard / Discord body can show fall-through reasons.
    local chain, winner = {}, nil
    for _, src in ipairs(priority) do
        local v = probe_source(bb, src, yesterday, min_cov)
        v.source = src
        chain[#chain + 1] = v
        if not winner and v.verdict == "ok" then winner = v end
    end

    -- Already published today's resolution -> idle (still record the chain
    -- snapshot to in-memory state for debugging / future RPC).
    if state.last_published_date == yesterday and winner
       and state.last_winner == winner.source then
        state.last_chain = chain
        app_heartbeat.stamp(handle, kb_label, "ok",
            string.format("idle — %s already resolved (%s won)",
                yesterday, winner.source),
            retry_s)
        return
    end

    if not winner then
        -- No eligible source. Report degraded; the chain summary is useful.
        local reasons = {}
        for _, c in ipairs(chain) do
            reasons[#reasons + 1] = c.source .. ":" .. c.verdict
        end
        local why = table.concat(reasons, " ")
        log(id, "no eligible source yet for %s — %s (Pacific %02d:%02d %s)",
            yesterday, why, p.hour, p.minute, tz)
        state.last_chain = chain
        app_heartbeat.stamp(handle, kb_label, "degraded",
            "waiting for source: " .. why:sub(1, 100), retry_s)
        return
    end

    -- Publish.
    local summary = {
        schema           = SCHEMA_ETO,
        class            = id.class,
        instance         = id.instance,
        date             = yesterday,
        eto_in           = winner.eto_in,
        source           = winner.source,
        coverage         = winner.coverage,
        n_obs            = winner.n_obs,
        status           = winner.status_str or "OK",
        fallback_chain   = chain,
        priority         = priority,
        min_coverage     = min_cov,
    }
    publish_resolution(id, ps, summary)

    state.last_published_date = yesterday
    state.last_winner         = winner.source
    state.last_record         = summary
    state.last_chain          = chain

    log(id, "resolved %s -> %s (ETo=%.3f in, cov=%.2f)",
        yesterday, winner.source, winner.eto_in or 0/0, winner.coverage or 0)
    app_heartbeat.stamp(handle, kb_label, "ok",
        string.format("resolved %s — %s ETo=%.3f",
            yesterday, winner.source, winner.eto_in or 0/0),
        retry_s)
end

-- Repost handler — main.lua's pump may serve <namespace>/eto/repost.
function M.handle_repost_request(handle, _req_payload)
    local bb = handle.blackboard
    local state = bb._eto_resolver or {}
    if not state.last_record then return "null" end
    return cjson.encode(state.last_record)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
