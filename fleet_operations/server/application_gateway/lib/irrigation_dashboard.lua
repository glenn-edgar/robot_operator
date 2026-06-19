-- irrigation_dashboard.lua — dashboard views for the irrigation_analytics
-- robot. Routes register under /irrigation/...
--
-- Read paths read SQLite files directly from /var/fleet/{kb1,kb2,kb2_wr,kb4}/.
-- All files are bind-mounted into the same container as this gateway, so no
-- network hop is needed.
--
-- Write paths (meter_readings, field_checks, clog_observations) accept POST
-- form bodies and store in the same files, with an audit row per write.
--
-- Server-side rendered HTML. Inline CSS in shared layout. No JS frameworks.
-- Auto-refresh via meta-refresh tag (30s NOW, 5min others).

local M = {}

-- =========================================================================
-- SQLite helpers
-- =========================================================================
local lsqlite3 = require("lsqlite3")
local pt_time  = require("pt_time")
local coil_solve = require("coil_solve")

local DB_PATHS = {
    kb1    = os.getenv("KB1_DB_PATH")    or "/var/fleet/kb1/kb1.db",
    kb2    = os.getenv("KB2_DB_PATH")    or "/var/fleet/kb2/kb2.db",
    kb2_wr = os.getenv("KB2_WR_DB_PATH") or "/var/fleet/kb2_wr/kb2_wr.db",
    kb4    = os.getenv("KB4_DB_PATH")    or "/var/fleet/kb4/kb4.db",
    notify = os.getenv("NOTIFY_DB_PATH") or "/var/fleet/notify/notifications.db",
}

local function open_ro(path)
    local db = lsqlite3.open(path, lsqlite3.OPEN_READONLY)
    return db
end

local function open_rw(path)
    return lsqlite3.open(path)
end

-- Run a SELECT, return list of row tables. pcall-guarded so a schema-drifted
-- query (a renamed column after a KB redesign) degrades to {} instead of
-- throwing and 500-ing the whole page.
local function query(db, sql)
    if not db then return {} end
    local out = {}
    local ok, err = pcall(function()
        for r in db:nrows(sql) do
            local copy = {}
            for k, v in pairs(r) do copy[k] = v end
            out[#out+1] = copy
        end
    end)
    if not ok then
        io.stderr:write("dashboard query failed: " .. tostring(err) .. "\n")
        return {}
    end
    return out
end

local function query_one(db, sql)
    local rows = query(db, sql)
    return rows[1]
end

local function exec(db, sql)
    if not db then return false, "no db" end
    local rc = db:exec(sql)
    return rc == lsqlite3.OK, db:errmsg()
end

-- =========================================================================
-- HTML helpers
-- =========================================================================

local function esc(s)
    if s == nil then return "" end
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
             :gsub('"', "&quot;"):gsub("'", "&#39;"))
end

local function fmt(template, t)
    return (template:gsub("{(%w+)}", function(k)
        local v = t[k]
        return v == nil and "" or tostring(v)
    end))
end

local function num(v, digits)
    if v == nil then return "—" end
    return string.format("%." .. (digits or 2) .. "f", v)
end

local function pdt_from_ms(ts_ms)
    if not ts_ms then return "—" end
    -- DST-aware Pacific (PST/PDT) via pt_time — replaces the old fixed -7h.
    return pt_time.format_ms(ts_ms, "!%Y-%m-%d %H:%M")
end

-- =========================================================================
-- Shared layout (head, header, nav, footer)
-- =========================================================================

local CSS = [[
:root {
    --bg:#1a1d22; --panel:#23272e; --text:#d6d6d6; --muted:#8a8a8a;
    --accent:#4fc3f7; --ok:#5cb85c; --warn:#f0ad4e; --bad:#d9534f;
    --border:#353a42; --hover:#2a2f37;
}
*{box-sizing:border-box;}
body{margin:0;background:var(--bg);color:var(--text);
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
    font-size:14px;}
header{background:var(--panel);padding:10px 20px;
    border-bottom:1px solid var(--border);display:flex;
    align-items:center;gap:14px;}
header h1{margin:0;font-size:16px;font-weight:600;}
header .status{margin-left:auto;color:var(--muted);font-size:12px;}
nav{background:#1f2228;padding:0 20px;display:flex;gap:0;
    border-bottom:1px solid var(--border);overflow-x:auto;}
nav a{color:var(--muted);padding:10px 18px;text-decoration:none;
    border-bottom:2px solid transparent;font-weight:500;white-space:nowrap;}
nav a:hover{color:var(--text);background:var(--hover);}
nav a.active{color:var(--accent);border-bottom-color:var(--accent);}
main{padding:16px 20px;max-width:1400px;}
.panel{background:var(--panel);border:1px solid var(--border);
    border-radius:4px;margin-bottom:14px;}
.panel-h{padding:8px 14px;border-bottom:1px solid var(--border);
    font-weight:600;font-size:13px;color:var(--muted);
    text-transform:uppercase;letter-spacing:0.05em;}
.panel-b{padding:14px;}
.grid{display:grid;gap:12px;}
.g2{grid-template-columns:1fr 1fr;}
.g3{grid-template-columns:1fr 1fr 1fr;}
.kv{display:flex;justify-content:space-between;padding:6px 0;
    border-bottom:1px dotted var(--border);}
.kv:last-child{border:0;}
.kv-k{color:var(--muted);}
.kv-v{font-family:"SF Mono",Menlo,Consolas,monospace;}
.tag{display:inline-block;padding:1px 8px;border-radius:3px;
    font-size:11px;font-weight:600;letter-spacing:0.03em;}
.t-ok{background:rgba(92,184,92,0.2);color:var(--ok);}
.t-warn{background:rgba(240,173,78,0.2);color:var(--warn);}
.t-bad{background:rgba(217,83,79,0.2);color:var(--bad);}
.t-info{background:rgba(79,195,247,0.2);color:var(--accent);}
.t-muted{background:rgba(138,138,138,0.2);color:var(--muted);}
table{width:100%;border-collapse:collapse;font-size:13px;}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--border);}
th{color:var(--muted);font-weight:600;font-size:11px;
    text-transform:uppercase;letter-spacing:0.04em;}
tr:hover td{background:var(--hover);}
.num{font-family:"SF Mono",Menlo,Consolas,monospace;text-align:right;}
.neg{color:var(--bad);}
.pos{color:var(--ok);}
.bar{display:inline-block;height:8px;border-radius:2px;
    background:linear-gradient(90deg,var(--accent),#2a7a9d);vertical-align:middle;}
form .row{display:flex;gap:14px;align-items:center;margin:8px 0;}
form label{min-width:140px;color:var(--muted);}
form input,form select,form textarea{
    background:#1a1d22;color:var(--text);border:1px solid var(--border);
    border-radius:3px;padding:5px 8px;font-family:inherit;font-size:13px;}
form input[type=number]{width:120px;}
form button{background:var(--accent);color:#000;border:0;padding:7px 16px;
    border-radius:3px;cursor:pointer;font-weight:600;}
form button.alt{background:var(--warn);}
form button:hover{filter:brightness(1.1);}
.valve-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(64px,1fr));
    gap:4px;}
.valve-cell{background:var(--panel);border:1px solid var(--border);
    padding:8px 4px;text-align:center;font-size:11px;border-radius:3px;
    text-decoration:none;color:var(--text);}
.valve-cell:hover{background:var(--hover);}
.valve-cell.ok{border-left:3px solid var(--ok);}
.valve-cell.warn{border-left:3px solid var(--warn);}
.valve-cell.bad{border-left:3px solid var(--bad);}
.valve-cell.muted{border-left:3px solid var(--muted);color:var(--muted);}
.valve-cell .r{font-family:"SF Mono",Menlo,Consolas,monospace;
    color:var(--muted);display:block;margin-top:2px;font-size:10px;}
.tiny{font-size:11px;color:var(--muted);}
.flash{padding:8px 14px;border-radius:3px;margin-bottom:14px;}
.flash.ok{background:rgba(92,184,92,0.15);border:1px solid var(--ok);}
.flash.err{background:rgba(217,83,79,0.15);border:1px solid var(--bad);}
]]

local NAV_ITEMS = {
    { path = "/irrigation",        label = "Now"    },
    { path = "/irrigation/today",  label = "Today"  },
    { path = "/irrigation/valves", label = "Valves" },
    { path = "/irrigation/cohort", label = "Cohort" },
    { path = "/irrigation/alerts", label = "Past Actions" },
    { path = "/irrigation/field",  label = "Field"  },
    { path = "/irrigation/meter",  label = "Meter R" },
    { path = "/irrigation/coil",   label = "Coil onset" },
    { path = "/irrigation/check",  label = "Sprinkler check" },
}

