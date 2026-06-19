-- chains/digest.lua — build DSL for the daily KB2/KB4 operator digest.
--
-- Two-tier notification model (Glenn 2026-06-10): KB1/KB3 push immediate
-- action alerts; KB2/KB4 diagnostics roll up into ONE summary at 18:00
-- Pacific that points the operator at the dashboard. Same daily-gate shape
-- as farm_soil/chains/digest.lua.
--
--   digest_col
--     [1] wait_time(boot_settle_s)  let the KB DBs exist before first check
--     [2] one_shot(DAILY_DIGEST)    gates on (today != last_published
--                                   AND Pacific hour >= hour_pacific)
--     [3] wait_time(retry_s)        ticks every 15 min
--     [4] reset                     loop

local DIGEST_KB_NAME    = "digest"
local DEFAULT_RETRY_S   = 900
local DEFAULT_BOOT_SETTLE_S = 10

local function build_digest(ct, kb_name, retry_s, boot_settle_s)
    ct:start_test(kb_name)
    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_wait_time(boot_settle_s or DEFAULT_BOOT_SETTLE_S)
        ct:asm_one_shot_handler("DAILY_DIGEST", {})
        ct:asm_wait_time(retry_s or DEFAULT_RETRY_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_digest          = build_digest,
    DIGEST_KB_NAME        = DIGEST_KB_NAME,
    DEFAULT_RETRY_S       = DEFAULT_RETRY_S,
    DEFAULT_BOOT_SETTLE_S = DEFAULT_BOOT_SETTLE_S,
}
