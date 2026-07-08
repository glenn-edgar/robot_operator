-- kb3_sustained.lua — schedule-aware ETO leak detector (Glenn 2026-06-10 spec).
--
-- Design: per-minute step-based detector that fires on 3 consecutive
-- minutes with the SMOOTH HUNTER meter over an absolute GPM threshold.
-- After 5-minute warmup at run start. ETO bins only (non-ETO short runs
-- are skipped entirely).
--
-- Sensor strategy (Glenn 2026-06-10 — leak/blocked signal split):
--   - LEAK detection (this module, KB3) trips on the SMOOTH HUNTER meter
--     (popup.FILTERED_HUNTER_VALVE) — the GPM curve = water actually
--     DELIVERED to irrigation. Hunter never sees the house draw, so no
--     house-draw correction is needed on the leak path.
--   - The PLC well meter (popup.PLC_FLOW_METER) is NOT used for leak
--     detection. PLC = well output = irrigation + house draw; it is the
--     BLOCKED-sprinkler signal (gallons curve, KB4) instead.
--   - No PLC median filtering: a glitchy PLC is a valve to fix on the
--     maintenance run, not noise to smooth over; and the gallons curve is
--     an integral that already averages out per-sample noise.
--   - city_delta = FHV - PLC is retained as telemetry only (never trips).
--     NOTE: on city bins Hunter sees city + well summed, so a heavy city
--     dwell can lift Hunter — watch for false leak fires there (clean at
--     14 GPM in the 2026-06-08..10 test; city bins peaked ~11.4 GPM).
--
-- Key concept: "step" = popup.ELASPED_TIME (controller's per-minute
-- counter — note the controller's typo, preserved as-is). It increments
-- once per minute at HH:MM:15. Polling at 30s, we detect each minute
-- transition by watching this value change. Each step transition is one
-- "evaluation" — we don't double-count within a minute.
--
-- Algorithm per evaluation:
--   if elapsed < 5: in warmup → reset consecutive, skip
--   hunter = popup.FILTERED_HUNTER_VALVE (GPM delivered to irrigation)
--   trip = hunter > THRESHOLD
--   if trip: consecutive += 1
--            if consecutive >= 3: FIRE
--   else:    consecutive = 0
--   city_delta = FHV - PLC  (telemetry only)
--
-- On FIRE: CLOSE_MASTER_VALVE (water off first) then SKIP_STATION
-- (advance queue). One fire per station — the fired flag stays true
-- until next STATION_START.
--
-- Independent of KB2 / KB4. No baseline math, no expected values.

local M = {}

-- =========================================================================
-- Tuneables
-- =========================================================================
-- Absolute leak ceiling (Glenn 2026-06-30: 13.5 → 14). Above this = more filtered
-- flow than a healthy well delivers = leak. (Was 13.5 to catch 4:4 at ~14; Glenn
-- set it back to a clean 14 GPM absolute.)
M.GPM_THRESHOLD       = 14.0   -- primary: fire if HUNTER > this for N consec min (absolute)
-- Secondary (relative) trip — Glenn 2026-06-10. Catches a break/leak that is
-- abnormally high FOR THIS BIN but still under the absolute 14 (e.g. a 7 GPM
-- bin pushed to 12 by a coyote-chewed line). Baseline = KB4 v2's per-bin Hunter
-- expected-flow = median of the last 7 per-run means of Hunter over min 5-15
-- (KB4V2.load_hunter_baseline). Fire if HUNTER > base_hunter + 4 GPM, sustained
-- 3 consec min, from the 5-minute mark — armed only once the bin has
-- >= BASELINE_MIN_N_CLEAN runs so a thin/seeding baseline can't false-trip.
-- Both trips share the 3-consec gate.
-- Set to +5 (Glenn 2026-06-30: was 2). +2 FALSE-TRIPPED 2:13 on 06-30 — its baseline
-- had been dragged down to ~6.9 by a week of FILTER-LOADED runs (delivery choked to
-- ~6-7); once the filter was cleaned, 2:13 recovered to its true ~9 and read +2.1 over
-- the suppressed baseline = false leak. +5 rides out that baseline-recovery lag (and the
-- same suppression on other ETO bins) while still catching a genuine break.
M.BASELINE_DELTA_GPM    = 5.0   -- secondary: fire if HUNTER > base_hunter + this
M.BASELINE_MIN_N_CLEAN  = 3     -- arm secondary only once >= this many runs collected
-- WARMUP_MINUTES exists because of SPRINKLER LINE RECHARGE (Glenn 2026-06-09):
-- When a station starts, the dry/depressurized sprinkler distribution lines
-- fill rapidly — water rushes in to refill empty pipe between the master
-- valve and the emitters. This produces a real, large PLC spike (observed
-- 18.2 GPM at min 1 on sat_4:9 18:00 vs steady-state 10.8 GPM). Once the
-- lines are charged and pressure equilibrium is reached, flow drops to the
-- emitters' actual demand. The 5-min warmup covers this charging phase.
-- DO NOT tighten warmup below ~3 min without first verifying line-recharge
-- duration for the most distant zone.
M.WARMUP_MINUTES      = 5
M.CONSECUTIVE_REQUIRED = 4     -- N minutes in a row over threshold (Glenn 2026-06-15: 3→4)
-- Flow-onset anchoring (Glenn 2026-06-10): flow can start a few minutes after
-- STATION_START (valve actuation + bookkeeping lag), and the line-recharge
-- transient rides on FIRST flow — so the warmup is counted from first flow
-- (PLC or Hunter > ONSET_GPM), not from elapsed=0. Keeps the recharge spike
-- (and its Hunter overshoot) reliably inside the warmup even when onset is
-- delayed. Verified against sat_4:9 06-09 18:00 (recharge at run-min 1-5).
M.ONSET_GPM           = 1.0

-- Upstream-break trip — PLC−Hunter divergence (Glenn 2026-06-10). A main-line
-- break UPSTREAM of the Hunter meter gushes from the well (PLC spikes) without
-- reaching the zone (Hunter stays normal), so the Hunter leak trip misses it.
-- Trip on SUSTAINED divergence; a transient divergence is benign house draw
-- (the well feeds the house). Non-city bins only — city bins legitimately have
-- Hunter > PLC. Normal divergence ~+1.5 GPM; house draw ~+4 (brief).
M.DIVERGENCE_GPM      = 8.0    -- fire if (PLC - Hunter) > this for N consec min
-- Well-exhaustion / dry-run guard — PLC well-flow collapse during a run that
-- WAS supplying. Arms once PLC exceeds WELL_ARMED_GPM (well was carrying the
-- run), trips on a sustained drop below WELL_FLOOR_GPM. Protects the pump and
-- cuts the draw so the well recovers. PLC-collapse proxy until WELL_PRESSURE
-- is wired.
M.WELL_ARMED_GPM      = 8.0    -- guard arms once PLC exceeds this
M.WELL_FLOOR_GPM      = 4.0    -- fire if PLC < this for N consec min once armed
-- Hunter cross-check (Glenn 2026-06-28): a PLC collapse while the smooth Hunter is
-- STILL FLOWING above this is a SAND-FOULED METER (delivery is fine), not a dying
-- well — that's the PLC-foul clean's job, so DON'T raise a WELL_EXHAUSTION alarm.
-- Only treat a PLC collapse as exhaustion when delivery (Hunter) is ALSO starved
-- below this. Kept in lockstep with the foul detector's HUN_FLOW_GPM (env
-- KB3_HUN_FLOW_GPM) by the call site. Fixes the recurring false RED on every foul.
M.WELL_HUNTER_FLOOR_GPM = 4.0