local function nav_html(active_path)
    local parts = {}
    for _, n in ipairs(NAV_ITEMS) do
        local cls = (n.path == active_path) and ' class="active"' or ""
        parts[#parts+1] = string.format('<a href="%s"%s>%s</a>', n.path, cls, n.label)
    end
    return '<nav>' .. table.concat(parts) .. '</nav>'
end

local function layout(title, active_path, body_html, opts)
    opts = opts or {}
    local refresh = opts.refresh_s and
        string.format('<meta http-equiv="refresh" content="%d">', opts.refresh_s) or ""
    local now_str = os.date("!%H:%M:%S") -- UTC; we'll show PT in header
    local pt_str = os.date("!%H:%M:%S", os.time() - 7*3600) .. " PT"
    return string.format([[
<!doctype html><html lang="en"><head>
<meta charset="utf-8">
<title>%s — irrigation</title>
%s
<style>%s</style>
</head><body>
<header>
  <h1>LaCima Irrigation</h1>
  <span class="tiny">lacima_wsl</span>
  <span class="status">%s</span>
</header>
%s
<main>%s</main>
</body></html>
]], esc(title), refresh, CSS, esc(pt_str), nav_html(active_path), body_html)
end

local function html_response(body)
    return 200, { "Content-Type: text/html; charset=utf-8" }, body
end

local function redirect(loc, flash_kind, flash_msg)
    local headers = { "Location: " .. loc }
    if flash_kind and flash_msg then
        -- Use a cookie-free flash: append query params
        local sep = loc:find("?", 1, true) and "&" or "?"
        loc = loc .. sep .. "flash=" .. flash_kind .. "&msg=" ..
            (flash_msg:gsub("[^%w]", function(c)
                return string.format("%%%02X", string.byte(c))
            end))
        headers = { "Location: " .. loc }
    end
    return 303, headers, ""
end

-- =========================================================================
-- Data helpers (read from SQLite files)
-- =========================================================================

local function load_kb2_baselines()
    local db = open_ro(DB_PATHS.kb2)
    if not db then return {} end
    local rows = query(db, [[
        SELECT valve, R_med, last_R, n_healthy, last_updated_ms
        FROM baselines_kb2 ORDER BY valve
    ]])
    db:close()
    local map = {}
    for _, r in ipairs(rows) do map[r.valve] = r end
    return rows, map
end

local function load_kb4_eto_baselines()
    local db = open_ro(DB_PATHS.kb4)
    if not db then return {} end
    local rows = query(db, [[
        SELECT bin, flow_5_15_med, gallons_5_15_med, n_healthy
        FROM baselines_eto ORDER BY bin
    ]])
    db:close()
    return rows
end

local function load_recent_eto(since_ms)
    local db = open_ro(DB_PATHS.kb4)
    if not db then return {} end
    local rows = query(db, string.format([[
        SELECT ts_ms, bin, schedule, run_time_m, flow_5_15, gallons_5_15,
               slope, intercept, wiggle_mad, curr_5_15, cls_gallons, cls_gpm,
               delta_gallons, delta_intercept
        FROM runs_eto WHERE ts_ms > %d ORDER BY ts_ms DESC LIMIT 60
    ]], since_ms))
    db:close()
    return rows
end

local function load_recent_non_eto(since_ms)
    local db = open_ro(DB_PATHS.kb4)
    if not db then return {} end
    local rows = query(db, string.format([[
        SELECT ts_ms, bin, schedule, run_time_m, flow_5_15, baseline_used,
               delta, cls
        FROM runs WHERE ts_ms > %d ORDER BY ts_ms DESC LIMIT 60
    ]], since_ms))
    db:close()
    return rows
end

local function load_recent_kb1_fires(since_ms)
    local db = open_ro(DB_PATHS.kb1)
    if not db then return {} end
    -- KB1 was redesigned 2026-06-09 to absolute overcurrent (irr_I/eq_I/excess);
    -- the old I_measured/I_expected/delta columns no longer exist.
    local rows = query(db, string.format([[
        SELECT ts_ms, bin, step, schedule, irr_I, eq_I, excess,
               cls, severity, note
        FROM runs_kb1 WHERE ts_ms > %d ORDER BY ts_ms DESC LIMIT 30
    ]], since_ms))
    db:close()
    return rows
end

local function load_recent_kb2_fires(since_ms)
    local db = open_ro(DB_PATHS.kb2)
    if not db then return {} end
    local rows = query(db, string.format([[
        SELECT ts_ms, cycle_id, valve, R_calc, baseline_used, delta_baseline,
               delta_step, cls, severity, note
        FROM runs_kb2 WHERE ts_ms > %d AND cls != 'OK'
        ORDER BY ts_ms DESC LIMIT 30
    ]], since_ms))
    db:close()
    return rows
end

local function load_recent_within(since_ms)
    local db = open_ro(DB_PATHS.kb2_wr)
    if not db then return {} end
    local rows = query(db, string.format([[
        SELECT ts_ms, bin, schedule, run_time_m, n_samples, R_start, R_end,
               end_delta, slope_ohm_pm, max_step_ohm, cls, severity, note
        FROM runs_kb2_within WHERE ts_ms > %d
        ORDER BY ts_ms DESC LIMIT 30
    ]], since_ms))
    db:close()
    return rows
end

-- =========================================================================
-- NOW view
-- =========================================================================

-- ETO pins (cached at module level — never change)
local ETO_PINS = {
    satellite_2 = { [13]=1, [14]=1, [15]=1, [16]=1 },
    satellite_3 = { [1]=1, [2]=1, [5]=1, [13]=1, [14]=1, [15]=1, [18]=1 },
    satellite_4 = { [1]=1, [3]=1, [4]=1, [6]=1, [7]=1, [9]=1,
                    [10]=1, [11]=1, [12]=1 },
}

local function is_eto_bin(bin_str)
    for s, p in bin_str:gmatch("(satellite_%d):(%d+)") do
        if ETO_PINS[s] and ETO_PINS[s][tonumber(p)] then return true end
    end
    return false
end

local function view_now(_req)
    local since_24h = (os.time() - 24*3600) * 1000
    local eto = load_recent_eto(since_24h)
    local kb1 = load_recent_kb1_fires(since_24h)
    local kb2 = load_recent_kb2_fires(since_24h)
    local within = load_recent_within(since_24h)
    local non_eto = load_recent_non_eto(since_24h)

    -- Tally
    local eto_warn = 0
    local eto_alert = 0
    for _, r in ipairs(eto) do
        if r.cls_gallons and r.cls_gallons:find("ALERT") then eto_alert = eto_alert + 1
        elseif r.cls_gallons and r.cls_gallons:find("WARN") then eto_warn = eto_warn + 1 end
        if r.cls_gpm and r.cls_gpm:find("ALERT") then eto_alert = eto_alert + 1
        elseif r.cls_gpm and r.cls_gpm:find("WARN") then eto_warn = eto_warn + 1 end
    end

    -- Last run
    local last = eto[1] or non_eto[1]
    local last_html
    if last then
        last_html = fmt([[
<div class="kv"><span class="kv-k">Bin</span><span class="kv-v">{bin}</span></div>
<div class="kv"><span class="kv-k">Time</span><span class="kv-v">{pdt}</span></div>
<div class="kv"><span class="kv-k">Schedule</span><span class="kv-v">{sched}</span></div>
<div class="kv"><span class="kv-k">Runtime</span><span class="kv-v">{rt} min</span></div>
<div class="kv"><span class="kv-k">5-15 GPM</span><span class="kv-v">{gpm}</span></div>
]], {
            bin = esc(last.bin),
            pdt = esc(pdt_from_ms(last.ts_ms)),
            sched = esc(last.schedule or "-"),
            rt = last.run_time_m or "—",
            gpm = num(last.flow_5_15, 2),
        })
    else
        last_html = '<p class="tiny">No runs in the last 24 hours yet.</p>'
    end

    -- Fire counts
    local total_fires = #kb1 + #kb2 + #within + eto_warn + eto_alert
    local fire_html = fmt([[
<div class="kv"><span class="kv-k">KB4 ETO WARN/ALERT</span><span class="kv-v">{eto}</span></div>
<div class="kv"><span class="kv-k">KB1 overcurrent</span><span class="kv-v">{kb1}</span></div>
<div class="kv"><span class="kv-k">KB2 cycle drift</span><span class="kv-v">{kb2}</span></div>
<div class="kv"><span class="kv-k">KB2 within-run</span><span class="kv-v">{wr}</span></div>
<div class="kv"><span class="kv-k">Total last 24h</span><span class="kv-v"><b>{total}</b></span></div>
]], {
        eto = eto_warn + eto_alert,
        kb1 = #kb1,
        kb2 = #kb2,
        wr = #within,
        total = total_fires,
    })

    local body = string.format([[
<div class="grid g2">
<div class="panel">
  <div class="panel-h">Last classified run</div>
  <div class="panel-b">%s</div>
</div>
<div class="panel">
  <div class="panel-h">Fires last 24h</div>
  <div class="panel-b">%s</div>
</div>
</div>

<div class="panel">
  <div class="panel-h">Detector status</div>
  <div class="panel-b">
    <div class="kv"><span class="kv-k">KB1 overcurrent (live)</span><span class="kv-v"><span class="tag t-ok">monitor-only</span></span></div>
    <div class="kv"><span class="kv-k">KB3-curve ETO leak (5-15 ceiling)</span><span class="kv-v"><span class="tag t-ok">armed</span></span></div>
    <div class="kv"><span class="kv-k">KB4 clog/leak (post-step)</span><span class="kv-v"><span class="tag t-ok">running</span></span></div>
    <div class="kv"><span class="kv-k">KB2 resistance (per cycle)</span><span class="kv-v"><span class="tag t-ok">running</span></span></div>
    <div class="kv"><span class="kv-k">KB2 within-run R(t)</span><span class="kv-v"><span class="tag t-ok">armed</span></span></div>
  </div>
</div>

<p class="tiny">Page auto-refreshes every 30 s.</p>
]], last_html, fire_html)

    return html_response(layout("Now", "/irrigation", body, { refresh_s = 30 }))
end

-- =========================================================================
-- TODAY view (stub — fills in next pass)
-- =========================================================================
local function view_today(_req)
    -- Yesterday 18:00 PT → today now
    local cut_pt = os.time() - 24*3600
    -- Roll back to 18:00 PT yesterday
    local now = os.date("*t", os.time() - 7*3600)
    -- Use 18:00 PT yesterday
    local yest = os.time({
        year = now.year, month = now.month, day = now.day - 1,
        hour = 18, min = 0, sec = 0,
    }) + 7*3600  -- shift PT back to UTC
    local since_ms = yest * 1000

    local eto = load_recent_eto(since_ms)
    local non_eto = load_recent_non_eto(since_ms)

    local function tag_for(cls)
        if not cls or cls == "OK" then return '<span class="tag t-ok">OK</span>' end
        if cls:find("ALERT") then return '<span class="tag t-bad">'..esc(cls)..'</span>' end
        if cls:find("WARN") then return '<span class="tag t-warn">'..esc(cls)..'</span>' end
        return '<span class="tag t-info">'..esc(cls)..'</span>'
    end

    local rows = {}
    for _, r in ipairs(eto) do
        rows[#rows+1] = string.format([[
<tr><td>%s</td><td>%s</td><td class="num">%s</td><td class="num">%s</td><td>%s</td><td>%s</td></tr>
]], esc(pdt_from_ms(r.ts_ms)), esc(r.bin),
   num(r.flow_5_15, 2), num(r.gallons_5_15, 0),
   tag_for(r.cls_gpm), tag_for(r.cls_gallons))
    end

    local table_html = #rows > 0 and string.format([[
