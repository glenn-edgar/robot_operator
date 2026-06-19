-- chains/kb1_overcurrent.lua — DSL for the KB1 live overcurrent detector.
--
-- Polls popup IRRIGATION_CURRENT every tick during ACTIVE_RUN. Compares to
-- expected current from KB2 baselines for the active bin. Fires KB1_KILL
-- at I > 1.8 A absolute (Discord), KB1_WARN at I > expected + 0.3 A (DB).
-- WSL test phase: monitor-only, no SKIP_STATION.

local KB1_OVERCURRENT_KB_NAME = "kb1_overcurrent"
local DEFAULT_POLL_S          = 30
local DEFAULT_BOOT_SETTLE_S   = 7    -- wait for KB2 to seed its baselines first

local function build_kb1_overcurrent(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)
    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB1_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb1_overcurrent      = build_kb1_overcurrent,
    KB1_OVERCURRENT_KB_NAME    = KB1_OVERCURRENT_KB_NAME,
    DEFAULT_POLL_S             = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S      = DEFAULT_BOOT_SETTLE_S,
}
