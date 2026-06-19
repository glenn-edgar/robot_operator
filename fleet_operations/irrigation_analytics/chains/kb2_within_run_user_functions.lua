-- chains/kb2_within_run_user_functions.lua — KB2_WR_TICK handler.
--
-- Per tick:
--   1. Poll past_actions on KB2-WR private cursor for new STEP_COMPLETE events
--   2. For each event on an ETO bin:
--        a. Fetch TIME_HISTORY (full record including IRRIGATION_CURRENT.data)
--        b. Compute n_zone_coils for the bin (handles redundant-contact,
--           true-dual, city-zone topology)
--        c. Read KB2 baselines (R_master + null_offset)
--        d. Back-derive R(t) per minute using compute_R_per_minute
--        e. Analyze: linear-fit slope, max step, MAD, end-vs-start
--        f. Classify (OK | R_HEATING_DURING_RUN | R_STEP_DURING_RUN |
--           R_END_HIGH | R_INSTABILITY)
--        g. INSERT row in runs_kb2_within
--        h. Discord push on R_STEP_DURING_RUN (high severity)

local cjson         = require("cjson")
local controller    = require("controller_client")
local KB2_WR        = require("kb2_within_run")
local KB2           = require("kb2_resistance")     -- for derive_calibration
local KB_ALERTS     = require("kb_alerts")
local app_heartbeat = require("app_heartbeat")

local M = { main = {}, one_shot = {}, boolean = {} }

local DIGEST_TOPIC   = "fleet/notify/digest/daily"
local SCHEMA_NOTIFY  = "fleet.notify.digest/1"
local DEFAULT_POLL_S = 60

-- ETO valves (mirror of eto_site_setup.json — 20 individual pins)
local ETO_PINS = {
    satellite_2 = { [13]=true, [14]=true, [15]=true, [16]=true },
    satellite_3 = { [1]=true,  [2]=true,  [5]=true,  [13]=true,
                    [14]=true, [15]=true, [18]=true },
    satellite_4 = { [1]=true,  [3]=true,  [4]=true,  [6]=true,
                    [7]=true,  [9]=true,  [10]=true, [11]=true, [12]=true },
}

-- Per-bin topology: how many real zone coils carry current when this bin
-- runs. Default = number of distinct ETO valves in the bin.
-- Special cases verified 2026-06-06:
--   sat_3:1/sat_3:7   → 1 coil (sat_3:7 is the actual coil-driver; sat_3:1
--                                is electrically near-null)
--   sat_3:2/sat_4:12  → 2 coils (true dual)
--   sat_1:39+s2:16    → s1:39 is city flush (~0 coil contribution), s2:16
--                                is the 1 real zone coil
local TOPOLOGY_OVERRIDES = {
    ["satellite_3:1/satellite_3:7"]                       = 1,
    ["satellite_3:2/satellite_4:12"]                      = 2,
    ["satellite_1:39/satellite_2:16"]                     = 1,
    ["satellite_1:39/satellite_3:14"]                     = 1,
    ["satellite_1:39/satellite_4:6/satellite_4:8"]        = 1,  -- s4:6 active, s4:8 redundant
}

local function log(id, fmt, ...)
    io.write(string.format("kb2_within_run [%s]: " .. fmt .. "\n", id.namespace, ...))
    io.flush()
end

local function now_ms() return os.time() * 1000 end

local function push_notify(ps, id, body)
    local payload = cjson.encode({
        schema   = SCHEMA_NOTIFY,
        class    = id.class,
        instance = id.instance,
        body     = body,
    })
    local ok, err = pcall(function() ps:publish(DIGEST_TOPIC, payload) end)
    return ok, err
end

