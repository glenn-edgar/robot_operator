-- chains/eto_sync.lua — build-time DSL for the irrigation-ETo-sync KB.
--
-- A push-control skill: at most once per Pacific civil day, after 14:00 PT,
-- read the irrigation controller's `eto_update_table` Redis hash, subtract
-- the CIMIS station-vs-spatial delta from every entry, cap at 0.20 / floor
-- at 0.0, and write the result back. On success: publish a one-line
-- Discord notification via the existing fleet/notify/digest/daily channel.
-- On unrecoverable failure: publish a Discord failure ONCE at 17:00 PT.
--
-- Same column shape as digest.lua / cimis.lua — a single one_shot leaf
-- making all the gate decisions internally, then a long retry sleep.
--
--   eto_sync_col
--     [1] one_shot(ETO_SYNC_TICK)   gates on (today != success_date,
--                                              now >= 14:00 PT,
--                                              both CIMIS sources present)
--     [2] wait_time(retry_s)        15 min between ticks (matches CIMIS)
--     [3] reset                     CFL_RESET -> loop
--
-- Robot owns content, service owns transport — this KB does not know
-- Discord exists. See discord-integration-architecture-2026-05-23.
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local ETO_SYNC_KB_NAME  = "eto_sync"
local DEFAULT_RETRY_S   = 900             -- 15 min; matches class_spec.eto_sync.retry_s

local function build_eto_sync(ct, kb_name, retry_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler("ETO_SYNC_TICK", {})
        ct:asm_wait_time(retry_s or DEFAULT_RETRY_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_eto_sync     = build_eto_sync,
    ETO_SYNC_KB_NAME   = ETO_SYNC_KB_NAME,
    DEFAULT_RETRY_S    = DEFAULT_RETRY_S,
}
