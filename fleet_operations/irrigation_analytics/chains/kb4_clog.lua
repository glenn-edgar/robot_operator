-- chains/kb4_clog.lua — DSL for the KB4 clog/leak detector KB.
--
-- Polls past_actions for IRRIGATION_STEP_COMPLETE events, classifies each
-- non-ETO bin's flow against per-bin SQLite baseline, emits Discord on
-- LEAK (flow > baseline + 5 GPM) and DB-only warnings on rising/drop
-- (delta beyond ±3 GPM). ETO bins are skipped here — they get a
-- separate (deferred) handler.
--
-- Column shape mirrors detector:
--   kb4_clog_col
--     [1] wait_time(boot_settle_s)   SQLite open + seed settle
--     [2] one_shot(KB4_TICK)         one full poll cycle
--     [3] wait_time(poll_s)          default 30 s
--     [4] reset                      back to [1]

local KB4_CLOG_KB_NAME      = "kb4_clog"
local DEFAULT_POLL_S        = 30
local DEFAULT_BOOT_SETTLE_S = 5

local function build_kb4_clog(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB4_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb4_clog       = build_kb4_clog,
    KB4_CLOG_KB_NAME     = KB4_CLOG_KB_NAME,
    DEFAULT_POLL_S       = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S = DEFAULT_BOOT_SETTLE_S,
}
