# Data access — hosts, credentials, redis, sqlite, controller API

Exhaustive because you start cold: if it isn't written here, you can't reach it.
Verify hostnames/ports against `memory/state.md` (they can change per deploy).

## Hosts

| Name | Address | Role | Reach |
|---|---|---|---|
| **the Pi** | `ssh robot` → `pi@192.168.1.66` | Runs the `irrigation-analytics` container (the robot). PRODUCTION. | SSH |
| **the controller** | `ssh pi@irrigation` → `192.168.1.146` | The irrigation controller: Flask web app + Redis. Drives the valves. | SSH + HTTP |
| **dashboard** | `http://192.168.1.66:28080/` | The robot's web UI (LAN / VPN). | HTTP |

The Pi and the controller are **separate machines**. A dev-host (WSL) reboot does
NOT touch either. Production lives on the Pi.

## The robot container (on the Pi)

- Dir: `/home/pi/farm/irrigation_analytics/` — `fleet.env`, `start.sh`, `var/` bind mount.
- Container name: `irrigation-analytics`, restart `unless-stopped` + rc.local autostart.
- Logs: `ssh robot 'docker logs irrigation-analytics 2>&1 | tail -100'`
  (or `| grep -iE "WELL-DRAWDOWN|MANUAL-LOG|armed=true"`).
- **Status one-liner** (run this first after any reset):
  ```
  ssh robot 'docker ps --filter name=irrigation-analytics --format "{{.Image}} {{.Status}}"; \
    docker logs irrigation-analytics 2>&1 | grep -iE "armed=true|seeded.*non-ETO" | tail'
  ```
  Healthy = container Up; `kb3_sustained armed=true`; `kb1_overcurrent armed=true`;
  `kb4_clog seeded ... non-ETO baselines`.

## Redis on the controller (the data source of truth)

There is **no `redis-cli` on the Pi**, and the controller's redis is reached via
`ssh pi@irrigation`. Query with a small python over ssh (the pattern the robot uses):

```
ssh pi@irrigation 'python3 -c "
import redis, json
r = redis.Redis(db=4)
# ... r.get / r.lrange / msgpack.unpackb ...
"'
```

**db=4 — irrigation data** (keys are bracketed paths; grep with `r.keys(b\"*<name>*\")`):
| Key (substring) | What |
|---|---|
| `popup` | Current live snapshot: `PLC_FLOW_METER` = `main_flow_meter` = **WELL SOURCE flow**; current step/schedule; elapsed. |
| `PLC_MEASUREMENTS_STREAM` | Time series: `main_flow_meter` (well/PLC), `FILTERED_HUNTER_VALVE` (downstream, **lags**), `HUNTER_HIRES`. |
| `TIME_HISTORY` | Raw per-run arrays per bin. **Use `.data` (the raw array), NOT `.mean`.** Each bin is its own analysis unit. |
| `PAST_ACTIONS` | Event log incl. `IRRIGATION_STEP_COMPLETE` (use to delineate cycles / find what fired this cycle). |
| `IRRIGATION_VALVE_TEST` | Per-cycle solenoid resistance probe (proof-of-life only — see system-model). |
| `IRRIGATION_PENDING` | **The job queue** (a redis list). `push`=lpush(back); `pop`=rpop(**front**); so **rpush = the NEXT job to run**. This is what the recharge action writes to (via the controller API, NOT a raw redis write). |

Payloads are **msgpack** (`import msgpack; msgpack.unpackb(v, raw=False)`), not JSON.

**db=5 — web/users credentials** (for controller HTTP auth):
```
ssh pi@irrigation 'python3 -c "
import redis, json
r = redis.Redis(db=5); h = r.hgetall(\"web\")
users = json.loads(h[b\"users\"].decode())
for u,p in users.items(): print(u+\":\"+p); break
"'
```
This is `admin:password` for the controller's HTTP Digest auth. **Redact it** in any
output. The robot's `lib/ws_command.lua` already loads this the same way.

## The robot's own SQLite DBs (its analysis memory)

On the Pi: `/home/pi/farm/irrigation_analytics/var/` (host) = `/var/fleet/` (in container).
**No sqlite3 CLI on the Pi** — query via luajit + lsqlite3 inside the container:
```
ssh robot 'docker exec -i irrigation-analytics luajit -e "
local sql = require(\"lsqlite3\")
local db = sql.open(\"/var/fleet/kb4/kb4.db\")
for row in db:nrows(\"SELECT * FROM baselines_eto LIMIT 5\") do print(row.bin, row.gal_med) end
"'
```

| DB (in `/var/fleet/`) | Tables of interest |
|---|---|
| `kb4/kb4.db` | `baselines` (non-ETO), `baselines_eto`, `clog_observations` (+`action`,`action_applied`), `flow_within`/`flow_within_baseline`, `coil_onset`/`coil_onset_baseline`, `watch_list`, `manual_reset_log`. `phantom=1` marks sub-floor bins. |
| `kb2_wr/kb2_wr.db` | `runs_kb2_within` (within-run resistance/thermal). |
| `kb_alerts` (table, in the persistence DB) | every Discord-bound alert; PT-stamped. |

## Controller HTTP API (how you ACT)

All POSTs use **HTTP Digest** (creds from db=5) **AND `curl -b ''`** (empty cookie
engine). Flask's `HTTPDigestAuth` binds the auth nonce to the session cookie — without
`-b ''` you get `Unauthorized Access` / 401. The robot's `lib/ws_command.lua` already
does this; the exact curl is in `actions/`.

| Route (POST, `http://192.168.1.146<route>`) | Body | Effect |
|---|---|---|
| `/ajax/mode_change` | `{"command":"<CMD>","schedule_name":"","step":"","run_time":""}` | Issue a controller command. The server pushes to `IRRIGATION_JOB_SCHEDULING` and acts. |
| `/ajax/irrigation_queue_front` | a full IRRIGATION_STEP job JSON | **rpush** the job onto `IRRIGATION_PENDING` → it runs NEXT. (The well-recharge insert.) |

`mode_change` command vocab (`op_mode` switch on the controller):
`CLEAR`(⛔never) / `SKIP_STATION` / `QUEUE_SCHEDULE` / `QUEUE_SCHEDULE_STEP` /
`QUEUE_SCHEDULE_STEP_TIME_A` / `OPEN_MASTER` / `CLOSE_MASTER` / `CLEAN_FILTER` /
`RESISTANCE_CHECK` / `SUSPEND` / `RESUME` / `RESET_SYSTEM_QUEUE` / `RESET_SYSTEM_NOW`.

**Controller editing note:** the controller's Flask runs the Werkzeug auto-reloader,
so editing a `.py` there auto-reloads — no restart needed. Web procs are root-owned.
Still: test any change on a throwaway job first (Safety Rule 4).
