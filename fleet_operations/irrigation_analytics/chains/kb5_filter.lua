-- chains/kb5_filter.lua — DSL for the KB5 PLC filter-load detector.
--
-- The PLC-source complement to kb3's Hunter-only flow_deplete (Glenn 2026-06-26):
-- when the FILTER/line loads up, the PLC well-source flow and the Filtered Hunter
-- delivery fall TOGETHER → CLEAN_FILTER is the correct recovery. Fires on a
-- self-referencing PLC drop with a mandatory Hunter cross-check, scope = city OR
-- non-ETO bins, rate-gated to once per 90 min. Monitor-first (KB5_FILTER_ARM).
--
-- Same tick skeleton as every other detector KB: settle, one-shot KB5_TICK,
-- wait poll_s, reset. Independent of every other KB.

local KB5_FILTER_KB_NAME = "kb5_filter"
local DEFAULT_POLL_S        = 30
local DEFAULT_BOOT_SETTLE_S = 5

local function build_kb5_filter(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)
    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB5_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb5_filter      = build_kb5_filter,
    KB5_FILTER_KB_NAME    = KB5_FILTER_KB_NAME,
    DEFAULT_POLL_S        = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S = DEFAULT_BOOT_SETTLE_S,
}