<table><thead><tr><th>Time</th><th>Bin</th><th>5-15 GPM</th><th>Gallons</th>
<th>GPM cls</th><th>Gallons cls</th></tr></thead>
<tbody>%s</tbody></table>
]], table.concat(rows)) or '<p class="tiny">No ETO runs since 18:00 PT yesterday.</p>'

    local body = string.format([[
<div class="panel">
<div class="panel-h">ETO runs since 18:00 PT yesterday (%d total)</div>
<div class="panel-b">%s</div>
</div>
<p class="tiny">Page refreshes every 5 min.</p>
]], #eto, table_html)

    return html_response(layout("Today", "/irrigation/today", body, { refresh_s = 300 }))
end

-- =========================================================================
-- VALVES view — 43-valve grid with health coloring + per-valve drill-down
-- =========================================================================

local function cls_for_valve(b)
    -- Health color based on rolling-median freshness + last sample direction
    if not b or not b.R_med or b.n_healthy == 0 then return "muted" end
    if not b.last_R then return "ok" end
    local d = math.abs((b.last_R or 0) - b.R_med)
    if d > 8 then return "bad" end
    if d > 4 then return "warn" end
    return "ok"
end

local function valve_to_sat_pin(v)
    local s, p = v:match("(satellite_%d):(%d+)")
    return s, tonumber(p)
end

local function view_valves(_req)
    local _, baselines = load_kb2_baselines()
    -- Group valves by satellite
    local satellites = { satellite_1 = {}, satellite_2 = {},
                         satellite_3 = {}, satellite_4 = {} }
    for valve, b in pairs(baselines) do
        local s, p = valve_to_sat_pin(valve)
        if s and p then
            satellites[s] = satellites[s] or {}
            table.insert(satellites[s], { pin = p, baseline = b })
        end
    end

    local sections = {}
    for _, sat in ipairs({ "satellite_1", "satellite_2", "satellite_3", "satellite_4" }) do
        local valves = satellites[sat]
        if valves and #valves > 0 then
            table.sort(valves, function(a, b) return a.pin < b.pin end)
            local cells = {}
            for _, v in ipairs(valves) do
                local b = v.baseline
                local cls = cls_for_valve(b)
                local valve_id = sat .. ":" .. v.pin
                local r_med_str = b and b.R_med and string.format("%.1f", b.R_med) or "—"
                cells[#cells+1] = string.format(
                    '<a class="valve-cell %s" href="/irrigation/valves/%s">'..
                    '<b>%d</b><span class="r">%s Ω</span></a>',
                    cls, valve_id, v.pin, r_med_str)
            end
            sections[#sections+1] = string.format([[
<div class="panel">
<div class="panel-h">%s</div>
<div class="panel-b"><div class="valve-grid">%s</div></div>
</div>
]], sat:gsub("_", " "), table.concat(cells))
        end
    end

    -- Legend
    local legend = [[
<div class="panel"><div class="panel-h">Legend</div><div class="panel-b">
<span class="valve-cell ok" style="display:inline-block;padding:4px 14px;">OK</span>
<span class="tiny">|Δ| ≤ 4 Ω from baseline</span>
&nbsp;&nbsp;
<span class="valve-cell warn" style="display:inline-block;padding:4px 14px;">WARN</span>
<span class="tiny">4 &lt; |Δ| ≤ 8 Ω</span>
&nbsp;&nbsp;
<span class="valve-cell bad" style="display:inline-block;padding:4px 14px;">BAD</span>
<span class="tiny">|Δ| &gt; 8 Ω</span>
&nbsp;&nbsp;
<span class="valve-cell muted" style="display:inline-block;padding:4px 14px;">—</span>
<span class="tiny">no baseline yet</span>
<p class="tiny">Click any valve for R history, baseline, meter readings.</p>
</div></div>
]]
    local body = legend .. table.concat(sections)
    return html_response(layout("Valves", "/irrigation/valves", body, { refresh_s = 300 }))
end

local function view_valve_detail(req)
    local valve = req.params.valve  -- "satellite_1:43" form
    local _, baselines = load_kb2_baselines()
    local b = baselines[valve]
    local since_7d = (os.time() - 7*24*3600) * 1000

    -- KB2 cycle history
    local kb2_rows = {}
    local db2 = open_ro(DB_PATHS.kb2)
    if db2 then
        kb2_rows = query(db2, string.format([[
            SELECT ts_ms, cycle_id, I_raw, offset_used, R_calc, baseline_used,
                   delta_baseline, delta_step, cls
            FROM runs_kb2 WHERE valve = %q AND ts_ms > %d
            ORDER BY ts_ms DESC LIMIT 30
        ]], valve, since_7d))
        db2:close()
    end

    -- Baseline summary
    local baseline_html = b and string.format([[
<div class="kv"><span class="kv-k">R_med (rolling)</span><span class="kv-v">%s Ω</span></div>
<div class="kv"><span class="kv-k">Last R</span><span class="kv-v">%s Ω</span></div>
<div class="kv"><span class="kv-k">n_healthy</span><span class="kv-v">%d</span></div>
<div class="kv"><span class="kv-k">Last updated</span><span class="kv-v">%s</span></div>
]], num(b.R_med, 2), num(b.last_R, 2),
   b.n_healthy or 0, esc(pdt_from_ms(b.last_updated_ms)))
       or '<p class="tiny">No baseline yet for this valve.</p>'

    -- KB2 history table
    local hist_rows = {}
    for _, r in ipairs(kb2_rows) do
        local delta = r.delta_baseline
        local delta_cls = (delta and math.abs(delta) > 4) and " neg" or ""
        hist_rows[#hist_rows+1] = string.format([[
<tr><td>%s</td><td class="num">%s</td><td class="num">%s</td><td class="num %s">%s</td><td>%s</td></tr>
]], esc(pdt_from_ms(r.ts_ms)),
   num(r.R_calc, 2), num(r.baseline_used, 2),
   delta_cls, num(delta, 2), esc(r.cls or "-"))
    end
    local hist_html = #hist_rows > 0 and string.format([[
