# Subsystems

A bottom-up catalog of every subsystem — why it was developed and what lives
inside it. The layers build on each other: native transport → LuaJIT bindings →
shared framework → services → robots → packaging.

## Native transport

### `third_party/zenoh-pico`

**Why:** the robots need a wire, and it has to work on a small box with no
broker. Zenoh provides pub/sub, queryable RPC, and discovery over one
lightweight protocol; `zenoh-pico` is the C implementation small enough to link
into the LuaJIT robots. It is vendored here (upstream, CMake) so the whole stack
builds offline.

**What's in it:** the upstream Eclipse `zenoh-pico` source tree. `build_libs.sh`
compiles it (CMake, shared lib) into `libzenohpico.so` plus generated headers
that the shims build against.

### `third_party/zenoh_libs`

**Why:** LuaJIT talks to C through FFI, but raw `zenoh-pico` is too low-level to
bind directly from robot code. These are thin C shims that present exactly the
three Zenoh primitives the framework uses, with a stable ABI for the LuaJIT FFI
bindings to load.

**What's in it** (`c/`, each a small Makefile project → one `.so`):

- **`token`** → `libzenoh_token.so` — FNV1a-32 hashing of well-known keyexprs
  (e.g. `fleet/persistence/query`, `fleet/admin/...`) into the integer tokens
  used for token-RPC.
- **`pub_sub`** → `libzenoh_pubsub.so` — publish / subscribe.
- **`rpc`** → `libzenoh_rpc.so` — queryable RPC (depends on `token`).

## Shared runtime + framework

### `fleet_operations/vendor`

**Why:** so a partial-repo pull (e.g. onto a Pi Zero 2) gets everything a robot
needs at runtime with no reference to the upstream `knowledge_base_assembly`
tree. These are vendored *copies* of upstream Lua and C runtime files; refresh
is a deliberate re-copy when picking up a new version (`PROVENANCE.md` is the
file-by-file map and freshness log).

**What's in it:**

- **The `chain_tree` engine** (`lua/ct_*.lua`) — loader, runtime, node-execution
  engine, built-in node functions (timers, time-of-day window waits, watchdog,
  state machine), tree walkers, and the function registry that maps compiled-IR
  function names to Lua callables.
- **The Zenoh FFI bindings** (`lua/zenoh_pubsub.lua`, `zenoh_rpc.lua`,
  `zenoh_token.lua`) — LuaJIT wrappers over the three shim `.so`.
- **The SQLite knowledge-base stack** (`lua/construct_*.lua`, `lua/kb_*.lua`) —
  construction-time builders and runtime CRUD for status tables, stream rings,
  job queues, RPC server/client queues, bit-mask stores, plus the CTE-based
  ltree query support.
- **The `ltree` SQLite extension** (`c/ltree/`) — PostgreSQL-style `ltree`
  path matching (ancestor/descendant/depth) as a loadable SQLite extension,
  built into `ltree.so` inside the container. This is what makes the persistence
  store query by hierarchical path.

> **Not vendored on purpose:** the `chain_tree` *DSL builder* (build-time only,
> runs on the dev machine) and the native `.so` (per-arch, built from source).

### `fleet_operations/robot_common`

**Why:** to hold the framework concerns shared by *every* robot class, so a class
directory only contains its domain logic. This is the seam that turned "one
robot" into "a fleet of the same shape."

**What's in it** (`lib/`, `chains/`, `tests/`):

- **KB0** — the bring-up / supervisor KB. Opens the Zenoh session, registers the
  robot with the controller (one-shot RPC), publishes the robot's persistence
  topology (so the store can declare subscriptions), waits out a defensive
  settle, then spawns the class's app KBs. KB0 is the *only* KB that knows about
  the controller.
- **identity, clock, heartbeat, daily_marker** — stable robot identity, time
  handling, the health-aware heartbeat that rolls up per-app-KB liveness, and the
  disk markers that stop daily one-shots from re-firing on container restart.

### `fleet_operations/identity`

**Why:** a robot needs a stable identity (`chip_uid`) that persists across
restarts and re-registrations so the controller's registry can track it.

**What's in it:** `state.json` — the persisted fleet-identity record.

## Server / back-office services

The Linux-side controller and the services that store and surface fleet data.
Each is one process; the container supervisor starts them in order. See
[Fleet framework → Architecture](../fleet/architecture.md).

