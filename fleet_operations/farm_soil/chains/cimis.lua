-- chains/cimis.lua — build-time DSL for the CIMIS application KBs.
--
-- Two KB instances of the same skill, one per CIMIS provider:
--   cimis_station  — handler CIMIS_TICK_STATION
--   cimis_spatial  — handler CIMIS_TICK_SPATIAL
--
-- They differ only in their source-config (bb._class_spec.cimis.sources.X)
-- and the user-fn name they dispatch to. Both run the same daily-gate state
-- machine — implemented in chains/cimis_user_functions.lua's cimis_tick_impl.
--
-- Each KB is a single column on a fixed cadence: every retry_s, run the
-- gate. If gated (already-done / outside Pacific 09:00–15:00) the leaf
-- returns immediately; if in-window it fetches CIMIS for yesterday, drops
-- provisional rows, and on a finalized ASCE ETo publishes once and marks
-- last_recorded_date. The 15-min wait IS the user-spec retry cadence.
--
--   cimis_<source>_col
--     [1] one_shot(CIMIS_TICK_<SOURCE>)
--     [2] wait_time(retry_s)
--     [3] reset
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local STATION_KB_NAME = "cimis_station"
local SPATIAL_KB_NAME = "cimis_spatial"

local DEFAULT_RETRY_S = 900            -- 15 minutes; matches class_spec.cimis.retry_s

local function build_cimis_kb(ct, kb_name, fn_name, retry_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler(fn_name, {})
        ct:asm_wait_time(retry_s)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

local function build_cimis_station(ct, kb_name, retry_s)
    build_cimis_kb(ct, kb_name, "CIMIS_TICK_STATION", retry_s or DEFAULT_RETRY_S)
end

local function build_cimis_spatial(ct, kb_name, retry_s)
    build_cimis_kb(ct, kb_name, "CIMIS_TICK_SPATIAL", retry_s or DEFAULT_RETRY_S)
end

return {
    build_cimis_station = build_cimis_station,
    build_cimis_spatial = build_cimis_spatial,
    STATION_KB_NAME     = STATION_KB_NAME,
    SPATIAL_KB_NAME     = SPATIAL_KB_NAME,
}