<table><thead><tr><th>Cycle</th><th>R calc</th><th>Baseline</th><th>Δ</th><th>Class</th></tr></thead>
<tbody>%s</tbody></table>
]], table.concat(hist_rows)) or '<p class="tiny">No recent cycles for this valve.</p>'

    local body = string.format([[
<h2>%s</h2>
<div class="grid g2">
<div class="panel">
<div class="panel-h">Baseline</div>
<div class="panel-b">%s</div>
</div>
<div class="panel">
<div class="panel-h">Actions</div>
<div class="panel-b">
<p><a href="/irrigation/meter?valve=%s">Record meter reading for this valve →</a></p>
<p><a href="/irrigation/valves">← back to all valves</a></p>
</div>
</div>
</div>
<div class="panel">
<div class="panel-h">Last %d valve_test cycles</div>
<div class="panel-b">%s</div>
</div>
]], esc(valve), baseline_html, esc(valve), #kb2_rows, hist_html)

    return html_response(layout(valve, "/irrigation/valves", body, { refresh_s = 300 }))
end

-- =========================================================================
-- PAST ACTIONS view — the robot's notifications log (Glenn 2026-06-10).
-- One chronological, level-colored, Pacific-stamped feed of every Discord-
-- bound message: action alerts (KB1/KB3, RED) + daily summaries (DIGEST,
-- YELLOW). Reads /var/fleet/notify/notifications.db (14-day retention).
-- Filter: all | actions | summaries. Paginated 50/page.
-- =========================================================================

local NOTIFY_LEVEL_TAG = { RED = "t-bad", YELLOW = "t-warn", GREEN = "t-ok" }
local ACTIONS_PER_PAGE = 50

local function view_actions(req)
    local filter = (req.query and req.query.filter) or "all"
    local page   = math.max(1, math.floor(tonumber(req.query and req.query.page) or 1))
    local src_sql = ""
    if filter == "actions"   then src_sql = " AND source IN ('KB1','KB3')"
    elseif filter == "summaries" then src_sql = " AND source IN ('DIGEST')"
    else filter = "all" end

    local db = open_ro(DB_PATHS.notify)
    local rows, total = {}, 0
    if db then
        rows = query(db, string.format(
            "SELECT ts_ms, level, source, kind, target, action, title, body "
            .. "FROM notifications WHERE 1=1%s ORDER BY ts_ms DESC LIMIT %d OFFSET %d",
            src_sql, ACTIONS_PER_PAGE, (page - 1) * ACTIONS_PER_PAGE))
        local tr = query_one(db, "SELECT count(*) AS c FROM notifications WHERE 1=1" .. src_sql)
        total = (tr and tr.c) or 0
        db:close()
    end

    local p = {}
    p[#p+1] = '<div class="panel"><div class="panel-h">Past Actions — robot notifications (last 14 days, Pacific time)</div>'
    p[#p+1] = '<div style="padding:8px 14px;">'
    for _, f in ipairs({ {"all","All"}, {"actions","Action alerts"}, {"summaries","Summaries"} }) do
        local a = (f[1] == filter) and ' style="color:var(--accent);font-weight:600;"' or ''
        p[#p+1] = string.format('<a href="/irrigation/alerts?filter=%s"%s>%s</a>&nbsp;&nbsp;', f[1], a, f[2])
    end
    p[#p+1] = '</div>'

    if not db then
        p[#p+1] = '<div style="padding:14px;">Notifications log not available yet (no events recorded).</div>'
    elseif #rows == 0 then
        p[#p+1] = '<div style="padding:14px;">No notifications for this filter.</div>'
    else
        p[#p+1] = '<table><thead><tr><th>Time (Pacific)</th><th>Level</th><th>Source</th>'
              .. '<th>Target</th><th>Message</th></tr></thead><tbody>'
        for _, r in ipairs(rows) do
            local tag = NOTIFY_LEVEL_TAG[r.level] or "t-muted"
            local action_line = (r.action and r.action ~= "")
                and ('<div class="kv-k" style="margin-top:4px;">action: ' .. esc(r.action) .. '</div>') or ''
            p[#p+1] = string.format(
                '<tr><td style="white-space:nowrap;">%s</td>'
                .. '<td><span class="tag %s">%s</span></td><td>%s/%s</td><td>%s</td>'
                .. '<td><details><summary>%s</summary>%s<pre style="white-space:pre-wrap;margin:6px 0 0;">%s</pre></details></td></tr>',
                esc(pt_time.format_ms(r.ts_ms)), tag, esc(r.level),
                esc(r.source), esc(r.kind), esc(r.target),
                esc(r.title), action_line, esc(r.body))
        end
        p[#p+1] = '</tbody></table>'
        local pages = math.max(1, math.ceil(total / ACTIONS_PER_PAGE))
        if pages > 1 then
            p[#p+1] = string.format('<div style="padding:10px 14px;color:var(--muted);">Page %d of %d &nbsp;', page, pages)
            if page > 1 then
                p[#p+1] = string.format('<a href="/irrigation/alerts?filter=%s&page=%d">‹ newer</a>&nbsp;&nbsp;', filter, page - 1)
            end
            if page < pages then
                p[#p+1] = string.format('<a href="/irrigation/alerts?filter=%s&page=%d">older ›</a>', filter, page + 1)
            end
            p[#p+1] = '</div>'
        end
    end
    p[#p+1] = '</div>'
    return html_response(layout("Past Actions", "/irrigation/alerts", table.concat(p), { refresh_s = 60 }))
end

-- =========================================================================
-- ALERTS view (superseded by view_actions; kept for reference, not routed)
-- =========================================================================

local function view_alerts(_req)
    local since_24h = (os.time() - 24*3600) * 1000
    local eto = load_recent_eto(since_24h)
    local non_eto = load_recent_non_eto(since_24h)
    local kb1 = load_recent_kb1_fires(since_24h)
    local kb2 = load_recent_kb2_fires(since_24h)
    local within = load_recent_within(since_24h)

    local fires = {}

    for _, r in ipairs(eto) do
        local cg, cp = r.cls_gallons or "OK", r.cls_gpm or "OK"
        if cg ~= "OK" then
            fires[#fires+1] = {
                ts_ms = r.ts_ms, source = "KB4 (gal)",
                target = r.bin, cls = cg,
                note = string.format("%.0f gal vs baseline (Δ %.0f)", r.gallons_5_15 or 0, r.delta_gallons or 0),
            }
        end
        if cp ~= "OK" then
            fires[#fires+1] = {
                ts_ms = r.ts_ms, source = "KB4 (gpm)",
                target = r.bin, cls = cp,
                note = string.format("flow %.1f / intercept %.2f", r.flow_5_15 or 0, r.intercept or 0),
            }
        end
    end
    for _, r in ipairs(non_eto) do
        if r.cls and r.cls ~= "OK" and r.cls ~= "no_baseline" then
            fires[#fires+1] = {
                ts_ms = r.ts_ms, source = "KB4 (non-ETO)",
                target = r.bin, cls = r.cls,
                note = string.format("flow %.1f, baseline %s, Δ %+.2f",
                    r.flow_5_15 or 0, num(r.baseline_used, 1), r.delta or 0),
            }
        end
    end
    for _, r in ipairs(kb1) do
        fires[#fires+1] = {
            ts_ms = r.ts_ms, source = "KB1",
            target = r.bin, cls = r.cls,
            note = string.format("I=%.2f exp=%.2f Δ%+.2f", r.I_measured or 0, r.I_expected or 0, r.delta or 0),
        }
    end
    for _, r in ipairs(kb2) do
        fires[#fires+1] = {
            ts_ms = r.ts_ms, source = "KB2",
            target = r.valve, cls = r.cls,
            note = r.note or string.format("R=%.1f baseline %.1f Δ%+.1f",
                r.R_calc or 0, r.baseline_used or 0, r.delta_baseline or 0),
        }
    end
    for _, r in ipairs(within) do
        fires[#fires+1] = {
            ts_ms = r.ts_ms, source = "KB2-WR",
            target = r.bin, cls = r.cls,
            note = r.note or string.format("R_start=%.1f R_end=%.1f slope %+.3f",
                r.R_start or 0, r.R_end or 0, r.slope_ohm_pm or 0),
        }
    end

    table.sort(fires, function(a, b) return a.ts_ms > b.ts_ms end)

    local rows = {}
    for _, f in ipairs(fires) do
        local cls = f.cls or "?"
        local tag = cls:find("ALERT") and "t-bad" or
                    cls:find("KILL") and "t-bad" or
                    cls:find("WARN") and "t-warn" or "t-info"
        rows[#rows+1] = string.format([[
<tr><td>%s</td><td>%s</td><td>%s</td><td><span class="tag %s">%s</span></td><td>%s</td></tr>
]], esc(pdt_from_ms(f.ts_ms)), esc(f.source), esc(f.target),
   tag, esc(cls), esc(f.note))
    end

    local table_html = #rows > 0 and string.format([[
<table><thead><tr><th>Time</th><th>Detector</th><th>Target</th><th>Class</th><th>Note</th></tr></thead>
<tbody>%s</tbody></table>
]], table.concat(rows)) or '<p class="tiny">No fires in the last 24 hours.</p>'

    local body = string.format([[
<div class="panel">
<div class="panel-h">Fires last 24 h (%d total)</div>
<div class="panel-b">%s</div>
</div>
]], #fires, table_html)

    return html_response(layout("Alerts", "/irrigation/alerts", body, { refresh_s = 60 }))
end

-- =========================================================================
-- COHORT view — satellite-level drift summary
-- =========================================================================

local function view_cohort(_req)
    local since_24h = (os.time() - 24*3600) * 1000
    local eto = load_recent_eto(since_24h)
    local non_eto = load_recent_non_eto(since_24h)

    -- Aggregate by satellite via first valve in bin
    local sat = {
        satellite_1 = { n = 0, sum_delta = 0, worst_d = 0, worst_bin = "" },
        satellite_2 = { n = 0, sum_delta = 0, worst_d = 0, worst_bin = "" },
        satellite_3 = { n = 0, sum_delta = 0, worst_d = 0, worst_bin = "" },
        satellite_4 = { n = 0, sum_delta = 0, worst_d = 0, worst_bin = "" },
    }
    local function bucket_for(bin)
        -- pick the non-sat_1:39 satellite if present (city zones land elsewhere)
        for s in bin:gmatch("(satellite_%d)") do
            if s ~= "satellite_1" or not bin:find("1:39") then return s end
        end
        return bin:match("(satellite_%d)")
    end
    local function record(bin, delta)
        local s = bucket_for(bin)
        if not s or not sat[s] then return end
        sat[s].n = sat[s].n + 1
        sat[s].sum_delta = sat[s].sum_delta + (delta or 0)
        if delta and delta < sat[s].worst_d then
            sat[s].worst_d = delta
            sat[s].worst_bin = bin
        end
    end
    for _, r in ipairs(eto) do
        if r.flow_5_15 and r.delta_intercept then
            record(r.bin, r.delta_intercept)
        end
    end
    for _, r in ipairs(non_eto) do
        if r.delta then record(r.bin, r.delta) end
    end

    -- Render rows
    local rows = {}
    local order = { "satellite_1", "satellite_2", "satellite_3", "satellite_4" }
    local fleet_n = 0
    local fleet_sum = 0
    for _, s in ipairs(order) do
        local d = sat[s]
        if d.n > 0 then
            fleet_n = fleet_n + d.n
            fleet_sum = fleet_sum + d.sum_delta
            local mean = d.sum_delta / d.n
            local mean_str = string.format("%+.2f", mean)
            local cls = (mean < -1.5) and "neg" or (mean > 1.5) and "pos" or ""
            local bar_w = math.min(280, math.abs(mean) * 70)
            rows[#rows+1] = string.format([[
<tr><td><b>%s</b></td><td class="num">%d</td>
<td class="num %s">%s GPM</td>
<td class="num">%+.2f GPM (%s)</td>
<td><span class="bar" style="width:%dpx;%s"></span></td></tr>
]], s:gsub("_", " "), d.n, cls, mean_str, d.worst_d, esc(d.worst_bin),
   bar_w, mean < 0 and "background:linear-gradient(90deg,var(--bad),#5a3030);" or "")
        end
    end
    local fleet_mean = fleet_n > 0 and (fleet_sum / fleet_n) or 0

    local body = string.format([[
<div class="panel">
<div class="panel-h">Cohort drift — last 24 h, mean Δ per satellite</div>
<div class="panel-b">
<table><thead><tr><th>Satellite</th><th>Runs</th><th>Mean Δ vs baseline</th><th>Worst run</th><th></th></tr></thead>
<tbody>%s</tbody>
</table>
<p class="tiny">Fleet mean Δ across %d runs = <b>%+.2f GPM</b>. Negative = under-delivery (pressure-starvation or clog). Positive = over-delivery (leak).</p>
</div>
</div>
<div class="panel">
<div class="panel-h">Reading the fingerprint</div>
<div class="panel-b">
<p>If <b>multiple satellites are uniformly down</b>, the cohort signature points at the <b>water side</b> (well, pump, main line) — not at individual valves.</p>
<p>If <b>one satellite is down while others are normal</b>, the supply line to that satellite is the suspect.</p>
<p>If <b>one valve drops while its satellite peers stay flat</b>, that's a localized clog or coil issue — check the Alerts page for the per-valve fire.</p>
</div>
</div>
]], table.concat(rows), fleet_n, fleet_mean)

    return html_response(layout("Cohort", "/irrigation/cohort", body, { refresh_s = 300 }))
end

-- =========================================================================
-- FIELD view — auto-generated punch list from recent fires
-- =========================================================================

local function view_field(_req)
    local since_7d = (os.time() - 7*24*3600) * 1000
    local since_24h = (os.time() - 24*3600) * 1000

    -- Persistent ETO BLOCKED_WARN / SAG_WARN over last 24h
    local eto = load_recent_eto(since_24h)
    local block_counts = {}
    for _, r in ipairs(eto) do
        for _, c in ipairs({ r.cls_gallons, r.cls_gpm }) do
            if c and (c:find("BLOCKED") or c:find("WARN")) then
                block_counts[r.bin] = (block_counts[r.bin] or 0) + 1
            end
        end
    end

    -- KB2 drifts
    local kb2 = load_recent_kb2_fires(since_7d)
    local drift_count = {}
    for _, r in ipairs(kb2) do
        if r.cls and (r.cls:find("WARN") or r.cls:find("ALERT") or r.cls:find("CREEP")) then
            drift_count[r.valve] = (drift_count[r.valve] or 0) + 1
        end
    end

    -- KB2 within-run heating/step
    local wr = load_recent_within(since_7d)
    local wr_count = {}
    for _, r in ipairs(wr) do
        if r.cls and r.cls ~= "OK" and r.cls ~= "TOO_FEW_SAMPLES" then
            wr_count[r.bin] = (wr_count[r.bin] or 0) + 1
        end
    end

    local function priority_section(title, items)
        if #items == 0 then return string.format(
            '<div class="panel"><div class="panel-h">%s</div>'..
            '<div class="panel-b"><p class="tiny">— nothing flagged</p></div></div>', title) end
        local lis = {}
        for _, it in ipairs(items) do
            lis[#lis+1] = "<li>" .. it .. "</li>"
        end
        return string.format(
            '<div class="panel"><div class="panel-h">%s</div>'..
            '<div class="panel-b"><ul>%s</ul></div></div>',
            title, table.concat(lis))
    end

    -- Build prioritized items
    local high, medium, low = {}, {}, {}

    -- High: multiple BLOCKED_WARN in 24h on same bin
    for bin, n in pairs(block_counts) do
        if n >= 2 then
            high[#high+1] = string.format(
                '<b>%s</b> — %d BLOCKED/WARN fires today (water side check)',
                esc(bin), n)
        elseif n == 1 then
            medium[#medium+1] = string.format(
                '<b>%s</b> — 1 BLOCKED/WARN today', esc(bin))
        end
    end

    -- High: KB2 ALERT (sustained 3-cycle drift)
    for valve, n in pairs(drift_count) do
        if n >= 2 then
            high[#high+1] = string.format(
                '<b>%s</b> — KB2 drift fired %d times in 7 days (coil aging?)',
                esc(valve), n)
        end
    end

    -- Medium: within-run heating/step
    for bin, n in pairs(wr_count) do
        if n >= 2 then
            medium[#medium+1] = string.format(
                '<b>%s</b> — %d within-run R fires last 7 days', esc(bin), n)
        elseif n == 1 then
            low[#low+1] = string.format(
                '<b>%s</b> — 1 within-run R event', esc(bin))
        end
    end

    -- Always include cohort hint if fleet is down
    local cohort_note = ""
    local eto_count = 0
    local fleet_delta_sum = 0
    for _, r in ipairs(eto) do
        if r.delta_intercept then
            eto_count = eto_count + 1
            fleet_delta_sum = fleet_delta_sum + r.delta_intercept
        end
    end
    if eto_count >= 5 and (fleet_delta_sum / eto_count) < -1.0 then
        high[#high+1] = string.format(
            'Fleet-wide cohort drift (%d runs, mean Δ %+.2f GPM) — check well/pump first',
            eto_count, fleet_delta_sum / eto_count)
    end

    local body = priority_section("HIGH priority", high) ..
                 priority_section("MEDIUM", medium) ..
                 priority_section("LOW (background)", low) ..
                 [[<div class="panel"><div class="panel-h">Note</div>
                 <div class="panel-b"><p class="tiny">
                 Auto-generated from the last 24h of ETO classifications +
                 last 7 days of KB2/KB2-WR fires. To log what you found in
                 the field, use the <a href="/irrigation/check">Sprinkler check</a>
                 page — the system will cross-reference your findings against
                 these predictions to tune thresholds.
                 </p></div></div>]]

    return html_response(layout("Field", "/irrigation/field", body, { refresh_s = 300 }))
end

-- =========================================================================
-- Write-table schemas (lazy-create on first use)
-- =========================================================================

-- Adds meter_readings + write_audit to kb2.db; field_checks +
-- clog_observations to kb4.db. All additive — won't break either.
local WRITE_SCHEMA_KB2 = [[
CREATE TABLE IF NOT EXISTS meter_readings (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms           INTEGER NOT NULL,
    valve           TEXT NOT NULL,
    R_meter_ohm     REAL NOT NULL,
    V_terminal      REAL,
    notes           TEXT,
    inspector       TEXT,
    override_baseline INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_meter_valve ON meter_readings(valve);
CREATE INDEX IF NOT EXISTS idx_meter_ts    ON meter_readings(ts_ms);

CREATE TABLE IF NOT EXISTS write_audit (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms        INTEGER NOT NULL,
    path         TEXT,
    user_agent   TEXT,
    payload      TEXT
);
]]

local WRITE_SCHEMA_KB4 = [[
CREATE TABLE IF NOT EXISTS field_checks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms           INTEGER NOT NULL,
    check_date      TEXT,
    inspector       TEXT,
    notes           TEXT
);
CREATE TABLE IF NOT EXISTS clog_observations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    check_id        INTEGER REFERENCES field_checks(id),
    bin             TEXT NOT NULL,
    total_heads     INTEGER,
    clogged_count   INTEGER,
    fixed_int       INTEGER DEFAULT 0,
    notes           TEXT
);
CREATE INDEX IF NOT EXISTS idx_clog_check ON clog_observations(check_id);
CREATE INDEX IF NOT EXISTS idx_clog_bin   ON clog_observations(bin);
]]

local function ensure_write_schemas()
    local db = open_rw(DB_PATHS.kb2)
    if db then db:exec(WRITE_SCHEMA_KB2); db:close() end
    db = open_rw(DB_PATHS.kb4)
    if db then db:exec(WRITE_SCHEMA_KB4); db:close() end
end
ensure_write_schemas()

local function audit(path, ua, payload)
    local db = open_rw(DB_PATHS.kb2)
    if not db then return end
    local stmt = db:prepare(
        "INSERT INTO write_audit(ts_ms, path, user_agent, payload) VALUES(?, ?, ?, ?)")
    if stmt then
        stmt:bind_values(os.time() * 1000, path, ua or "", payload or "")
        stmt:step(); stmt:finalize()
    end
    db:close()
end

-- =========================================================================
-- METER ENTRY view + POST handler
-- =========================================================================

local function flash_html(req)
    local flash = req.query.flash
    local msg = req.query.msg
    if flash == "ok" and msg then
        return '<div class="flash ok">' .. esc(msg) .. '</div>'
    elseif flash == "err" and msg then
        return '<div class="flash err">' .. esc(msg) .. '</div>'
    end
    return ""
end

local function view_meter(req)
    local selected = req.query.valve or ""
    local rows, baselines = load_kb2_baselines()
    local options = { '<option value="">— select —</option>' }
    for _, b in ipairs(rows) do
        local sel = (b.valve == selected) and " selected" or ""
        options[#options+1] = string.format('<option value="%s"%s>%s</option>',
            esc(b.valve), sel, esc(b.valve))
    end

    local context_html = ""
    if selected ~= "" and baselines[selected] then
        local b = baselines[selected]
        -- recent meter history for this valve
        local db = open_ro(DB_PATHS.kb2)
        local mr_rows = db and query(db, string.format([[
            SELECT ts_ms, R_meter_ohm, V_terminal, notes, inspector, override_baseline
            FROM meter_readings WHERE valve = %q ORDER BY ts_ms DESC LIMIT 10
        ]], selected)) or {}
        if db then db:close() end
        local history = {}
        for _, r in ipairs(mr_rows) do
            history[#history+1] = string.format(
                "<tr><td>%s</td><td class=\"num\">%s Ω</td><td>%s</td><td>%s</td></tr>",
                esc(pdt_from_ms(r.ts_ms)), num(r.R_meter_ohm, 2),
                esc(r.inspector or ""), esc(r.notes or ""))
        end
        local hist_table = #history > 0 and string.format([[
<table><thead><tr><th>Time</th><th>R meter</th><th>Who</th><th>Notes</th></tr></thead>
<tbody>%s</tbody></table>
]], table.concat(history)) or '<p class="tiny">No meter readings logged yet.</p>'

        context_html = string.format([[
<div class="panel">
<div class="panel-h">Current baseline for %s</div>
<div class="panel-b">
<div class="kv"><span class="kv-k">Calc R (rolling median)</span><span class="kv-v">%s Ω</span></div>
<div class="kv"><span class="kv-k">Last calc R</span><span class="kv-v">%s Ω</span></div>
<div class="kv"><span class="kv-k">n_healthy cycles</span><span class="kv-v">%d</span></div>
</div></div>
<div class="panel"><div class="panel-h">Recent meter readings</div>
<div class="panel-b">%s</div></div>
]], esc(selected), num(b.R_med, 2), num(b.last_R, 2), b.n_healthy or 0, hist_table)
    end

    local today_iso = os.date("!%Y-%m-%d", os.time() - 7*3600)
    local form = string.format([[
<div class="panel">
<div class="panel-h">Record new meter reading</div>
<div class="panel-b">
<form method="POST" action="/irrigation/meter">
<div class="row"><label>Valve</label>
<select name="valve" required onchange="this.form.action='/irrigation/meter?valve='+encodeURIComponent(this.value);this.form.method='GET';this.form.submit();">
%s
</select></div>
<div class="row"><label>Measured R (Ω)</label><input type="number" step="0.1" name="R_meter_ohm" required></div>
<div class="row"><label>Terminal V (opt)</label><input type="number" step="0.1" name="V_terminal"></div>
<div class="row"><label>Inspector</label><input type="text" name="inspector" value="Glenn"></div>
<div class="row"><label>Date</label><input type="date" name="check_date" value="%s"></div>
<div class="row"><label>Notes</label><input type="text" name="notes" placeholder="post-maintenance, etc."></div>
<div class="row"><label></label>
  <button type="submit" name="action" value="save">Save measurement</button>
  &nbsp;<button type="submit" name="action" value="override" class="alt"
    onclick="return confirm('Override KB2 baseline with this meter value? Resets rolling median.');">
    Save AND override baseline
  </button>
</div>
</form>
</div></div>
]], table.concat(options), today_iso)

    local body = flash_html(req) .. form .. context_html
    return html_response(layout("Meter R", "/irrigation/meter", body))
end

local function post_meter(req)
    if not req.form then
        return redirect("/irrigation/meter", "err", "no form data")
    end
    local valve = req.form.valve
    local R = tonumber(req.form.R_meter_ohm)
    if not valve or valve == "" or not R then
        return redirect("/irrigation/meter", "err", "valve + R required")
    end
    local action = req.form.action or "save"

    local db = open_rw(DB_PATHS.kb2)
    if not db then
        return redirect("/irrigation/meter", "err", "DB unavailable")
    end

    local stmt = db:prepare([[
        INSERT INTO meter_readings(ts_ms, valve, R_meter_ohm, V_terminal, notes, inspector, override_baseline)
        VALUES(?, ?, ?, ?, ?, ?, ?)
    ]])
    stmt:bind_values(
        os.time() * 1000, valve, R,
        tonumber(req.form.V_terminal),
        req.form.notes or "", req.form.inspector or "",
        action == "override" and 1 or 0)
    stmt:step(); stmt:finalize()

    if action == "override" then
        local cjson_ok, cjson = pcall(require, "cjson")
        local ring_json = cjson_ok and cjson.encode({ R }) or "[]"
        local upd = db:prepare([[
            UPDATE baselines_kb2
            SET R_med = ?, R_mad = 0, n_healthy = 1, last_R = ?,
                window_json = ?, last_updated_ms = ?,
                note = COALESCE(note, '') || ' [meter-override ' || ? || ']'
            WHERE valve = ?
        ]])
        if upd then
            upd:bind_values(R, R, ring_json, os.time() * 1000,
                os.date("!%Y-%m-%d"), valve)
            upd:step(); upd:finalize()
        end
    end
    db:close()

    audit("/irrigation/meter",
        req.headers["user-agent"] or "",
        string.format("valve=%s R=%.2f action=%s", valve, R, action))

    local msg = action == "override"
        and string.format("Saved %s = %.2f Ω AND overrode baseline", valve, R)
        or  string.format("Saved %s = %.2f Ω", valve, R)
    return redirect("/irrigation/meter?valve=" .. valve, "ok", msg)
end

-- =========================================================================
-- SPRINKLER CHECK ENTRY view + POST handler
-- =========================================================================

local function load_recent_predictions(since_ms)
    local db = open_ro(DB_PATHS.kb4)
    if not db then return {} end
    local rows = query(db, string.format([[
        SELECT bin, cls_gallons, cls_gpm, delta_gallons, ts_ms
        FROM runs_eto WHERE ts_ms > %d
        AND (cls_gallons != 'OK' OR cls_gpm != 'OK')
        ORDER BY ts_ms DESC
    ]], since_ms))
    db:close()
    return rows
end

local function view_check(req)
    local today_iso = os.date("!%Y-%m-%d", os.time() - 7*3600)
    -- Recent KB4 predictions (so user can compare against findings)
    local since_3d = (os.time() - 3*24*3600) * 1000
    local preds = load_recent_predictions(since_3d)
    local pred_rows = {}
    for _, p in ipairs(preds) do
        local cls = p.cls_gallons ~= "OK" and p.cls_gallons or p.cls_gpm
        pred_rows[#pred_rows+1] = string.format(
            "<tr><td>%s</td><td>%s</td><td>%s</td><td class=\"num\">%+.0f gal</td></tr>",
            esc(p.bin), esc(cls), esc(pdt_from_ms(p.ts_ms)), p.delta_gallons or 0)
    end
    local pred_html = #pred_rows > 0 and string.format([[
<table><thead><tr><th>Bin</th><th>KB4 predicted</th><th>When</th><th>Δ gal</th></tr></thead>
<tbody>%s</tbody></table>
]], table.concat(pred_rows)) or '<p class="tiny">No KB4 predictions in last 3 days.</p>'

    -- Recent checks
    local db = open_ro(DB_PATHS.kb4)
    local check_rows = db and query(db, [[
        SELECT id, ts_ms, check_date, inspector, notes
        FROM field_checks ORDER BY ts_ms DESC LIMIT 10
    ]]) or {}
    local recent_rows = {}
    for _, c in ipairs(check_rows) do
        local obs = db and query(db, string.format(
            "SELECT bin, clogged_count, total_heads, fixed_int FROM clog_observations WHERE check_id = %d",
            c.id)) or {}
        local sum_clog, sum_heads = 0, 0
        for _, o in ipairs(obs) do
            sum_clog = sum_clog + (o.clogged_count or 0)
            sum_heads = sum_heads + (o.total_heads or 0)
        end
        recent_rows[#recent_rows+1] = string.format(
            "<tr><td>%s</td><td>%s</td><td class=\"num\">%d/%d clog/heads in %d bins</td><td>%s</td></tr>",
            esc(c.check_date or ""), esc(c.inspector or ""),
            sum_clog, sum_heads, #obs, esc(c.notes or ""))
    end
    if db then db:close() end
    local recent_html = #recent_rows > 0 and string.format([[
<table><thead><tr><th>Date</th><th>Inspector</th><th>Findings</th><th>Notes</th></tr></thead>
<tbody>%s</tbody></table>
]], table.concat(recent_rows)) or '<p class="tiny">No field checks logged yet.</p>'

    local form = string.format([[
<div class="panel">
<div class="panel-h">Log a new field check</div>
<div class="panel-b">
<form method="POST" action="/irrigation/check">
<div class="row"><label>Date of check</label><input type="date" name="check_date" value="%s" required></div>
<div class="row"><label>Inspector</label><input type="text" name="inspector" value="Glenn"></div>
<div class="row"><label>Notes</label><input type="text" name="notes" placeholder="overall comments"></div>

<h3 style="margin-top:18px;font-size:14px;color:var(--muted);">Per-valve observations (leave blank if not inspected)</h3>
<table style="width:auto;">
<thead><tr><th>Bin</th><th>Total heads</th><th>Clogged</th><th>Fixed?</th><th>Action</th><th>Notes</th></tr></thead>
<tbody>
%s
</tbody></table>

<div class="row" style="margin-top:14px;"><label></label>
<button type="submit">Save field check</button></div>
</form>
</div></div>
]], today_iso, (function()
    local _, baselines = load_kb2_baselines()
    -- Use ETO bins from kb4
    local eto_bl = load_kb4_eto_baselines()
    local rows = {}
    for i, b in ipairs(eto_bl) do
        rows[#rows+1] = string.format([[
<tr><td><input type="hidden" name="bin_%d" value="%s">%s</td>
<td><input type="number" name="total_%d" min="0" max="200" style="width:80px;"></td>
<td><input type="number" name="clog_%d" min="0" max="200" style="width:80px;"></td>
<td><input type="checkbox" name="fixed_%d" value="1"></td>
<td><select name="action_%d"><option value="">—</option><option value="inspect_ok">inspected OK</option><option value="clean_heads">cleaned heads</option><option value="cap_heads">capped/removed heads</option><option value="replace_valve">replaced valve</option><option value="replace_solenoid">replaced solenoid</option><option value="repair_leak">repaired leak</option><option value="other">other</option></select></td>
<td><input type="text" name="note_%d" style="width:200px;"></td></tr>
]], i, esc(b.bin), esc(b.bin), i, i, i, i, i)
    end
    return table.concat(rows)
