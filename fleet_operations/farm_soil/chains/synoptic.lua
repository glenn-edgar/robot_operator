-- chains/synoptic.lua — build-time DSL for the per-station weather-ETo KBs.
--
-- Both stations are accessed through the Synoptic/MesoWest API but they belong
-- to different ground networks, which the KB names and publish paths reflect:
--   sce_se224       — SE224 SCE Murrieta Hogbacks (utility-owned, 10-min)
--                      handler SCE_TICK_SE224, publishes under sce/SE224/*
--   synoptic_sruc1  — SRUC1 Santa Rosa Plateau (Synoptic-native RAWS, hourly)
--                      handler SYNOPTIC_TICK_SRUC1, publishes under synoptic/SRUC1/*
--
-- They share the same daily-gate state machine and same lib (synoptic_eto.lua,
-- the API client). The implementation in chains/synoptic_user_functions.lua
-- dispatches by station_id and reads each station's publish_prefix from
-- class_spec, so adding a third weather source is a one-row class_spec edit.
--
-- Each KB is a single column on a fixed cadence: every retry_s, run the
-- gate. If gated (already-recorded / pre-window) the leaf returns
-- immediately; else it pulls yesterday's wide UTC window via the Synoptic
-- API, runs per-bin Penman, and publishes the daily ETo. The 15-min wait
-- IS the user-spec retry cadence (matches cimis.lua).
--
--   synoptic_<stid>_col
--     [1] one_shot(SYNOPTIC_TICK_<STID>)
--     [2] wait_time(retry_s)
--     [3] reset
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local SE224_KB_NAME    = "sce_se224"
local SRUC1_KB_NAME    = "synoptic_sruc1"
local DEFAULT_RETRY_S  = 900

local function build_weather_kb(ct, kb_name, fn_name, retry_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler(fn_name, {})
        ct:asm_wait_time(retry_s)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

local function build_sce_se224(ct, kb_name, retry_s)
    build_weather_kb(ct, kb_name, "SCE_TICK_SE224", retry_s or DEFAULT_RETRY_S)
end

local function build_synoptic_sruc1(ct, kb_name, retry_s)
    build_weather_kb(ct, kb_name, "SYNOPTIC_TICK_SRUC1", retry_s or DEFAULT_RETRY_S)
end

return {
    build_sce_se224      = build_sce_se224,
    build_synoptic_sruc1 = build_synoptic_sruc1,
    SE224_KB_NAME        = SE224_KB_NAME,
    SRUC1_KB_NAME        = SRUC1_KB_NAME,
}
