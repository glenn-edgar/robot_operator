-- main.lua — KB1 shadow robot (bare LuaJIT poll loop).
--
-- Shadow mode: observe + alert. No SKIP_STATION. No CLOSE_MASTER_VALVE.
-- No writes to controller's IRRIGATION_PAST_ACTIONS stream. Discord events
-- ARE sent (real channel). All would-have-been actions are logged.
--
-- Layout per cycle (60 s):
--   1. controller.popup_get()             ← current state + samples
--   2. controller.past_actions_xrange()   ← STATION_START / STEP_COMPLETE / etc.
--   3. update arming from past_actions delta (io_setup, eto_restriction)
--   4. state_machine.classify(popup, manual_suspend)
--   5. detect state edges, log KB2 would-have-been-enabled markers
--   6. modes.evaluate(state, popup, arming, last)
--   7. log everything; send Discord per event
--   8. sleep until next poll
--
-- Env contract:
--   POLL_INTERVAL_S       optional, default 60
--   MANUAL_SUSPEND        optional, "1" forces SUSPENDED(MANUAL) for testing
--   DISCORD_WEBHOOK_URL   optional, omit → log-only
--   KB1_THRESHOLDS_JSON   optional path to per-bin KB1 curves (current)
--   BASELINES_JSON        optional path to per-bin KB3/KB4 baselines (flow)
--   VAR_DIR               optional, default ./var

local ffi = require("ffi")
ffi.cdef[[
    int usleep(unsigned int usec);
]]

local script_dir = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
package.path = script_dir .. "lib/?.lua;"
            .. script_dir .. "../../server/notification_service/lib/?.lua;"
            .. script_dir .. "../../vendor/lua/?.lua;"
            .. package.path

local cjson      = require("cjson")
local Controller = require("controller")
local SM         = require("state_machine")
local Modes      = require("modes")
local Logger     = require("logger")
local Discord    = require("discord")
local T          = require("thresholds")
local Baselines  = require("baselines")
local KB3Live    = require("kb3_live")
local KB2Post    = require("kb2_post")
local KB4Post    = require("kb4_post")
local WsCommand  = require("ws_command")

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local POLL_S          = tonumber(os.getenv("POLL_INTERVAL_S") or "30")
local MANUAL_SUSPEND  = os.getenv("MANUAL_SUSPEND") == "1"
local VAR_DIR         = os.getenv("VAR_DIR") or (script_dir .. "var")
local CURVES_PATH     = os.getenv("KB1_THRESHOLDS_JSON")
                        or (script_dir .. "../explore/kb1_thresholds.json")
local BASELINES_PATH  = os.getenv("BASELINES_JSON")
                        or (script_dir .. "../explore/baseline_state/baselines.json")

os.execute("mkdir -p " .. VAR_DIR)

local poll_log, err1   = Logger.open(VAR_DIR .. "/kb1.log")
if not poll_log then io.stderr:write("FATAL: open kb1.log: " .. err1 .. "\n"); os.exit(1) end
local event_log, err2  = Logger.open(VAR_DIR .. "/kb1_events.log")
if not event_log then io.stderr:write("FATAL: open kb1_events.log: " .. err2 .. "\n"); os.exit(1) end
local kb3_log,   err3  = Logger.open(VAR_DIR .. "/kb3_live.log")
if not kb3_log then io.stderr:write("FATAL: open kb3_live.log: " .. err3 .. "\n"); os.exit(1) end
local kb2_log,   err4  = Logger.open(VAR_DIR .. "/kb2_events.log")
if not kb2_log then io.stderr:write("FATAL: open kb2_events.log: " .. err4 .. "\n"); os.exit(1) end
local kb4_log,   err5  = Logger.open(VAR_DIR .. "/kb4_events.log")
if not kb4_log then io.stderr:write("FATAL: open kb4_events.log: " .. err5 .. "\n"); os.exit(1) end
local ws_log,    err6  = Logger.open(VAR_DIR .. "/ws_command.log")
if not ws_log then io.stderr:write("FATAL: open ws_command.log: " .. err6 .. "\n"); os.exit(1) end