end)())

    local body = flash_html(req) .. form ..
        string.format('<div class="panel"><div class="panel-h">Recent KB4 predictions (last 3 days)</div><div class="panel-b">%s</div></div>', pred_html) ..
        string.format('<div class="panel"><div class="panel-h">Recent checks</div><div class="panel-b">%s</div></div>', recent_html)

    return html_response(layout("Sprinkler check", "/irrigation/check", body))
end

local function post_check(req)
    if not req.form then
        return redirect("/irrigation/check", "err", "no form data")
    end
    local db = open_rw(DB_PATHS.kb4)
    if not db then return redirect("/irrigation/check", "err", "DB unavailable") end

    -- additive migration: per-valve maintenance ACTION (drives the manual-log
    -- baseline-reset watcher). Harmless if the column already exists.
    pcall(function() db:exec("ALTER TABLE clog_observations ADD COLUMN action TEXT") end)
    pcall(function() db:exec("ALTER TABLE clog_observations ADD COLUMN action_applied INTEGER DEFAULT 0") end)

    local ck_stmt = db:prepare([[
        INSERT INTO field_checks(ts_ms, check_date, inspector, notes)
        VALUES(?, ?, ?, ?)
    ]])
    ck_stmt:bind_values(os.time() * 1000,
        req.form.check_date or "", req.form.inspector or "", req.form.notes or "")
    ck_stmt:step()
    ck_stmt:finalize()
    local check_id = db:last_insert_rowid()

    -- Walk bin_N fields
    local obs_count = 0
    for k, v in pairs(req.form) do
        local idx = k:match("^bin_(%d+)$")
        if idx then
            local bin = v
            local total = tonumber(req.form["total_" .. idx])
            local clog = tonumber(req.form["clog_" .. idx])
            local fixed = (req.form["fixed_" .. idx] == "1") and 1 or 0
            local note = req.form["note_" .. idx]
            local action = req.form["action_" .. idx]
            if action == "" then action = nil end
            -- Only insert if user entered something
            if total or clog or action or (note and note ~= "") then
                local obs = db:prepare([[
                    INSERT INTO clog_observations(check_id, bin, total_heads, clogged_count, fixed_int, action, notes)
                    VALUES(?, ?, ?, ?, ?, ?, ?)
                ]])
                obs:bind_values(check_id, bin, total, clog, fixed, action, note or "")
                obs:step(); obs:finalize()
                obs_count = obs_count + 1
            end
        end
    end
    db:close()

    audit("/irrigation/check",
        req.headers["user-agent"] or "",
        string.format("check_id=%d obs=%d", check_id, obs_count))

    return redirect("/irrigation/check", "ok",
        string.format("Saved check #%d with %d valve observations", check_id, obs_count))
