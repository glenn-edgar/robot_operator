-- lib/synoptic_eto.lua — multi-station Synoptic/MesoWest ETo agent.
--
-- Ported from ~/irrigation_eto/luajit/eto_agent.lua (handoff 2026-05-31).
-- Pulls one station's wide UTC window, parses the CSV, normalizes it onto a
-- regular grid at the native interval, fills gaps by linear interpolation,
-- and integrates ETo by running the CIMIS-Penman calc PER BIN (10-min for
-- SE224, hourly for SRUC1) weighted by real elapsed time. DST-safe (23/25h
-- local days).
--
-- Public API
--   M.stations                                — registry, add a row = add a station
--   M.daily_eto(stid, date, opts)             — {eto, status, coverage, ...} or nil,err
--   M.fetch_csv(stid_or_st, date, opts)       — raw CSV (uses cache_dir if set)
--   M.parse_csv(csv)                          — sorted obs records
--   M.normalize(obs, date, interval)          — grid of filled bins + info
--   M.integrate_eto(bins, alt_ft)             — ETo inches (sum of per-bin Penman)
--   M.wind_summary(obs, date)                 — speed-weighted vector wind
--
-- Token resolution order (first non-empty wins):
--   opts.token  ->  M.config.token  ->  $SYNOPTIC_TOKEN env var
--
-- cache_dir behavior
--   If opts.cache_dir (or M.config.cache_dir) is set, fetch_csv first tries to
--   read "<dir>/<STID>_<date>.csv". On a hit the API is NOT called. On a miss
--   the API is called and the response is written to that path. This is the
--   once-per-day belt-and-suspenders: a same-day restart short-circuits to
--   cached data. Disk write errors are logged to stderr but don't fail the fetch.
--
-- Errors never raise: functions return (nil, errstring).

local M = {}

----------------------------------------------------------------------------
-- Shared request config + per-station registry.
----------------------------------------------------------------------------
M.config = {
    url       = "https://api.synopticdata.com/v2/stations/timeseries",
    token     = nil,           -- prefer env SYNOPTIC_TOKEN; opts.token overrides
    vars      = "air_temp,relative_humidity,wind_speed,solar_radiation",
    curl      = "curl",
    timeout   = 30,
    cache_dir = nil,           -- per-call opts.cache_dir overrides
}

M.stations = {
    SE224 = { stid = "SE224", alt_ft = 1370, lat = 33.584,  interval = 600,
              name = "SCE Murrieta Hogbacks (10-min)" },
    SRUC1 = { stid = "SRUC1", alt_ft = 1987, lat = 33.5181, interval = 3600,
              name = "Santa Rosa Plateau (RAWS)" },
}

----------------------------------------------------------------------------
-- Generic helpers
----------------------------------------------------------------------------
local floor = math.floor

local function split(s, sep)
    local out, i = {}, 1
    while true do
        local j = string.find(s, sep, i, true)
        if not j then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, j - 1); i = j + 1
    end
    return out
end

local function lines(blob)
    blob = blob:gsub("\r\n", "\n")
    return blob:gmatch("([^\n]*)\n?")
end

-- Days since 1970-01-01 for a proleptic-Gregorian Y/M/D (timezone independent).
local function ymd_to_days(y, m, d)
    local a  = floor((14 - m) / 12)
    local yy = y + 4800 - a
    local mm = m + 12 * a - 3
    local jdn = d + floor((153 * mm + 2) / 5) + 365 * yy + floor(yy / 4)
              - floor(yy / 100) + floor(yy / 400) - 32045
    return jdn - 2440588                              -- JDN(1970-01-01)=2440588
end

local function ts_parse(s)
    local Y, Mo, D, h, mi, sec, sgn, oh, om =
        s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)([%+%-])(%d%d)(%d%d)")
    if not Y then return nil end
    Y,Mo,D,h,mi,sec,oh,om = tonumber(Y),tonumber(Mo),tonumber(D),
                            tonumber(h),tonumber(mi),tonumber(sec),tonumber(oh),tonumber(om)
    local off = (oh * 3600 + om * 60) * (sgn == "-" and -1 or 1)
    local local_secs = ymd_to_days(Y, Mo, D) * 86400 + h * 3600 + mi * 60 + sec
    return local_secs - off, off, string.format("%04d-%02d-%02d", Y, Mo, D)
end

local function yesterday()
    return os.date("%Y-%m-%d", os.time() - 24 * 3600)
end

local function resolve(station)
    if type(station) == "table" then return station end
    return M.stations[station]
end

local function resolve_token(opts)
    return (opts and opts.token) or M.config.token or os.getenv("SYNOPTIC_TOKEN")
