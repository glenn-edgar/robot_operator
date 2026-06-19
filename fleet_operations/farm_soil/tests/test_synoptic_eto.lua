-- tests/test_synoptic_eto.lua — bench test for the new ETo subsystem.
--
-- WSL bench validation. Three sections:
--   1. lib/synoptic_eto.lua — live pull for SE224 + SRUC1 on a known-good
--      date (2026-05-30) and compare against handoff-validated numbers.
--   2. cache_dir behavior — second call must return from_cache=true.
--   3. eto_resolver priority logic — synthetic blackboard scenarios:
--      (a) all four sources OK         -> SE224 wins
--      (b) SE224 SPARSE                -> cimis_spatial wins
--      (c) SE224 + spatial both stale  -> SRUC1 wins
--      (d) only cimis_station ok       -> cimis_station wins
--      (e) nothing eligible            -> verdict carries fall-through reasons
--
-- Run:  cd farm_soil && LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;" \
--       LUA_PATH="lib/?.lua;chains/?.lua;../robot_common/lib/?.lua;;" \
--       SYNOPTIC_TOKEN=<token> luajit tests/test_synoptic_eto.lua
--
-- DOES NOT touch Zenoh, the controller, or the robot pump.

local synoptic_eto = require("synoptic_eto")

local fail_count = 0
local function check(label, ok, detail)
    if ok then
        print(string.format("  PASS  %s", label))
    else
        print(string.format("  FAIL  %s — %s", label, detail or "(no detail)"))
        fail_count = fail_count + 1
    end
end

local function approx(a, b, tol) return math.abs(a - b) <= (tol or 0.001) end

-- ---------------------------------------------------------------------------
-- Section 1 — live Synoptic API pulls
-- ---------------------------------------------------------------------------
print("[1] Live API: SE224 + SRUC1 on 2026-05-30 (expected 0.205 / 0.236)")
do
    local se224, e1 = synoptic_eto.daily_eto("SE224", "2026-05-30")
    check("SE224 daily_eto returned", se224 ~= nil, tostring(e1))
    if se224 then
        check(string.format("SE224 ETo=%.3f ≈ 0.205", se224.eto),
              approx(se224.eto, 0.205, 0.002), "got " .. tostring(se224.eto))
        check("SE224 n_obs == 144 (10-min × 24h)",
              se224.n_obs == 144, "got " .. tostring(se224.n_obs))
        check("SE224 status == OK", se224.status == "OK", se224.status)
        check("SE224 interval == 600", se224.interval == 600,
              tostring(se224.interval))
    end

    local sruc1, e2 = synoptic_eto.daily_eto("SRUC1", "2026-05-30")
    check("SRUC1 daily_eto returned", sruc1 ~= nil, tostring(e2))
    if sruc1 then
        check(string.format("SRUC1 ETo=%.3f ≈ 0.236", sruc1.eto),
              approx(sruc1.eto, 0.236, 0.002), "got " .. tostring(sruc1.eto))
        check("SRUC1 n_obs == 24 (hourly × 24h)",
              sruc1.n_obs == 24, "got " .. tostring(sruc1.n_obs))
        check("SRUC1 status == OK", sruc1.status == "OK", sruc1.status)
    end
end

-- ---------------------------------------------------------------------------
-- Section 2 — cache_dir behavior
-- ---------------------------------------------------------------------------
print("[2] cache_dir: 1st call writes, 2nd call reads from disk")
do
    local cache = "/tmp/synoptic_test_cache_" .. os.time()
    os.execute("mkdir -p " .. cache)
    local r1 = synoptic_eto.daily_eto("SRUC1", "2026-05-30", { cache_dir = cache })
    check("1st call returns result", r1 ~= nil)
    check("1st call from_cache == false",
          r1 and r1.from_cache == false, "from_cache=" .. tostring(r1 and r1.from_cache))
    local fh = io.open(cache .. "/SRUC1_2026-05-30.csv", "r")
    check("cache file written", fh ~= nil)
    if fh then fh:close() end

    local r2 = synoptic_eto.daily_eto("SRUC1", "2026-05-30", { cache_dir = cache })
    check("2nd call returns result", r2 ~= nil)
    check("2nd call from_cache == true",
          r2 and r2.from_cache == true, "from_cache=" .. tostring(r2 and r2.from_cache))
    check("cached ETo matches live ETo",
          r1 and r2 and approx(r1.eto, r2.eto),
          string.format("live=%.6f cached=%.6f",
              r1 and r1.eto or -1, r2 and r2.eto or -1))
    os.execute("rm -rf " .. cache)