end

-- =========================================================================
-- Route registration
-- =========================================================================

-- =========================================================================
-- COIL ONSET view — solenoid current-onset signature monitor
-- =========================================================================

-- Latest field finding per valve, from the most recent field check, so the
-- page can show whether field-failed valves cluster in a signature group.
local function load_field_findings()
    local db = open_ro(DB_PATHS.kb4)
    if not db then return {} end
    local out = {}
    local rows = query(db, [[
        SELECT o.bin AS bin, o.clogged_count AS clogged, o.notes AS notes
        FROM clog_observations o
        WHERE o.check_id = (SELECT MAX(id) FROM field_checks) ]])
    for _, r in ipairs(rows) do
        -- a composite obs (a/b) annotates each member valve
        for v in tostring(r.bin):gmatch("[^/]+") do
            local note = r.notes
            if (note == nil or note == "") and tonumber(r.clogged) and tonumber(r.clogged) > 0 then
                note = string.format("clogged x%d", tonumber(r.clogged))
            end
            if note and note ~= "" then out[v] = note end
        end
    end
    db:close()
    return out
end

-- Watch list — valves under deliberate observation (a falling coil, a thermal
-- overshoot to confirm, a flagged resistance group). One row per valve in kb4.db.
local function load_watch_list()
    local db = open_ro(DB_PATHS.kb4)
    if not db then return {} end
    local out = {}
    for _, r in ipairs(query(db, [[
        SELECT valve, reason, source, added_ms FROM watch_list ORDER BY added_ms ]])) do
        out[r.valve] = r
    end
    db:close()
    return out
