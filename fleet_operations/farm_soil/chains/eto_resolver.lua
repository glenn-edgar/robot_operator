-- chains/eto_resolver.lua — build-time DSL for the daily-ETo resolver KB.
--
-- One KB. Walks the configured priority chain (default:
-- SE224 -> CIMIS spatial -> SRUC1 -> CIMIS station-237) once per Pacific
-- civil day, picks the first source whose latest record is for yesterday and
-- meets quality gates (status==OK, coverage>=min_coverage), and publishes
-- the resolved daily ETo to <namespace>/eto/{daily, latest}. The dashboard
-- reads these.
--
-- Same column shape as cimis.lua / eto_sync.lua — a single one_shot leaf
-- doing all the work, then the retry wait.
--
--   eto_resolver_col
--     [1] one_shot(ETO_RESOLVE_TICK)
--     [2] wait_time(retry_s)
--     [3] reset
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local ETO_RESOLVER_KB_NAME = "eto_resolver"
local DEFAULT_RETRY_S      = 900           -- 15 min cadence

local function build_eto_resolver(ct, kb_name, retry_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler("ETO_RESOLVE_TICK", {})
        ct:asm_wait_time(retry_s or DEFAULT_RETRY_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_eto_resolver     = build_eto_resolver,
    ETO_RESOLVER_KB_NAME   = ETO_RESOLVER_KB_NAME,
    DEFAULT_RETRY_S        = DEFAULT_RETRY_S,
}
