-- chains/moisture.lua — build-time DSL for the moisture application KB.
--
-- The farm_soil moisture skill-KB. Spawned by KB0's SPAWN_APP_KBS once the
-- robot reaches operating (class_spec.app_kbs lists it). A single column
-- looping on a fixed cadence:
--
--   moisture_col
--     [1] one_shot(MOISTURE_FETCH)  fetch TTN -> decode -> in-memory ring
--                                   -> publish each sensing point's slots
--     [2] wait_time(3600)           1 hour
--     [3] reset                      CFL_RESET -> loop
--
-- The TTN sensors uplink hourly; MOISTURE_FETCH re-fetches a lookback window
-- each cycle and timestamp-reconciles, so the robot stays correct regardless
-- of fetch phase. Same column shape as fake_counter (one-shot + wait + reset).
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local MOISTURE_KB_NAME = "moisture"
local FETCH_INTERVAL_S = 3600        -- 1 hour

local function build_moisture(ct, kb_name)
    ct:start_test(kb_name)

    local col = ct:define_column(
        "moisture_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler("MOISTURE_FETCH", {})
        ct:asm_wait_time(FETCH_INTERVAL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_moisture   = build_moisture,
    MOISTURE_KB_NAME = MOISTURE_KB_NAME,
}