end

-- Onset spike groups (within-run; co-energized additions cancel)
local SPIKE_TAG = {
    SPIKE_SEVERE = "t-bad", SPIKE_STRONG = "t-warn", SPIKE_MILD = "t-warn", FLAT = "t-info",
}
local SPIKE_LABEL = {
    SPIKE_SEVERE = "spike≥0.30", SPIKE_STRONG = "spike0.15-0.30",
    SPIKE_MILD   = "spike0.05-0.15", FLAT = "flat",
}
local NULL_A     = 0.10   -- |per-coil current| below this = unconnected / wiring null
local WEAK_DELTA = 0.10   -- connected coil this far below connected median = weak

local function median_list(t)
    local n = #t; if n == 0 then return nil end
    table.sort(t)
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return (t[n / 2] + t[n / 2 + 1]) / 2
end

local function view_coil(_req)
    local db = open_ro(DB_PATHS.kb4)
    local rows = db and query(db, [[
        SELECT valve, n, hold_med, spike_delta_med, sig_group, last_ms
        FROM coil_onset_baseline WHERE hold_med IS NOT NULL ]]) or {}
    if db then db:close() end

    -- one equation per energized-set key: hold = master(1:43) + Σ pair-member coils
    local eqs = {}
    for _, r in ipairs(rows) do
        local members = {}
        for v in tostring(r.valve):gmatch("[^/]+") do members[#members + 1] = v end
        eqs[#eqs + 1] = { members = members, b = r.hold_med, w = tonumber(r.n) or 1 }
    end
    local master, coil, ok, rms = nil, {}, false, 0
    pcall(function() master, coil, ok, rms = coil_solve.solve(eqs) end)

    local findings = load_field_findings()
    local watch = load_watch_list()

    -- per-single-valve onset spike (from its own single-key baseline)
    local spike = {}
    for _, r in ipairs(rows) do
        if not tostring(r.valve):find("/") then
            spike[r.valve] = { group = r.sig_group, delta = r.spike_delta_med,
                               last_ms = r.last_ms, n = r.n }
        end
    end

    -- split solved coils into connected vs null references
    local connected, nulls = {}, {}
    if ok and coil then
        for v, amps in pairs(coil) do
            if math.abs(amps) < NULL_A then
                nulls[#nulls + 1] = { valve = v, amps = amps }
            else
                connected[#connected + 1] = { valve = v, amps = amps }
            end
        end
    end
    local cmed
    do
        local list = {}
        for _, c in ipairs(connected) do list[#list + 1] = c.amps end
        cmed = median_list(list)
    end
    local n_weak = 0
    for _, c in ipairs(connected) do
        c.dmed = (cmed and c.amps - cmed) or nil
        c.weak = (cmed ~= nil and c.amps <= cmed - WEAK_DELTA)
        if c.weak then n_weak = n_weak + 1 end
        local sp = spike[c.valve]
        c.sig = sp and sp.group or nil
        c.n = sp and sp.n or nil
        c.last_ms = sp and sp.last_ms or nil
        c.field = findings[c.valve]
    end
    table.sort(connected, function(a, b) return a.amps < b.amps end)   -- weakest first
    table.sort(nulls, function(a, b) return a.valve < b.valve end)

    local null_str = {}
    for _, z in ipairs(nulls) do null_str[#null_str + 1] = esc(z.valve) end
    local hdr = string.format([[
<p><b>Master (1:43, implicit):</b> %s A&nbsp;&nbsp;
<b>Typical coil:</b> %s A&nbsp;&nbsp;
<b>Fit residual:</b> %s A %s&nbsp;&nbsp;
<b>Weak-coil candidates:</b> <span class="tag %s">%d</span></p>
<p class="tiny"><b>Null references (≈0 A — unconnected / wiring artifacts; confirm the fit's zero):</b> %s</p>
]], num(master, 3), num(cmed, 3), num(rms, 3),
    (rms and rms < 0.10) and '<span class="tag t-info">good</span>' or '<span class="tag t-warn">high</span>',
    n_weak > 0 and "t-bad" or "t-info", n_weak,
    #null_str > 0 and table.concat(null_str, ", ") or "none")

    local trows = {}
    for _, c in ipairs(connected) do
        local amp_tag = c.weak and "t-bad" or "t-info"
        local sg = c.sig and string.format('<span class="tag %s">%s</span>',
            SPIKE_TAG[c.sig] or "t-info", esc(SPIKE_LABEL[c.sig] or c.sig)) or
            '<span class="tiny">—</span>'
        local fld = c.field and ('<span class="tag t-warn">' .. esc(c.field) .. '</span>') or
            '<span class="tiny">—</span>'
        local vcell = esc(c.valve) ..
            (watch[c.valve] and ' <span class="tag t-warn" title="'
                .. esc(watch[c.valve].reason or "watched") .. '">👁 watch</span>' or "")
        trows[#trows + 1] = string.format([[
<tr><td>%s</td><td style="text-align:right"><span class="tag %s">%s</span></td>
<td style="text-align:right">%s</td><td>%s</td>
<td style="text-align:right">%s</td><td>%s</td><td class="tiny">%s</td></tr>
]], vcell, amp_tag, num(c.amps, 3),
    c.dmed ~= nil and num(c.dmed, 3) or "—", sg,
    c.n and tostring(c.n) or "—", fld, esc(pdt_from_ms(c.last_ms)))
    end

    -- watch-list panel
    local wrows = {}
    for v, w in pairs(watch) do
        local amps = (coil and coil[v]) and num(coil[v], 3) or "—"
        wrows[#wrows + 1] = string.format(
            '<tr><td>%s</td><td style="text-align:right">%s</td><td>%s</td><td class="tiny">%s</td></tr>',
            esc(v), amps, esc(w.reason or ""), esc(pdt_from_ms(w.added_ms)))
    end
    local watch_html = #wrows > 0 and string.format([[
<div class="panel">
<div class="panel-h">👁 Watch list (%d)</div>
<div class="panel-b"><table><thead><tr>
<th>Valve</th><th>I_coil (A)</th><th>Reason</th><th>Since</th></tr></thead>
<tbody>%s</tbody></table></div>
</div>
]], #wrows, table.concat(wrows)) or ""

    local table_html = (ok and #trows > 0) and string.format([[
<table>
<thead><tr>
<th>Valve</th><th title="solved per-coil current, master removed">I_coil (A)</th>
<th title="vs connected-coil median">Δ median</th>
<th title="within-run onset spike">Onset</th>
<th>Runs</th><th>Field finding</th><th>Updated</th>
</tr></thead><tbody>%s</tbody></table>
]], table.concat(trows)) or
        '<p class="tiny">No solved data yet — accumulates as valves run, or the backfill has not been applied.</p>'

    local body = string.format([[
%s
<div class="panel">
<div class="panel-h">Per-coil current — least-squares decomposition</div>
<div class="panel-b">%s</div>
</div>
<div class="panel">
<div class="panel-h">Connected coils — weakest first (%d)</div>
<div class="panel-b">%s
<p class="tiny" style="margin-top:10px">
IRRIGATION_CURRENT is a <b>sum</b>: master 1:43 (every run) + the 1–3 pair members.
We solve the whole run-set as a linear system for each coil and the master, so
<b>I_coil</b> is the true per-coil current with the master removed. Unconnected valves
and wiring artifacts solve to ≈0 A (the null references above). A <b>connected</b> coil
sitting low vs the median, or trending toward the null floor Thursday over Thursday,
is the weak-coil / high-R signal. <b>Onset</b> is the within-run first-minute spike
(additions cancel) — informational.
</p></div>
</div>
]], watch_html, hdr, #connected, table_html)

    return html_response(layout("Coil onset", "/irrigation/coil", body, { refresh_s = 300 }))
end

function M.register_routes(srv)
    srv:route("GET", "/irrigation", view_now)
    srv:route("GET", "/irrigation/today", view_today)
    srv:route("GET", "/irrigation/valves", view_valves)
    srv:route("GET", "/irrigation/valves/:valve", view_valve_detail)
    srv:route("GET", "/irrigation/cohort", view_cohort)
    srv:route("GET", "/irrigation/alerts", view_actions)
    srv:route("GET", "/irrigation/field", view_field)
    srv:route("GET", "/irrigation/meter", view_meter)
    srv:route("POST", "/irrigation/meter", post_meter)
    srv:route("GET", "/irrigation/coil", view_coil)
    srv:route("GET", "/irrigation/check", view_check)
    srv:route("POST", "/irrigation/check", post_check)
end

return M
