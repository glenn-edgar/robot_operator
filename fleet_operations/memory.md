# Robot Fleet Management Design — Locked Decisions

**Originally locked:** 2026-05-18 (decisions #1–#26)
**Amended:** 2026-05-19 (decisions #27–#32 — see top section below)
**Status:** Design phase complete; first code landed in `fake_robot/` + `bench_manager/`.
**Companion file:** `continue.md` (current state, open questions, next-session work)

---

## 2026-05-19 Amendments — Decisions #27–#32

**These decisions amend and partially override the 2026-05-18 base.** Read this section first; in-line ⚠️ markers below flag where the base text has been superseded.

### #27 — Identity loaded out-of-band, NOT via Zenoh commissioning (OVERRIDES #23)

**Rescinds the runtime over-Zenoh commissioning flow from the original Fake Robot section.** No more `fleet/uncommissioned/<uid>/announce`-and-wait-for-assignment-then-re-exec choreography.

Hybrid C scheme (operator-config in env, process-managed state in file):

- `ROBOT_CLASS` — env, **required**, fail-fast if missing
- `ROBOT_INSTANCE` — env, **required**, fail-fast if missing
- `IDENTITY_DIR` — env, optional, default `./identity`; dir auto-created
- `$IDENTITY_DIR/state.json` — JSON `{chip_uid, first_seen, fw_version}`; `chip_uid` is UUID v4 auto-generated on first boot from `/dev/urandom`, written-through, never changes after.

Shared by all Linux robots. Implementation: `fake_robot/lib/identity.lua`.

**Why:** runtime Zenoh-commissioning was over-engineered avoidance of mqtt_robot debt. Out-of-band identity matches mqtt_robot's actual precedent and the USB commissioning tool pattern — operational robots never commission themselves; a standalone production tool does it.

### #28 — Pi Zero 2 is bare-process target (no containers)

Hybrid C identity scheme works identically under `docker run` or under systemd unit / shell launcher; the bootstrap reads env from the process environment regardless of launcher.

**Why:** Pi Zero 2 W has 512 MB RAM; Docker overhead unacceptable.

### #29 — Controller merely acknowledges connection

Controller (fleet_manager) does NOT validate class registration, NOT enforce instance uniqueness, NOT issue NACKs. Just ACKs that it saw the announce. Uniqueness is an operator concern.

**Why:** robot is sovereign per encapsulation model (decisions #1, #9). Controller is a passive registry.

### #30 — ACK wire shape: Zenoh RPC on `fleet/admin/register`

- Client (robot): `cli:call(zt.hash("fleet/admin/register"), payload, timeout_ms=5000)` — synchronous-blocking with timeout.
- Server (fleet_manager): queryable registered on the same token.
- Request payload (JSON): `{class, instance, chip_uid, fw_version, capabilities, ts}`.
- Reply payload (JSON): `{ok: true, controller_id, ts, echo_chip_uid}`.

Uses existing `zenoh_rpc.lua` binding atop `libzenoh_rpc.so`. NACK path not in scope. Timeout → retry-with-backoff is the only failure path.

### #31 — Namespace setup: core leaves + `on_namespace_up` class hook

**Core leaves every Linux robot declares (foundational, owned by the shared connection KB):**

| Direction | Leaf | Payload (JSON) | Cadence |
|---|---|---|---|
| pub | `<class>/<instance>/state` | `{state, ts, reason?}` — state ∈ `initializing\|ready\|operating\|degraded\|fault` | on transition |
| pub | `<class>/<instance>/heartbeat` | `{seq, ts}` | 1 Hz |
| pub | `<class>/<instance>/capabilities` | `[action_id, ...]` | once on `namespace_up` entry; re-published after each successful register |
| pub | `<class>/<instance>/hardware` | `{chip_uid, fw_version, first_seen}` | once on `namespace_up` entry |
| sub | `<class>/<instance>/desired_state` | `{state}` from fleet_manager | — |

**Initial publish sequence on entering `namespace_up`:**
1. publish `capabilities`
2. publish `hardware`
3. publish `state = "ready"`
4. invoke class hook `on_namespace_up(session, identity, bb)`
5. transition to `operating`
6. start 1 Hz heartbeat KB

Heartbeat content is `{seq, ts}` only — NOT `{seq, ts, state}`. State subscribers subscribe to `state` directly.

**Class-specific extension:** each class ships a `class_spec.lua` returning `{capabilities, on_namespace_up = fn(session, identity, bb)}`. `main.lua` `require`s the spec based on `ROBOT_CLASS`.

**Token-name convention:** `fleet/admin/<verb>[_<object>]` (e.g., `fleet/admin/register`, `fleet/admin/heartbeat`, `fleet/admin/list_classes`, `fleet/admin/list_instances`). Robot-namespace topics stay `<class>/<instance>/<leaf>`.

### #32 — Disconnect detection via passive controller heartbeat

Controller publishes `fleet/admin/heartbeat` at 1 Hz with `{seq, ts}` — symmetric with robot heartbeat. Robot subscribes on entry to `operating`, tracks `last_heartbeat_seen_ts`. If `now - last_heartbeat_seen_ts > 3 s` (3 missed heartbeats), emit `EV_DISCONNECTED` → KB transitions back to `connecting`.

Active-probe options (RPC ping) were considered and rejected — `:call` is blocking and interrupts the tick cadence; passive subscribe is non-blocking and fits the existing poll loop.

**Reconnect policy:** on `EV_DISCONNECTED`, close the Zenoh session, reopen it, restart from `announced` (call register again). Fresh session, no stale-state edge cases.

**First-heartbeat-after-register:** start the no-heartbeat timer at register-success time; same 3 s window applies.

### #33 — Two-clock model: monotonic ms + wall-clock REALTIME

Both clocks live in `fake_robot/lib/clock.lua`. Different jobs, different primitives:

- **`clock.now_ms()`** — `CLOCK_MONOTONIC`, integer milliseconds. For elapsed-time math: disconnect-watch, backoff, heartbeat-publish cadence. Immune to NTP/manual/VM clock jumps. Lua double holds int64 ms without precision loss for ~285k years. Blackboard fields end in `_ms`.
- **`clock.wall_now()`** — `CLOCK_REALTIME` + `os.date("!*t")` gmtime breakout. Same shape as C `cfl_time_info_t`: `{year, month, day, dow (Mon=0..Sun=6), doy, hour, minute, second, epoch_s (fractional double)}`. For ts fields on the wire AND boundary-event emission.

**Boundary events emitted by main.lua's pump.** Each tick, the pump compares current `wall_now()` to previous-tick `wall_now()` and pushes `CFL_SECOND_EVENT` / `CFL_MINUTE_EVENT` / `CFL_HOUR_EVENT` / `CFL_DAY_EVENT` / `CFL_MONTH_EVENT` / `CFL_YEAR_EVENT` (event IDs 5–11 from `ct_definitions.lua`) for each changed field, with `event_data` carrying the wall snapshot. Connection KB ignores these (only handles `CFL_TIMER_EVENT`); class-specific KBs use them for cron-style scheduling.

**Clock-jump guard.** On any tick where `|wall_delta_ms - mono_delta_ms| > 1000`, boundary events are suppressed with a one-line warning. Protects against Pi Zero 2 NTP-step cascades (clock jumping from 1970 to current year would otherwise fire every boundary at once).

**Why the split:**
- `CLOCK_REALTIME` alone is wrong for elapsed-time math (jumps wedge timeouts).
- `CLOCK_MONOTONIC` alone is wrong for scheduled tasks (no calendar awareness).
- Precedent: `libcomm/comm.c:118 comm_now_ms()` uses `CLOCK_MONOTONIC`; `ct_builtins.lua:1160 wall_timestamp()` uses `CLOCK_REALTIME`. Two-clock honors both.

### Code landed (2026-05-19)

```
fake_robot/
  main.lua                              chain_tree pump (10 Hz default) +
                                        wall-clock boundary event emission
  class_spec.lua                        generic fake_robot spec (stub on_namespace_up)
  chains/
    connection.lua                      DSL: blackboard + 1-col KB
                                        (timing fields end in _ms, monotonic)
    connection_user_functions.lua       FULL state machine — connecting / ack'd /
                                        namespace_up / operating / disconnected all real
    connection.json                     compiled IR (15 nodes)
  lib/
    identity.lua                        env+file identity load (decision #27)
    zenoh_session.lua                   thin wrapper over libzenoh_pubsub
    zenoh_rpc_session.lua               thin wrapper over libzenoh_rpc client
    clock.lua                           POSIX two-clock readers (decision #33)
bench_manager/
  main.lua                              throwaway stub controller:
                                          RPC queryable on fleet/admin/register
                                          publisher on fleet/admin/heartbeat @1 Hz
```

End-to-end smoke tests verified:
- Happy path through all five states with real publishes/subscribes
- bench_manager kill → 3 s disconnect detection → session reopen → register retry with backoff
- bench_manager restart → register recovery → back to operating
- 90 s wall-clock-boundary run captured `CFL_MINUTE_EVENT @ 2026-05-19 20:16:00 UTC` at the exact minute boundary; 10 SECOND events per 10 s confirmed

### First chain_tree KB shape — connection state machine

States: `disconnected → connecting → announced → ack'd → namespace_up → operating`. Disconnect event loops back to `connecting`. Shared by all Linux robots (foundational; chains/ graduates per decision #26).

**This is NOT a commissioning state machine** — commissioning is gone (decision #27).

### Vendor pattern (2026-05-19)

Pi Zero 2 will receive a partial-repo pull and must not depend on any
upstream `~/knowledge_base_assembly/` paths at runtime. Lua-side runtime
files are vendored into `fleet_design/vendor/lua/` (11 files, ~164 KB):

- 7 from `chain_tree_luajit/runtime_dict/` (ct_loader, ct_runtime, ct_engine, ct_builtins, ct_definitions, ct_common, ct_walker)
- 1 from `ros_planner_ii/runtime/` (fn_registry)
- 3 from `knowledge_base/zenoh/lib/` (zenoh_pubsub, zenoh_rpc, zenoh_token)

DSL builder (`chain_tree_luajit/lua_dsl/`) stays external — it's a build-time
tool for regenerating `connection.json` and never runs on the Pi.

Native `.so` files (libzenoh_pubsub, _rpc, _token, libzenohpico) remain
external in bench dev with TODO Pi-deploy comments in the `run.sh`
scripts; they'll be cross-compiled and copied into `vendor/lib-aarch64/`
when Pi deploy work begins.

See `vendor/PROVENANCE.md` for the file-by-file source map and refresh
guidance. `fake_robot/run.sh` and `bench_manager/run.sh` are the
canonical launchers — they bake in repo-relative `LUA_PATH` and
`LUA_CPATH` so no upstream env-setup is needed.

### Token-only binding constraint (noted, no design impact)

The `libzenoh_pubsub` binding uses uint32 FNV1a-32 token hashes, not key-expression strings. Local clients CANNOT subscribe to Zenoh wildcards like `**/heartbeat` via this binding — only exact key strings. Fits the design: wildcards happen at the gateway layer (decision #6), not at the robot client.

---

## Origin

This design emerged from a 2026-05-18 dialog exploring the Linux-side fleet management layer that sits above the existing libcomm dongle work. Multiple course-corrections during the dialog — early sketches were rejected as over-engineered or wrong-shape. The decisions captured here represent the corrected design after pushback.

This work is **independent** of (does not block, is not blocked by):
- libcomm dongle work (continues unchanged; USB-CDC wire between dongle and container)
- s_engine M-port (continues unchanged)
- SAMD21 register_dongle firmware (continues unchanged)

## Architecture model — encapsulated robot

The robot is the **only real source of truth** for its own state. The robot controller is an encapsulated system; external apps interact ONLY via published APIs, never directly with the internal namespace.

**Web server analogy:** nginx exposes routes, not its internal upstream pool layout, Lua scripts, or backend database schema. Internal architecture can refactor freely; external API contract is the stable surface.

**Rejected reference models:**
- **ROS** — assumes globally shared namespace; every node sees every topic. Wrong shape.
- **Automotive (CAN DBC, SOME/IP, ARXML)** — assumes centrally-published namespaces all integrators know. Wrong shape.

**Correct reference model:** microservices with private databases, OOP encapsulation, actor model, OPC UA server pattern. Internal namespace is private; public API is the only external surface.

## The boundary

| Layer | Protocol | Visibility |
|---|---|---|
| Inside robot controller | Zenoh (memory-only storages) | Internal only — never exposed |
| External API (operator dashboards, fleet ops, analytics, KB feeds) | HTTP / NATS / MQTT / KB feeds (one per consumer type) | Public, stable contract |

**Zenoh is implementation detail.** External world never speaks Zenoh.

The boundary is enforced by **publish apps** — gateway processes inside the robot controller that subscribe to internal Zenoh, translate to the appropriate external protocol, and expose a curated public surface.

## Identity model — class + instance

- `class_id`: **firmware-defined** (e.g., `car_window_controller`). A chip running this firmware IS this class.
- `instance_id`: **operator-assigned at commissioning** (e.g., `right_door`).
- **Robot namespace = `<class_id>/<instance_id>`** — two Zenoh segments.

Hardware identity (chip_uid for MCUs, UUID for containers) is **metadata, NOT identity.** Stored under `<class>/<instance>/hardware`. Hardware can be swapped without changing the robot's identity.

## Namespace structure — flat under robot namespace

All robot-related keys live **flat** under the robot's namespace. **No** `telemetry/`, `status/`, `commands/`, `events/` sub-categories. Cross-cutting discovery is via wildcard on leaf names.

```
car_window_controller/right_door/state              ← actual lifecycle state
car_window_controller/right_door/heartbeat          ← 1 Hz liveness
car_window_controller/right_door/position           ← live telemetry
car_window_controller/right_door/motor_current
car_window_controller/right_door/error_count
car_window_controller/right_door/fault_raised      ← discrete event
car_window_controller/right_door/capabilities      ← what robot can do (from firmware)
car_window_controller/right_door/hardware           ← chip_uid, fw_version
car_window_controller/right_door/desired_state     ← what state robot should be in
car_window_controller/right_door/zone               ← operator-set zone
car_window_controller/right_door/config_version    ← pointer to config
car_window_controller/right_door/friendly_name     ← operator-set alias
car_window_controller/right_door/tags               ← arbitrary operator labels
car_window_controller/right_door/move_to            ← inbound command
car_window_controller/right_door/calibrate          ← inbound command
```

## Write authority — split by leaf, not by subtree

Three writer roles, all writing under the same robot subtree:

| Writer | Leaves it owns |
|---|---|
| **Robot itself** | actual `state`, `heartbeat`, telemetry (`position`, `motor_current`, ...), events (`fault_raised`, ...), `capabilities`, `hardware` |
| **Fleet Manager** | `desired_state`, `zone`, `config_version`, `friendly_name`, `tags` |
| **Publish apps** (translating external commands) | inbound command leaves (`move_to`, `calibrate`, `reset_errors`, ...) |

Enforcement (when needed) via Zenoh ACLs keyed on key-expression patterns.

## Discovery — wildcards on leaf names

Zenoh wildcards: `*` = one segment, `**` = zero or more segments. With class and instance as separate segments:

```
car_window_controller/*/state             ← actual state, all window controller instances
car_window_controller/*/desired_state     ← desired state, all instances
**/heartbeat                               ← all live robots in the fleet
car_window_controller/right_door/**       ← everything one specific robot publishes
**/position                                ← all positions everywhere (any class)
car_window_controller/*/zone              ← zone assignments for all window controllers
**/desired_state                           ← every robot's desired state (drives reconciliation)
```

**Naming convention discipline:** robot class firmware authors should share leaf-name conventions where the concept matches (`position`, `state`, `heartbeat`, `move_to`) so cross-class wildcards work. Class-specific topics get class-specific names.

## Storage — memory only in Zenoh

- **All Zenoh storages are memory-backed.** No persistence in Zenoh.
- Persistence handled by a **separate process** inside the robot controller (Persistence Service).
- Persistent backend: **SQLite embedded in the management container** (locked).
- **Persistence implementation is deferred** — design known, code not written.
- **No replay flow needed** for now (deferred).

## Standalone MCU robots (e.g., Pico 2 W)

Pico 2 W and similar MCUs participate as **first-class robots** in this fleet:

- `chip_uid` is hardware metadata, **NOT identity**
- `class_id` + `instance_id` assigned at commissioning (same flow as Linux containers)
- Stored in **LittleFS** on the chip
- **zenoh-pico C agent** on the chip (existing implementation in `~/knowledge_base_assembly/c_programs_and_containers/build_blocks/knowledge_base/zenoh/`)
- Subscribes to its own desired_state, publishes its own actual state under its namespace
- WiFi connectivity assumed; bootstrap-locator strategy deferred

**Wio Terminal: dropped from scope** (decided 2026-05-18).

## Commissioning flow

> ⚠️ **SUPERSEDED 2026-05-19 by decision #27.** This Zenoh-channel commissioning flow has been rescinded. Identity is now loaded out-of-band by the bootstrap layer (env vars + `state.json`); the operator assigns `(class, instance)` by writing env/file before launch, not via a runtime Zenoh round trip. See the 2026-05-19 Amendments section at the top of this file. The text below is preserved for design-dialog history.

1. Hardware boots fresh (no class/instance assigned). Has chip_uid.
2. Pre-commissioned firmware connects to commissioning channel.
3. Operator UI sees the chip announcement (chip_uid + capabilities).
4. Operator assigns `(class_id, instance_id)` binding for the chip.
5. Chip writes assignment to local persistent storage (LittleFS / volume).
6. Chip reboots into operational namespace as `<class>/<instance>`.
7. From this point: robot operates under its assigned namespace; no further central coordination unless re-commissioning or hardware replacement.

This is the **same pattern** as the existing dongle commissioning (operator-assigned `instance_id` via libcomm), generalized to robots over Zenoh.

## What the management container holds

Much lighter than early sketches suggested:

- **SQLite registry** mapping `(chip_uid → class_id, instance_id, hw_metadata)`
- **Fleet Manager service** that validates commissioning requests (instance_id uniqueness within class; capability check)
- **Persistence Service** (deferred) that subscribes to robot-published state and durably stores it
- **Publish apps** (one per external protocol) that translate internal Zenoh ↔ external API

**Does NOT hold:**
- A central namespace schema (the robot class's firmware IS the schema)
- A central registry of valid roles (classes exist where their firmware exists)
- A capability validator (running the firmware IS the capability proof)

## Robot Classes — Runtime Registry (locked 2026-05-18)

Robot classes are **NOT** stored in `catalogs/robot_classes.lua` (the existing static-catalog pattern in `nano_data_center_base`). Static-catalog approach requires KB rebuild + system restart on every class change — incompatible with decision #9 (firmware IS the schema, dynamic discovery).

**Class definitions live in `registry.db.classes`** — a runtime table populated dynamically. Updated without rebuilds, without restarts.

### Schema (sketch — not yet finalized)

```
classes (in registry.db):
  class_id        TEXT PRIMARY KEY    -- "car_window_controller"
  description     TEXT                 -- from firmware announcement
  capabilities    JSON                 -- list of action_ids from firmware
  first_seen_at   INTEGER              -- when first instance commissioned
  last_seen_at    INTEGER              -- updated on instance activity
  source          TEXT                 -- "firmware_announced" | "operator_declared"
  state           TEXT                 -- "active" | "deprecated"
```

### Two population paths

1. **Firmware-announced** — first time a robot of class X commissions, its firmware's capability declaration (published on its namespace, e.g., `car_window_controller/right_door/capabilities`) is captured into `classes`.
2. **Operator-declared** (optional) — operator pre-registers a class via fleet_manager admin queryable for planning purposes, before any instance is online. Supports "plan for cargo_hauler even when none are currently running."

Class entries **persist** across reboots and instance lifecycles. A class with zero current instances stays known; can be marked `deprecated` to retire it from planning.

### Consumer model

The planner (and any other class-aware consumer) reads the **runtime registry**, not a static catalog:
- Internal consumers: subscribe to `fleet/classes/**` or call `fleet/admin/list_classes` queryable
- External consumers: through the gateway layer (HTTP / KB / etc.)

**Adding a new robot class:** build firmware → commission a chip → firmware announces → captured → planner sees it. **Zero KB rebuild, zero restart.**

### Existing infrastructure to avoid

- `catalogs/robot_classes.lua` — static pattern with `surface_hauler_v2` example. NOT our path; we don't extend it.
- `subsystems/robots.lua` + `subsystems/robot_classes.lua` — KB builders that process the static catalog into postgres. Not used by our flow. Worth a skim later to confirm no overlap or extract anything reusable, but they're not the path.

### Planner placement (locked 2026-05-18)

**The planner is an external consumer**, NOT part of our server container's application_logic layer.

- Planner runs outside our server container (separate container, possibly separate CPU — likely a more powerful node for compute-heavy planning)
- Planner talks to our fleet via the **gateway layer** (published external API)
- Planner does NOT speak internal Zenoh; it speaks whatever external protocol the gateway publishes (NATS / KB / HTTP / etc.)
- Planner can be replaced, upgraded, restarted independently from the fleet

**Implication for the gateway layer:** the gateway must expose class-catalog + instance-state + command endpoints to support the planner. The planner is the first significant external consumer driving the gateway's contract design. Specifically:

- List/subscribe known classes (from `registry.db.classes`)
- List/subscribe instances per class (from `registry.db.robots` + live state)
- Send commands to specific instances (translated to internal `<class>/<instance>/<command>` publishes)
- Subscribe to position / state / zone changes

**Implication for application_logic layer:** it does NOT host the planner. Application_logic may still synthesize/aggregate data the planner consumes (derived views, summary topics), but the planning decision-making itself lives in the external planner.

## Server Container — Internal Architecture (locked 2026-05-18)

### Container substrate

Server container is built `FROM nanodatacenter/luajit-base:latest` and reuses its **chain-tree supervisor** (`luajit/luajit_base/container/supervisor/`) for in-container app management. Lifecycle: `sync → setup → monitor → request_shutdown → teardown`. Spawns apps via libc FFI (`fork/execvp/waitpid/kill`).

**Not s6-overlay, not supervisord** — the chain-tree supervisor is the established pattern.

### Five-layer app model

One process per layer (Model B). LuaJIT can't be safely multi-threaded for app code (GC + JIT thread issues — same reason `zenoh_pubsub` wrapper uses queue+poll). Five processes communicating via internal zenohd:

| Layer | Process | Owns | start_order |
|---|---|---|---|
| Base | `zenohd` | Internal Zenoh router (memory storages) | 10 |
| Robot controller | `fleet_manager` | `registry.db` (SQLite) + commissioning queryables + audit | 20 |
| Persistence | `persistence_*` (mode-aware) | `persistence.db` OR bridge to platform postgres | 30 |
| Application logic | `application_logic` | Business workflows, multi-robot orchestration, derived/synthesized state | 40 |
| Application (gateway) | `gateway_*` (mode-aware) | External protocol surface (HTTP/MQTT/NATS/KB) OR bridge to platform gateway | 50 |

Application layer and application logic layer are **separately stacked**, not combined. Both publish/subscribe through internal zenohd as Zenoh peers — even inside the same container. Same separation as hexagonal/ports-and-adapters architecture.

### Two SQLite databases

| DB | Owner | Volume | Why split |
|---|---|---|---|
| `registry.db` | fleet_manager (Robot Controller layer) | LOW (commissioning events only — thousands of rows lifetime) | Rare writes, operator-driven |
| `persistence.db` | persistence_local (standalone mode only) | HIGH (continuous robot state stream) | Continuous writes, needs rotation/TTL |

Different schemas, different write profiles, different lifecycles. Registry stays LOCAL in both modes (controller-scoped state). Persistence DB only exists in standalone mode — in managed mode, state is published to platform postgres.

### zenohd is NOT infrastructure

zenohd serves robots in this controller; it's NOT a platform-level shared service. It ships inside the server container, not as a separate `platform_containers/` peer of dcs_console/observability/etc. Platform infrastructure = shared services (postgres, nats, mosquitto, kv-bridge); zenohd is application-scoped.

### Two-mode operation

Same code, different deployment posture:

**Standalone mode** — single container, manually `docker run`, self-contained on one Pi 4/5. Useful for bench dev, edge deployments, single-site shops.

**Managed mode** — deployed under DCS (system_node_control); integrates with platform postgres + gateway + observability containers.

**Mode-aware apps** (persistence + gateway): same image carries both variants; per-deployment **`app.manifest.json`** picks which variant to bundle. This is **option (i)** from the dialog — single image, manifest swap (not env-var branching, not separate images).

| App | Standalone variant | Managed variant |
|---|---|---|
| persistence | `persistence_local` (writes local SQLite) | `persistence_bridge` (publishes to nats → pg) |
| gateway | `gateway_local` (own HTTP/MQTT socket) | `gateway_bridge` (registers routes with platform gateway container) |

zenohd / fleet_manager / application_logic stay local in both modes.

### DCS integration (managed mode)

In managed mode, the server container is **one container under DCS** (`commissioning_software/system_node_control/`):

- Cluster topology described in **master Postgres KB** (laptop-side, `construction/`)
- Per-CPU `bootstrap.db` sliced from master KB, deployed via `stage_deploy.sh`
- DCS host process on each CPU reads its `bootstrap.db`, spawns containers (including ours) via `docker-host-broker`
- Two orchestration layers — DCS handles container lifecycle (start/stop/restart at container level); chain-tree supervisor inside the container handles the five apps

We do NOT write orchestration code. We define our container in the KB, ship the image, DCS deploys it.

### Hardware target

Server container runs on Pi 4 or Pi 5 only (not lower-power chips). All robot agents and libcomm code targets `aarch64-linux-gnu` lowest-common-denominator (Cortex-A53 ISA), portable across Pi Zero 2, Pi 4, Pi 5, Snapdragon WSL, Pocket Beagle 2, Arduino Snapdragon.

## Existing infrastructure to reuse

- **Internal Zenoh fabric:** `~/knowledge_base_assembly/c_programs_and_containers/build_blocks/knowledge_base/zenoh/` — C wrappers (`libzenoh_pubsub.so`, `libzenoh_rpc.so`, `libzenoh_token.so`) on zenoh-pico 1.9.0. **All Linux-side.**
- **LuaJIT bindings:** `~/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh/` — FFI wrappers, queue+poll subscriber pattern (cross-thread safety for LuaJIT).
- **zenoh-pico for MCU:** upstream library at `~/src/zenoh-pico` (v1.9.0). Pico 2 W port is a planned next-session work item per that tree's `continue.md`.
- **`eclipse/zenoh:latest` Docker container** — used as router for testing.

## What is NOT in this design (deferred)

| Item | Status |
|---|---|
| Persistence implementation (SQLite schema + Persistence Service) | Designed, deferred |
| Recovery / replay flow on router restart | Not needed yet |
| Auth / ACLs (Zenoh access control plugin) | Deferred |
| Bootstrap-locator strategy for MCU robots (factory-burned URL vs mDNS vs BLE pairing) | Deferred |
| LittleFS layout details on MCU | Deferred |
| Multi-region / multi-cloud federation | Deferred until needed |
| Cross-robot coordination (Open-RMF territory) | Deferred |
| First external publish app (HTTP for operator UI?) | Not yet designed |
| Robot class catalog / firmware-per-class organization | Implicit; not yet formalized |

## Development Plan (locked 2026-05-18)

Three parallel paths split across two Claude windows. Independent system to start; cross-path integration is a deliberate future milestone.

### Three paths

| Path | What | Location | Tech stack |
|---|---|---|---|
| **1. Server container** | The 5-layer server container as designed (zenohd / fleet_manager / persistence / application_logic / application_gateway) | `fleet_design/server/` | LuaJIT-on-Linux, zenoh-pico (via `knowledge_base/zenoh/` C wrappers + LuaJIT FFI bindings), `luajit_base` chain-tree supervisor |
| **2. Fake Linux robot** | Throwaway Linux process simulating a robot for end-to-end testing of server + commissioning + operational flows | `fleet_design/fake_robot/` | LuaJIT-on-Linux, same Zenoh bindings as Path 1; **NO libcomm, NO MQTT, NO physics** |
| **3. MCU dongle development** | Continues existing libcomm / SAMD21 / four-layer-sync / RS-485-slave work in motioncore-prototype | `motioncore-prototype/` (top-level + samd21/) | C on Cortex-M0+, libcomm over USB-CDC, no Zenoh |

### Two Claude windows

- **Window A — `fleet_design`** handles Paths 1 + 2 together. Same tech stack, same directory tree, can be advanced turn-by-turn in one window.
- **Window B — `motioncore-prototype`** continues Path 3 on its existing track (per top-level `continue.md`).

### Standalone-first discipline

All Path 1/2 development happens in standalone mode initially:
- No DCS integration
- No postgres / platform-gateway / KB bridge wiring
- Single Pi or laptop; manually `docker run`
- Mode-aware apps (`persistence_bridge`, `gateway_bridge`) are deliberate phase-2 work

Bridge variants are designed but not built until standalone is solid.

### Cross-window coordination

Window A and Window B do NOT share execution state. Integration is a deliberate future milestone — at minimum:
- M1: A real Linux robot (with a Path-3 dongle inside) commissions through Path 1 fleet_manager — uses Path 2's fleet contract with libcomm-to-dongle as internal implementation
- M2: Multiple robot types appear in the same `registry.db` simultaneously (fake_robot + Linux-with-dongle robot at minimum)
- M3: External consumer (planner / operator UI) sees all robot types via the gateway, indistinguishable by runtime

Until M1, Path 3 continues its own libcomm-over-USB-CDC test harness as today.

### Robot runtimes — all share one fleet contract

From the fleet's perspective every robot is a Zenoh peer with a `<class>/<instance>` namespace. Internal implementation is invisible:

| Runtime | What it is | When |
|---|---|---|
| **Pure Linux robot** | LuaJIT process, no hardware (e.g. `fake_robot`) | Path 2; first to land |
| **Linux robot + dongle** | LuaJIT process + libcomm + USB-CDC + actual dongle chip (e.g. `car_window_controller`) | Same path as pure Linux robot; dongle is internal plumbing. Lands at M1 when Window B integrates with Window A. |
| **MCU robot** | C on RP2350 / etc., zenoh-pico over WiFi, LittleFS for state, chip_uid from BOOTROM | Next class after Linux pipeline works; same fleet contract, different runtime |

**The dongle is NOT a fleet concept.** It's an implementation detail of certain Linux robots. The class is what the robot *does* (`car_window_controller`), not how it does it. No special "dongle robot" class exists.

There is **no Path 4**. Linux-hosted robot containers reuse Path 2's contract.

## Fake Robot — Test Scaffolding (locked 2026-05-18)

Path 2's deliverable. Under `fleet_design/fake_robot/`.

### Purpose

Exercise the server's commissioning + operational flows end-to-end without needing real MCU hardware. Test scaffolding, intended to be **deleted** when real robot classes ship — `fake_robot/README.md` should explicitly say so to resist scope creep.

### Commissioning model (mandatory from day one)

> ⚠️ **SUPERSEDED 2026-05-19 by decision #27.** The pseudocode below describing first-boot Zenoh announce + wait-for-assignment + re-exec is rescinded. fake_robot now reads `ROBOT_CLASS` + `ROBOT_INSTANCE` from env at every startup; `chip_uid` is auto-generated and persisted to `IDENTITY_DIR/state.json`. The "class+instance NEVER from env var" rule has been reversed: env IS the authoritative source for operator-assigned identity. Preserved below for design-dialog history.

The existing `ros_planner_ii_mqtt_robot` work skipped commissioning and accumulated debt. Fake_robot commissions properly:

```
On first start (no commission state on disk):
  - Generate or load chip_uid equivalent (UUID, persisted in IDENTITY_DIR)
  - Connect to Zenoh
  - Publish announcement to fleet/uncommissioned/<uid>/announce
    payload: { hardware_class: "fake_robot", capabilities: [...], fw_version }
  - Subscribe to fleet/commissioning/<uid>/assignment
  - Wait (no operational traffic) until assignment arrives
  - On assignment: write (class, instance) to local state file
  - Re-exec self (simulates chip reboot into operational mode)

On subsequent start (commission state exists):
  - Read (class, instance) from state file
  - robot_id = <class>/<instance>
  - Operate as a normal commissioned robot
```

Local state file = file analog of MCU LittleFS. **Class+instance NEVER comes from env var** — that would bypass commissioning and re-create the mqtt_robot debt.

### Identity isolation — one binary, N instances

```bash
IDENTITY_DIR=/tmp/fake_a ./fake_robot &
IDENTITY_DIR=/tmp/fake_b ./fake_robot &
IDENTITY_DIR=/tmp/fake_c ./fake_robot &
```

Each gets its own chip_uid (generated first boot), commissions independently. Allows realistic fleet testing with multiple fakes.

### Generic behavior (locked: Q2 = generic always)

Behavior is **the same regardless of assigned class**. No per-class personalities initially. Publishes a generic telemetry set (counter, fake-temperature, fake-position, etc.) under whatever `<class>/<instance>` namespace was assigned at commissioning.

Rationale: prove commissioning + operational lifecycle work first with simplest possible behavior. Per-class personality modules (matching real class contracts like `car_window_controller`) are deliberate future work, added only when a specific test needs them.

### First commissioned class (locked: Q3 = generic class `fake_robot`)

First fake_robot is commissioned as the generic class `fake_robot`. Proves end-to-end pipeline without depending on any real class spec. Real classes commission later.

### Scope discipline (cap explicitly)

- **No libcomm** — not needed for testing the Zenoh-side fleet contract
- **No MQTT** — not needed
- **No physics simulation** — fake numbers are sufficient
- **Only Zenoh participation** — commissioning channel + operational pub/sub
- **`fake_robot/README.md`** must state: "Stub behavior is throwaway; the commissioning + dispatch chains are foundational and graduate out when real Linux robots land."

### Engine substrate — chain_tree across all fleet_design robots

**chain_tree is the engine for everything in fleet_design.** Two implementations by deployment target:

| Target | Engine implementation | Where it lives |
|---|---|---|
| Pure Linux robot (fake_robot) | **`chain_tree_luajit`** | `~/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/chain_tree_luajit/` |
| Linux robot + dongle inside | **`chain_tree_luajit`** (Linux side; dongle internals invisible to fleet) | same as above |
| MCU robot (Pico 2 / ESP32) — future | **`chain_tree_c`** | `~/knowledge_base_assembly/c_programs_and_containers/build_blocks/chain_tree_c/` |

**chain_tree and s_engine are distinct engines.** They are NOT the same engine with different DSLs.

**s_engine is OUTSIDE fleet_design scope.** It is a space-optimized engine used ONLY inside ARM 32K dongles (SAMD21, RA4M1) — necessary because 32K SRAM can't host chain_tree. When a dongle is inside a Linux robot, that's Track-3 implementation detail of the robot's internals; the fleet never sees s_engine.

**Fake_robot is partly-throwaway, partly-foundation.** Reusable across all Linux robots:

- Bootstrap (Zenoh connect, identity load, file IO) — direct LuaJIT
- **Commissioning state machine — chain_tree_luajit** (foundational, reusable for all Linux robots)
- External Zenoh event dispatch — chain_tree_luajit (foundational pattern, specific events per class)
- Internal robot event dispatch — chain_tree_luajit (foundational pattern, specific events per class)
- Generic telemetry (throwaway) — direct LuaJIT

Existing `mqtt_robot` (`building_blocks/ros_planner_ii_mqtt_robot/`) uses `chain_tree_luajit` already (see its `ct_runtime`, `ct_loader_pure`, `ct_engine`, etc.); fleet_design's Linux robots use the same engine. mqtt_robot is referenced for both architectural pattern AND engine choice.

**Specific variant choice: `runtime_dict/` (`ct_*` modules), following mqtt_robot.** Not `runtime/` (`cfl_*`) — even though the cfl_ variant is newer and has more features (s_engine bridge, 156-function complete), following mqtt_robot keeps code structurally moveable between the two. Reconsider only if a cfl_-only feature is needed.

**File structure follows mqtt_robot's pattern:**

| mqtt_robot | fake_robot equivalent |
|---|---|
| `mqtt_robot_main.lua` (bootstrap + engine setup + tick loop) | `main.lua` |
| `robot_controller.lua` (direct controller, not chain-tree) | `lib/controller.lua` |
| `remote_user_functions.lua` (Lua fns registered as chain-tree actions via `fn_registry`) | `lib/user_functions.lua` |
| `remote_dsl.lua` (DSL source) + `remote.json` (compiled) | `chains/*.lua` (DSL) + compiled JSON in build step |
| `mqtt_robot_config.lua` (config loader) | `lib/identity.lua` (IDENTITY_DIR + chip_uid persistence) |

Drop entirely from mqtt_robot's stack for fake_robot: libcomm, MQTT, physics (`physics_core`, `physics_ffi`, `libphysics`), `dongle_hal`, `robot_hal`, `drive_base_ffi`, `comm_manifest`, `link_client`, `ct_avro`.

### Directory layout (fake_robot)

```
fleet_design/fake_robot/
├── README.md
├── main.lua                          ← bootstrap entry point (direct LuaJIT)
├── lib/
│   ├── identity.lua                  ← UUID generate/persist, IDENTITY_DIR handling
│   └── zenoh_session.lua             ← thin wrapper over existing FFI bindings
├── chains/                           ← chain_tree definitions (FOUNDATIONAL, reused)
│   ├── commissioning.lua             ← commissioning state machine
│   ├── external_event_dispatch.lua   ← Zenoh-event handlers
│   └── internal_event_dispatch.lua   ← internal robot event handlers
└── stub_behavior/                    ← throwaway only
    └── generic_telemetry.lua         ← fake counter / temperature publisher
```

When the first real Linux robot lands, `chains/` graduates to a shared location (e.g., `fleet_design/linux_robot_lib/` or upstream to `nano_data_center_base/`); `fake_robot/` keeps just `stub_behavior/` and a `require` of the shared chains.

## Hardware / deployment targets

**Server container (management container):** Pi 4 or Pi 5 only. Not targeted at lower-power chips.

**C code (robot agents, libcomm, anything portable):** must compile and run on:
- Pi Zero 2 class — Cortex-A53, ARMv8-A 64-bit (also matches Pocket Beagle 2 and Arduino Snapdragon — same ARM core)
- Snapdragon WSL (Snapdragon X Elite laptops running aarch64 Linux under WSL)
- Pi 4 — Cortex-A72, ARMv8-A 64-bit
- Pi 5 — Cortex-A76, ARMv8.2-A 64-bit

All targets are `aarch64-linux-gnu`. Build for the lowest common denominator (Cortex-A53 ISA) — no Pi-5-specific or A76-specific instructions. Compiled binaries should be portable across all listed targets.

## Conventions

- Robot namespace separator: **`/`** (Zenoh-native segment separator). `<class>/<instance>/<leaf>`
- Class IDs use snake_case (`car_window_controller`, `scservo_arm`)
- Instance IDs use snake_case and are operator-meaningful (`right_door`, `station_3`)
- Leaf names follow shared conventions across classes where concepts match (`state`, `heartbeat`, `position`)

## Push-back captured

- Earlier sketches proposed a centralized `fleet_schema.yaml` with sites, zones, functions, capabilities. **Rejected** — over-engineered for the encapsulation model. Firmware is the schema.
- Earlier sketches used ROS/automotive as reference models. **Rejected** — those are shared-namespace architectures; this is encapsulated. Microservices / OOP / OPC UA are the right references.
- Earlier sketches assumed external apps subscribe directly to Zenoh. **Rejected** — Zenoh is internal-only; external apps speak NATS/MQTT/HTTP/KB through publish apps.
- Earlier sketches added `app/` top-level prefix and `telemetry/`/`status/`/`commands/` sub-categories. **Rejected** — flat namespace under robot is sufficient; wildcards on leaf names handle cross-cutting queries.
