-- chains/monitor.lua — build-time DSL for the irrigation_analytics monitor KB.
--
-- Phase 1: skeleton. Wakes every poll_s, calls one_shot MONITOR_TICK which
-- (for now) just stamps the heartbeat. Real controller-polling + state
-- publishing land in Phase 2.
--
-- Column shape (mirrors rancho_water/chains/daily_pull):
--   monitor_col
--     [1] wait_time(boot_settle_s)  let persistence's sub-declarations
--                                   propagate before the first publish
--     [2] one_shot(MONITOR_TICK)    poll controller, publish state, heartbeat
--     [3] wait_time(poll_s)         default 30 s
--     [4] reset                     CFL_RESET -> back to [1]
--
-- The 5 s boot-settle is the same as rancho_water — it covers the
-- persistence sub-declaration propagation gap on fresh stack-up.

local MONITOR_KB_NAME       = "monitor"
local DEFAULT_POLL_S        = 30
local DEFAULT_BOOT_SETTLE_S = 5

local function build_monitor(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("MONITOR_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_monitor          = build_monitor,
    MONITOR_KB_NAME        = MONITOR_KB_NAME,
    DEFAULT_POLL_S         = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S  = DEFAULT_BOOT_SETTLE_S,
}
