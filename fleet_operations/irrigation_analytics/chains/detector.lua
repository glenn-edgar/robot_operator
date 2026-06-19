-- chains/detector.lua — build-time DSL for the KB1+KB3 detector KB.
--
-- Polls past_actions + popup independently of the monitor KB. On each tick:
--   - past_actions_xrange(cursor) → process STATION_START / STEP_COMPLETE
--     transitions to arm/disarm the per-bin session
--   - popup_get() → feed irr_current into the rolling median window
--     (TIME_STAMP-gated) and run KB1 modes.evaluate
--   - FILTERED_HUNTER_VALVE → run KB3Live.update during ACTIVE_RUN
--   - For each fired event: push to fleet/notify/digest/daily (Discord),
--     ws_command.post for allowed actions (SKIP_LIVE-gated), persist to
--     <namespace>/events/sample stream
--
-- Column shape mirrors monitor:
--   detector_col
--     [1] wait_time(boot_settle_s)   persistence sub-declarations settle
--     [2] one_shot(DETECTOR_TICK)    one full poll cycle
--     [3] wait_time(poll_s)          default 30 s
--     [4] reset                      back to [1]

local DETECTOR_KB_NAME      = "detector"
local DEFAULT_POLL_S        = 30
local DEFAULT_BOOT_SETTLE_S = 5

local function build_detector(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("DETECTOR_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_detector         = build_detector,
    DETECTOR_KB_NAME       = DETECTOR_KB_NAME,
    DEFAULT_POLL_S         = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S  = DEFAULT_BOOT_SETTLE_S,
}
