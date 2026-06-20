# Architecture

## The wire

Everything inside the container talks **Zenoh** (router-routed inside a
container, peer-to-peer between containers if/when there are multiple
geographic complexes). Three Zenoh primitives are used:

* **pub/sub** — robot heartbeats, moisture readings, CIMIS samples,
  rancho usage samples, digest payloads.
* **token-RPC** — persistence query, robot registration. Tokens are
  FNV1a-32 hashes of well-known keyexprs (`fleet/persistence/query`,
  `fleet/admin/...`).
* **fleet-wide discovery channel** — `fleet/admin/persistence_topology_announce`,
  `fleet/admin/persistence_service_announce`. The well-known one-way
  back-and-forth that lets persistence discover whatever robots
  happen to be alive.

There is no MQTT, no NATS, no Postgres in this stack. SQLite + Zenoh
only. A farm site has spotty WAN connectivity; the robots are
designed to be a self-sufficient island.

## The container's process tree

```
tini (PID 1)
└─ /app/start.sh         ← supervisor (`packaging/container/start.sh`)
   ├─ zenohd             ← Zenoh router
   ├─ fleet_manager      ← controller (register RPC + heartbeat)
   ├─ persistence        ← SQLite store + query RPC
   ├─ application_gateway ← HTTP front-end + dashboard SPA
   ├─ notification_service ← Discord push
   ├─ farm_soil          ← LuaJIT robot (one per class instance)
   └─ rancho_water       ← LuaJIT robot
```

Whole-container restart on any child crash (`docker run
--restart=unless-stopped`). Per-process self-heal was rejected in
favor of supervisor simplicity.

## Why the staggered startup

Naive parallel launch exposed a fatal race: the persistence service's
discovery sub on `fleet/admin/persistence_topology_announce` declared
~400 ms after persistence started. Robots publishing topology in those
first 200 ms got their messages **silently dropped** (zenoh-pico is
fire-and-forget; no subscriber at delivery time means no message).

The container supervisor now stages launches:

| Phase | At | Process |
|---|---|---|
| 1 | 0 s | zenohd |
| 2 | +60 s | fleet_manager |
| 3 | +75 s | persistence, application_gateway, notification_service |
| 4 | +105 s | robot processes |

Total cold-boot ~110 s. Paid once per container start. Robots only
come up after every back-office service has had 30 s to settle.

## Robot internal shape (chain_tree_luajit)

Every robot follows the same pattern:

```
main.lua
└─ KB0 (the bring-up / supervisor KB — robot_common/chains/connection.lua)
   ├─ open zenoh session
   ├─ register with fleet_manager (one-shot RPC)
   ├─ publish persistence topology (so the persistence service can declare subs)
   ├─ wait 15 s (defensive — even staggered startup keeps this slack)
   └─ spawn app KBs:
      ├─ moisture       (farm_soil)
      ├─ cimis          (farm_soil)
      ├─ digest         (farm_soil)
      └─ daily_pull     (rancho_water)
```

Each app KB stamps an `app_heartbeats[name]` entry in the robot's
blackboard once per work cycle; KB0 rolls those into the per-robot
published heartbeat. KB0 is the only KB that knows about the
controller.

## Persistence layer

Two-phase apply_topology:

1. `diff_topology()` — fast, returns added/removed leaves from the
   topology announce.
2. Persistence opens zenoh subs for newly-added leaves immediately.
3. `reconcile_schema()` — slow (DB schema mutation via `construct_kb`
   `add_*_field` per leaf).

Messages arriving during the slow phase buffer in the zenoh sub
queue (depth 64). The order matters — opening subs before slow
schema work is the fix for the zero-stream-capture bug surfaced
during the 2026-05-24 containerization arc.

Schema is **declared by each robot** via `class_spec.persistence_topology()`
— the persistence service is robot-agnostic; it builds whatever
ltree paths the robots announce. Status leaves (`heartbeat`,
`<source>/latest`) UPSERT in place; stream leaves are
fixed-size rings (`length` per declaration).

## Why no auth (yet)

Inside a container, all comms are localhost. The dashboard binds
0.0.0.0 only on Pi (where LAN reachability is the point). The
gateway has **no auth today** — port-obscurity is the current
mitigation (see `dashboard_port_obscurity_todo` memory).
Real fix is HTTP basic / session-token auth on the gateway.