-- Set of event.action values the robot is allowed to POST to the controller.
-- Anything not in this set falls through to log-only (avoids accidentally
-- emitting CLEAR or other dangerous commands if a new event ever tags one).
local ALLOWED_ACTIONS = {
    SKIP_STATION       = true,
    CLOSE_MASTER_VALVE = true,
}

-- KB4 edge-triggered cond_state per (bin_key, direction).
-- Direction is implicit in the KIND (KB4_SHORT_LOW or KB4_SHORT_HIGH); state
-- is stored as cond_state[bin_key .. ":" .. kind] = "ok"|"fired".
-- Resets on robot restart (operator gets a fresh "good morning" alert if a
-- fault is still active after restart).
local kb4_cond_state = {}

-- repo_root: explore/ + robot/ sibling. script_dir = robot/, parent = irrigation_analytics/
local REPO_IRRIGATION = (script_dir:gsub("/+$", "")):match("^(.+)/[^/]+$") or "."

-- ---------------------------------------------------------------------------
-- Load per-bin curves (KB2 will own this later; we read explore's file).
-- The explore file's per_bin schema:
--   { mu_i_asym, sd_i_asym, i_low_open, spike_thresh, ... }
-- We map → { mu, sd, i_low_open }.
-- ---------------------------------------------------------------------------
local curves = {}
do
    local fh = io.open(CURVES_PATH, "r")
    if fh then
        local raw = fh:read("*a")
        fh:close()
        local ok, decoded = pcall(cjson.decode, raw)
        if ok and decoded and decoded.per_bin then
            for bin_key, e in pairs(decoded.per_bin) do
                if e.mu_i_asym and e.i_low_open then
                    curves[T.canonicalize_key(bin_key)] = {
                        mu        = e.mu_i_asym,
                        sd        = e.sd_i_asym,
                        i_low_open = e.i_low_open,
                    }
                end
            end
            io.stderr:write(string.format(
                "KB1 SHADOW: loaded %d calibrated bins from %s\n",
                (function() local n = 0; for _ in pairs(curves) do n=n+1 end; return n end)(),
                CURVES_PATH))
        else
            io.stderr:write(string.format(
                "KB1 SHADOW: curve file load failed (decode error or missing per_bin), running uncalibrated: %s\n",
                CURVES_PATH))
        end
    else
        io.stderr:write(string.format(
            "KB1 SHADOW: no curve file at %s — all bins uncalibrated\n",
            CURVES_PATH))
    end
end

-- ---------------------------------------------------------------------------
-- Load per-bin baselines.json (KB3 live + KB4 post analyzers).
-- ---------------------------------------------------------------------------
local baselines, n_long_bl, n_short_bl, bl_err = Baselines.load(BASELINES_PATH)
if not baselines then
    io.stderr:write(string.format(
        "KB1 SHADOW: baselines load FAILED (%s) — KB3 live disabled: %s\n",
        bl_err or "?", BASELINES_PATH))
else
    local n_kb3_elig = 0
    for _, v in pairs(baselines.bins) do
        if v.mode == "long" and v.kb3_eligible then n_kb3_elig = n_kb3_elig + 1 end
    end
    io.stderr:write(string.format(
        "KB1 SHADOW: loaded baselines schema=%s long=%d short=%d kb3_eligible=%d\n",
        baselines.schema, n_long_bl, n_short_bl, n_kb3_elig))
end

-- ---------------------------------------------------------------------------
-- Persistent state across polls
-- ---------------------------------------------------------------------------

local last_stream_id_path = VAR_DIR .. "/last_stream_id"
local function load_last_stream_id()
    local fh = io.open(last_stream_id_path, "r")
    if not fh then return nil end
    local s = fh:read("*l"); fh:close()
    if s and s ~= "" then return s end
end
local function save_last_stream_id(id)
    if not id or id == "" then return end
    local fh = io.open(last_stream_id_path, "w")
    if fh then fh:write(id); fh:close() end
end

local last_stream_id = load_last_stream_id()
local prev_state = nil
local last_sample = nil   -- { irr_current, eq_current } previous poll
local arming = nil        -- { bin_key, curve, eto_restriction_seen, samples_seen,
                          --   started_at, started_at_ts,
                          --   irr_window, last_accepted_ts, sent_kinds }
local master_idle = nil   -- { armed_ts, irr_window, last_accepted_ts, sent_kinds }
                          -- nil whenever state ≠ MASTER_IDLE_CHECK

-- Shadow validation only watches state changes going forward. Fast-forward
-- the cursor to the current tip if we have no saved cursor.
if not last_stream_id then
    local tip, terr = Controller.past_actions_tip()
    if tip and tip ~= "" then
        last_stream_id = tip
        save_last_stream_id(last_stream_id)
        io.stderr:write("KB1 SHADOW: fast-forwarded past_actions cursor to " .. tip .. "\n")
    else
        io.stderr:write("KB1 SHADOW: past_actions_tip failed: " .. (terr or "nil") .. "\n")
    end
end

io.stderr:write(string.format(
    "KB1 SHADOW: starting — poll=%ds, var=%s, curves=%d, manual_suspend=%s\n",
    POLL_S, VAR_DIR,
    (function() local n=0; for _ in pairs(curves) do n=n+1 end; return n end)(),
    tostring(MANUAL_SUSPEND)))

-- ---------------------------------------------------------------------------
-- One poll cycle
-- ---------------------------------------------------------------------------

local function poll_once()
    local cycle = { t = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local pending_kb4 = nil   -- list of bin_keys with STEP_COMPLETE this poll

    -- 1) popup
    local popup, perr = Controller.popup_get()
    if not popup then
        cycle.error = perr
        poll_log:write(cycle)
        return
    end
    cycle.popup = {
        SCHEDULE_NAME           = popup.SCHEDULE_NAME,
        STEP                    = popup.STEP,
        RUN_TIME                = popup.RUN_TIME,
        ELASPED_TIME            = popup.ELASPED_TIME,
        MASTER_VALVE            = popup.MASTER_VALVE,
        SUSPEND                 = popup.SUSPEND,
        PLC_IRRIGATION_CURRENT  = popup.PLC_IRRIGATION_CURRENT,
        PLC_EQUIPMENT_CURRENT   = popup.PLC_EQUIPMENT_CURRENT,
        TIME_STAMP              = popup.TIME_STAMP,
        FILTERED_HUNTER_VALVE   = popup.FILTERED_HUNTER_VALVE,
        HUNTER_VALVE            = popup.HUNTER_VALVE,
    }

    -- 2) past_actions delta
    local delta, aerr = Controller.past_actions_xrange(last_stream_id, 200)
    if not delta then
        cycle.past_actions_error = aerr
        delta = {}
    end
    cycle.past_actions_n = #delta

    -- 3) update arming from delta
    for _, ent in ipairs(delta) do
        if ent.action == "IRRIGATION_STATION_START" and type(ent.details) == "table" then
            local io_setup = ent.details.io_setup
            local bin_key  = T.canonicalize_io_setup(io_setup)
            arming = {
                bin_key                = bin_key,
                io_setup               = io_setup,
                curve                  = T.lookup_curve(curves, bin_key),
                eto_restriction_seen   = false,
                samples_seen           = 0,
                started_at             = ent.stream_id,
                started_at_ts          = os.time(),
                schedule_name          = ent.details.schedule_name,
                step                   = ent.details.step,
                irr_window             = {},   -- median window for warn-tier
                last_accepted_ts       = nil,
                -- Edge-triggered Discord: per-(bin, kind) state ok|fired.
                -- Reset on each new STATION_START. Fires on ok→event,
                -- suppresses on fired→event, returns to ok when event stops.
                -- No recovery alerts.
                cond_state             = {},
                -- KB3 live detector: per-sprinkler-step sample slots + run-scoped
                -- one-shot. by_step[STEP] = filtered_flow_sample. fires when
                -- the 5-step sliding window [n-4..n] is all over threshold and
                -- n >= 9 (controller's STEP counter, per popup.STEP).
                kb3                    = { by_step = {}, last_step = 0, fired = false },
            }
            -- BIN_UNCALIBRATED one-shot: if either the KB1 current curve OR
            -- the KB3/KB4 flow baseline is missing for this bin, the robot
            -- has no detector watching this run. Surface it immediately —
            -- the 4:6/4:8 incident (2026-06-01) cost ~500 gal of city water
            -- because both lookups silently missed and operator only saw
            -- the fetch_failed line in kb4_events.log the next morning.
            local has_curve    = arming.curve ~= nil
            local has_baseline = baselines and Baselines.lookup(baselines, arming.bin_key) ~= nil
            if not has_curve or not has_baseline then
                local missing = {}
                if not has_curve    then missing[#missing+1] = "KB1-curve" end
                if not has_baseline then missing[#missing+1] = "KB3/KB4-baseline" end
                local msg = string.format(
                    "[KB1 SHADOW] BIN_UNCALIBRATED (YELLOW)\n" ..
                    "Run started for bin=%s without %s — robot has no detector " ..
                    "watching. Verify baseline key ordering or new-bin commissioning.\n" ..
                    "schedule=%s step=%s",
                    arming.bin_key, table.concat(missing, " + "),
                    arming.schedule_name or "?",
                    tostring(arming.step))
                local ok, derr = Discord.send(msg, {
                    logger = function(m) io.stderr:write("[discord] " .. m .. "\n") end,
                })
                event_log:write({
                    event = { kind = "BIN_UNCALIBRATED", level = "YELLOW",
                              bin_key = arming.bin_key,
                              missing = missing,
                              msg     = "run started without one or more detectors" },
                    sent  = ok,
                    send_err = (not ok) and derr or nil,
                    state    = "ACTIVE_RUN",
                    bin_key  = arming.bin_key,
                })
            end
        elseif ent.action == "IRRIGATION_STEP_COMPLETE" then
            -- Derive bin_key from details (more robust than relying on arming,
            -- which can be nil if robot started after STATION_START).
            local bin_key = nil
            if type(ent.details) == "table" then
                bin_key = T.canonicalize_io_setup(ent.details.io_setup)
            end
            if (not bin_key or bin_key == "?") and arming then
                bin_key = arming.bin_key
            end
            if bin_key and bin_key ~= "?" and baselines then
                cycle.kb4_step_complete = cycle.kb4_step_complete or {}
                cycle.kb4_step_complete[#cycle.kb4_step_complete+1] = bin_key
                -- Defer the actual fetch+process to after the past_actions
                -- loop so we don't slow down the delta walk. Stash for stage 5b.
                pending_kb4 = pending_kb4 or {}
                pending_kb4[#pending_kb4+1] = bin_key
            end
            arming = nil
        elseif ent.action == "SKIP_OPERATION" then
            arming = nil    -- disarm but no curve update
        elseif ent.action == "IRRIGATION_ETO_RESTRICTION" then
            if arming then arming.eto_restriction_seen = true end
        end
        if ent.stream_id then last_stream_id = ent.stream_id end
    end

    -- 4) state classification
    local state = SM.classify(popup, MANUAL_SUSPEND)
    cycle.state = state

    -- 4b) track MASTER_IDLE_CHECK session (warm-up timestamp + window + cooldown)
    if state == SM.states.MASTER_IDLE_CHECK then
        if prev_state ~= SM.states.MASTER_IDLE_CHECK then
            master_idle = {
                armed_ts         = os.time(),
                irr_window       = {},
                last_accepted_ts = nil,
                cond_state       = {},   -- edge-triggered per (kind); reset on entering MASTER_IDLE_CHECK
            }
        end
    else
        master_idle = nil
    end

    -- 5) edges (kb2 trigger on RESISTANCE exit)
    local edges = SM.edges(prev_state, state)
    if #edges > 0 then cycle.edges = edges end
    local kb2_events_this_poll = {}
    for _, ed in ipairs(edges) do
        if ed == "KB2_RUN_RESISTANCE_ANALYSIS" then
            io.stderr:write("KB2: RESISTANCE_CHECK exit detected — running analyzer\n")
            local result, kerr = KB2Post.run_analysis(REPO_IRRIGATION)
            if not result then
                io.stderr:write("KB2: analyzer FAILED: " .. tostring(kerr) .. "\n")
                kb2_log:write({
                    t = cycle.t, event = "analyzer_failed", error = kerr,
                })
            else
                local ev = KB2Post.event_from_result(result)
                kb2_log:write({
                    t            = cycle.t,
                    event        = "analyzer_ok",
                    summary      = result.summary,
                    cohort_stats = result.cohort_stats,
                    bad          = result.bad,
                    marginal     = result.marginal,
                })
                kb2_events_this_poll[#kb2_events_this_poll+1] = ev
                io.stderr:write(string.format(
                    "KB2: analyzed %d valves: %d bad, %d marginal (level=%s)\n",
                    result.summary and result.summary.n_valves or 0,
                    ev.n_bad or 0, ev.n_marginal or 0, ev.level))
            end
        end
    end

    -- 5b) KB4 — process each STEP_COMPLETE that fired this poll.
    -- Fetch the bin's TIME_HISTORY (newest run), reduce, update window,
    -- score (short only), apply edge-trigger, emit Discord event if flagged.
    local kb4_events_this_poll = {}
    local kb4_any_baseline_update = false
    if pending_kb4 and baselines then
        for _, bin_key in ipairs(pending_kb4) do
            local th, terr = Controller.time_history_bin(bin_key)
            if not th then
                io.stderr:write(string.format(
                    "KB4: time_history_bin(%s) failed: %s\n", bin_key, tostring(terr)))
                kb4_log:write({
                    t = cycle.t, event = "fetch_failed",
                    bin_key = bin_key, error = terr,
                })
            else
                local res, kev, kerr = KB4Post.process(
                    bin_key, baselines, th.flow_data or {}, kb4_cond_state)
                kb4_log:write({
                    t          = cycle.t,
                    bin_key    = bin_key,
                    mode       = res and res.mode,
                    reduction  = res and res.reduction,
                    last       = res and res.last,
                    new_ref    = res and res.new_ref,
                    new_ref_mad= res and res.new_ref_mad,
                    n_runs_total = res and res.n_runs_total,
                    updated    = res and res.updated,
                    kind       = res and res.kind,
                    delta      = res and res.delta,
                    threshold  = res and res.threshold,
                    fired_event= kev ~= nil,
                    error      = kerr,
                    n_samples  = th.n,
                })
                if res and res.updated then
                    kb4_any_baseline_update = true
                end
                if kev then
                    kb4_events_this_poll[#kb4_events_this_poll+1] = kev
                    io.stderr:write(string.format(
                        "KB4 FIRE: %s last=%.2f vs ref=%.2f Δ=%+.2f (%s)\n",
                        bin_key, res.last, res.ref, res.delta, kev.kind))
                end
            end
        end
        if kb4_any_baseline_update then
            local ok, perr = KB4Post.persist(baselines, BASELINES_PATH)
            if not ok then
                io.stderr:write("KB4: persist failed: " .. tostring(perr) .. "\n")
            end
        end
    end

    -- 6) advance sample counter for sample-0 skip
    if state == SM.states.ACTIVE_RUN and arming then
        arming.samples_seen = (arming.samples_seen or 0) + 1
    end

    -- 6b) gate-by-TIME_STAMP: push current irr_current into the active
    -- session's rolling-median window only when the controller has
    -- published a fresh measurement. PLC_IRRIGATION_CURRENT updates ~1/min
    -- while poll cadence is 30s, so half the polls see the same value.
    -- See thresholds.SAMPLE_DEDUP_TS_GAP_S.
    local cur_ts = tonumber(popup.TIME_STAMP)
    local irr    = tonumber(popup.PLC_IRRIGATION_CURRENT) or 0
    local active_window
    if state == SM.states.ACTIVE_RUN and arming then
        active_window = arming
    elseif state == SM.states.MASTER_IDLE_CHECK and master_idle then
        active_window = master_idle
    end
    local sample_accepted = false
    if active_window then
        local last_ts = active_window.last_accepted_ts
        if (not last_ts) or (cur_ts and (cur_ts - last_ts) >= T.SAMPLE_DEDUP_TS_GAP_S) then
            T.push_window(active_window.irr_window, irr, T.MEDIAN_WINDOW_N)
            active_window.last_accepted_ts = cur_ts
            sample_accepted = true
        end
    end
    local irr_median   = active_window and T.rolling_median(active_window.irr_window) or nil
    local irr_window_n = active_window and #active_window.irr_window or 0
    if active_window then
        cycle.window = {
            n               = irr_window_n,
            median          = irr_median,
            sample_accepted = sample_accepted,
            last_ts         = active_window.last_accepted_ts,
        }
    end

    -- 6c) KB3 LIVE flow detector — runs only during ACTIVE_RUN.
    -- Step-indexed (popup.STEP) sliding window: warmup until STEP >= 9,
    -- then fire when [STEP-4..STEP] are ALL over threshold. KB3 dedups
    -- internally by step number, so we feed every poll (no TIME_STAMP gate).
    local kb3_result = nil
    if state == SM.states.ACTIVE_RUN and arming and arming.bin_key and baselines then
        local bl   = Baselines.lookup(baselines, arming.bin_key)
        local filt = tonumber(popup.FILTERED_HUNTER_VALVE)
        local step = tonumber(popup.STEP)
        if bl and filt and step then
            kb3_result = KB3Live.update(bl, arming.kb3, filt, step)
            if kb3_result then
                cycle.kb3 = {
                    bin_key       = arming.bin_key,
                    eligible      = bl.kb3_eligible,
                    sample        = kb3_result.sample,
                    ref           = kb3_result.ref,
                    err           = kb3_result.err,
                    threshold     = kb3_result.threshold,
                    step          = kb3_result.step,
                    window_over_n = kb3_result.window_over_n,
                    fired         = kb3_result.fired,
                    suppressed    = kb3_result.suppressed,
                }
                if kb3_result.fired then
                    io.stderr:write(string.format(
                        "KB3 LIVE FIRE: bin=%s sample=%.2f err=%+.2f step=%d\n",
                        arming.bin_key, kb3_result.sample, kb3_result.err,
                        kb3_result.step))
                end
            end
        end
    end

    -- 7) evaluate modes
    local events = Modes.evaluate(state, popup, arming, last_sample, {
        now_ts = os.time(),
        master_idle_armed_ts = master_idle and master_idle.armed_ts,
        irr_median           = irr_median,
        irr_window_n         = irr_window_n,
    }) or {}
    -- 7b) append KB3 fire as an event so Discord dispatch sees it (one per run
    -- enforced inside KB3Live; edge-trigger in section 9 is a no-op for it).
    if kb3_result and kb3_result.fired then
        events[#events+1] = KB3Live.event(arming.bin_key, baselines and Baselines.lookup(baselines, arming.bin_key),
                                          arming.kb3, kb3_result)
    end
    -- 7c) append KB2 events (RESISTANCE_CHECK completion). One per edge.
    -- KB2 events bypass edge-trigger cooldown — they're discrete daily-cycle
    -- summaries, each one fires once.
    for _, kev in ipairs(kb2_events_this_poll) do
        events[#events+1] = kev
    end
    -- 7d) append KB4 short-bin events. Edge-trigger already applied inside
    -- KB4Post.process using kb4_cond_state — they bypass the session
    -- edge-trigger logic in section 9.
    for _, kev in ipairs(kb4_events_this_poll) do
        kev._kb4_already_edged = true   -- marker so section 9 skips re-cooldown
        events[#events+1] = kev
    end
    if #events > 0 then cycle.events = events end
    -- record warmup remaining for log visibility
    local warmup_left = nil
    if state == SM.states.ACTIVE_RUN and arming and arming.started_at_ts then
        local left = T.WARMUP_S - (os.time() - arming.started_at_ts)
        if left > 0 then warmup_left = left end
    elseif state == SM.states.MASTER_IDLE_CHECK and master_idle then
        local left = T.WARMUP_S - (os.time() - master_idle.armed_ts)
        if left > 0 then warmup_left = left end
    end
    if warmup_left then cycle.warmup_s_remaining = warmup_left end

    -- 8) record sample for next cycle (sustained-N comparison)
    last_sample = {
        irr_current = tonumber(popup.PLC_IRRIGATION_CURRENT) or 0,
        eq_current  = tonumber(popup.PLC_EQUIPMENT_CURRENT)  or 0,
    }
    cycle.arming_summary = arming and {
        bin_key      = arming.bin_key,
        calibrated   = arming.curve ~= nil,
        samples_seen = arming.samples_seen,
        eto_suppressed = arming.eto_restriction_seen,
    } or nil

    poll_log:write(cycle)
    if cycle.kb3 then
        kb3_log:write({
            t       = cycle.t,
            bin_key = cycle.kb3.bin_key,
            sample  = cycle.kb3.sample,
            ref     = cycle.kb3.ref,
            err     = cycle.kb3.err,
            step          = cycle.kb3.step,
            window_over_n = cycle.kb3.window_over_n,
            fired      = cycle.kb3.fired,
            suppressed = cycle.kb3.suppressed,
        })
    end

    -- 9) Discord per event — EDGE-TRIGGERED cooldown.
    -- Policy: alert once on ok→fired transition. Suppress while fired.
    -- Return to ok silently when condition clears (no recovery alert).
    -- Re-arm on next ok→fired edge.
    -- State resets per session: arming on STATION_START, master_idle on
    -- entering MASTER_IDLE_CHECK. IDLE-state events still un-cooldown'd.
    local function session_for(ev)
        if state == SM.states.ACTIVE_RUN then return arming end
        if state == SM.states.MASTER_IDLE_CHECK then return master_idle end
        return nil
    end

    -- (a) Build the set of kinds that fired in THIS poll (KB1/KB3 only; KB4
    -- events manage their own cond_state inside KB4Post and use _kb4_already_edged)
    local seen_kinds = {}
    for _, ev in ipairs(events) do
        if not ev._kb4_already_edged then
            seen_kinds[ev.kind] = true
        end
    end
    -- (b) Transition fired→ok for any tracked kind NOT seen this poll
    local function clear_unseen(sess)
        if not sess or not sess.cond_state then return end
        for k, st in pairs(sess.cond_state) do
            if st == "fired" and not seen_kinds[k] then
                sess.cond_state[k] = "ok"
            end
        end
    end
    clear_unseen(arming)
    clear_unseen(master_idle)

    -- (c) Per-event fire/suppress decision against cond_state
    for _, ev in ipairs(events) do
        local sess = session_for(ev)
        local suppressed = false
        if not ev._kb4_already_edged and sess and sess.cond_state then
            if sess.cond_state[ev.kind] == "fired" then
                suppressed = true   -- still in fault, no re-alert
            end
        end
        local ok, derr
        if suppressed then
            ok, derr = false, "edge_suppressed"
        else
            local content = Discord.format_event(ev, {
                state    = state,
                schedule = popup.SCHEDULE_NAME,
                step     = popup.STEP,
                bin_key  = arming and arming.bin_key,
            })
            ok, derr = Discord.send(content, {
                logger = function(m) io.stderr:write("[discord] " .. m .. "\n") end,
            })
            if ok and not ev._kb4_already_edged and sess and sess.cond_state then
                sess.cond_state[ev.kind] = "fired"
            end
        end
        -- Controller-side action: dispatch on the SAME edge as the Discord
        -- send (suppress on cooldown, fire once per ok→fired transition).
        -- ALLOWED_ACTIONS gates which event actions actually POST; unknown
        -- action strings fall through to log-only.
        local ws_ok, ws_code, ws_err
        if not suppressed and ev.action and ALLOWED_ACTIONS[ev.action] then
            ws_ok, ws_code, ws_err = WsCommand.post(ev.action, {
                logger = function(m) io.stderr:write("[ws] " .. m .. "\n") end,
            })
            ws_log:write({
                kind   = ev.kind,
                action = ev.action,
                ok     = ws_ok,
                code   = ws_code,
                err    = ws_err,
                bin_key = arming and arming.bin_key,
            })
        end
        event_log:write({
            event                 = ev,
            sent                  = ok,
            edge_suppressed       = suppressed or nil,
            send_err              = (not ok and not suppressed) and derr or nil,
            action_dispatched     = ws_ok or nil,
            action_code           = ws_code,
            action_err            = ws_err,
            state                 = state,
            bin_key               = arming and arming.bin_key,
            window_n              = irr_window_n,
            irr_median            = irr_median,
        })
    end

    prev_state = state
    save_last_stream_id(last_stream_id)
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

while true do
    local okp, perr = pcall(poll_once)
    if not okp then
        poll_log:write({ fatal = "poll_once raised: " .. tostring(perr) })
        io.stderr:write("KB1 SHADOW: poll_once raised: " .. tostring(perr) .. "\n")
    end
    ffi.C.usleep(POLL_S * 1000000)
end
