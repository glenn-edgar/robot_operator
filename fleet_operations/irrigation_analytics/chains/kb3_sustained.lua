-- chains/kb3_sustained.lua — DSL for the KB3 sustained-leak detector.
--
-- Per Glenn's 2026-06-09 redesign: schedule-aware, ETO-only, 5-min
-- warmup, fires on 3 consecutive minutes with PLC_FLOW_METER > 15 GPM
-- OR FILTERED_HUNTER_VALVE > 15 GPM. On fire: CLOSE_MASTER_VALVE then
-- SKIP_STATION. Independent of every other KB.

local KB3_SUSTAINED_KB_NAME = "kb3_sustained"
local DEFAULT_POLL_S        = 30
local DEFAULT_BOOT_SETTLE_S = 5

local function build_kb3_sustained(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)
    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB3_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb3_sustained     = build_kb3_sustained,
    KB3_SUSTAINED_KB_NAME   = KB3_SUSTAINED_KB_NAME,
    DEFAULT_POLL_S          = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S   = DEFAULT_BOOT_SETTLE_S,
}
