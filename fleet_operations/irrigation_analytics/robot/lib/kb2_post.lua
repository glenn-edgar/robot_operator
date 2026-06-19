-- kb2_post.lua — KB2 resistance analyzer trigger.
--
-- Fires on exit from SUSPENDED_RESISTANCE state (controller just finished its
-- daily valve-test cycle). Shells out to explore/analyze_resistance.py
-- with --fetch (pull fresh valve_test from Pi) + --json (structured output).
-- Parses the JSON and returns:
--   - A summary table (logged to kb2_events.log)
--   - A Discord-ready event with bad + marginal solenoid list
--
-- Discord-policy: one event per analysis run. Edge-trigger doesn't apply
-- because each RESISTANCE_CHECK is a discrete event; we always send the
-- summary on completion (even if 0 bad / 0 marginal — useful for "I'm
-- alive" confirmation that the analyzer ran).

local cjson = require("cjson")

local M = {}

-- Where the analyzer lives relative to robot/lib/ — handled by run_analysis.
local DEFAULT_SCRIPT  = "explore/analyze_resistance.py"
local SCRIPT_TIMEOUT  = 30  -- seconds; fetch_data.sh takes 5-15s typical

-- Spawn the analyzer, return (parsed_json, err)
function M.run_analysis(repo_root)
    local script = repo_root .. "/" .. DEFAULT_SCRIPT
    -- Wrap with timeout to bound runtime; redirect stderr to /dev/null so
    -- only the JSON payload comes back on stdout.
    local cmd = string.format(
        "timeout %d python3 %q --fetch --json 2>/dev/null",
        SCRIPT_TIMEOUT, script)
    local pipe = io.popen(cmd, "r")
    if not pipe then return nil, "popen failed" end
    local raw = pipe:read("*a")
    local _, _, exit_code = pipe:close()
    if not raw or raw == "" then
        return nil, string.format("empty output (exit=%s)", tostring(exit_code))
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "json decode: " .. tostring(decoded):sub(1, 200)
    end
    if decoded.error then
        return nil, "analyzer: " .. tostring(decoded.error)
    end
    if decoded.schema ~= "kb2_resistance.v1" then
        return nil, "unsupported analyzer schema: " .. tostring(decoded.schema)
    end
    return decoded, nil
end

-- Format a one-line summary per valve for Discord.
-- Note: cjson decodes JSON null as a userdata sentinel; check type(x)=="number"
-- rather than truthiness.
local function fmt_valve(r)
    local rv = (type(r.r_corr) == "number") and string.format("%.1fΩ", r.r_corr) or "—"
    local zv = (type(r.z)      == "number") and string.format(" z=%+.1f", r.z)   or ""
    return string.format("  • %s  %s  R=%s%s", r.valve, r.status, rv, zv)
end

-- Build a Discord event from the analyzer result.
-- Always returns one event (level=YELLOW when marginal/bad, GREEN if clean).
function M.event_from_result(result)
    local s = result.summary or {}
    local bad_list      = result.bad      or {}
    local marg_list     = result.marginal or {}
    local n_bad         = s.n_bad      or #bad_list
    local n_marginal    = s.n_marginal or #marg_list
    local level, kind
    if n_bad > 0 then
        level, kind = "RED", "KB2_RESISTANCE_BAD"
    elseif n_marginal > 0 then
        level, kind = "YELLOW", "KB2_RESISTANCE_MARGINAL"
    else
        level, kind = "GREEN", "KB2_RESISTANCE_OK"
    end

    -- Header summary line
    local header = string.format(
        "KB2 resistance: %d valves, %d stable, %d marginal, %d bad  "
            .. "(offset=%.4f, drift=%.4f)",
        s.n_valves or 0, s.n_stable or 0, n_marginal, n_bad,
        s.offset_today or 0, s.phantom_drift or 0)

    -- Body lists (capped to avoid Discord 2000-char limit)
    local lines = { header }
    if n_bad > 0 then
        lines[#lines+1] = string.format("**BAD (%d)**", n_bad)
        for i, r in ipairs(bad_list) do
            if i > 20 then lines[#lines+1] = string.format("  ...+%d more", n_bad - 20); break end
            lines[#lines+1] = fmt_valve(r)
        end
    end
    if n_marginal > 0 then
        lines[#lines+1] = string.format("**MARGINAL (%d)**", n_marginal)
        for i, r in ipairs(marg_list) do
            if i > 20 then lines[#lines+1] = string.format("  ...+%d more", n_marginal - 20); break end
            lines[#lines+1] = fmt_valve(r)
        end
    end
    if n_bad == 0 and n_marginal == 0 then
        lines[#lines+1] = "All valves stable."
    end

    return {
        kind   = kind,
        level  = level,
        action = nil,                    -- analysis-only; no action
        msg    = table.concat(lines, "\n"),
        n_bad      = n_bad,
        n_marginal = n_marginal,
        n_stable   = s.n_stable or 0,
        generated_at = result.generated_at,
    }
end

return M