-- ETO valve membership. Mirror of farm-side eto_site_setup.json — these
-- are the 20 pins that run on the No_city_water schedule. Non-ETO bins
-- (short runs, city flushes, grass schedules) are skipped entirely
-- because their 5-min warmup + 3-minute sustained check doesn't fit
-- their run profile.
M.ETO_PINS = {
    satellite_2 = { [13]=true, [14]=true, [15]=true, [16]=true },
    satellite_3 = { [1]=true, [2]=true, [5]=true, [13]=true, [14]=true,
                    [15]=true, [18]=true },
    satellite_4 = { [1]=true, [3]=true, [4]=true, [6]=true, [7]=true,
                    [9]=true, [10]=true, [11]=true, [12]=true },
}

function M.is_eto_bin(io_setup)
    if type(io_setup) ~= "table" then return false end
    for _, group in ipairs(io_setup) do
        if type(group) == "table" then
            local sat = group.remote
            for _, bit in ipairs(group.bits or {}) do
                if M.ETO_PINS[sat] and M.ETO_PINS[sat][tonumber(bit)] then
                    return true
                end
            end
        end
    end
    return false
end

-- City-water valve identity (locked from irrigation_channel_physics memo):
-- sat_1:39 is the city-water valve with dwell. When any group in the
-- io_setup contains sat_1:39, water can come from EITHER well or city,
-- which makes FHV > PLC legitimate (the delta IS the city water).
M.CITY_VALVE = { remote = "satellite_1", bit = 39 }

