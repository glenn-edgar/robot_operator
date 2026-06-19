-- chains/daily_pull.lua — build-time DSL for the rancho_water daily-pull KB.
--
-- Once per Pacific civil day at-or-after digest.hour_pacific, fetch
-- yesterday's hourly usage from the Rancho customer portal, format it,
-- publish on fleet/notify/digest/daily AND on <namespace>/usage/{sample,latest}
-- for persistence.
--
-- Column shape (daily-gate state machine, decided inside DAILY_PULL):
--
--   daily_pull_col
--     [1] wait_time(boot_settle_s)  give persistence's sub-declarations
--                                   time to propagate back across zenoh
--                                   before our first publish. See the
--                                   late-binding race note below.
--     [2] one_shot(DAILY_PULL)      gate, fetch+format+publish, stamp date
--     [3] wait_time(retry_s)        15 min between attempts
--     [4] reset                     CFL_RESET -> back to [1]
--
-- Why the boot-settle: on a fresh stack-up persistence subscribes to our
-- leaves on receiving our topology announce, but those sub-declarations
-- take ~100–200ms to propagate back to us. The daily_pull leaf would
-- otherwise fire inside that window and the one-shot usage publishes
-- (stream + latest) would be silently dropped. Heartbeat publishes survive
-- the gap because app_heartbeat republishes continuously; the daily 1×
-- publishes have no recovery window. boot_settle_s also runs at the top
-- of every cycle, but since the gate makes us idle on every tick after
-- the first publish, the extra few seconds per cycle never matters.

local DAILY_PULL_KB_NAME    = "daily_pull"
local DEFAULT_RETRY_S       = 900
local DEFAULT_BOOT_SETTLE_S = 5     -- enough headroom for zenoh-pico
                                    -- sub-declaration propagation on
                                    -- localhost; tune up for slower fabrics.

local function build_daily_pull(ct, kb_name, retry_s, boot_settle_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("DAILY_PULL", {})
        ct:asm_wait_time(retry_s or DEFAULT_RETRY_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_daily_pull       = build_daily_pull,
    DAILY_PULL_KB_NAME     = DAILY_PULL_KB_NAME,
    DEFAULT_RETRY_S        = DEFAULT_RETRY_S,
    DEFAULT_BOOT_SETTLE_S  = DEFAULT_BOOT_SETTLE_S,
}
