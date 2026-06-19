-- thresholds.lua — locked KB1 thresholds (see memory kb1_design_locked_2026-05-29.md).
--
-- All Amps unless noted. Pure data + lookup helpers — no I/O, no side effects.
--
-- Mode 1 (low) and Mode 3 (high warn) require per-bin calibration. For
-- uncalibrated bins, only Mode 4 + EQ are armed.

local M = {}

-- Physics anchors
M.V_SUPPLY     = 15.7    -- V
M.R_MASTER     = 33      -- Ω → I_master = 0.476 A
M.R_PER_VALVE  = 43      -- Ω → I_per_valve = 0.365 A
M.I_MASTER     = M.V_SUPPLY / M.R_MASTER
M.I_PER_VALVE  = M.V_SUPPLY / M.R_PER_VALVE

-- Universal trip / warn ceilings on the two current channels
M.IRR_TRIP_A   = 1.75    -- Mode 4 per-valve hard trip (wire damage at 2.0 A)
M.EQ_WARN_A    = 1.25    -- Equipment Current — warn tier
M.EQ_TRIP_A    = 1.75    -- Equipment Current — trip tier

-- MASTER_IDLE_CHECK thresholds (master alone, no irrigation step)
M.MASTER_LOW_A      = 0.25   -- below → master coil open / wire broken
M.MASTER_HIGH_WARN  = 1.00   -- above → master coil aging short (warn)
-- Mode 4 1.75 A applies on top as universal trip.

-- Detection cadence
M.SUSTAINED_N  = 2       -- sustained N samples (≥) for warn-tier fires

-- Rolling-median gate for warn-tier (MODE_1_LOW / MODE_3_HIGH_WARN /
-- MASTER_IDLE_LOW / MASTER_IDLE_HIGH_WARN). The controller updates
-- PLC_IRRIGATION_CURRENT once per minute (quantized to ~6 mA steps),
-- which means per-poll threshold checks oscillate noisily across the
-- line and generate 100s of duplicate Discord pushes per run. Warn-tier
-- rules instead compare the median over the last MEDIAN_WINDOW_N
-- accepted samples against threshold; nothing fires until the window
-- is full. Hard trips (Mode 4 / EQ_TRIP / MASTER_HIGH_TRIP) stay
-- per-sample — wire damage can't wait 15 min.
M.MEDIAN_WINDOW_N        = 15
-- Only accept a new sample into the median window when the controller's
-- TIME_STAMP has advanced by at least this many seconds since the last
-- accepted sample. Acts as a dedup gate when the poller runs faster
-- than the controller's per-minute current update (poll cadence is 30s
-- but current refreshes every 60s).
M.SAMPLE_DEDUP_TS_GAP_S  = 50

function M.push_window(window, value, max_n)
    window[#window + 1] = value
    while #window > max_n do
        table.remove(window, 1)
    end
end

function M.rolling_median(window)
    if not window or #window == 0 then return nil end
    local s = {}
    for i, v in ipairs(window) do s[i] = v end
    table.sort(s)
    local n = #s
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return 0.5 * (s[n / 2] + s[n / 2 + 1])
end

-- Warm-up window after arming. PLC_IRRIGATION_CURRENT lags the controller's
-- bookkeeping state (SCHEDULE_NAME, STEP, MASTER_VALVE) by ~120 s — it's a
-- buffered/averaged reading. So per-bin Mode 1 / Mode 3 and the
-- MASTER_LOW / MASTER_HIGH_WARN thresholds would false-fire reading a stale
-- baseline during that window. Gate them off for WARMUP_S after arming.
-- Mode 4 (universal 1.75 A wire-safety trip) and EQ-warn/EQ-trip stay
-- armed — wire damage can't wait 2 min.
M.WARMUP_S = 120

-- Per-bin curve table (KB2 publishes; here we use the explore-derived seed).
-- Schema per bin:  { mu = number, sd = number, i_low_open = number }
-- io_setup → bin_key canonical form: "satellite_X:Y" sorted by (sat#, bit#),
-- joined with "/".
function M.canonicalize_io_setup(io_setup)
    -- io_setup shape: { {remote="satellite_1", bits={39}}, ... }
    local pins = {}
    for _, group in ipairs(io_setup or {}) do
        local sat = tostring(group.remote or "?")
        for _, bit in ipairs(group.bits or {}) do
            pins[#pins+1] = string.format("%s:%d", sat, bit)
        end
    end
    table.sort(pins)   -- canonical ordering — sat_1:27 before sat_1:39 before sat_3:2
    return table.concat(pins, "/")
end

function M.count_valves(io_setup)
    local n = 0
    for _, group in ipairs(io_setup or {}) do
        n = n + #(group.bits or {})
    end
    return n
end

-- Canonicalize a compound bin_key by sorting its valve components.
-- Mirrors baselines.canonicalize_key; needed because explore-side
-- derive_kb1_thresholds.py keys bins in past_actions io_setup natural
-- order while runtime canonicalizes to sorted order. Without this,
-- sat_4:6/sat_4:8/sat_1:39 in the file misses lookup for the runtime's
-- sat_1:39/sat_4:6/sat_4:8 → silent BIN_UNCALIBRATED.
function M.canonicalize_key(bin_key)
    if not bin_key or type(bin_key) ~= "string" then return bin_key end
    if not bin_key:find("/", 1, true) then return bin_key end
    local parts = {}
    for p in bin_key:gmatch("[^/]+") do parts[#parts+1] = p end
    table.sort(parts)
    return table.concat(parts, "/")
end

-- Curve lookup. Returns the calibrated entry or nil (uncalibrated bin).
function M.lookup_curve(curves, bin_key)
    if not curves or not bin_key or bin_key == "" then return nil end
    local c = curves[bin_key]
    if c and c.mu and c.sd and c.i_low_open then
        return c
    end
    return nil
end

-- Compute the per-bin Mode 3 (high warn) trip from mu. No cap — rule scales
-- with bin's own mu. For high-N bins this lands above 1.75 trip, which is
-- intended (Mode 4 catches first for high-current bins).
function M.mode3_high_warn(mu)
    return 1.5 * mu
end

-- Per-bin Mode 3 RED (sustained-high → SKIP_STATION). Set at 2.0× the
-- bin's mu — substantially above the YELLOW warn at 1.5× so we only
-- escalate on serious deviation. Glenn 2026-06-01: shorted-solenoid
-- candidates should advance to next station, not just Discord-ping.
function M.mode3_high_red(mu)
    return 2.0 * mu
end

return M