function M.is_city_bin(io_setup)
    if type(io_setup) ~= "table" then return false end
    for _, group in ipairs(io_setup) do
        if type(group) == "table" and group.remote == M.CITY_VALVE.remote then
            for _, bit in ipairs(group.bits or {}) do
                if tonumber(bit) == M.CITY_VALVE.bit then return true end
            end
        end
    end
    return false
end

function M.bin_key(io_setup)
    local parts = {}
    for _, group in ipairs(io_setup or {}) do
        if type(group) == "table" then
            local sat = group.remote or "?"
            for _, bit in ipairs(group.bits or {}) do
                parts[#parts+1] = sat .. ":" .. tostring(bit)
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, "/")
end

-- =========================================================================
-- Step evaluation
-- =========================================================================
--
-- arming: the per-station state table. Mutated in place. Fields:
--   bin             string
--   is_city         bool — set at STATION_START; affects city_delta logging
--   baseline_gpm    REAL | nil — KB4 v2 per-bin baseline if available with
--                                n_clean_runs >= BASELINE_MIN_N_CLEAN
--   started_sid     past_actions stream_id of STATION_START
--   prev_elapsed    last seen popup.ELASPED_TIME (so we eval only on change)
--   consecutive     current count of over-threshold minutes
--   fired           bool — true after we've fired this station
--
-- Returns table describing what happened. Caller logs and may dispatch on
-- action="FIRE". `trip_path` is "primary" | "secondary" | "both" | nil so
-- the operator knows which gate fired.
--
-- Trip rule (signal = SMOOTH HUNTER, the GPM curve):
--   primary   = HUNTER > GPM_THRESHOLD
--   secondary = baseline_gpm and HUNTER > (baseline_gpm + BASELINE_DELTA_GPM)
--   trip      = primary OR secondary
-- PLC does NOT trip (carried for telemetry / city_delta only). secondary is
-- dormant until a Hunter-frame per-bin baseline exists (caller passes nil).
function M.evaluate_step(arming, elapsed, plc, hunter)
    if not arming or not elapsed then
        return { action = "skip", reason = "no_arming_or_elapsed" }
    end

    -- Detect actual minute change. If elapsed hasn't changed, it's the
    -- same minute — skip silently (caller can still log periodically).
    if arming.prev_elapsed and elapsed == arming.prev_elapsed then
        return { action = "no_change", elapsed = elapsed }
    end
    arming.prev_elapsed = elapsed

    -- city_delta: signed FHV - PLC (positive = city water contributing).
    local city_delta = nil
    if plc and hunter then city_delta = hunter - plc end

    -- Flow-onset: record the elapsed minute at which flow first appears on
    -- either meter; the warmup is measured from there (see M.ONSET_GPM).
    if not arming.flow_onset then
        if math.max(plc or 0, hunter or 0) > M.ONSET_GPM then
            arming.flow_onset = elapsed
        end
    end

    -- Warmup: don't evaluate until WARMUP_MINUTES past first flow. If flow
    -- hasn't started yet (flow_onset nil), stay in warmup.
    local warmed = arming.flow_onset and (elapsed - arming.flow_onset) or -1
    if warmed < M.WARMUP_MINUTES then
        arming.consecutive = 0
        return {
            action = "warmup", elapsed = elapsed,
            plc = plc, hunter = hunter, city_delta = city_delta,
            consecutive = 0, in_warmup = true,
            baseline_gpm = arming.baseline_gpm,
        }
    end

    -- Already fired this station — log but don't re-fire.
    if arming.fired then
        return {
            action = "fired_already", elapsed = elapsed,
            plc = plc, hunter = hunter, city_delta = city_delta,
            consecutive = arming.consecutive, fired = true,
            baseline_gpm = arming.baseline_gpm,
        }
    end

    -- ===== Three run-time hydraulic trips, evaluated together =====
    local hunter_val = hunter or 0
    local plc_val    = plc or 0

    -- (1) LEAK — on the SMOOTH HUNTER meter (water delivered to irrigation).
    --     Absolute Hunter > threshold, or relative Hunter > per-bin baseline+4.
    local trip_primary = hunter_val > M.GPM_THRESHOLD
    local trip_secondary = arming.baseline_gpm
        and (hunter_val > (arming.baseline_gpm + M.BASELINE_DELTA_GPM)) or false
    local leak_trip = trip_primary or trip_secondary
    arming.consecutive = leak_trip and ((arming.consecutive or 0) + 1) or 0

    -- (2) UPSTREAM BREAK — PLC−Hunter divergence (well gushing before the zone
    --     meter). Non-city bins only (city bins legitimately have Hunter > PLC).
    --     Sustained-gated so transient house draws don't trip.
    local divergence = (plc and hunter) and (plc_val - hunter_val) or nil
    local div_trip = (not arming.is_city) and divergence
        and (divergence > M.DIVERGENCE_GPM) or false
    arming.div_consec = div_trip and ((arming.div_consec or 0) + 1) or 0

    -- (3) WELL EXHAUSTION / dry-run guard — PLC well-flow collapse during a run
    --     that WAS supplying. Arms once PLC exceeds WELL_ARMED_GPM, trips on a
    --     sustained drop below WELL_FLOOR_GPM (protects the pump; lets the well
    --     recover). PLC-collapse proxy until WELL_PRESSURE is wired.
    if plc_val > M.WELL_ARMED_GPM then arming.well_flowing = true end
    -- Hunter cross-check: a PLC collapse with Hunter STILL FLOWING is a fouled meter,
    -- not exhaustion — only count the trip when delivery (Hunter) is ALSO starved.
    local hunter_starved = hunter_val < M.WELL_HUNTER_FLOOR_GPM
    local well_trip = arming.well_flowing
        and (plc_val < M.WELL_FLOOR_GPM) and hunter_starved or false
    arming.well_consec = well_trip and ((arming.well_consec or 0) + 1) or 0

    -- First trip to reach the consecutive gate fires; all three close the master.
    -- One fire per station (arming.fired latches until next STATION_START).
    local fire_type = nil
    if arming.consecutive >= M.CONSECUTIVE_REQUIRED then fire_type = "leak"
    elseif arming.div_consec >= M.CONSECUTIVE_REQUIRED then fire_type = "divergence"
    elseif arming.well_consec >= M.CONSECUTIVE_REQUIRED then fire_type = "well"
    end
    local should_fire = (fire_type ~= nil) and (not arming.fired)
    if should_fire then arming.fired = true end

    local trip_path = nil
    if trip_primary and trip_secondary then trip_path = "both"
    elseif trip_primary then trip_path = "primary"
    elseif trip_secondary then trip_path = "secondary"
    end

    return {
        action         = should_fire and "FIRE" or "checked",
        fire_type      = should_fire and fire_type or nil,
        elapsed        = elapsed,
        plc            = plc,
        hunter         = hunter,
        city_delta     = city_delta,
        divergence     = divergence,
        trip_primary   = trip_primary,
        trip_secondary = trip_secondary,
        trip_path      = trip_path,
        baseline_gpm   = arming.baseline_gpm,
        consecutive    = arming.consecutive,
        div_consec     = arming.div_consec,
        well_consec    = arming.well_consec,
        fired          = arming.fired,
    }
