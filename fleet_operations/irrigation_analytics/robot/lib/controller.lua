-- controller.lua — talks to the LaCima irrigation controller (192.168.1.146).
--
-- Two reads per poll cycle:
--   popup_get()           one HGETALL of the popup hash, msgpack-decoded
--   past_actions_xrange() XRANGE from a saved stream_id forward, decoded
--
-- Both run as one-shot ssh+python invocations on `pi@irrigation`. That
-- matches the existing fetch_data.sh / fetch_time_history.sh pattern and
-- avoids HTTP Digest auth + LuaSec coupling on WSL.
--
-- Each call exits with an error string on failure rather than raising —
-- the caller decides whether to skip the cycle or back off.

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

local SSH_HOST  = "pi@irrigation"
local SSH_TIMEOUT_S = 8

local function shell_escape_single(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run_remote_python(py_code)
    -- Single-quote the heredoc body — no shell expansion on the local side.
    -- Pass the python to remote stdin to avoid quoting hell.
    local tmp = os.tmpname()
    local fh = io.open(tmp, "w")
    if not fh then return nil, "controller: cannot open tmp file" end
    fh:write(py_code)
    fh:close()
    local cmd = string.format(
        "ssh -o ConnectTimeout=%d -o BatchMode=yes %s 'python3 -' < %s 2>&1",
        SSH_TIMEOUT_S, SSH_HOST, shell_escape_single(tmp))
    local pipe = io.popen(cmd, "r")
    local raw = pipe and pipe:read("*a") or ""
    local _, _, exit_code = pipe and pipe:close() or false, nil, -1
    os.remove(tmp)
    return raw, exit_code
end

-- ---------------------------------------------------------------------------
-- popup_get — returns a flat table { SCHEDULE_NAME=..., PLC_IRRIGATION_CURRENT=..., ... }
-- ---------------------------------------------------------------------------
function M.popup_get()
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
    local raw, _ = run_remote_python(py)
    if not raw or raw == "" then
        return nil, "controller: popup ssh returned empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller: popup decode failed: " .. raw:sub(1, 200)
    end
    if decoded._error then
        return nil, "controller: " .. tostring(decoded._error)
    end
    return decoded
end

-- ---------------------------------------------------------------------------
-- past_actions_tip() — return current newest stream_id without payloads.
-- Used on first poll to skip historical entries (shadow mode only cares
-- about state changes going forward).
-- ---------------------------------------------------------------------------
function M.past_actions_tip()
    local py = string.format([[
import redis, sys
r = redis.Redis(db=%d)
ents = r.xrevrange(%q, max='+', min='-', count=1)
if not ents:
    sys.stdout.write("")
else:
    sys.stdout.write(ents[0][0].decode())
]], PAST_ACTIONS_DB, PAST_ACTIONS_KEY)
    local raw, _ = run_remote_python(py)
    if not raw or raw == "" then return nil, "controller: past_actions empty / unreachable" end
    return raw:gsub("%s+$", ""), nil
end

-- ---------------------------------------------------------------------------
-- time_history_bin(bin_key) — pull TIME_HISTORY[bin_key], return newest run.
-- The full TIME_HISTORY hash is ~8 MB; this pulls only one bin's bytes
-- (msgpack-decoded list of runs, we take the last one).
-- Returns {flow_data = [GPM, ...], n = int, mean = float, sd = float}
-- or nil, err on failure.
-- ---------------------------------------------------------------------------
local TIME_HISTORY_DB  = 4
local TIME_HISTORY_KEY =
    "[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]" ..
    "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]" ..
    "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]"

function M.time_history_bin(bin_key)
    if not bin_key or bin_key == "" then return nil, "bin_key empty" end
    -- The bin's hash key is the bin_key string (not the master hash key).
    -- Pull the field directly with HGET to avoid loading the entire 8 MB hash.
    -- IMPORTANT: time_history stores compound keys in arbitrary valve order
    -- (e.g. "satellite_4:6/satellite_4:8/satellite_1:39"), while past_actions
    -- emits a different order ("satellite_1:39/satellite_4:6/satellite_4:8").
    -- Direct HGET on the past_actions form misses the data; that bug let a
    -- 50-sample pipe break on 4:6/4:8 go undetected. We resolve by matching
    -- on the SORTED valve set rather than the literal field name.
    local py = string.format([[
import redis, msgpack, json, sys
r = redis.Redis(db=%d)
KEY = %q
WANT = sorted(%q.split("/"))
# Fast path: try the literal name first.
v = r.hget(KEY, %q)
if v is None:
    # Fallback: scan field names, match on sorted-valve-set.
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
    local raw, _ = run_remote_python(py)
    if not raw or raw == "" then
        return nil, "controller: time_history_bin ssh returned empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller: time_history_bin decode failed: " .. raw:sub(1, 200)
    end
    if decoded._error then
        return nil, "controller: " .. tostring(decoded._error)
    end
    return decoded
end

-- ---------------------------------------------------------------------------
-- past_actions_xrange(last_id) — pull entries newer than last_id.
-- Returns (entries[], newest_seen_id) on success.
-- Each entry: { stream_id, action, level, details }.
-- last_id == nil or "" → "-" (entire stream). Use sparingly; first call
-- only.
-- ---------------------------------------------------------------------------
function M.past_actions_xrange(last_id, count_max)
    local min_id = "-"
    if last_id and last_id ~= "" then
        -- XRANGE is inclusive of min; bump last_id by appending '+1' on the seq part
        -- Simpler: use "(<id>" exclusive syntax (XRANGE supports it since Redis 6.2)
        min_id = "(" .. last_id
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
    local raw, _ = run_remote_python(py)
    if not raw or raw == "" then
        return nil, "controller: past_actions ssh returned empty"
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok then
        return nil, "controller: past_actions decode failed: " .. raw:sub(1, 200)
    end
    -- Flatten: stream entries store everything as one dict (the `data` field
    -- holds the action body, alongside stream_id).
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

return M
