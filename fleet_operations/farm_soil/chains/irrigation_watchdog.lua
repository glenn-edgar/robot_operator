-- chains/irrigation_watchdog.lua — build-time DSL for the irrigation-site
-- liveness watchdog.
--
-- The irrigation Pi (192.168.1.146) sits on an Alexa-controlled power plug.
-- After a power-blip the operator has to remotely flip the plug back on; we
-- nag them on Discord until they do, then ack the restoration.
--
-- Polls every poll_s; after the server has been unreachable for
-- down_threshold_s seconds, posts a Discord alert; while still down, posts
-- another alert every alert_interval_s. On recovery, posts a single
-- "RESTORED after X" ack.
--
--   irrigation_watchdog_col
--     [1] one_shot(IRRIGATION_WATCHDOG_TICK)
--     [2] wait_time(poll_s)              60s probe cadence
--     [3] reset                          CFL_RESET -> loop
--
-- Robot owns content, service owns transport — this KB does not know
-- Discord exists. See discord-integration-architecture-2026-05-23.
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local IRRIGATION_WATCHDOG_KB_NAME = "irrigation_watchdog"
local DEFAULT_POLL_S              = 60

local function build_irrigation_watchdog(ct, kb_name, poll_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler("IRRIGATION_WATCHDOG_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_irrigation_watchdog   = build_irrigation_watchdog,
    IRRIGATION_WATCHDOG_KB_NAME = IRRIGATION_WATCHDOG_KB_NAME,
    DEFAULT_POLL_S              = DEFAULT_POLL_S,
}