end

-- =========================================================================
-- SQLite — per-minute evaluation log + fires
-- =========================================================================
local lsqlite3 = nil
local function ensure_lsqlite3()
    if lsqlite3 then return lsqlite3 end
    local ok, mod = pcall(require, "lsqlite3")
    if not ok then return nil, "lsqlite3 not available: " .. tostring(mod) end
    lsqlite3 = mod
    return mod
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS evals_kb3 (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms           INTEGER NOT NULL,
    bin             TEXT,
    is_city         INTEGER DEFAULT 0,
    schedule        TEXT,
    station_step    INTEGER,
    elapsed_min     INTEGER,
    plc_gpm         REAL,
    hunter_gpm      REAL,
    city_delta_gpm  REAL,
    baseline_gpm    REAL,
    trip_primary    INTEGER,
    trip_secondary  INTEGER,
    trip_path       TEXT,
    consecutive     INTEGER,
    in_warmup       INTEGER,
    fired           INTEGER,
    action          TEXT
);
CREATE INDEX IF NOT EXISTS idx_evals_kb3_bin ON evals_kb3(bin);
CREATE INDEX IF NOT EXISTS idx_evals_kb3_ts  ON evals_kb3(ts_ms);
CREATE INDEX IF NOT EXISTS idx_evals_kb3_fired ON evals_kb3(fired);

CREATE TABLE IF NOT EXISTS runs_kb3 (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms           INTEGER NOT NULL,
    bin             TEXT,
    is_city         INTEGER DEFAULT 0,
    schedule        TEXT,
    station_step    INTEGER,
    elapsed_min     INTEGER,
    plc_gpm         REAL,
    hunter_gpm      REAL,
    city_delta_gpm  REAL,
    baseline_gpm    REAL,
    trip_path       TEXT,
    actions_sent    TEXT,
    armed           INTEGER DEFAULT 0,
    note            TEXT
);
CREATE INDEX IF NOT EXISTS idx_runs_kb3_ts ON runs_kb3(ts_ms);

