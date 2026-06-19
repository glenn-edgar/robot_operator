-- chains/kb2_resistance.lua — DSL for the KB2 resistance trend KB.
--
-- Polls the controller's IRRIGATION_VALVE_TEST hash for new valve_test
-- cycles. Each cycle: compute 2-null offset from sat_3:1 + sat_4:6,
-- compute R per valve via R = 15.6 V / (I_raw - offset), classify vs
-- rolling-median baseline, write to /var/fleet/kb2/kb2.db, emit
-- Discord on R_DRIFT_ALERT (sustained 3-cycle) and MASTER_RELAY_CREEP.
--
-- Mirrors KB4 chain shape:
--   kb2_resistance_col
--     [1] wait_time(boot_settle_s)   SQLite open + baseline-seed settle
--     [2] one_shot(KB2_TICK)         one full poll cycle
--     [3] wait_time(poll_s)          default 60 s (valve_test is infrequent)
--     [4] reset                      back to [1]

local KB2_RESISTANCE_KB_NAME = "kb2_resistance"
local DEFAULT_POLL_S         = 60
local DEFAULT_BOOT_SETTLE_S  = 5

local function build_kb2_resistance(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB2_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb2_resistance     = build_kb2_resistance,
    KB2_RESISTANCE_KB_NAME   = KB2_RESISTANCE_KB_NAME,
    DEFAULT_POLL_S           = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S    = DEFAULT_BOOT_SETTLE_S,
}
