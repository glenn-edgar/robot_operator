-- chains/kb4_v2_user_functions.lua — KB4_V2_TICK handler.
--
-- COLLECTION ONLY per Glenn 2026-06-09 PM. KB3 prevents well depletion;
-- KB4 v2 just builds per-bin baselines passively.
--
-- Event-driven: polls past_actions for STATION_START / STEP_COMPLETE pairs,
-- and on each STEP_COMPLETE pulls the PLC_MEASUREMENTS_STREAM window for
-- the run, computes (win_flow_gpm, win_gallons, end_flow_gpm), updates the
-- per-bin rolling-7 baseline. NO Discord push, NO alerts. Future
-- threshold-based alerters can read runs_kb4v2 rows independently.
--
-- State in blackboard under bb._kb4v2.

local controller    = require("controller_client")
local KB4V2         = require("kb4_v2")
local KB_ALERTS     = require("kb_alerts")
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

local DEFAULT_POLL_S = 60

local function log(id, fmt, ...)
    io.write(string.format("kb4_v2 [%s]: " .. fmt .. "\n", id.namespace, ...))
    io.flush()
end

local function now_ms() return os.time() * 1000 end

M.one_shot.KB4V2_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local id       = bb._identity
    local cs       = bb._class_spec
    local cfg      = (cs and cs.kb4_v2) or {}
    local poll_s   = cfg.poll_s or DEFAULT_POLL_S
    local ssh_host = cfg.ssh_host or "pi@irrigation"
    local db_path  = cfg.db_path  or "/var/fleet/kb4v2/kb4v2.db"

    if cfg.rolling_n then KB4V2.ROLLING_N = cfg.rolling_n end

    if not bb._kb4v2 then
        bb._kb4v2 = {
            db = nil,
            last_stream_id = nil,
            initialized = false,
            -- bin → STATION_START sid_ms, popped on STEP_COMPLETE
            opens = {},
        }
    end
    local st = bb._kb4v2

    if not st.db then
        local db, err = KB4V2.open_db(db_path)
        if not db then
            log(id, "open_db FAILED at %s: %s", db_path, tostring(err))
            app_heartbeat.stamp(handle, "kb4_v2", "degraded",
                "open_db failed", poll_s)
            return
        end
        st.db = db
        KB_ALERTS.ensure_schema(db)   -- blocked-sprinkler alerts → daily digest
        log(id, "db ready at %s (COLLECTION-ONLY, window=%d-%d min, rolling=%d)",
            db_path, KB4V2.WINDOW_START_MIN, KB4V2.WINDOW_END_MIN,
            KB4V2.ROLLING_N)
    end
    local db = st.db

    if not st.initialized then
        local tip, _ = controller.past_actions_tip({
            ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8,
        })
        st.last_stream_id = tip
        st.initialized = true
        log(id, "past_actions cursor fast-forwarded to %s", tostring(tip))
    end

    local delta, _ = controller.past_actions_xrange(
        st.last_stream_id, 200,
        { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
    delta = delta or {}

    local processed = 0
    for _, ent in ipairs(delta) do
        if ent.action == "IRRIGATION_STATION_START"
           and type(ent.details) == "table" then
            local bin_key = KB4V2.bin_key(ent.details.io_setup)
            st.opens[bin_key] = ent.stream_id  -- ms-prefix in stream_id

        elseif ent.action == "IRRIGATION_STEP_COMPLETE"
            and type(ent.details) == "table" then
            local io_setup = ent.details.io_setup
            local bin_key  = KB4V2.bin_key(io_setup)
            local is_eto   = KB4V2.is_eto_bin(io_setup)
            local is_city  = KB4V2.is_city_bin(io_setup)
            local run_time = tonumber(ent.details.run_time) or 0

            local opens_sid = st.opens[bin_key]
            st.opens[bin_key] = nil

            -- Skip short runs (no 5-15 window available).
            if run_time < KB4V2.MIN_RUN_DURATION then
                log(id, "skip %s — run_time=%d min < %d",
                    bin_key, run_time, KB4V2.MIN_RUN_DURATION)
            else
                -- Derive ms boundaries: prefer paired STATION_START sid;
                -- fall back to STEP_COMPLETE - run_time.
                local end_ms = tonumber((ent.stream_id or ""):match("^(%d+)"))
                                or now_ms()
                local start_ms
                if opens_sid then
                    start_ms = tonumber((opens_sid or ""):match("^(%d+)"))
                                or (end_ms - run_time * 60000)
                else
                    start_ms = end_ms - run_time * 60000
                end

                local samples, perr = controller.plc_xrange(
                    start_ms, end_ms,
                    { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
                if not samples then
                    log(id, "plc_xrange FAILED for %s: %s",
                        bin_key, tostring(perr))
                elseif #samples == 0 then
                    log(id, "no PLC samples in window for %s", bin_key)
                else
                    local stats, serr =
                        KB4V2.compute_window_stats(samples, start_ms, end_ms)
                    if not stats then
                        log(id, "compute_window_stats nil for %s: %s",
                            bin_key, tostring(serr))
                    else
                        -- Load baseline (separate per-bin; is_city carried
                        -- via bin_key uniqueness — city bins have sat_1:39
                        -- in the key, so distinct from non-city by name).
                        local baseline = KB4V2.load_baseline(db, bin_key)
                        local bin_type = is_eto and "eto" or "non_eto"
                        local tag, delta, note =
                            KB4V2.tag_run(bin_type, stats, baseline)

                        KB4V2.insert_run(db, {
                            ts_ms          = now_ms(),
                            bin            = bin_key,
                            is_eto         = is_eto,
                            is_city        = is_city,
                            sid            = ent.stream_id,
                            schedule       = ent.details.schedule_name,
                            step           = ent.details.step,
                            run_time_min   = run_time,
                            n_samples      = stats.n_samples,
                            win_flow_gpm   = stats.win_flow_gpm,
                            win_hunter_gpm = stats.win_hunter_gpm,
                            win_gallons    = stats.win_gallons,
                            end_flow_gpm   = stats.end_flow_gpm,
                            base_flow_used = baseline and baseline.base_flow_gpm,
                            leak_delta     = delta,  -- informational only
                            cls            = tag,
                            note           = note,
                        })

                        -- Always update baseline. Median of 7 is robust to a
                        -- single outlier; KB3 prevents most poisoning at the
                        -- source (well-depletion cascade is broken by trip).
                        local ring_flow = (baseline and baseline.ring_flow) or {}
                        local ring_gal  = (baseline and baseline.ring_gal)  or {}
                        local ring_end  = (baseline and baseline.ring_end)  or {}
                        KB4V2.push_ring(ring_flow, stats.win_flow_gpm, KB4V2.ROLLING_N)
                        KB4V2.push_ring(ring_gal,  stats.win_gallons,  KB4V2.ROLLING_N)
                        if stats.end_flow_gpm then
                            KB4V2.push_ring(ring_end, stats.end_flow_gpm, KB4V2.ROLLING_N)
                        end
                        local new_flow = KB4V2.median(ring_flow)
                        local new_gal  = KB4V2.median(ring_gal)
                        local new_end  = KB4V2.median(ring_end)
                        local n_clean  = ((baseline and baseline.n_clean_runs) or 0) + 1
                        KB4V2.upsert_baseline(db, bin_key, {
                            is_city           = is_city,
                            is_eto            = is_eto,
                            base_flow_gpm     = new_flow,
                            base_gallons_5_15 = new_gal,
                            base_end_flow_gpm = new_end,
                            n_clean_runs      = n_clean,
                            ring_flow         = ring_flow,
                            ring_gal          = ring_gal,
                            ring_end          = ring_end,
                            last_updated_ms   = now_ms(),
                        })

                        -- Blocked-sprinkler alert (PLC gallons curve) → digest.
                        -- Checked vs the PRE-update baseline; ETO + mature only.
                        if is_eto then
                            local blocked, bnote = KB4V2.classify_blocked(stats, baseline)
                            if blocked then
                                KB_ALERTS.record(db, {
                                    ts_ms = now_ms(), source = "kb4", kind = "clog",
                                    severity = "warn", target = bin_key, summary = bnote })
                                log(id, "BLOCKED %s — %s", bin_key, bnote)
                            end
                        end

                        processed = processed + 1
                        log(id, "%s%s%s win_flow=%.1f win_gal=%.0f%s base=%s %s%s",
                            bin_key,
                            is_eto and " [ETO]" or " [non-ETO]",
                            is_city and " [city]" or "",
                            stats.win_flow_gpm,
                            stats.win_gallons,
                            stats.end_flow_gpm
                                and string.format(" end=%.1f", stats.end_flow_gpm)
                                or "",
                            baseline and string.format("%.1f", baseline.base_flow_gpm or 0) or "nil",
                            tag,
                            delta and string.format(" Δ=%+.1f", delta) or "")
                    end
                end
            end
        end
        if ent.stream_id then st.last_stream_id = ent.stream_id end
    end

    app_heartbeat.stamp(handle, "kb4_v2", "ok",
        string.format("processed=%d cursor=%s",
            processed, tostring(st.last_stream_id)),
        poll_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
