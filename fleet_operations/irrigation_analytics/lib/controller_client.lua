-- lib/controller_client.lua — fetch controller state from LaCima irrigation.
--
-- Ported from irrigation_analytics/robot/lib/controller.lua. Phase 3 adds
-- past_actions + time_history reads for KB1/KB3 detection.
--
-- One-shot ssh+python invocation against the host configured in
-- class_spec.controller.ssh_host (default pi@irrigation). Mirrors the
-- existing fetch_data.sh pattern. Errors are returned, never raised — the
-- caller decides whether to skip the tick or back off.

local cjson = require("cjson")

local M = {}

local POPUP_DB  = 4
local POPUP_KEY =
    "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]" ..
    "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]" ..
    "[IRRIGATION_CONTROL_MANAGEMENT:IRRIGATION_CONTROL_MANAGEMENT]" ..
    "[PACKAGE:IRRIGATION_CONTROL_MANAGEMENT][MANAGED_HASH:IRRIGATION_CONTROL]"

local PAST_ACTIONS_DB  = 4
local PAST_ACTIONS_KEY =
    "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]" ..
    "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]" ..
    "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][STREAM_REDIS:IRRIGATION_PAST_ACTIONS]"

local TIME_HISTORY_DB  = 4
local TIME_HISTORY_KEY =
    "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]" ..
    "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]" ..
    "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]"

local PLC_STREAM_DB = 4
-- PLC_MEASUREMENTS_STREAM — high-accuracy well-side flow + plc currents.
-- ~1 sample/min. Key lives under PLC_MEASUREMENTS/PLC_MEASUREMENTS_PACKAGE.
-- Fields (per sample): main_flow_meter, FILTERED_HUNTER_VALVE,
-- HUNTER_HIRES_VALVE, HUNTER_VALVE, plc_irrigation_1, plc_slave_1.

local DEFAULT_SSH_HOST    = "pi@irrigation"
local DEFAULT_SSH_TIMEOUT = 8