end

local function resolve_cache_dir(opts)
    return (opts and opts.cache_dir) or M.config.cache_dir
end

----------------------------------------------------------------------------
-- Cache I/O. Plain CSV files on disk, keyed by "<STID>_<date>.csv".
----------------------------------------------------------------------------
local function cache_path(dir, stid, date)
    if dir:sub(-1) == "/" then return dir .. stid .. "_" .. date .. ".csv" end
    return dir .. "/" .. stid .. "_" .. date .. ".csv"
end

local function read_cache(dir, stid, date)
    if not dir then return nil end
    local fh = io.open(cache_path(dir, stid, date), "r")
    if not fh then return nil end
    local body = fh:read("*a"); fh:close()
    if not body or #body == 0 then return nil end
    return body
end

local function write_cache(dir, stid, date, body)
    if not dir then return end
    local fh, oerr = io.open(cache_path(dir, stid, date), "w")
    if not fh then
        -- Most likely cause: dir doesn't exist yet (first run, fresh
        -- container). Try once to mkdir -p and reopen. If it still fails,
        -- log + skip the cache write — the live API path already succeeded.
        os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
        fh, oerr = io.open(cache_path(dir, stid, date), "w")
    end
    if not fh then
        io.stderr:write(string.format(
            "synoptic_eto: WARN cache write open %s: %s\n",
            cache_path(dir, stid, date), tostring(oerr)))
        return
    end
    local ok, werr = fh:write(body); fh:close()
    if not ok then
        io.stderr:write(string.format(
            "synoptic_eto: WARN cache write %s: %s\n",
            cache_path(dir, stid, date), tostring(werr)))
    end
end