local function bin_valves_from_io(io_setup)
    local out = {}
    for _, g in ipairs(io_setup or {}) do
        local sat = g.remote or "?"
        for _, b in ipairs(g.bits or {}) do
            out[#out+1] = sat .. ":" .. tostring(b)
        end
    end
    table.sort(out)
    return out
end

local function is_eto_bin(valves)
    for _, v in ipairs(valves) do
        local sat, pin = v:match("(satellite_%d+):(%d+)")
        pin = tonumber(pin)
        if ETO_PINS[sat] and ETO_PINS[sat][pin] then return true end
    end
    return false
end

local function n_zone_coils_for_bin(bin_key, valves)
    local override = TOPOLOGY_OVERRIDES[bin_key]
    if override then return override end
    -- Default: count distinct valves but subtract 1 if sat_1:39 (city) present
    local n = 0
    for _, v in ipairs(valves) do
        if v ~= "satellite_1:39" then n = n + 1 end
    end
    return math.max(1, n)
end

-- Fetch full TIME_HISTORY record for a bin (handles both key orderings).
local function fetch_th(opts, bin_key)
    local TH_DB  = 4
    local TH_KEY = "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT][IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL][PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]"
    local py = string.format([[
import redis, msgpack, json, sys
r = redis.Redis(db=%d)
KEY = %q
WANT = sorted(%q.split("/"))
v = r.hget(KEY, %q)
if v is None:
    for field in r.hkeys(KEY):
        f = field.decode() if isinstance(field, bytes) else field
        if sorted(f.split("/")) == WANT:
            v = r.hget(KEY, field); break
if v is None:
    sys.stdout.write(json.dumps({"_error": "bin not found"})); sys.exit(0)
runs = msgpack.unpackb(v, raw=False)
if not runs:
    sys.stdout.write(json.dumps({"_error": "empty runs"})); sys.exit(0)
rec = runs[-1]
out = {
    "I_data":   (rec.get("IRRIGATION_CURRENT") or {}).get("data") or [],
    "I_mean":   (rec.get("IRRIGATION_CURRENT") or {}).get("mean"),
    "I_sd":     (rec.get("IRRIGATION_CURRENT") or {}).get("sd"),
    "n_runs":   len(runs),
}
sys.stdout.write(json.dumps(out, default=str))
]], TH_DB, TH_KEY, bin_key, bin_key)
    local tmp = os.tmpname()
    local f = io.open(tmp, "w"); if not f then return nil end
    f:write(py); f:close()
    local cmd = string.format(
        "ssh -o ConnectTimeout=%d -o BatchMode=yes %s 'python3 -' < %s 2>/dev/null",
        opts.timeout_s or 8, opts.ssh_host or "pi@irrigation", tmp)
    local pipe = io.popen(cmd, "r")
    if not pipe then os.remove(tmp); return nil end
    local raw = pipe:read("*a") or ""
    pipe:close(); os.remove(tmp)
    if raw == "" then return nil end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or decoded._error then return nil end
    return decoded
end

M.one_shot.KB2_WR_TICK = function(handle, _node)
    local bb       = handle.blackboard
    local id, ps   = bb._identity, bb._pubsub
    local cs       = bb._class_spec
    local cfg      = (cs and cs.kb2_within_run) or {}
    local poll_s   = cfg.poll_s or DEFAULT_POLL_S
    local ssh_host = cfg.ssh_host or "pi@irrigation"
    local db_path  = cfg.db_path     or "/var/fleet/kb2_wr/kb2_wr.db"
    local kb2_path = cfg.kb2_db_path or "/var/fleet/kb2/kb2.db"

    if not bb._kb2_wr then
        bb._kb2_wr = {
            db = nil, initialized = false, last_stream_id = nil,
            kb2_R = nil, kb2_R_master = 40.0, kb2_offset = nil,
        }
    end
    local st = bb._kb2_wr

    if not st.db then
        local db, err = KB2_WR.open_db(db_path)
        if not db then
            log(id, "open_db FAILED at %s: %s", db_path, tostring(err))
            app_heartbeat.stamp(handle, "kb2_within_run", "degraded",
                "open_db failed", poll_s)
            return
        end
        st.db = db
        KB_ALERTS.ensure_schema(db)   -- daily-digest alert record lives in kb2_wr.db
        log(id, "db ready at %s", db_path)
        -- Read all cold R values from KB2's baselines table (KB1 used to
        -- expose load_kb2_R but was simplified out of that role in the
        -- KB1 rewrite; KB2_WR now owns these reads directly).
        local cold_R, cold_err = KB2_WR.load_all_cold_R(kb2_path)
        st.cold_R = cold_R or {}
        local n_cold = 0
        for _ in pairs(st.cold_R) do n_cold = n_cold + 1 end
        local R_master = KB2_WR.load_master_R(kb2_path)
        st.kb2_R_master = R_master or 40.0
        st.kb2_offset = KB2_WR.load_kb2_offset(kb2_path)
        log(id, "loaded cold_R for %d valves (R_master=%.1f Ω, offset=%s)%s",
            n_cold, st.kb2_R_master,
            st.kb2_offset and string.format("%.4f A", st.kb2_offset) or "nil",
            cold_err and (" — " .. cold_err) or "")
    end
    local db = st.db

    -- Initialize cursor to current tip on first run
    if not st.initialized then
        local tip, _ = controller.past_actions_tip({
            ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8,
        })
        st.last_stream_id = tip
        st.initialized = true
        log(id, "past_actions cursor fast-forwarded to %s", tostring(tip))
    end

    local delta, _ = controller.past_actions_xrange(
        st.last_stream_id, 100,
        { ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8 })
    delta = delta or {}

    -- Lazy-derive calibration: only fetch popup if we're going to process at
    -- least one ETO STEP_COMPLETE this tick. Most ticks have no new events.
    local calibration = nil
    local function get_calibration()
        if calibration then return calibration end
        local popup_data = controller.popup_get({
            ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8,
        })
        -- KB2_WR has no live currents table for the legacy 2-null fallback;
        -- if popup lacks v_psu, derive_calibration falls back to a 2-null
        -- offset of 0, so we patch in the KB2-DB-cached offset here.
        calibration = KB2.derive_calibration(popup_data, {})
        if calibration.source == "legacy_2null" then
            calibration.offset = st.kb2_offset or 0
        end
        log(id, "calibration source=%s v_psu=%.3f offset=%.4f",
            calibration.source, calibration.v_psu,
            calibration.source == "controller"
                and (calibration.controller_offset or 0)
                or calibration.offset)
        return calibration
    end

    local processed = 0
    local flagged = 0
    for _, ent in ipairs(delta) do
        if ent.action == "IRRIGATION_STEP_COMPLETE" and type(ent.details) == "table" then
            local io_setup = ent.details.io_setup
            local valves = bin_valves_from_io(io_setup)
            local bin_key = table.concat(valves, "/")
            if is_eto_bin(valves) then
                -- Refresh offset (may have changed if KB2 ran a new cycle)
                local fresh_offset = KB2_WR.load_kb2_offset(kb2_path)
                if fresh_offset then st.kb2_offset = fresh_offset end

                local n_coils = n_zone_coils_for_bin(bin_key, valves)
                local cal = get_calibration()

                local th = fetch_th({
                    ssh_host = ssh_host, timeout_s = cfg.timeout_s or 8,
                }, bin_key)
                if th and th.I_data and #th.I_data > 0 then
                    local R_series = KB2_WR.compute_R_per_minute_calibrated(
                        th.I_data, cal, st.kb2_R_master, n_coils)
                    local result = KB2_WR.analyze_run(R_series)

                    -- Thermal-lift analysis (Glenn 2026-06-09 PM). Uses
                    -- per-bin parallel-R baseline (all bin valves + master)
                    -- from KB2's cold R values, and subtracts the 2-null
                    -- offset from each minute's raw IRRIGATION_CURRENT.
                    local lift_results = nil
                    local R_baseline_par, baseline_err =
                        KB2_WR.compute_parallel_baseline(
                            st.cold_R, valves, st.kb2_R_master)
                    if R_baseline_par then
                        local null_offset_for_lift = (cal.source == "controller")
                                            and (cal.controller_offset or 0)
                                            or (st.kb2_offset or 0)
                        local lift_series = KB2_WR.compute_thermal_lift(
                            th.I_data, null_offset_for_lift, R_baseline_par)
                        if lift_series then
                            lift_results = KB2_WR.analyze_thermal_lift(lift_series, 5, 15)
                            log(id, "thermal: bin=%s R_base=%.2f Ω lift_win=%s lift_end=%s lift_max=%s",
                                bin_key, R_baseline_par,
                                lift_results.lift_window and string.format("%+.2f Ω", lift_results.lift_window) or "nil",
                                lift_results.lift_end    and string.format("%+.2f Ω", lift_results.lift_end)    or "nil",
                                lift_results.lift_max    and string.format("%+.2f Ω", lift_results.lift_max)    or "nil")

                            -- Early-failure alert: solenoid running hot (sun /
                            -- self-heating on long runs). Sustained lift vs cold
                            -- baseline → Discord. Note long runs (worst case).
                            local tl_cls, _tl_sev, _tl_pct, tl_note =
                                KB2_WR.classify_thermal_lift(lift_results, R_baseline_par)
                            if tl_cls then
                                flagged = flagged + 1
                                local rt = tonumber(ent.details.run_time) or 0
                                -- Two-tier notify: record for the 18:00 digest, no per-run Discord.
                                KB_ALERTS.record(db, {
                                    ts_ms = now_ms(), source = "kb2_wr",
                                    kind = "thermal", severity = "warn", target = bin_key,
                                    summary = string.format("%s step=%s run=%s min%s — %s",
                                        tl_cls, tostring(ent.details.step),
                                        tostring(ent.details.run_time),
                                        rt >= 30 and " (long run)" or "", tl_note) })
                                log(id, "alert[thermal/warn] %s: %s", bin_key, tl_note)
                            end
                        end
                    elseif baseline_err then
                        log(id, "thermal: bin=%s baseline skipped — %s", bin_key, baseline_err)
                    end

                    local ins_ok, ins_err = KB2_WR.insert_run(db, {
                        ts_ms       = now_ms(),
                        sid         = ent.stream_id,
                        bin         = bin_key,
                        step        = ent.details.step,
                        schedule    = ent.details.schedule_name,
                        run_time_m  = ent.details.run_time,
                        n_samples   = result.n,
                        null_offset = (cal.source == "controller")
                                        and (cal.controller_offset or 0)
                                        or st.kb2_offset,
                        R_master    = st.kb2_R_master,
                        R_baseline_par = R_baseline_par,
                        lift_window = lift_results and lift_results.lift_window,
                        lift_end    = lift_results and lift_results.lift_end,
                        lift_max    = lift_results and lift_results.lift_max,
                        R_start     = result.R_start,
                        R_end       = result.R_end,
                        end_delta   = result.end_delta,
                        R_med       = result.R_med,
                        R_mad       = result.R_mad,
                        slope_ohm_pm    = result.slope_ohm_per_min,
                        intercept_ohm   = result.intercept,
                        max_step_ohm    = result.max_step_ohm,
                        max_step_minute = result.max_step_minute,
                        peak_1_5_r      = result.peak_1_5_r,
                        peak_1_5_dev    = result.peak_1_5_dev,
                        cls         = result.cls,
                        severity    = result.severity,
                        note        = result.note,
                    })
                    if not ins_ok then
                        log(id, "INSERT FAILED bin=%s: %s — within-run row NOT stored",
                            bin_key, tostring(ins_err))
                    end
                    processed = processed + 1
                    log(id, "ETO %s: n=%d R_med=%.1f R_start=%.1f R_end=%.1f slope=%+.3f cls=%s",
                        bin_key, result.n,
                        result.R_med or 0,
                        result.R_start or 0,
                        result.R_end or 0,
                        result.slope_ohm_per_min or 0,
                        result.cls)
                    -- Cross-correlate with KB2 baseline R (per-cycle valve_test value).
                    -- For single-zone bins (most ETO bins), the implied within-run
                    -- coil R can be compared to KB2's latest baseline_R for that
                    -- valve. Log the comparison; future logic can elevate to Discord
                    -- when both sources flag the same valve same direction.
                    if #valves == 1 then
                        local zone_valve = valves[1]
                        local kb2_R = st.kb2_R and st.kb2_R[zone_valve]
                        if kb2_R and result.R_med then
                            local delta_kb2 = result.R_med - kb2_R
                            if math.abs(delta_kb2) > 3 then
                                log(id, "CROSS-CORR %s: within-run R_med=%.1f vs KB2 baseline %.1f Δ=%+.1f Ω%s",
                                    zone_valve, result.R_med, kb2_R, delta_kb2,
                                    math.abs(delta_kb2) > 5 and " [notable]" or "")
                            end
                        end
                    end
                    -- Persistence gate: R_STEP_DURING_RUN is noisy (V/(I-offset)
                    -- is unstable at these currents → a single jittery sample
                    -- trips a >5 Ω step; fired on 16/20 bins 2026-06-16). Require
                    -- the SAME bin to step on two consecutive runs before it
                    -- reaches the digest. R_HEATING/other alerts are unaffected.
                    local step_gated = false
                    if result.cls == "R_STEP_DURING_RUN" then
                        local prev_cls = KB2_WR.prev_run_cls(db, bin_key, ent.stream_id)
                        if prev_cls ~= "R_STEP_DURING_RUN" then
                            step_gated = true
                            log(id, "suppress R_STEP %s: single-run (prior=%s — needs 2 consecutive)",
                                bin_key, tostring(prev_cls))
                        end
                    end
                    if (result.severity == "alert" or result.cls == "R_HEATING_DURING_RUN")
                       and not step_gated then
                        flagged = flagged + 1
                        -- Two-tier notify: record for the 18:00 digest, no per-run Discord.
                        KB_ALERTS.record(db, {
                            ts_ms = now_ms(), source = "kb2_wr",
                            kind = "heating", severity = result.severity or "warn",
                            target = bin_key,
                            summary = string.format("%s step=%s — %s (R_start=%.1f R_end=%.1f slope=%+.3f Ω/min)",
                                result.cls, tostring(ent.details.step), result.note or "",
                                result.R_start or 0, result.R_end or 0,
                                result.slope_ohm_per_min or 0) })
                        log(id, "alert[heating/%s] %s: %s", result.severity or "warn", bin_key, result.cls)
                    end
                else
                    log(id, "no TH for %s — skipping", bin_key)
                end
            end
        end
        if ent.stream_id then st.last_stream_id = ent.stream_id end
    end

    app_heartbeat.stamp(handle, "kb2_within_run", "ok",
        string.format("tick: processed=%d flagged=%d cursor=%s",
            processed, flagged, tostring(st.last_stream_id)),
        poll_s)
end

M.registry = { main = M.main, one_shot = M.one_shot, boolean = M.boolean }
return M
