-- chains/kb2_within_run.lua — DSL for the KB2 within-run R analysis KB.
--
-- Polls past_actions for STEP_COMPLETE on ETO bins. For each, pulls
-- TIME_HISTORY's IRRIGATION_CURRENT.data[], derives per-minute coil R via
-- back-calculation against master path, analyzes for thermal drift, step
-- jumps, instability, end-vs-start aging. Writes to runs_kb2_within.
-- Discord push on R_STEP_DURING_RUN.

local KB2_WITHIN_RUN_KB_NAME = "kb2_within_run"
local DEFAULT_POLL_S         = 60
local DEFAULT_BOOT_SETTLE_S  = 7

local function build_kb2_within_run(ct, kb_name, poll_s, boot_settle_s)
    ct:start_test(kb_name)
    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("KB2_WR_TICK", {})
        ct:asm_wait_time(poll_s or DEFAULT_POLL_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_kb2_within_run    = build_kb2_within_run,
    KB2_WITHIN_RUN_KB_NAME  = KB2_WITHIN_RUN_KB_NAME,
    DEFAULT_POLL_S          = DEFAULT_POLL_S,
    DEFAULT_BOOT_SETTLE_S   = DEFAULT_BOOT_SETTLE_S,
}
