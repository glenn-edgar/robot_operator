# Robot classes

A robot class is a directory under `fleet_design/` with a
`class_spec.lua`, a `main.lua`, and a `chains/` folder. Today's
classes:

## farm_soil

LoRaWAN soil-moisture monitoring with CIMIS daily evapotranspiration
context, plus an operator-facing daily digest. Standalone — works
without WAN once the TTN poll has run.

**App KBs:**

* **`moisture`** — fetches TTN uplinks (`limit` per cycle from
  `class_spec.ttn`), parses SenseCAP S2105 frames, dedups against
  the per-slot ring (`ring_append` by `received_at`), publishes each
  genuinely-new reading on `<namespace>/<device>/<location>/latest`,
  and persists the ring to disk after every append.
  Cadence: every 3600 s.
* **`cimis_station`** — pulls daily ETo from the CIMIS station data
  source. Daily-gated state machine (4 gates: already-published →
  pre-window → fetch → publish).
* **`cimis_spatial`** — same module, different KB instance, pulls
  the spatial (grid) ETo source.
* **`digest`** — daily one-shot at the configured Pacific hour
  (default 09:00). Reads moisture rings + CIMIS state from the
  blackboard, formats a table, publishes on
  `fleet/notify/digest/daily`. Now disk-marker-gated so container
  restarts don't re-fire.

**Persistence topology:**

```
farm_soil_<instance>.stream.cimis.station.sample        (length=30)
farm_soil_<instance>.stream.cimis.spatial.sample        (length=30)
farm_soil_<instance>.status.cimis.station.latest
farm_soil_<instance>.status.cimis.spatial.latest
farm_soil_<instance>.stream.<device>.<location>.latest  (length=256)
farm_soil_<instance>.status.heartbeat
```

**Secrets required:**

* `TTN_BEARER_TOKEN` — TTN application API key.

**Config keys** (see `class_spec.lua`):

* `ttn.url_base`, `ttn.app_name`, `ttn.lookback_hours`, `ttn.limit`
* `cimis.sources` — table of `{ source_id, target_kind, target }`
* `device_locations` — table mapping TTN device ID → operator-friendly location
* `digest.hour_pacific`, `digest.retry_s`

See `fleet_design/farm_soil/README.md` for the longer-form class
spec, including the standalone-operation decision (#17) and the
zenoh-pico per-sample-publish constraint (multi-KB payloads silently
drop — verified on bench).

## rancho_water

Daily scrape of a customer's Rancho California Water District portal,
publishes hourly-usage + daily total + Rancho's own anomaly flags
(LeakDetected, ExceededFlowThreshold, etc).

**App KBs:**

* **`daily_pull`** — daily one-shot at the configured Pacific hour
  (default 09:00). Fetches yesterday's usage from the portal,
  publishes a digest body to `fleet/notify/digest/daily` and the
  same envelope (compact form — hourly array trimmed to `{h,gph,gpm}`)
  to the persistence stream + status leaves.

  The portal is JSON REST under a thin ASP.NET shell —
  `/api/usage/get/` returns the per-day numbers. **curl gotcha**:
  never `--request=POST` alongside `data-urlencode` — forces POST on
  redirect, which strips the body and returns 411. Use POST implicit
  via data.

**Persistence topology:**

```
rancho_water_<instance>.stream.usage.sample    (length=30)
rancho_water_<instance>.status.usage.latest
rancho_water_<instance>.status.heartbeat
```

**Secrets required:**

* `RANCHO_WATER_ACCOUNT` — account number
* `RANCHO_WATER_PASSWORD` — portal password

**Config keys:**

* `rancho.account_number` — alphanumeric account id (the portal also
  needs this even though credentials are also set)
* `rancho.timeout_s`
* `digest.hour_pacific`, `digest.retry_s`

## Adding a new class

1. Mirror an existing class's directory layout (`lib/`, `chains/`,
   `class_spec.lua`, `main.lua`, `run.sh`).
2. Implement the data source (HTTP fetch, hardware poll, whatever).
3. Define `class_spec.persistence_topology()` — declare the ltree
   leaves your class will publish.
4. Wire one or more app-KBs (`chains/<name>.lua` +
   `chains/<name>_user_functions.lua`).
5. Add a launcher line in `packaging/container/start.sh` and a
   `Dockerfile` `COPY <class>` line.
6. Rebuild the image. The persistence layer will discover the new
   topology and add the schema on next robot boot.

The shared `robot_common/` code (KB0 + identity + clock + heartbeat
+ daily_marker) handles the framework concerns; the class only
contains its domain-specific logic.