----------------------------------------------------------------------------
-- Fetch a wide UTC window (day-1 .. day+2) so the full LOCAL day is covered
-- regardless of UTC offset; we filter to the local date later. Honors cache_dir.
----------------------------------------------------------------------------
function M.fetch_csv(station, date, opts)
    opts = opts or {}
    local st = resolve(station)
    if not st then return nil, "unknown station: " .. tostring(station) end
    date = date or yesterday()
    local y, mo, d = date:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return nil, "bad date (want YYYY-MM-DD): " .. tostring(date) end

    local dir = resolve_cache_dir(opts)
    if dir then
        local cached = read_cache(dir, st.stid, date)
        if cached then return cached, nil, true end       -- 3rd return = "from_cache"
    end

    local token = resolve_token(opts)
    if not token or token == "" then
        return nil, "no Synoptic token (set SYNOPTIC_TOKEN env or opts.token)"
    end

    -- local midnight (as if UTC) +/- a day, formatted UTC for the API
    local mid = ymd_to_days(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    local start_s = os.date("!%Y%m%d%H%M", mid - 24 * 3600)
    local end_s   = os.date("!%Y%m%d%H%M", mid + 48 * 3600)

    local url = string.format(
        "%s?stid=%s&token=%s&start=%s&end=%s&vars=%s&obtimezone=local&units=metric&output=csv",
        opts.url or M.config.url, st.stid, token,
        start_s, end_s, opts.vars or M.config.vars)
    local cmd = string.format('%s -s -m %d "%s"',
        opts.curl or M.config.curl, opts.timeout or M.config.timeout, url)

    local pipe = io.popen(cmd, "r")
    if not pipe then return nil, "could not run curl" end
    local body = pipe:read("*a"); pipe:close()
    if not body or #body == 0 then return nil, "empty response (network/timeout)" end
    if body:sub(1, 1) == "{" then
        local msg = body:match('"RESPONSE_MESSAGE"%s*:%s*"([^"]*)"')
                  or body:match('"message"%s*:%s*"([^"]*)"') or body
        return nil, "API error: " .. msg
    end

    if dir then write_cache(dir, st.stid, date, body) end
    return body, nil, false
end

----------------------------------------------------------------------------
-- Parse CSV -> array of obs {epoch, off, date, TC, HUM, wind, solar}, time-sorted.
-- Columns matched by header NAME, not position.
----------------------------------------------------------------------------
function M.parse_csv(csv)
    local idx, recs = nil, {}
    for line in lines(csv) do
        if line == "" or line:sub(1, 1) == "#" then
            -- skip
        elseif not idx then
            if line:find("Date_Time", 1, true) then
                idx = {}
                local cols = split(line, ",")
                for i = 1, #cols do idx[cols[i]] = i end
            end
        elseif line:match("^%s*,") or line:find("Celsius", 1, true) then
            -- units row
        else
            local f = split(line, ",")
            local epoch, off, dstr = ts_parse(f[idx["Date_Time"]] or "")
            local tc    = tonumber(f[idx["air_temp_set_1"]])
            local hum   = tonumber(f[idx["relative_humidity_set_1"]])
            local wind  = tonumber(f[idx["wind_speed_set_1"]])
            local solar = tonumber(f[idx["solar_radiation_set_1"]])
            local wdcol = idx["wind_direction_set_1"]
            local wdir  = wdcol and tonumber(f[wdcol]) or nil
            if epoch and tc and hum and wind and solar then
                recs[#recs + 1] = { epoch = epoch, off = off, date = dstr,
                                    TC = tc, HUM = hum, wind = wind, solar = solar,
                                    wdir = wdir }
            end
        end
    end
    table.sort(recs, function(a, b) return a.epoch < b.epoch end)
    return recs
end

local STD = { 300, 600, 900, 1800, 3600 }
local function snap_interval(sec)
    local best, bd = 3600, math.huge
    for _, v in ipairs(STD) do
        local diff = math.abs(v - sec)
        if diff < bd then best, bd = v, diff end
    end
    return best
end

----------------------------------------------------------------------------
-- NORMALIZE: build a regular grid over the LOCAL day and interpolate each
-- variable onto it. Returns bins + diagnostics.
----------------------------------------------------------------------------
function M.normalize(obs, date, interval)
    local day = {}
    for i = 1, #obs do if obs[i].date == date then day[#day + 1] = obs[i] end end
    if #day < 2 then
        return nil, "insufficient data for " .. tostring(date) .. " (" .. #day .. " obs)"
    end

    if not interval then
        local diffs = {}
        for i = 2, #day do diffs[#diffs + 1] = day[i].epoch - day[i - 1].epoch end
        table.sort(diffs)
        interval = snap_interval(diffs[floor(#diffs / 2) + 1] or 3600)
    end

    -- DST-correct day boundaries using offset at start vs end of day
    local y, mo, d = date:match("(%d+)-(%d+)-(%d+)")
    local base = ymd_to_days(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    local day_start = base - day[1].off
    local day_end   = (base + 86400) - day[#day].off
    local span = day_end - day_start
    local n = floor(span / interval + 0.5)
    if n < 1 then return nil, "degenerate day span" end

    local max_gap = 0
    for i = 2, #day do
        local g = day[i].epoch - day[i - 1].epoch
        if g > max_gap then max_gap = g end
    end

    local j = 1
    local function interp(t)
        while j < #day and day[j + 1].epoch <= t do j = j + 1 end
        local a = day[j]
        local b = day[math.min(j + 1, #day)]
        if t <= a.epoch or a.epoch == b.epoch then
            return a.TC, a.HUM, a.wind, a.solar, 0
        elseif t >= b.epoch then
            return b.TC, b.HUM, b.wind, b.solar, 0
        end
        local w = (t - a.epoch) / (b.epoch - a.epoch)
        return a.TC  + w * (b.TC  - a.TC),
               a.HUM + w * (b.HUM - a.HUM),
               a.wind+ w * (b.wind- a.wind),
               a.solar+w * (b.solar-a.solar), (b.epoch - a.epoch)
    end

    local bins, gap_bins = {}, 0
    local delta = interval / 86400
    for k = 1, n do
        local t = day_start + (k - 0.5) * interval
        local tc, hum, wd, sr, spacing = interp(t)
        if spacing > interval * 1.5 then gap_bins = gap_bins + 1 end
        bins[k] = { TC = tc, HUM = hum, wind = wd, solar = sr, delta = delta }
    end

    return bins, {
        interval = interval, n_bins = n, n_obs = #day,
        day_hours = span / 3600,
        coverage = #day / n,
        gap_bins = gap_bins,
        max_gap_min = max_gap / 60,
    }
end

----------------------------------------------------------------------------
-- Wind-direction summary (vector-resultant, speed-weighted).
----------------------------------------------------------------------------
local COMPASS = { "N","NNE","NE","ENE","E","ESE","SE","SSE",
                  "S","SSW","SW","WSW","W","WNW","NW","NNW" }
local function to_compass(deg) return COMPASS[(floor((deg % 360) / 22.5 + 0.5)) % 16 + 1] end

local function resultant(set)
    if #set == 0 then return nil end
    local rad = math.pi / 180
    local u, v, scal = 0, 0, 0
    for i = 1, #set do
        local s, d = set[i].wind, set[i].wdir
        u = u + s * math.sin(d * rad)
        v = v + s * math.cos(d * rad)
        scal = scal + s
    end
    local ang = (math.atan2(u, v) / rad) % 360
    return { deg = ang, compass = to_compass(ang), mean_spd = scal / #set,
             constancy = (scal > 0) and (math.sqrt(u*u + v*v) / scal) or 0, n = #set }
end

function M.wind_summary(obs, date)
    local all, day, night = {}, {}, {}
    for i = 1, #obs do
        local o = obs[i]
        if o.date == date and o.wdir then
            all[#all + 1] = o
            local h = floor(((o.epoch + o.off) % 86400) / 3600)
            if h >= 12 and h <= 17 then day[#day + 1] = o
            elseif h >= 22 or h <= 6 then night[#night + 1] = o end
        end
    end
    if #all == 0 then return nil end
    return { all = resultant(all), afternoon = resultant(day), night = resultant(night) }
end

----------------------------------------------------------------------------
-- ETo physics (CIMIS-Penman, albedo 0.18). Sums per-bin contributions.
-- Per-bin Penman is the point: SE224 has 144 bins/day @ 10-min cadence; the
-- calc runs at each, weighted by b.delta (interval/86400). Returns inches.
----------------------------------------------------------------------------
function M.integrate_eto(bins, alt_ft)
    local exp = math.exp
    local alt = (alt_ft or 0) * 0.3048
    local P = 101.3 - 0.0115 * alt + 5.44e-7 * alt * alt
    local ETod = 0.0
    for i = 1, #bins do
        local b  = bins[i]
        local U2 = b.wind
        local tc = b.TC
        local tk = tc + 273.3
        local es = 0.6108 * exp(17.27 * tc / tk)
        local ea = es * b.HUM / 100.0
        local VPD = es - ea
        local DEL = (4099 * es) / ((tc + 237.3) * (tc + 237.3))
        local G   = 0.000646 * P * (1 + 0.000949 * tc)
        local W   = DEL / (DEL + G)
        local SR  = b.solar
        local FU2 = (SR > 10) and (0.03 + 0.0576 * U2) or (0.125 + 0.0439 * U2)
        SR = 0.82 * SR
        local NR = SR / (694.5 * (1 - 0.000946 * tc))
        local RL = (-5.67e-8 * (273 ^ 4) + 5.67e-8 * (tk ^ 4)) / (694.5 * (1 - 0.000946 * tc))
        local ETH = (NR * W + (1 - W) * VPD * FU2 - W * RL) * 24
        ETod = ETod + ETH * b.delta
    end
    return ETod / 25.4
end

----------------------------------------------------------------------------
-- MAIN: daily_eto(stid, date, opts) -> result, nil | nil, errstring
----------------------------------------------------------------------------
function M.daily_eto(station, date, opts)
    opts = opts or {}
    local st = resolve(station)
    if not st then return nil, "unknown station: " .. tostring(station) end
    date = date or yesterday()

    local csv, err, from_cache = M.fetch_csv(st, date, opts)
    if not csv then return nil, err end
    local obs = M.parse_csv(csv)
    local bins, info = M.normalize(obs, date, opts.interval or st.interval)
    if not bins then return nil, info end

    local eto = M.integrate_eto(bins, opts.alt_ft or st.alt_ft)

    local status = "OK"
    if info.coverage < 0.5 then status = "SPARSE"
    elseif info.coverage < 0.85 then status = "PARTIAL" end

    return {
        eto = eto, date = date, station = st.stid, name = st.name,
        alt_ft = st.alt_ft, lat = st.lat,
        interval = info.interval, n_obs = info.n_obs, n_bins = info.n_bins,
        coverage = info.coverage, gap_bins = info.gap_bins,
        max_gap_min = info.max_gap_min, day_hours = info.day_hours,
        status = status, from_cache = from_cache or false,
    }
end

----------------------------------------------------------------------------
-- CLI: luajit synoptic_eto.lua <STID> [YYYY-MM-DD]
-- (handy for bench testing; the chain layer calls daily_eto directly)
----------------------------------------------------------------------------
if arg and (arg[0] or ""):match("([^/]+)%.lua$") == "synoptic_eto" then
    local station = arg[1] or "SE224"
    local res, e = M.daily_eto(station, arg[2])
    if not res then io.stderr:write("ERROR: " .. tostring(e) .. "\n"); os.exit(1) end
    print(string.format(
        "%-6s %-35s %s  ETo=%.3f in  | %d obs/%d bins @ %ds (cov %.0f%%, gap %.0fmin, %.1fh) [%s]%s",
        res.station, res.name, res.date, res.eto, res.n_obs, res.n_bins,
        res.interval, res.coverage * 100, res.max_gap_min, res.day_hours,
        res.status, res.from_cache and "  (cached)" or ""))
end

return M
