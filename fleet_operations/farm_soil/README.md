# farm_soil — soil-moisture monitoring robot

A standalone LuaJIT chain_tree robot that ingests LoRaWAN soil-sensor data
from The Things Network and publishes it onto a local Zenoh fabric. The
LuaJIT port of the Python `robot_person/skills/lorwan_moisture` skill —
rebuilt as a real fleet_design robot.

## Operating mode — standalone (decision #17)

This system operates **independent of system/node control and its
namespace** — no DCS, no platform Postgres / MQTT / NATS, no master-KB
registration (#19 is managed-mode and does not apply). The Zenoh container
is a *local* server for these robots. SQLite3 is the only database. A farm
has spotty connectivity; the system is a self-sufficient island.

## Shape

- **Skill modules** (engine-agnostic, `lib/`) — `decoder.lua` (TTN SSE +
  SenseCAP S2105 frame parsing), `ttn_client.lua` (HTTPS GET to TTN, via
  `curl`).
- **The moisture skill is a KB** (`chains/`) — a chain_tree column scheduled
  by the time-of-day window leaves: fetch the TTN lookback → `get` the
  `recent` slot from zenohd → reconcile new uplinks by timestamp → `put` the
  updated `recent` slot + the `latest` slot back. The robot is **stateless** —
  nothing is stored in its KB/blackboard between ticks; the Zenoh slots are
  the source of truth.
- **KB0** — the shared connection manager; also receives per-app-KB
  heartbeats so the robot's published heartbeat is health-aware.

## Namespace (per sensing point, on the local zenohd)

```
farm_soil/<instance>/<device>/<location>/latest    one uplink record, timestamped
farm_soil/<instance>/<device>/<location>/recent    256-deep ring of uplink records
```

Devices are dynamic — a `<device>/<location>` subtree appears the first time
that device is seen in the TTN stream; adding a sensor is one config entry.

## Data flow

robot → local zenohd (`latest` + `recent` slots, memory-only) → persistence
app subscribes `**/latest`, integrates by timestamp, writes the central
SQLite store → local web servers read the SQLite. The persistence SQLite is
the **only durable copy** — WAL mode + a backup cadence are required.

## Build status

- [x] slice 1 — `lib/decoder.lua` + tests
- [ ] slice 2 — `lib/ttn_client.lua`
- [ ] slice 3 — robot scaffold (`main.lua`, `run.sh`, `class_spec.lua`)
- [ ] slice 4 — the moisture KB (`chains/`) — forces the shared-KB0 decision
- [ ] slice 5 — KB0 app-KB heartbeat (`connection.lua`)
- [ ] persistence app + local web servers (separate, `server/` layers)

## Secrets

`secrets/ttn.env` (gitignored) holds `TTN_BEARER_TOKEN`; `run.sh` sources it.
Copy `secrets/ttn.env.example` to start.
