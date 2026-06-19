-- chains/kb4_v2.lua — DSL for the KB4 v2 flow-baseline KB.
--
-- Glenn 2026-06-09: PLC-based per-bin flow baseline. Builds normalized
-- flow + total gallons curves over 5-15 min window for ETO bins (leak
-- detection at base + 2 GPM), and end-of-run flow for non-ETO. Coexists
-- with the legacy kb4_clog (non-ETO cohort starvation / clog fingerprint).

local KB4_V2_KB_NAME        = "kb4_v2"
local DEFAULT_POLL_S        = 60
local DEFAULT_BOOT_SETTLE_S = 5

local function build_kb4_v2(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)
    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB4V2_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb4_v2          = build_kb4_v2,
    KB4_V2_KB_NAME        = KB4_V2_KB_NAME,
    DEFAULT_POLL_S        = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S = DEFAULT_BOOT_SETTLE_S,
}