end

-- ---------------------------------------------------------------------------
-- Section 3 — eto_resolver priority logic
-- ---------------------------------------------------------------------------
print("[3] eto_resolver: priority chain")

-- Minimal harness: simulate the user-fn's environment with a synthetic bb +
-- a fake pubsub that captures publishes. We invoke the one_shot directly.
local resolver_fns = require("eto_resolver_user_functions")
local cjson = require("cjson")

-- Fake clock — pin California today/yesterday + hour. The user-fn reads
-- clock.california_yesterday() and clock.pacific_now(); replace the module
-- table for the duration of the test.
local clock = require("clock")
local saved = { y = clock.california_yesterday, p = clock.pacific_now }

local function pin_clock(yesterday, hour)
    clock.california_yesterday = function() return yesterday end
    clock.pacific_now = function()
        return { hour = hour, minute = 0, is_dst = true }
    end
end

local function unpin_clock()
    clock.california_yesterday = saved.y
    clock.pacific_now          = saved.p
end

-- Fake pubsub: captures every publish so we can inspect.
local function make_pubsub()
    local pub = { msgs = {} }
    function pub:publish(key, payload)
        self.msgs[#self.msgs + 1] = { key = key, payload = payload }
    end
    return pub
end

-- Stub app_heartbeat: avoid filesystem side effects. We don't assert
-- heartbeat shape here — only the resolution outcome.
local app_heartbeat = require("app_heartbeat")
local saved_stamp = app_heartbeat.stamp
app_heartbeat.stamp = function(_h, _label, _state, _msg, _retry) end

-- Build a minimal handle + class_spec + identity for each scenario.
local function make_handle(scenario)
    local bb = {
        _identity   = { class = "farm_soil", instance = "test01",
                        namespace = "fleet/farm_soil/test01" },
        _pubsub     = make_pubsub(),
        _class_spec = {
            eto_resolver = {
                retry_s = 900, min_coverage = 0.85,
                priority = { "SE224", "cimis_spatial", "SRUC1", "cimis_station" },
            },
        },
        _synoptic = {
            SE224 = scenario.SE224 and { last_record = scenario.SE224 } or {},
            SRUC1 = scenario.SRUC1 and { last_record = scenario.SRUC1 } or {},
        },
        _cimis = {
            station = scenario.cimis_station
                and { last_record = scenario.cimis_station } or {},
            spatial = scenario.cimis_spatial
                and { last_record = scenario.cimis_spatial } or {},
        },
    }
    return { blackboard = bb }
end

local function get_resolution(handle)
    local msgs = handle.blackboard._pubsub.msgs
    for _, m in ipairs(msgs) do
        if m.key:find("/eto/daily") then return cjson.decode(m.payload) end
    end
    return nil
end

pin_clock("2026-05-30", 14)

-- Scenario (a): all OK -> SE224 wins
do
    local h = make_handle({
        SE224 = { eto = 0.205, date = "2026-05-30", status = "OK", coverage = 1.0, n_obs = 144 },
        SRUC1 = { eto = 0.236, date = "2026-05-30", status = "OK", coverage = 1.0, n_obs = 24 },
        cimis_spatial = { value = 0.23, date = "2026-05-30" },
        cimis_station = { value = 0.24, date = "2026-05-30" },
    })
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local r = get_resolution(h)
    check("(a) all-ok publishes /eto/daily", r ~= nil)
    check("(a) winner == SE224", r and r.source == "SE224", r and r.source)
    check("(a) eto_in == 0.205", r and approx(r.eto_in, 0.205), tostring(r and r.eto_in))
    check("(a) fallback_chain has all 4 entries",
          r and #r.fallback_chain == 4, r and #r.fallback_chain)
end

-- Scenario (b): SE224 SPARSE -> cimis_spatial wins
do
    local h = make_handle({
        SE224 = { eto = 0.21, date = "2026-05-30", status = "SPARSE", coverage = 0.40, n_obs = 58 },
        SRUC1 = { eto = 0.236, date = "2026-05-30", status = "OK", coverage = 1.0, n_obs = 24 },
        cimis_spatial = { value = 0.23, date = "2026-05-30" },
        cimis_station = { value = 0.24, date = "2026-05-30" },
    })
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local r = get_resolution(h)
    check("(b) SE224-sparse: spatial wins",
          r and r.source == "cimis_spatial", r and r.source)
    -- First chain entry must reflect SE224's "sparse" verdict
    check("(b) chain[1].verdict == 'sparse'",
          r and r.fallback_chain[1].verdict == "sparse",
          r and r.fallback_chain[1].verdict)
end

-- Scenario (c): SE224 + spatial both stale -> SRUC1 wins
do
    local h = make_handle({
        SE224 = { eto = 0.19, date = "2026-05-29", status = "OK", coverage = 1.0, n_obs = 144 },
        SRUC1 = { eto = 0.236, date = "2026-05-30", status = "OK", coverage = 1.0, n_obs = 24 },
        cimis_spatial = { value = 0.22, date = "2026-05-28" },
        cimis_station = { value = 0.24, date = "2026-05-30" },
    })
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local r = get_resolution(h)
    check("(c) SE224/spatial stale: SRUC1 wins",
          r and r.source == "SRUC1", r and r.source)
end

-- Scenario (d): only cimis_station eligible
do
    local h = make_handle({
        SE224 = nil,
        SRUC1 = { eto = 0.22, date = "2026-05-29", status = "OK", coverage = 1.0, n_obs = 24 },
        cimis_spatial = nil,
        cimis_station = { value = 0.24, date = "2026-05-30" },
    })
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local r = get_resolution(h)
    check("(d) only-cimis_station: it wins",
          r and r.source == "cimis_station", r and r.source)
end

-- Scenario (e): nothing eligible -> no publish, chain captured in state
do
    local h = make_handle({
        SE224 = nil,
        SRUC1 = { eto = 0.22, date = "2026-05-29", status = "OK", coverage = 1.0, n_obs = 24 },
        cimis_spatial = { value = 0.22, date = "2026-05-28" },
        cimis_station = nil,
    })
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local r = get_resolution(h)
    check("(e) no eligible -> no /eto/daily publish", r == nil)
    -- Chain summary lives on the bb so external observers can see why
    check("(e) bb._eto_resolver.last_chain populated",
          h.blackboard._eto_resolver and h.blackboard._eto_resolver.last_chain ~= nil)
end

-- Scenario (f): idempotency — second tick same day same winner = no republish
do
    local h = make_handle({
        SE224 = { eto = 0.205, date = "2026-05-30", status = "OK", coverage = 1.0, n_obs = 144 },
        SRUC1 = { eto = 0.236, date = "2026-05-30", status = "OK", coverage = 1.0, n_obs = 24 },
        cimis_spatial = { value = 0.23, date = "2026-05-30" },
        cimis_station = { value = 0.24, date = "2026-05-30" },
    })
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local first_count = #h.blackboard._pubsub.msgs
    resolver_fns.registry.one_shot.ETO_RESOLVE_TICK(h)
    local second_count = #h.blackboard._pubsub.msgs
    check("(f) 2nd tick same-day same-winner skips republish",
          first_count == second_count,
          string.format("1st=%d 2nd=%d", first_count, second_count))
end

unpin_clock()
app_heartbeat.stamp = saved_stamp

-- ---------------------------------------------------------------------------
print()
if fail_count == 0 then
    print("ALL TESTS PASSED")
    os.exit(0)
else
    print(string.format("%d TEST(S) FAILED", fail_count))
    os.exit(1)
end
