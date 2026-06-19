-- chains/digest.lua — build-time DSL for the daily-digest application KB.
--
-- A push-notification skill: at most once per Pacific civil day, read the
-- in-memory moisture rings and the latest CIMIS records, format a fixed-
-- width report, and publish it on `fleet/notify/digest/daily`. The
-- notification_service (layer 60) subscribes there and POSTs to Discord.
--
-- The column ticks on a short retry cadence; the actual once-per-day
-- decision is made inside DAILY_DIGEST (calendar-anchored daily gate,
-- same shape as the CIMIS KBs). retry_s matches CIMIS so the moisture/
-- CIMIS data have a chance to be fresh by the time the gate opens.
--
--   digest_col
--     [1] one_shot(DAILY_DIGEST)   gates on (today != last_published_date
--                                  AND Pacific hour >= hour_pacific)
--     [2] wait_time(retry_s)       15 min between ticks
--     [3] reset                    CFL_RESET -> loop
--
-- Robot owns content, service owns transport — this KB does not know
-- Discord exists. See discord-integration-architecture-2026-05-23.
--
-- Pure build module — no CLI block; chains/build.lua requires it.

local DIGEST_KB_NAME    = "digest"
local DEFAULT_RETRY_S   = 900                 -- 15 min; matches class_spec.digest.retry_s

local function build_digest(ct, kb_name, retry_s)
    ct:start_test(kb_name)

    local col = ct:define_column(
        kb_name .. "_col", nil, nil, nil, nil, {}, true)

        ct:asm_one_shot_handler("DAILY_DIGEST", {})
        ct:asm_wait_time(retry_s or DEFAULT_RETRY_S)
        ct:asm_reset()

    ct:end_column(col)
    ct:end_test()
end

return {
    build_digest      = build_digest,
    DIGEST_KB_NAME    = DIGEST_KB_NAME,
    DEFAULT_RETRY_S   = DEFAULT_RETRY_S,
}
