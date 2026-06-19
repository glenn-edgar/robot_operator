-- robot_common/chains/connection.lua — KB0 builder module (shared).
--
-- KB0 is the shared connection lifecycle — identical for every robot class.
-- This module exports build_kb0(ct, kb_name); a per-robot build driver
-- (<robot>/chains/build.lua) requires it together with the class's app-KB
-- build modules and assembles them into one compiled IR.
--
-- Structure:
--   outer column "kb0_outer"
--     [1] wait_for_event("ZENOH_CONNECTED")  HALT boot-gate — blocks every
--                                            younger sibling until the runtime
--                                            reports the zenoh transport up.
--     [2] state_machine "protocol_sm"
--           state "wait_for_ack"             announce registration, await the
--                                            controller ack (retry on
--                                            timeout), publish the namespace,
--                                            run the class hook, spawn app KBs.
--           state "verify_controller_heartbeat"
--                                            verify the controller heartbeat;
--                                            on loss kill app KBs + return to
--                                            wait_for_ack.
--     [3] asm_halt()                         terminal — KB0 runs forever.
--
-- ONE recovery scope — the controller heartbeat. A 2026-05-20 design had a
-- second, broader transport-recovery scope (verify(TEST_ZENOH_CONNECTION));
-- removed 2026-05-21 — it had no detector and was redundant: a zenohd outage
-- stops the controller heartbeat, so the controller-heartbeat scope already
-- drives the full re-bringup, and zenoh-pico client mode reconnects on its
-- own. Confirmed by the transport-bounce test.
--
-- build_kb0 uses only the passed-in ChainTreeMaster instance `ct` — this
-- module requires nothing itself.

local KB0_NAME = "connection"

local function build_kb0(ct, kb_name)
    ct:start_test(kb_name)

    -- The first element of a KB must be a column.
    local outer = ct:define_column("kb0_outer", nil, nil, nil, nil, {}, true)

        -- [1] Wait for the zenoh transport. timeout 0 => pure HALT until the
        -- runtime posts ZENOH_CONNECTED. The HALT blocks [2]/[3]/[4].
        ct:asm_log_message("KB0: waiting for zenoh transport")
        ct:asm_wait_for_event("ZENOH_CONNECTED", 1, false, 0, nil, nil, {})

        -- The boot gate has cleared — the zenoh transport is up. Fall through
        -- to the protocol layer. (No transport-recovery guard here; see the
        -- "ONE recovery scope" note in the file header.)
        ct:asm_log_message("KB0: zenoh transport up — entering protocol layer")

        -- [2] Protocol state machine.
        local protocol_sm = ct:define_state_machine(
            "protocol_sm", "protocol_sm",
            { "wait_for_ack", "verify_controller_heartbeat" },
            "wait_for_ack", true)

            -- state: wait_for_ack — controller handshake, then the bringup
            -- sequence. The handshake retries via wait_for_event's timeout:
            -- on a 3 s timeout (counted in CFL_SECOND_EVENTs) reset=true loops
            -- this state's column, re-running ANNOUNCE_REGISTRATION.
            local st_ack = ct:define_state("wait_for_ack", nil)
                ct:asm_log_message("protocol: announcing registration")
                ct:asm_one_shot_handler("ANNOUNCE_REGISTRATION", {})
                ct:asm_wait_for_event("REGISTRATION_ACK", 1, true, 3,
                    nil, "CFL_SECOND_EVENT", {})
                ct:asm_log_message("protocol: ack received — running bringup sequence")
                ct:asm_one_shot_handler("PUBLISH_NAMESPACE", {})
                ct:asm_one_shot_handler("NAMESPACE_UP_HOOK", {})
                -- Settle for the persistence layer's sub-declarations to
                -- propagate back across the zenoh fabric before our app KBs
                -- fire their first one_shot publishes. Without this, fresh-DB
                -- boots silently drop the initial leaf round. 15 s is sized
                -- for persistence's worst-case startup path: open SQLite +
                -- pump cadence + receive topology + two-phase open_subs +
                -- schema reconcile. (5 s was empirically not enough on a
                -- fresh DB — moisture's 68-uplink backfill and cimis's
                -- 7-day historical seed both fired before subs were open.)
                ct:asm_wait_time(15)
                ct:asm_one_shot_handler("SPAWN_APP_KBS", {})
                ct:change_state(protocol_sm, "verify_controller_heartbeat")
                ct:asm_halt()
            ct:end_column(st_ack)

            -- state: verify_controller_heartbeat — steady-state monitor.
            -- verify + publish + delay + reset loops the column. reset=true is
            -- required: with reset=false a failure CFL_TERMINATEs the column
            -- and nothing re-enables it. On verify failure ERROR_CONTROLLER_LOST
            -- kills app KBs and drives the SM back to wait_for_ack — zenoh
            -- untouched (narrow recovery). PUBLISH_ROBOT_HEARTBEAT rolls the
            -- app-KB heartbeats into the robot's published heartbeat each loop.
            local st_hb = ct:define_state("verify_controller_heartbeat", nil)
                ct:asm_log_message("protocol: operating — monitoring controller heartbeat")
                ct:asm_verify("TEST_CONTROLLER_HEARTBEAT", { threshold_s = 3.5 },
                    true, "ERROR_CONTROLLER_LOST", {})
                ct:asm_one_shot_handler("PUBLISH_ROBOT_HEARTBEAT", {})
                ct:asm_wait_time(3.0)
                ct:asm_reset()
            ct:end_column(st_hb)

        ct:end_state_machine(protocol_sm, "protocol_sm")

        -- [3] Terminal halt — a permanently enabled node so the outer column
        -- never auto-completes. KB0 runs forever.
        ct:asm_halt()

    ct:end_column(outer)
    ct:end_test()
end

return { build_kb0 = build_kb0, KB0_NAME = KB0_NAME }