-- key/val store. Holds last_clean_ms = ms timestamp of the last CLEAN_FILTER this
-- KB issued (either the flow-deplete recovery OR the PLC-foul clean). It is the
-- SHARED filter-clean rate-gate: both clean paths consult + update it so one
-- loading-filter event produces ONE clean, not two. Persisted so a restart keeps
-- the cooldown.
CREATE TABLE IF NOT EXISTS kb3_meta (
    key TEXT PRIMARY KEY,
    val INTEGER
);

-- Flow step-change leak-watch de-dup (lib/flow_step.lua). One row per bin that has
-- stepped up; last_alert_ms gates re-alerting (else it fires every run the step persists).
CREATE TABLE IF NOT EXISTS flow_step_state (
    bin           TEXT PRIMARY KEY,
    last_alert_ms INTEGER,
    last_delta    REAL
);
]]

function M.open_db(path)
    local mod, err = ensure_lsqlite3()
    if not mod then return nil, err end
    local db, code, errmsg = mod.open(path)
    if not db then
        return nil, string.format("open %s failed: %s/%s",
            path, tostring(code), tostring(errmsg))
    end
    local rc = db:exec(SCHEMA)
    if rc ~= mod.OK then
        local msg = db:errmsg()
        db:close()
        return nil, "schema migration failed: " .. tostring(msg)
    end
    return db
end

-- Shared filter-clean cooldown (see kb3_meta above).
function M.get_last_clean_ms(db)
    local v = nil
    for row in db:nrows("SELECT val FROM kb3_meta WHERE key='last_clean_ms'") do
        v = tonumber(row.val)
    end
    return v
end

function M.set_last_clean_ms(db, ts_ms)
    local stmt = db:prepare(
        "INSERT OR REPLACE INTO kb3_meta(key,val) VALUES('last_clean_ms',?)")
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(tonumber(ts_ms) or 0)
    stmt:step()
    stmt:finalize()
    return true
end

-- Flow step-change leak-watch de-dup: last alert time for a bin (0 if never).
function M.get_flow_step_alert_ms(db, bin)
    local v = 0
    for row in db:nrows("SELECT last_alert_ms FROM flow_step_state WHERE bin=" ..
                        string.format("%q", bin)) do
        v = tonumber(row.last_alert_ms) or 0
    end
    return v
end

function M.set_flow_step_alert(db, bin, ts_ms, delta)
    local stmt = db:prepare(
        "INSERT OR REPLACE INTO flow_step_state(bin,last_alert_ms,last_delta) VALUES(?,?,?)")
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(bin, tonumber(ts_ms) or 0, tonumber(delta) or 0)
    stmt:step()
    stmt:finalize()
    return true
end

function M.insert_eval(db, fields)
    local stmt = db:prepare([[
        INSERT INTO evals_kb3(
            ts_ms, bin, is_city, schedule, station_step, elapsed_min,
            plc_gpm, hunter_gpm, city_delta_gpm, baseline_gpm,
            trip_primary, trip_secondary, trip_path, consecutive,
            in_warmup, fired, action)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(fields.ts_ms, fields.bin,
        fields.is_city and 1 or 0,
        fields.schedule,
        fields.station_step, fields.elapsed_min,
        fields.plc_gpm, fields.hunter_gpm,
        fields.is_city and fields.city_delta_gpm or nil,
        fields.baseline_gpm,
        fields.trip_primary and 1 or 0,
        fields.trip_secondary and 1 or 0,
        fields.trip_path,
        fields.consecutive or 0,
        fields.in_warmup and 1 or 0,
        fields.fired and 1 or 0,
        fields.action)
    stmt:step()
    stmt:finalize()
    return true
end

function M.insert_fire(db, fields)
    local stmt = db:prepare([[
        INSERT INTO runs_kb3(
            ts_ms, bin, is_city, schedule, station_step, elapsed_min,
            plc_gpm, hunter_gpm, city_delta_gpm, baseline_gpm,
            trip_path, actions_sent, armed, note)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]])
    if not stmt then return nil, db:errmsg() end
    stmt:bind_values(fields.ts_ms, fields.bin,
        fields.is_city and 1 or 0,
        fields.schedule,
        fields.station_step, fields.elapsed_min,
        fields.plc_gpm, fields.hunter_gpm,
        fields.is_city and fields.city_delta_gpm or nil,
        fields.baseline_gpm,
        fields.trip_path,
        fields.actions_sent or "",
        fields.armed and 1 or 0,
        fields.note)
    stmt:step()
    stmt:finalize()
    return true
end

return M