local function shell_escape_single(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run_remote_python(ssh_host, timeout_s, py_code)
    local tmp = os.tmpname()
    local fh = io.open(tmp, "w")
    if not fh then return nil, "controller_client: cannot open tmp file" end
    fh:write(py_code)
    fh:close()
    local cmd = string.format(
        "ssh -o ConnectTimeout=%d -o BatchMode=yes %s 'python3 -' < %s 2>&1",
        timeout_s, ssh_host, shell_escape_single(tmp))
    local pipe = io.popen(cmd, "r")
    local raw = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    os.remove(tmp)
    return raw
end

-- popup_get(opts) — opts = { ssh_host, timeout_s }
-- Returns popup_table or nil, err.
function M.popup_get(opts)
    opts = opts or {}
    local ssh_host  = opts.ssh_host  or DEFAULT_SSH_HOST
    local timeout_s = opts.timeout_s or DEFAULT_SSH_TIMEOUT
    local py = string.format([[
import redis, msgpack, json, sys
r = redis.Redis(db=%d)
KEY = %q
h = r.hgetall(KEY)
if not h:
    sys.stdout.write(json.dumps({"_error": "popup hash empty"}))
    sys.exit(0)
out = {}
for kk, vv in h.items():
    k = kk.decode()
    try:
        out[k] = msgpack.unpackb(vv, raw=False)
    except Exception:
        try: out[k] = vv.decode()
        except: out[k] = repr(vv)
sys.stdout.write(json.dumps(out, default=str))
]], POPUP_DB, POPUP_KEY)
    local raw = run_remote_python(ssh_host, timeout_s, py)
    if not raw or raw == "" then
        return nil, "controller_client: popup ssh returned empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller_client: popup decode failed: " .. raw:sub(1, 200)
    end
    if decoded._error then
        return nil, "controller_client: " .. tostring(decoded._error)
    end
    return decoded
end

-- past_actions_tip(opts) — newest past_actions stream_id without payloads.
-- Used on first poll to skip historical entries (KB1/KB3 only cares about
-- state changes going forward).
function M.past_actions_tip(opts)
    opts = opts or {}
    local ssh_host  = opts.ssh_host  or DEFAULT_SSH_HOST
    local timeout_s = opts.timeout_s or DEFAULT_SSH_TIMEOUT
    local py = string.format([[
import redis, sys
r = redis.Redis(db=%d)
ents = r.xrevrange(%q, max='+', min='-', count=1)
if not ents:
    sys.stdout.write("")
else:
    sys.stdout.write(ents[0][0].decode())
]], PAST_ACTIONS_DB, PAST_ACTIONS_KEY)
    local raw = run_remote_python(ssh_host, timeout_s, py)
    if not raw or raw == "" then
        return nil, "controller_client: past_actions empty / unreachable"
    end
    return (raw:gsub("%s+$", "")), nil
end

-- past_actions_xrange(last_id, count_max, opts) — entries newer than last_id.
-- Returns (entries[], newest_seen_id) on success.
-- Each entry: { stream_id, action, level, details }.
-- last_id == nil or "" → "-" (entire stream). Use sparingly; first call only.
function M.past_actions_xrange(last_id, count_max, opts)
    opts = opts or {}
    local ssh_host  = opts.ssh_host  or DEFAULT_SSH_HOST
    local timeout_s = opts.timeout_s or DEFAULT_SSH_TIMEOUT
    local min_id = "-"
    if last_id and last_id ~= "" then
        min_id = "(" .. last_id   -- exclusive of last_id (Redis ≥ 6.2)
    end
    local n = count_max or 200
    local py = string.format([[
import redis, msgpack, json, sys
r = redis.Redis(db=%d)
KEY = %q
ents = r.xrange(KEY, min=%q, max='+', count=%d)
out = []
for sid, fields in ents:
    rec = {"stream_id": sid.decode()}
    for k, v in fields.items():
        ks = k.decode()
        try:
            rec[ks] = msgpack.unpackb(v, raw=False)
        except Exception:
            try: rec[ks] = v.decode()
            except: rec[ks] = repr(v)
    out.append(rec)
sys.stdout.write(json.dumps(out, default=str))
]], PAST_ACTIONS_DB, PAST_ACTIONS_KEY, min_id, n)
    local raw = run_remote_python(ssh_host, timeout_s, py)
    if not raw or raw == "" then
        return nil, "controller_client: past_actions ssh returned empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller_client: past_actions decode failed: " .. raw:sub(1, 200)
    end
    local entries = {}
    local newest = last_id
    for _, e in ipairs(decoded) do
        local data = e.data or {}
        entries[#entries+1] = {
            stream_id = e.stream_id,
            action    = data.action,
            level     = data.level,
            details   = data.details,
        }
        newest = e.stream_id
    end
    return entries, newest
end

-- time_history_bin(bin_key, opts) — newest run for a single bin.
-- The full TIME_HISTORY hash is ~8 MB; we HGET only one bin's bytes.
-- IMPORTANT: time_history stores compound keys in arbitrary valve order
-- (e.g. "satellite_4:6/satellite_4:8/satellite_1:39"), while past_actions
-- emits a different order ("satellite_1:39/satellite_4:6/satellite_4:8").
-- Direct HGET on the past_actions form misses the data; that bug let a
-- 50-sample pipe break on 4:6/4:8 go undetected. We resolve by matching
-- on the SORTED valve set rather than the literal field name.
function M.time_history_bin(bin_key, opts)
    if not bin_key or bin_key == "" then return nil, "bin_key empty" end
    opts = opts or {}
    local ssh_host  = opts.ssh_host  or DEFAULT_SSH_HOST
    local timeout_s = opts.timeout_s or DEFAULT_SSH_TIMEOUT
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
            v = r.hget(KEY, field)
            break
if v is None:
    sys.stdout.write(json.dumps({"_error": "bin not found in time_history"}))
    sys.exit(0)
runs = msgpack.unpackb(v, raw=False)
if not runs:
    sys.stdout.write(json.dumps({"_error": "bin has no runs"}))
    sys.exit(0)
newest = runs[-1]
hunter = newest.get("HUNTER_FLOW_METER") or {}
out = {
    "flow_data": hunter.get("data") or [],
    "n":         len(hunter.get("data") or []),
    "mean":      hunter.get("mean"),
    "sd":        hunter.get("sd"),
    "total":     hunter.get("total"),
    "n_runs":    len(runs),
}
sys.stdout.write(json.dumps(out, default=str))
]], TIME_HISTORY_DB, TIME_HISTORY_KEY, bin_key, bin_key)
    local raw = run_remote_python(ssh_host, timeout_s, py)
    if not raw or raw == "" then
        return nil, "controller_client: time_history_bin ssh returned empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller_client: time_history_bin decode failed: " .. raw:sub(1, 200)
    end
    if decoded._error then
        return nil, "controller_client: " .. tostring(decoded._error)
    end
    return decoded
end