### `fleet_operations/server/fleet_manager`

**Why:** the fleet needs a controller that robots register with and a heartbeat
they can watch for passive disconnect detection — but the robot is sovereign, so
the controller is deliberately *passive* (no validation, no NACK, no uniqueness
enforcement).

**What's in it:** an RPC queryable on `fleet/admin/register` (records the robot,
replies with controller id + echo), a 1 Hz heartbeat publisher on
`fleet/admin/heartbeat`, and an in-memory registry keyed by `chip_uid`
(`class, instance, fw_version, capabilities, first_seen, last_seen,
register_count`). The registry module is the seam for a future SQLite
`registry.db`.

### `fleet_operations/server/persistence`

**Why:** the robots need a single durable store, and it must not need to know
about any specific robot — robots come and go, and new classes are added without
touching the store.

**What's in it:** a SQLite-backed store plus a query RPC. It is **robot-agnostic**:
it learns the schema from the persistence topology each robot *announces*, then
builds whatever `ltree` paths the robots declare. Status leaves UPSERT in place;
stream leaves are fixed-size rings. A two-phase apply (open subscriptions for new
leaves *first*, then do the slow schema mutation) is the fix for the
zero-stream-capture race found during containerization.

### `fleet_operations/server/application_gateway`

**Why:** operators need to *see* the data, and the persistence query RPC is a
Zenoh interface, not something a browser speaks.

**What's in it:** an HTTP server in front of the persistence query RPC that also
serves the dashboard SPA (e.g. the irrigation alerts page). Binds `0.0.0.0` on
the Pi for LAN reachability. No auth yet — port-obscurity is the interim
mitigation.

### `fleet_operations/server/notification_service`

**Why:** an island system still has to reach a human when something is wrong.

**What's in it:** a subscriber on `fleet/notify/digest/daily` that POSTs to
Discord (no-op without a webhook). Discord today; ntfy / Slack / SMS are
slot-ins.

## Robot classes

A robot class is a directory with a `class_spec.lua`, a `main.lua`, and a
`chains/` folder. The shared `robot_common` core handles framework concerns; the
class contains only its domain logic and its declared persistence topology.

Each robot has its own background page that walks its operation against the six
themes from the [Opening](index.md):

- **[farm_soil — consolidation](farm_soil.md)** — many sources (LoRaWAN console,
  two ETo feeds) collapsed into one daily picture; observe-only.
- **[rancho_water — the adapter](rancho_water.md)** — one closed portal, no
  actuation; the universal-adapter pattern and its brittleness in miniature.
- **[irrigation_analytics — the full virtual operator](irrigation_analytics.md)**
  — extraction *and* armed control over the LaCima controller, physics-grounded
  detectors (KB0..KB4), and the `irrigation-ops` operator runbook.

For the mechanical spec of each class (KBs, config keys, persistence topology),
see [Fleet framework → Robot classes](../fleet/robots.md).

## Packaging

### `fleet_operations/packaging` and `packaging_irrigation_analytics`

**Why:** to turn the framework + robots into the single deployable container that
is the unit of deploy, and to make that image build reproducibly from the
vendored binaries.

**What's in it:**

- **`packaging/`** — the shared base: the `Dockerfile`, the container
  **supervisor** (`container/start.sh` — staggered launch, whole-container crash
  supervision, and the structured JSON crash log with burst dedup), `build_assets/`
  (the staged/committed `.so`), and `wsl/` bench helpers.
- **`packaging_irrigation_analytics/`** — the concrete image for the irrigation
  complex: its own `Dockerfile` + `build.sh` (stages the `.so`, regenerates the
  chain IR, runs `docker build`) and the `wsl/start.sh` host run-wrapper used both
  on the bench and as the shape of the Pi deploy.

## Top-level: the self-contained build

### `build_libs.sh`

**Why:** to make the whole repository buildable offline, with no dependency on
any external source tree — the on-disk counterpart of the robots'
field self-sufficiency.

**What's in it:** a single script that compiles `zenoh-pico` and the three shims
from the vendored `third_party/` sources, in dependency order, and stages the
four `.so` into `packaging/build_assets/lib/`. The binaries are also committed,
so the image builds even without running it first; re-run it to regenerate from
source after a bump or arch change. See [Build from source](../build-from-source.md).