-- mark_hunter_latest(bin_key, opts) — newest per-minute HUNTER_FLOW_METER
-- reading from the controller's IRRIGATION_MARK_DATA hash (the in-progress
-- run's binned data). This is the CORRECT GPM unit that matches the baseline
-- ceiling — popup.FILTERED_HUNTER_VALVE is a different scale (~2-3× lower
-- than the per-minute binned reading) and was causing KB3 / KB3-curve to
-- silently miss real over-baseline events on 2026-06-08 sat_3:15 (16 GPM
-- spike + 30+ min sustained 10-13 GPM never triggered any fire).
--
-- Returns { value = GPM_last_minute, n = sample_count } on success, or
-- (nil, err) on failure. Tries permutations of the bin_key to handle the
-- two-key-orderings gotcha [[two-key-orderings-2026-05-27]].
local MARK_DATA_DB  = 4
local MARK_DATA_KEY =
    "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]" ..
    "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]" ..
    "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_MARK_DATA]"

function M.mark_hunter_latest(bin_key, opts)
    if not bin_key or bin_key == "" then return nil, "bin_key empty" end
    opts = opts or {}
    local ssh_host  = opts.ssh_host  or DEFAULT_SSH_HOST
    local timeout_s = opts.timeout_s or DEFAULT_SSH_TIMEOUT
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
    sys.stdout.write(json.dumps({"_error": "bin not in mark_data"})); sys.exit(0)
d = msgpack.unpackb(v, raw=False)
hf = (d.get("HUNTER_FLOW_METER") or {}).get("data") or []
sys.stdout.write(json.dumps({"value": hf[-1] if hf else None, "n": len(hf)}))
]], MARK_DATA_DB, MARK_DATA_KEY, bin_key, bin_key)
    local raw = run_remote_python(ssh_host, timeout_s, py)
    if not raw or raw == "" then
        return nil, "controller_client: mark_hunter empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller_client: mark_hunter decode failed: " .. raw:sub(1, 200)
    end
    if decoded._error then
        return nil, "controller_client: " .. tostring(decoded._error)
    end
    return decoded
end

-- plc_xrange(start_ms, end_ms, opts) — fetch PLC_MEASUREMENTS_STREAM
-- samples between two ms-epoch boundaries. Returns
--   { samples = [{ sid_ms = INT, main_flow_meter, FILTERED_HUNTER_VALVE,
--                  HUNTER_HIRES_VALVE, plc_irrigation_1, plc_slave_1 }, ...] }
-- The stream auto-discovers via "*PLC_MEASUREMENTS_STREAM*" scan so we
-- don't hard-code the full bracketed key (it's long and unique enough).
function M.plc_xrange(start_ms, end_ms, opts)
    if not start_ms or not end_ms then
        return nil, "plc_xrange: start_ms / end_ms required"
    end
    opts = opts or {}
    local ssh_host  = opts.ssh_host  or DEFAULT_SSH_HOST
    local timeout_s = opts.timeout_s or DEFAULT_SSH_TIMEOUT
    local py = string.format([[
import redis, msgpack, json, sys
r = redis.Redis(db=%d)
KEY = None
for k in r.scan_iter(match="*PLC_MEASUREMENTS_STREAM*"):
    KEY = k; break
if KEY is None:
    sys.stdout.write(json.dumps({"_error": "PLC_MEASUREMENTS_STREAM not found"}))
    sys.exit(0)
ents = r.xrange(KEY, min="%d-0", max="%d-0", count=20000)
out = []
for sid, fields in ents:
    try:
        d = msgpack.unpackb(fields[b"data"], raw=False)
    except Exception as e:
        continue
    if not isinstance(d, dict):
        continue
    rec = {"sid_ms": int(sid.decode().split("-")[0])}
    for k in ("main_flow_meter","FILTERED_HUNTER_VALVE","HUNTER_HIRES_VALVE",
              "HUNTER_VALVE","plc_irrigation_1","plc_slave_1"):
        if k in d and d[k] is not None:
            rec[k] = float(d[k])
    out.append(rec)
sys.stdout.write(json.dumps({"samples": out}))
]], PLC_STREAM_DB, start_ms, end_ms)
    local raw = run_remote_python(ssh_host, timeout_s, py)
    if not raw or raw == "" then
        return nil, "controller_client: plc ssh empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller_client: plc decode failed: " .. raw:sub(1, 200)
    end
    if decoded._error then
        return nil, "controller_client: " .. tostring(decoded._error)
    end
    return decoded.samples or {}
end

return M
