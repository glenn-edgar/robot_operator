# fleet_design — Continue From Here

## Resume here (2026-05-29 — irrigation R-only KBs, full-day build)

**Goal:** land two R-only knowledge bases under `irrigation_analytics/`:
**KB1** (live R during scan, alert-only) and **KB2** (daily trend + calibration
health). Buildable in one day with data in hand. No more measurement sessions
needed.

**Full plan in memory**: `[[r-kb-implementation-plan-2026-05-29]]`.
**Calibration baseline in memory**: `[[r-scan-noise-floor-2026-05-27]]`.

### Calibration model (locked 2026-05-28 session)

```
V_PSU            = 15.7 V                (operator-measured)
R_master         = 33 Ω                  (sat_1:43, physical multimeter)
I_master_true    = V_PSU / R_master      = 0.4758 A
ACS712_OFFSET    = I_master_meas − I_master_true   (today: −0.0196 A / −3 LSB)
I_true(any)      = I_meas − ACS712_OFFSET
R(any)           = V_PSU / I_true
```

The ACS712 offset is the day-over-day knob: yesterday −1 LSB, today −3 LSB.
KB2 tracks this as a system-health metric (alerts if it drifts ≥3 LSB vs
7-day median — catches PSU/sensor aging).

### Reference tables (carry into both KBs)

- **Watch list** (intrinsic noise, σ ≥ 1.16 LSB — wider gates):
  sat_4:1, sat_3:14, sat_3:11, sat_2:4, sat_2:6, sat_2:15, sat_4:8
- **Anchor list** (1-LSB σ, common-mode cross-check):
  sat_4:13, sat_3:18, sat_1:44, sat_4:12, sat_4:2
- **Disconnected / skip from detection**:
  sat_1:1, sat_1:28, sat_1:38, sat_1:40, sat_3:1, sat_4:6
- **Multi-coil bin** (heavy load): sat_1:44 (~0.67 A, ~22 Ω)

### KB1 detection gates

| condition | rule | sub-reason |
|---|---|---|
| open coil | `I_meas < 0.15 A` ≥2 consecutive | `OPEN` |
| shorted coil | `I_meas > 1.5 A` (R < 10 Ω) | `SHORT` |
| out-of-band | `|I_meas − baseline| > 10 LSB` (15 for watch list) | `DEVIATION` |
| stuck idle | last 3 samples < 0.15 A mid-scan | `STUCK_IDLE` |
| PSU sag | master sat_1:43 newest < 0.40 A | `BUS_DEAD` |
| scan interrupted | no master energized in last 60 s | `SCAN_INTERRUPTED` |

Polling model (no controller event hook known): poll the
`IRRIGATION_VALVE_TEST` Redis hash every 2 s during active scan, 60 s when
idle. Detect "scan active" by master sat_1:43 slot[19] flipping from idle
to energized. Push Discord on first open/short hit, debounce 5 min per valve.

**No autonomous skip** — R changes are slow-developing, alert-only.

### KB2 anomaly rules

| condition | threshold | tier |
|---|---|---|
| ΔR vs 7-day median | > +3 Ω (non-watch) | per-valve alert |
| ΔR vs 7-day median | > +5 Ω (watch list) | per-valve alert |
| ΔR vs 7-day median | < −3 Ω | replacement/new-coil alert |
| ACS712_OFFSET shift | > 3 LSB vs 7-day median | system-health alert |
| V_PSU_implied shift | > 0.3 V vs 7-day median | system-health alert |
| disconnected-list changed | any | wiring-event alert |

Persist daily snapshots to `server/persistence/` as a stream-KB under
`irrigation_analytics/r_scan_daily/`. Rolling-median per valve computed
on-the-fly from the stream.

Daily Discord digest at 06:00 PT (after the controller's nightly auto-scan),
single push with anchor report + anomaly list + watch-tier informational.

### File layout

```
fleet_design/irrigation_analytics/
  kb1_r_live/
    main.lua              # chain_tree controller
    detector.lua          # gate evaluation
    baseline.lua          # per-valve expected I (loaded from kb2_r_baseline.json)
    discord_push.lua      # alert formatter
    config.lua            # thresholds, debounce
  kb2_r_trend/
    main.lua              # chain_tree controller
    calibrate.lua         # master anchor + offset derivation
    detector.lua          # baseline comparison + anomaly rules
    persist.lua           # stream append + 7-day pull
    digest.lua            # Discord digest formatter
    config.lua            # thresholds
  data/
    kb2_r_baseline.json   # exported nightly by KB2, consumed by KB1
```

### Build order (one full day)

1. **KB2 calibrate.lua** — port master-anchor + offset derivation from
   `explore/analyze_resistance.py` (1-2 h)
2. **KB2 detector.lua** — rolling-median + 7-day threshold comparison (1 h)
3. **KB2 persist.lua** — stream append using persistence library (30 min)
4. **KB2 digest.lua** + notification_service wiring (1 h)
5. **KB1 baseline.lua** — load per-valve expected bands from KB2 output (30 min)
6. **KB1 detector.lua** — gate evaluation (1-2 h)
7. **KB1 push** — Discord wire with debounce (30 min)
8. **Bench smoke** — replay today's snapshot + synthetic open-coil mutation (1 h)

### What NOT to build (decided 2026-05-28)

- ❌ Mann-Kendall / change-point per valve — noise floor swallows signal
- ❌ ARIMA / time-series forecasting — no labeled failures
- ❌ Per-valve aging models — solenoids fail abruptly, not gracefully
- ❌ Buffer-internal pattern mining — 20-slot rolling rotation isn't a time series
- ❌ Autonomous skip authority for KB1 — R changes aren't real-time-actionable

Heavy stats stay deferred to flow-side analysis. The R-scan is fundamentally
a threshold detector.

### Pre-build gotcha checklist

- All bench files in `<repo>/var/...`, never `/tmp` on WSL (rule absolute)
- Secrets (irrigation password, Discord webhook) → `secrets/`, 0600, gitignored
- Persistence boot-race: KB0 needs the 5-s `wait_time` between NAMESPACE_UP
  and SPAWN_APP_KBS (known fix)
- `irrigation_analytics` namespace already exists — extend it, don't create new

### Open thread separate from this work

- Thursday operator-labeled bad-head list arrived 2026-05-28 (17 bad heads
  across 20 tree valves) — confirms all faults are flow-side (no R signal).
  Curves/flow analysis handles that, NOT this R track.

---

## Flow-side companion track (locked 2026-05-28)

Independent from R-KB. Lives in `irrigation_analytics/explore/` for now.

### Short-run end-only strategy (LOCKED)

For runs ≤ 5 steps, the failure signal is ONLY at the settled steady-state.
Drop multi-feature scoring. One number per run:

```
end_mean(run) = mean(run.HUNTER_FLOW.data[-3:])     # last 3 of 5 steps
baseline(bin) = median + MAD over historic runs (excluding newest)
delta         = newest_end − baseline_median
flag if |delta| > max(K_MAD * MAD, gpm_floor)
   K_MAD     = 3.5
   gpm_floor = 2.0
direction: Δ > 0 → broken/missing/stuck-open head
           Δ < 0 → clogged/partial-block head
```

Full rationale + validation: `[[end-only-short-run-strategy-2026-05-28]]`.

### First validation (2026-05-28)

`explore/short_run_end_score.py` against fresh time_history.json + today's
operator labels (17 tree-bad-heads + 4:13/2:2 fail + 2:6 clean):

```
TP=3  FN=4  FP=0  TN=3
precision=1.00   recall=0.43
```

Misses are all single-bad-head on multi-head valves (Δ at noise floor).

### Six unlabeled anomalies for operator inspection

These were not on today's bad-head list but the analyzer flagged them.
Confirm next opportunity:

| valve   | Δ (gpm) | likely    |
|---------|---------|-----------|
| 3:11    | −10.33  | major clog / shut-off |
| 1:13    | −5.33   | partial clog |
| 1:12    | −4.67   | partial clog |
| 1:7     | −4.00   | partial clog |
| 3:19    | +2.67   | broken / open head |
| 3:4     | −2.33   | partial clog |

### Tomorrow's slot

R-KB build is primary. If R-KB finishes ahead of estimate, fill remaining
time with:
1. Add paired-bin (X+1:39) end-mean as a second-vote axis (improves single-
   head recall)
2. Tune K_MAD + gpm_floor with the 6 unlabeled findings once operator
   confirms
3. Promote `short_run_end_score.py` to a flow-KB scaffold (kb3_flow_short)

---

## Status (2026-05-19)

**Design phase complete + connection KB fully implemented end-to-end.**

All five states of the connection state machine are real (no stubs):
`connecting` → `ack'd` → `namespace_up` → `operating` → on disconnect → `disconnected` → back to `connecting`. Smoke-tested through the happy path, kill-mid-run disconnect detection, and recovery on bench_manager restart.

Two-clock model in place: `CLOCK_MONOTONIC` ms for elapsed-time math (timeouts, backoff, heartbeat cadence) and `CLOCK_REALTIME` for wire `ts` fields + wall-clock boundary events. main.lua's pump emits `CFL_{SECOND,MINUTE,HOUR,DAY,MONTH,YEAR}_EVENT` to the chain_tree on boundary crossings, with a clock-jump guard for Pi Zero 2 NTP-step cascades. Verified: a 90 s run captured `CFL_MINUTE_EVENT @ 2026-05-19 20:16:00 UTC` at the exact minute boundary.

History: design dialog opened 2026-05-18 (26 base decisions); extended 2026-05-19 with amendments #27–#33 — see `memory.md` top section.

## What this directory is

- `memory.md` — load-bearing locked decisions + design rationale + push-backs captured. **Read this before any implementation work in this area.**
- `continue.md` — this file. Current state + open questions + next-session candidates.
- `server/` — Path 1 robot controller. `fleet_manager/` layer built 2026-05-21 (register RPC + heartbeat + in-memory registry); see `server/README.md`.
- `fake_robot/` — Path 2 robot (populated 2026-05-19): `main.lua`, `class_spec.lua`, `chains/` (DSL + user fns + compiled IR), `lib/` (identity + pubsub + RPC wrappers)
- `bench_manager/` — retired 2026-05-21; the real controller is `server/fleet_manager/`.

## What this design is

The architectural design for the Linux-side fleet management layer in motioncore. Sits ABOVE the libcomm dongle work; separate from s_engine.

| Layer | What it does |
|---|---|
| Robot controller (encapsulated system) | Hosts internal Zenoh fabric + publish apps |
| Internal namespace | `<class>/<instance>/<leaf>` — robot-sovereign |
| Publish apps | Translate internal Zenoh ↔ external APIs (HTTP / NATS / MQTT / KB) |
| External world | Speaks only to publish apps; never sees Zenoh |

## What this design is NOT

- Not a libcomm replacement — libcomm continues for dongle ↔ container wire
- Not a re-architecture of s_engine — separate substrate
- Not the implementation — pure design as of this date

## Architecture at a glance

```
External world (operator dashboards, fleet ops, analytics, KB consumers)
        │
        ├── HTTP / NATS / MQTT / KB feeds
        │
        ▼
┌─────────────────────────────────────────────────────────────┐
│ Robot Controller                                            │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Publish apps (boundary / API gateway)                │  │
│  └────────────────────┬──────────────────────────────────┘  │
│                       │                                     │
│                       │  internal pub/sub (Zenoh)           │
│                       ▼                                     │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Robot namespaces                                     │  │
│  │    car_window_controller/right_door/state             │  │
│  │    car_window_controller/right_door/position          │  │
│  │    car_window_controller/right_door/desired_state     │  │
│  │    car_window_controller/left_door/...                │  │
│  │    scservo_arm/station_3/...                          │  │
│  │                                                       │  │
│  │  Wildcards for cross-cutting access:                  │  │
│  │    car_window_controller/*/state                      │  │
│  │    **/heartbeat                                       │  │
│  │    **/position                                        │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  Linux containers + MCU robots (zenoh-pico over WiFi)       │
│  all participate as peers in the internal fabric            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Locked design decisions (summary — see memory.md for full rationale)

**Namespace / identity / fabric** (locked earlier in 2026-05-18 dialog):

1. Zenoh lives **only inside** the robot controller. External world uses other protocols.
2. Robot identity: `<class_id>/<instance_id>`. Class is firmware-defined; instance is operator-assigned at commissioning.
3. Robot owns its namespace. All robot-related keys live flat under `<class>/<instance>/`.
4. No `telemetry/`, `status/`, `commands/` sub-categories. Discovery via wildcards on leaf names.
5. Three writer roles share the robot subtree: robot, Fleet Manager, publish apps. Authority split by leaf, not subtree.
6. All Zenoh storages are memory-only. Persistence is a separate Persistence Service (SQLite in container), implementation deferred.
7. MCU robots (Pico 2 W) are first-class. zenoh-pico C agent. LittleFS for class+instance storage. Wio Terminal dropped from scope.
8. Hardware UID is metadata, not identity. Hardware swap doesn't change robot identity.
9. No central namespace schema. Firmware IS the schema. Reference model: microservices / OOP encapsulation / OPC UA — NOT ROS or automotive.
10. Management container holds only the `(chip_uid → class, instance, metadata)` registry + Fleet Manager + Persistence Service + publish apps.

**Server container internal architecture** (locked late 2026-05-18 dialog):

11. Server container runs on Pi 4 or Pi 5 only. C code (libcomm + robot agents) is aarch64-portable across Pi Zero 2 / Pi 4/5 / Snapdragon WSL / Pocket Beagle 2 / Arduino Snapdragon — target Cortex-A53 ISA.
12. Server container is built `FROM nanodatacenter/luajit-base:latest`. Reuses its chain-tree supervisor for in-container app management. NOT s6, NOT supervisord.
13. **Five layers, five processes** (Model B — one process per layer): zenohd → fleet_manager → persistence → application_logic → application_gateway. start_order 10/20/30/40/50.
14. Application layer (gateways) and Application logic layer (business) are **separately stacked**, not combined. Both are Zenoh peers on the internal fabric even inside the same container.
15. **Two SQLite DBs**: `registry.db` (fleet_manager, low write) + `persistence.db` (persistence_local, high write, standalone-only).
16. zenohd is NOT platform infrastructure. It ships inside this container; serves only the robots under this controller.
17. **Two operational modes**: standalone (single Pi, manual `docker run`) and managed (under DCS with platform infrastructure).
18. **Mode-aware apps** use option (i): single image carries both variants; per-deployment `app.manifest.json` selects which to bundle. Only `persistence` and `gateway` have mode variants; zenohd/fleet_manager/application_logic stay local in both modes.
19. **DCS integration** uses existing system_node_control three-layer model (construction/runtime/deployment). We don't write orchestration; we declare our container in the master KB.
20. **Robot classes live in `registry.db.classes` runtime table**, NOT in `catalogs/robot_classes.lua`. Two population paths (firmware-announced on first commissioning + optional operator pre-declaration). Adding a new class requires no KB rebuild, no restart.
21. **Planner is an external consumer**, NOT part of application_logic layer. Runs outside our server container; talks to fleet via the gateway layer. Drives the gateway's external API contract (class catalog + instance state + commands). Can be replaced/upgraded independently from the fleet.
22. **Development plan**: three paths (1: server container, 2: fake Linux robot, 3: MCU dongle continuation). Two Claude windows: Window A = `fleet_design/` (Paths 1+2); Window B = `motioncore-prototype/` (Path 3). Standalone-first; managed-mode wiring deferred.
23. **Fake robot is mandatory test scaffolding** with full commissioning model from day one (avoids the mqtt_robot debt). Lives at `fleet_design/fake_robot/`. One binary, N instances via `IDENTITY_DIR` env. Generic behavior (no per-class personalities yet). First commissioned class = generic `fake_robot`. **Class+instance NEVER set via env** — only assigned by commissioning.
24. **All robots share one fleet contract.** Pure Linux robot, Linux-robot-with-dongle, and MCU robot are indistinguishable to the server — same Zenoh `<class>/<instance>` namespace, same commissioning flow, same operational pub/sub. The dongle is **internal implementation**, not a fleet concept. No special "dongle robot" class. No Path 4 for Linux-hosted robot containers — they reuse Path 2's contract.
25. **MCU robot is the next class after Linux pipeline works.** Same fleet contract; different runtime (C on RP2350, zenoh-pico over WiFi, LittleFS for state, chip_uid from BOOTROM). Validates contract holds across runtimes. Deferred until Paths 1+2 are stable.
26. **fake_robot is partly-throwaway, partly-foundation.** Bootstrap is direct LuaJIT. Commissioning state machine + external Zenoh event dispatch + internal event dispatch use **`chain_tree_luajit`** (foundational, reused across all Linux robots). The `chains/` directory graduates out when first real Linux robot lands; `stub_behavior/` is the only true throwaway. **Engine by target: Linux robots = `chain_tree_luajit` (`luajit_programs_and_containers/building_blocks/chain_tree_luajit/`); MCU robots (Pico 2 / ESP32) when they land = `chain_tree_c` (`c_programs_and_containers/build_blocks/chain_tree_c/`).** chain_tree and s_engine are **distinct engines**; s_engine is space-optimized for ARM 32K dongles only (SAMD21, RA4M1) and is OUTSIDE fleet_design scope (Track 3 internal). mqtt_robot is referenced for both pattern and engine choice (it already uses chain_tree_luajit).

**2026-05-19 amendments (decisions #27–#32 — see memory.md top for full text):**

27. **Identity loaded out-of-band, NOT via Zenoh commissioning** — OVERRIDES #23's runtime-Zenoh-commissioning model. Hybrid C scheme: `ROBOT_CLASS` + `ROBOT_INSTANCE` env (required, fail-fast); `IDENTITY_DIR/state.json` for auto-generated chip_uid + first_seen + fw_version. Shared by all Linux robots (`fake_robot/lib/identity.lua`).
28. **Pi Zero 2 is bare-process target** (no Docker; 512 MB RAM unsuitable). Same code runs in container OR via systemd unit / shell launcher; bootstrap reads env from process environment regardless.
29. **Controller merely acknowledges connection** — no validation, no NACK, no uniqueness enforcement. Robot is sovereign; controller is a passive registry. Connection KB has no NACK branch; timeout → retry-with-backoff is the only failure path.
30. **ACK wire shape: Zenoh RPC on `fleet/admin/register`** — synchronous `cli:call(...)`, JSON request `{class, instance, chip_uid, fw_version, capabilities, ts}`, reply `{ok, controller_id, ts, echo_chip_uid}`. Uses existing `zenoh_rpc.lua` binding.
31. **Namespace setup: core leaves + `on_namespace_up` class hook.** Publishers (`state`, `heartbeat`, `capabilities`, `hardware`), subscriber (`desired_state`). Initial publish sequence on entry to `namespace_up`: capabilities → hardware → state=ready → class hook → operating → start 1 Hz heartbeat KB. Each class ships its own `class_spec.lua`. Token-name rule: `fleet/admin/<verb>[_<object>]`.
32. **Disconnect detection via passive controller heartbeat** on `fleet/admin/heartbeat` (1 Hz `{seq, ts}`). 3 s threshold (3 missed heartbeats) → `EV_DISCONNECTED` → close session, reopen, restart from `announced`. Non-blocking; symmetric with robot heartbeat.
33. **Two-clock model: monotonic ms + wall-clock REALTIME.** Both live in `lib/clock.lua`. `now_ms()` (CLOCK_MONOTONIC) for elapsed-time math (timeouts, backoff, heartbeat cadence; blackboard fields end in `_ms`). `wall_now()` (CLOCK_REALTIME + `os.date("!*t")`) for wire `ts` fields and boundary-event emission. main.lua's pump emits `CFL_SECOND/MINUTE/HOUR/DAY/MONTH/YEAR_EVENT` on field changes between consecutive ticks; suppressed on any tick where `|wall_delta - mono_delta| > 1 s` (Pi-Zero-2 NTP-step guard). Class-specific KBs use boundary events for cron-style scheduling; connection KB ignores them.

## Open work after 2026-05-19

**Design phase is complete (decisions #27–#33 all locked).** Connection KB is fully implemented and smoke-tested. Remaining items are downstream:

### Connection KB

- ✓ All five state handlers real (was the next-session work; landed same day)
- ✓ Two-clock model in place; boundary events emitted by pump
- Clock-jump guard untested under a synthetic NTP step (would need `date -s` or VM pause/resume to exercise; logic is straightforward, low risk)

### Bench convenience

- **`run.sh` launcher** for both `fake_robot/` and `bench_manager/` baking in `LUA_CPATH` / `LUA_PATH` / `LD_LIBRARY_PATH` — current bench dev requires typing them every smoke run.
- **`docker compose`** entry for the local `eclipse/zenoh` peer so `make smoke` does the whole loop.

### Class-specific work (next real KB)

- `class_spec.lua` for `fake_robot` still has a stub `on_namespace_up`; first real class spec will declare class-specific pubs/subs (e.g., `fake_counter` publisher) and demonstrate consuming a wall-clock boundary event for a scheduled task.
- First real Linux robot class (likely `car_window_controller` per CWC spec) — when this lands, `fake_robot/lib/` graduates to a shared location (decision #26 was directional, concrete path TBD).

### Server container internals (Path 1 — still open from 2026-05-18)

1. **Internal Zenoh transport between in-container processes** — TCP loopback vs Unix socket.
2. **Disk layout** — bind-mount vs named docker volume for `registry.db`, `persistence.db`.
3. **External port surface** — only the `gateway` app exposes ports; which?
4. **Application gateway split** — one `gateway` process hosting all protocols, or per-protocol?
5. **Where the server container source lives** — `nano_data_center_base/platform_containers/motioncore_server/` vs `motioncore-prototype/server_container/`?
6. **KB schema** for declaring our container in the master KB.
7. **`gateway` placeholder in platform_containers** — separate platform-level container, or stay app-internal?

### Design-broader (still open from earlier in dialog)

8. **Spin-off directory name** — `fleet_design/` is a working name.
9. **First external protocol to build** — likely NATS or KB (driven by planner per decision #21).
10. **SQLite registry schema** — not yet designed.
11. **Operator commissioning UI** — CLI tool, web UI, or both?
12. **MCU bootstrap-locator strategy** — factory-burned URL vs mDNS scout vs BLE pairing.
13. **LittleFS layout** on MCU.
14. **Naming convention discipline** across robot classes.
15. **Auth / ACL** — when blocking (probably when external apps come online).
16. **First real robot class to implement** — likely `car_window_controller` per CWC spec.
17. **Where `chains/` graduates to** when first real Linux robot lands (decision #26 was directional).

### Resolved (no longer open)

- ~~Q1 identity scheme~~ — locked as decision #27 (hybrid C: env + file)
- ~~Q2 ACK wire shape~~ — locked as decision #30 (RPC on `fleet/admin/register`)
- ~~Q3 namespace setup~~ — locked as decision #31 (core leaves + class hook)
- ~~Q4 disconnect detection~~ — locked as decision #32 (passive controller heartbeat)
- ~~Time-source~~ — locked as decision #33 (two-clock model: monotonic ms + wall-clock REALTIME)
- ~~Connection KB state handlers~~ — all five fully implemented and smoke-tested

## Cross-references

| Reference | Where |
|---|---|
| Companion memory file (this design) | `memory.md` (this directory) |
| Internal Zenoh C wrappers (existing) | `~/knowledge_base_assembly/c_programs_and_containers/build_blocks/knowledge_base/zenoh/` |
| LuaJIT Zenoh bindings (existing) | `~/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh/` |
| zenoh-pico upstream | `~/src/zenoh-pico` (v1.9.0, commit 88e0ba3) |
| libcomm dongle work (independent track) | `motioncore-prototype/continue.md` (top-level) |
| CWC class spec (relevant robot class) | `motioncore-prototype/car_door_window_controller/continue.md` |
| Auto-memory for motioncore-prototype | `~/.claude/projects/-home-gedgar-motioncore-prototype/memory/` |

## How to resume (end of 2026-05-19 session)

```bash
cd /home/gedgar/motioncore-prototype/fleet_design/
cat memory.md       # 2026-05-19 amendments at top, then 2026-05-18 base
cat continue.md     # this file — current state + open work + resume instructions
```

**Cold-start reading order (required before any work):**

1. `memory.md` — start with the **2026-05-19 Amendments** section at the top (decisions #27–#32); then base decisions #1–#26 below.
2. This file's "Locked design decisions" section (decisions #1–#32 summarized).
3. This file's "Open work after 2026-05-19" section.
4. Smoke-test the existing code (see commands below) before adding more — confirms the bench setup still works.

## Bench smoke-test recipe

End-to-end loop: docker zenohd + bench_manager + fake_robot. The `run.sh`
launchers bake in `LUA_CPATH` / `LUA_PATH` (repo-relative, picking out of
`vendor/lua/`) and the bench-only `LD_LIBRARY_PATH` for native `.so` files.

```bash
# 1. Start zenohd if not already running
docker run -d --rm --name zenoh-smoke \
    -p 17447:7447/tcp -p 17447:7447/udp \
    eclipse/zenoh:latest \
    --listen tcp/0.0.0.0:7447 --listen udp/0.0.0.0:7447

# 2. fleet_manager — the robot controller (terminal A)
ZENOH_LOCATOR=tcp/127.0.0.1:17447 ./server/fleet_manager/run.sh

# 3. fake_robot (terminal B)
ROBOT_CLASS=fake_robot ROBOT_INSTANCE=alpha IDENTITY_DIR=/tmp/fake_alpha \
ZENOH_LOCATOR=tcp/127.0.0.1:17447 ./fake_robot/run.sh

# 4. DSL recompile (if you edit chains/connection.lua) — build-time only,
#    needs the external chain_tree DSL builder (not vendored; never runs
#    on Pi). Path is intentionally external.
DSL_DIR=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/chain_tree_luajit/lua_dsl
LUA_PATH="$DSL_DIR/?.lua;;" luajit fake_robot/chains/connection.lua fake_robot/chains/connection.json
```

The `run.sh` launchers point `LD_LIBRARY_PATH` at external bench locations
for the four zenoh `.so` files (libzenoh_pubsub / _rpc / _token + libzenohpico).
These will be replaced by `vendor/lib-aarch64/` once we cross-compile for Pi.
Override `LD_LIBRARY_PATH` in the caller env to bypass the bench default.

## Resume here (2026-05-25 morning — check the overnight gateway)

**FIRST THING TO CHECK:** how often did the application_gateway
crash overnight, and is it currently up?

```sh
# Quick triage — from the repo root:
cd ~/motioncore-prototype/fleet_design

# 1. Is the container alive? (Up X minutes/hours)
docker ps --filter name=fleet --format '{{.Names}}\t{{.Status}}'

# 2. How many crashes overnight? (each line is one unique-signature crash event)
grep crash packaging/wsl/var/logs/supervisor.log

# 3. How many container restarts? (every flap → +1 boot)
grep -c container_boot packaging/wsl/var/logs/supervisor.log

# 4. Is the morning Discord digest in the log? (fires at 09:00 PDT)
docker logs fleet 2>&1 | grep -E 'digest delivered|daily_pull.*published'

# 5. Dashboard still serving?
curl -s http://127.0.0.1:8080/api/robots | head -c 200
```

**Expected if everything went well:** 1 boot, 0 crashes, container
"Up many hours", Discord digest fired at 09:00. The container left
running last night was a real-world test of:
- whole-container restart machinery
- persistence Bug 2 fix (rehydrate from DB on restart)
- whether the gateway heap-corruption bug (rc=134, the known
  zenoh-pico FFI heap-corruption thing — see
  `[[dashboard-polish-2026-05-24]]`) bites under steady-state
  load without dashboard polling, or only when humans poke at it

**If gateway crashed N times overnight:** that confirms the bug
fires under just-the-heartbeat/persistence-republish background
traffic, not only under dashboard polling. That would escalate the
"rebuild zenoh-pico with AddressSanitizer to chase it" task from
"someday" to "before Pi deploy." If 0 crashes, the bug is dashboard-
polling-induced only and lower priority.

After triage: continue the **container deploy to Pi 4 at
192.168.1.66** track. The image already runs unchanged on arm64
(WSL bench is Apple Silicon arm64, same as Pi 4). Just need to
move the bits over and set `NETWORK_MODE=host` in the Pi's
fleet.env.

---

## Resume here (2026-05-24 — multi-robot dashboard smoke + packaging next)

**Tracks 1 + 2 done; dashboard smoke green for both robots.** Glenn
spent ~30 min poking at the application_gateway dashboard with
`farm_soil/lacima01` (3 moisture + 2 CIMIS + heartbeat) and
`rancho_water/main` (usage/sample + usage/latest + heartbeat) both
live. Three UX gaps surfaced and got fixed inline (see
`dashboard-polish-2026-05-24` memory): status-leaf hourly charts,
leaves cache refresh-on-every-tick, stream view de-noised to just
the operationally-useful metrics. Result: moisture stream view
went from 11 chart metrics + 9 noisy table columns →
3 metrics + 5 clean columns. Generic fixes — any future robot
benefits.

The smoke also surfaced **three gotchas worth fixing before deploy**:

- **Gateway heap corruption** under sustained polling
  (`malloc(): unsorted double linked list corrupted` from inside
  the zenoh-pico FFI). Recovery is one pkill + relaunch. Auto-
  restart in container will mask, but the underlying bug is real.
- **Persistence boot-race recurs for every new robot** —
  publisher fires data within ~200 ms of its topology announce,
  persistence's sub-declarations haven't propagated back yet, data
  is silently dropped. Hit BOTH robots this smoke; rancho_water
  got a per-robot fix (boot_settle wait_time(5)), but the systemic
  fix is one edit to shared KB0 (`robot_common/chains/connection.lua`):
  insert `wait_time(5)` between `NAMESPACE_UP_HOOK` and
  `SPAWN_APP_KBS`. Single change covers every present and future
  robot class. **Do this before container packaging.**
- **Dashboard leaves cache** locked in stale partial topology
  until hard-reload — fixed in 16ea37b (always re-fetch).

Next is **container packaging** — decision #12 in the locked
decisions list, deferred since 2026-05-19 with "do this once all
the layers are stable". They are now (5 server processes:
fleet_manager, persistence, application_gateway,
notification_service, plus zenohd; 2 robot classes). See the new
Plan section at the bottom.

## Resume here (2026-05-24 — Rancho water robot landed)

**Track-2 of the three-track plan landed same day as Track-1.** New
robot `rancho_water/` runs in parallel to `farm_soil`, scrapes Glenn's
customer portal once per Pacific civil day at-or-after 09:00, formats
yesterday's hourly usage + total, and pushes via the existing
`notification_service` digest channel. End-to-end bench-verified —
`2026-05-23` real data: 25 hourly rows, 678 gallons total, delivered
to Discord. See `rancho-water-robot-2026-05-24` memory for the build
and `discord-push-done-2026-05-24` for the underlying push framework.

The big realization that simplified the design: **the Rancho portal is
JSON REST under a thin ASP.NET shell**, not HTML to scrape. The
`/api/usage/get/` endpoint returns the full day envelope including
`LeakDetected` / `ExceededFlowThreshold` / `ExceededRuntimeThreshold`
flags. Per user direction we **dropped the anomaly-rule design** —
v1 just feeds the data; v2 can watch the flags as an in-process listener.

The framework's first **second robot** — validates the "framework for
all robot controllers, not just farm_soil" claim. The shared KB0
(`robot_common/chains/connection.lua`) carried over zero-change; only
the app-KB layer changed.

One curl pitfall worth carrying forward: **never `request = "POST"`
alongside `data-urlencode` in a curl -K config**. The explicit method
forces POST on the 302 follow, but curl doesn't auto-resend the body
→ `HTTP 411 Length Required`. The `data-urlencode` lines alone make
the first request POST and let curl downgrade the redirect to GET,
which is what you want. Caught + commented in `rancho_water/lib/rancho_portal.lua`.

Next is Track-3 (HTTP / dashboard beef-up) per the original plan
(`next-tracks-2026-05-24`), or a v2 of either Track-1 / Track-2 if
real-use surfaces something. The framework now ships pushes from
two unrelated data sources to the same Discord channel.

## Resume here (2026-05-24 — Discord push framework)

**Track-1 of the three-track plan landed.** Layer-60 `notification_service`
is live, and `farm_soil` has a daily-digest leaf. End-to-end verified
twice on the bench: a synthetic publisher AND a real `farm_soil` boot
both delivered through to Discord (HTTP 204) via the LuaSec HTTPS POST.
See `discord-push-done-2026-05-24` memory for what was built and
`discord-integration-architecture-2026-05-23` for the locked pattern.

What's in:
- `server/notification_service/` — token sub on `fleet/notify/digest/daily`
  → `lib/discord_webhook.lua` POST. `_post` injection seam for tests.
  Secret in gitignored `secrets/discord.env`. Offline unit tests +
  `tests/post_test_digest.sh` wire smoke.
- `robot_common/lib/format_table.lua` — pure-Lua port of
  `~/robot_person/robots/farm_soil/format.py` (engine-free, testable).
- `farm_soil/chains/digest.lua` + `digest_user_functions.lua` —
  24-h `tick_delay` column; reads in-memory state (no persistence
  round-trip); publishes `{schema, class, instance, body}` envelope.
- `farm_soil/class_spec.lua app_kbs` += `"digest"`; IR rebuilt to 78 nodes.

Two small things noted during the bench run:
- **First boot-time digest races the other app KBs.** At boot the digest
  one_shot may fire BEFORE moisture/CIMIS have populated, yielding a
  near-empty body. Acceptable for v1 (24-h cycles after that are full);
  fix when needed by either staggering `app_kbs` spawn order or by
  swapping the column shape to wait→digest→reset.
- **LuaSec return shape**: `https.request` returns `(r, c, h, sline)`,
  not `(code, h, s)` — `r == 1` flags success, `c` is the HTTP status.
  Initial port had it wrong (read `r` as the status), printed
  `HTTP 1 table:` errors despite Discord returning 204. Pattern carried
  into `lib/discord_webhook.lua` with a comment so the next port
  (ntfy/Slack) gets it right.

Next is Track-2 (Rancho water), but it needs an open conversation
about data source / anomaly rule / robot shape — see the Plan section
below for the questions to ask before any code.

## Resume here (2026-05-23 — gateway + dashboard MVP)

**Layers 30 → 40 → 50 are wired end-to-end** for the first time.
Persistence (layer-30) now has a complete v1 read interface (slices 1+2
landed earlier same day); on top of that landed an HTTP gateway
(layer-40, `server/application_gateway/`) that fronts the query RPC and
serves a single-page dashboard (layer-50, `static/index.html`) — a
real browser view of live `farm_soil` data via the full
zenoh-RPC → HTTP → browser path. See
`application-gateway-dashboard-2026-05-23` memory for the gateway
specifics (HTTP server choice, route surface, chart auto-detect,
natural-timestamp display lesson); slice-1+2 memories
(`persistence-query-api-slice1-2026-05-23`,
`persistence-query-api-slice2-2026-05-23`) cover the RPC backend it
sits on. The two empirical gotchas still apply
(`fleet/admin/persistence_query` poison key, `/tmp` on WSL2).

Two empirical gotchas surfaced and got pinned during the slice-1 acid test:
- **Poison key**: `fleet/admin/persistence_query` deterministically
  breaks zenoh-pico's reply routing (server-side `z_query_reply` OK,
  client times out). 5×5 isolated repro; only this exact string. The
  query topic was renamed to `fleet/persistence/query`; the announce
  stays on `fleet/admin/*` for naming parity. Documented in
  `server/persistence/QUERY_API.md` with the zenoh-pico commit and
  exact failing keystr.
- **`/tmp` on WSL2 poisons construct_kb**: defaulting the DB at
  `/tmp/persistence.db` reliably crashes the stream pre-allocation
  with `SQLITE_IOERR_WRITE` (ext 5898) — same ext4 fs as `/home`,
  908 GB free, bare SQLite to `/tmp` works fine, only construct_kb's
  many-fsync pattern fails. Default DB moved to `<repo>/var/persistence.db`
  (run.sh creates the dir; `.gitignore` covers it; main.lua emits a
  WARN if anyone explicitly points the DB at bare `/tmp/foo.db`). See
  `feedback-no-tmp-for-persistent-files` memory for the general rule.

**Earlier today**, the persistence layer landed (layer-30 + decision #6
realized — see `persistence-layer-2026-05-23` memory) and the CIMIS
skill picked up multi-day backfill (drop the 15:00 cutoff, fetch a
trailing 7-day window every retry, publish each newly-finalized day to
both `/sample` stream + `/latest` status leaves — see updated
`cimis-skill-2026-05-22` memory).

### Layout (updated)

```
fleet_design/
  vendor/lua/        ct_* runtime + zenoh bindings + (NEW 2026-05-23)
                     23 kb_sqlite3 Lua files (sqlite3_helpers,
                     knowledge_base_manager, construct_* family,
                     kb_data_structures, kb_status_table, kb_stream,
                     kb_query_support, kb_rpc_*, kb_link_*, bit_mask_*)
  vendor/c/ltree/    (NEW) C source for the SQLite ltree extension —
                     PostgreSQL-style hierarchical path queries.
                     Bench: `sudo make install` -> /usr/local/lib/ltree.so;
                     Container/Pi: run.sh auto-builds.
  robot_common/      shared
    chains/          {connection.lua (KB0 builder),
                      connection_user_functions.lua}
    lib/             {identity, clock (Hinnant date arithmetic +
                      US-Pacific DST rule), zenoh_session,
                      zenoh_rpc_session, app_heartbeat}
    tests/           test_clock.lua (28 deterministic checks)
  fake_robot/        the generic test robot — class_spec, chains/build.lua,
                     the fake_counter app KB
  farm_soil/         the soil-moisture + ET-reference robot
    class_spec.lua   declares moisture + cimis KBs +
                     persistence_topology() + publish_persistence_topology
    chains/build.lua assembles 4 KBs into one IR (67 nodes)
    chains/          connection.json, moisture.lua + user_fns,
                     cimis.lua + user_fns (multi-day backfill)
    lib/             {decoder, ttn_client, moisture,
                      cimis_client, cimis_decoder}
    tests/           {test_decoder, test_moisture, test_ttn_client,
                      test_cimis_decoder, test_cimis_client}
    secrets/ttn.env  TTN_BEARER_TOKEN + CIMIS_APP_KEY (gitignored)
    main.lua         pump loop now republishes persistence_topology
                     every PERSISTENCE_TOPOLOGY_REPUBLISH_S (= 30 s)
  server/fleet_manager/   the controller (register RPC + heartbeat + registry)
  server/notification_service/  (NEW 2026-05-24) layer-60 push.
                          Token sub on fleet/notify/digest/daily →
                          discord_webhook POST via LuaSec.
                          {main.lua, lib/discord_webhook.lua, run.sh,
                          secrets/{.gitignore, discord.env.example},
                          tests/{test_discord_webhook, post_test_digest}}.
                          Robot owns content, service owns transport.
  server/application_gateway/   layer-40+50 MVP. LuaSocket-based
                          HTTP/1.1 GET server (no framework) that calls
                          fleet/persistence/query and exposes JSON +
                          a single-page dashboard. {main.lua,
                          lib/{http_server, persistence_client}.lua,
                          static/index.html, run.sh}. Default
                          127.0.0.1:8080. Dashboard auto-refreshes every
                          10 s; stream leaves render inline SVG line
                          charts with per-metric switcher; uses payload
                          natural timestamp (entry.received_at / date)
                          not the DB ingest second.
  server/persistence/     layer-30. Subscribes to fleet-wide
                          `fleet/admin/persistence_topology_announce`,
                          idempotently construct_kb's per-instance
                          tables, opens per-leaf data subs, dispatches
                          to push_stream_data / set_status_data.
                          NOW ALSO (slice 1, 2026-05-23 late evening)
                          serves a read RPC on `fleet/persistence/query`
                          + announces itself on
                          `fleet/admin/persistence_service_announce`.
                          {main.lua, lib/{persistence,query_server}.lua,
                           QUERY_API.md, test_query_client.{lua,sh},
                           run.sh}.
                          Default DB now `<repo>/var/persistence.db`
                          (NOT /tmp — WSL2 hazard, see memory).
  var/                    (gitignored) bench persistence.db lives here.
```

Each robot's `chains/build.lua` requires the shared KB0 builder + its own
app-KB modules and assembles one `connection.json` IR (farm_soil = 67 nodes
after CIMIS landed; fake_robot = 45).

### farm_soil — the irrigation robot (slices 1–5 + A–D, real-data verified)

A standalone LuaJIT chain_tree robot: polls LoRaWAN soil sensors from The
Things Network AND California's CIMIS Web API and publishes onto the local
Zenoh fabric. Standalone mode (#17) — no DCS, SQLite-only, local zenohd.

- **KB0** (shared) — connect, register, publish namespace, watch the
  controller heartbeat, supervise app KBs.
- **moisture KB** — hourly: fetch the TTN 24 h window → decode → append to a
  256-deep in-memory ring → publish each new reading per-sample on
  `farm_soil/<instance>/<device>/<location>/latest`.
- **`sample` RPC** (`farm_soil/<instance>/sample`) — pull one ring entry by
  index (0 = newest); ad-hoc queries + gap backfill.
- **cimis_station + cimis_spatial KBs** — two KB instances of one CIMIS
  skill module. **As of 2026-05-23**, each runs a 3-gate state machine
  (up-to-date / pre-window / in-window-gap-pending) — the 15:00 cutoff
  was dropped. Each in-window tick fetches a trailing
  `lookback_days = 7` window ending yesterday, then publishes every
  newly-finalized day in date order onto BOTH leaves:
  `…/cimis/<source>/sample` (stream — durable per-day record)
  and `…/cimis/<source>/latest` (status — last-write-wins).
  The 09:00 start remains: before that, CIMIS posts today's row as
  provisional and the filter cannot reliably reject it. 15 min retry
  between attempts; retrying past 15:00 / overnight is fine — the
  robot self-heals gaps end-to-end. The two-KB pattern (one module,
  N instances by source/target — the **skill-KB taxonomy**) is
  reusable for any future multi-source skill.
- **per-KB `repost` RPC** (`farm_soil/<instance>/cimis/<source>/repost`) —
  empty request, returns the latest recorded reading JSON or the literal
  `null`. Solves late-subscriber catch-up (zenoh-pico has no retained
  storage).
- **honest heartbeat** — every ~3 s KB0 publishes `…/heartbeat`
  `{ts, state, apps}`, rolling up each app KB's stamped health.

Verified live:
- moisture: 64–67 real uplinks/fetch from the lacima ranch (3 sensing
  points) — per-sample published + received, the `sample` RPC, heartbeats.
- CIMIS (2026-05-23 10:32 PDT, fresh-state smoke): both KBs ran the
  full 7-day backfill (2026-05-16..05-22) in chronological order onto
  both `/sample` and `/latest` leaves; 28 wire publishes received by an
  independent subscriber in publication order; repost RPC returned the
  freshest day for both sources.
- Persistence (2026-05-23 10:55 PDT): cold persistence.db, robot first,
  persistence subscribed → 74 valid stream rows (7 CIMIS station + 67
  moisture) + 3 status rows. Read-back via KBDS:get_status_data and
  kb.stream:get_latest_stream_data matches the wire byte-for-byte.
- Late-joining persistence (2026-05-23 11:31 PDT): robot up first +
  publishing for 10 s, persistence cold-started; caught the next 30 s
  periodic topology republish, ran schema reconcile (+8 new leaves,
  new kb), opened 8 data subs, began landing heartbeat dispatches.
- Persistence query API slice 1 (2026-05-23 ~14:00 PDT, final smoke):
  test client received the service-announce within seconds, called
  `list_kbs()` → `farm_soil_lacima01 (leaf_count=8)`,
  `latest(kb_name, "heartbeat")` →
  `state=operating apps=[moisture=ok,cimis_station=ok,cimis_spatial=ok]`,
  all three negative envelope checks (unsupported_op / not_found /
  bad_request) returned the right codes. Exit 0.

### THE zenoh lesson — publish per-sample, never blobs

zenoh-pico's pub/sub **silently drops multi-KB payloads** (a ~7 KB value
never arrived; ~600 B is fine — confirmed by a real-data smoke). So the robot
publishes each reading as its own small message, never the 256-ring as one
object. The vendored bindings have **no get-from-storage** and zenohd runs no
storage — which is why the robot holds the ring in memory and serves it by RPC.

### Commits since the 2026-05-21 wrap

`311d440` re-vendor ct_builtins (time-window leaves) · `6c739ee` graduate
KB0 + lib → robot_common · `7bbf981` farm_soil skill modules · `d53ab75`
farm_soil scaffold + moisture KB · `6f6ac8c` republish RPC · `88ebd0b`
per-sample publish + `sample` RPC · `7ae3cd6` slice 5 (KB0 app-KB
heartbeat) · `c4b91b4` wrap (continue.md 2026-05-22) · `7954c52` CIMIS
skill (slices A–D — Pacific clock, cimis_client + decoder, two KB
instances, repost RPC, live-verified). 2026-05-23: `f68d1c1` CIMIS
multi-day backfill (drop 15:00 cutoff, 7-day lookback, sample+latest
leaves) · `59f473c` persistence layer (vendor kb_sqlite3 stack,
server/persistence/, robot-side topology announce + 30s periodic
republish; three-smoke verified). Parallel RA4M1-track commits
(`b9da8b7` mode-2 spectral scaffolding · `ed9965d` wrap · `db4a4eb`
CMSIS-DSP lifted · `83baaed` spectral hardware-verified).
Engine repo (`~/knowledge_base_assembly`): `77ec769b` time-window leaves.
2026-05-23 late evening: `6a22566` persistence query RPC slice 1
(`latest()` + `list_kbs()`, service-announce, envelope + size-cap, two
gotchas pinned with precise workarounds) · `1d2cb3f` slice 2
(`stream()`/`latest_stream()`/`list_leaves()`, id-based cursor +
iterative size-trim; kb_stream gains after_id+order_by; KBDS facade
gap closed) · `bbd8944` application_gateway (LuaSocket HTTP + JSON +
single-page SVG-chart dashboard, natural-timestamp display, cjson
empty-array fix; layers 40+50 MVP).

### Bench smoke

```
# zenohd router:
docker run -d --name fleet-zenohd -p 7447:7447/tcp -p 7447:7447/udp \
  eclipse/zenoh --listen tcp/0.0.0.0:7447 --listen udp/0.0.0.0:7447
# fleet_manager:
unset LUA_CPATH LUA_PATH
server/fleet_manager/run.sh &
# persistence (one-time: cd vendor/c/ltree && sudo make install).
# DB default = <repo>/var/persistence.db — do NOT point at /tmp on
# WSL2 (poisons construct_kb; main.lua emits a WARN if you try).
unset LUA_CPATH LUA_PATH
server/persistence/run.sh &
# farm_soil (needs TTN_BEARER_TOKEN + CIMIS_APP_KEY in farm_soil/secrets/ttn.env):
unset LUA_CPATH LUA_PATH
(cd farm_soil && ROBOT_CLASS=farm_soil ROBOT_INSTANCE=lacima01 \
   IDENTITY_DIR=$PWD/identity ./run.sh) &
# query the persistence DB over Zenoh (acid-test smoke client):
unset LUA_CPATH LUA_PATH
server/persistence/test_query_client.sh
# HTTP gateway + dashboard (http://127.0.0.1:8080/):
unset LUA_CPATH LUA_PATH
server/application_gateway/run.sh &
# notification service (needs DISCORD_WEBHOOK_URL in
# server/notification_service/secrets/discord.env — gitignored):
unset LUA_CPATH LUA_PATH
server/notification_service/run.sh &
# wire smoke (publishes one synthetic digest → real Discord POST):
server/notification_service/tests/post_test_digest.sh
# rancho_water robot (needs RANCHO_WATER_ACCOUNT + _PASSWORD; falls back
# to farm_soil/secrets/ttn.env). Daily-gate fires at 09:00 Pacific.
unset LUA_CPATH LUA_PATH
(cd rancho_water && ROBOT_CLASS=rancho_water ROBOT_INSTANCE=main \
   IDENTITY_DIR=$PWD/identity ./run.sh) &
# rebuild rancho IR after a chains/ edit:
luajit rancho_water/chains/build.lua rancho_water/chains/connection.json
# inspect what persistence is storing (direct SQLite, read-only):
sqlite3 var/persistence.db "SELECT path, label FROM knowledge_base"
sqlite3 var/persistence.db \
  "SELECT path, COUNT(*) FROM knowledge_base_stream WHERE valid=1 GROUP BY path"
# rebuild an IR after a chains/ edit:
luajit farm_soil/chains/build.lua farm_soil/chains/connection.json
```

`unset LUA_CPATH LUA_PATH` is important — the host's interactive shell
has Lua-5.4-ABI paths set by luarocks that crash LuaJIT's cjson loader.
The run.sh scripts set the correct LuaJIT-ABI paths only if the env is
empty.

The vendored bindings are still **client-mode + zenohd-router only** — bench
and container tests need the `zenohd` router above. Pi Zero 2 deploy (no
containers) remains a separate, unsolved problem.

## Plan for next session (2026-05-25 — packaging + deploy)

The five server processes (`fleet_manager`, `persistence`,
`application_gateway`, `notification_service`, plus `zenohd`) and
two robot classes (`farm_soil`, `rancho_water`) are all stable.
Time to bake them into images and stand them up on a real target.

**First action 2026-05-25**: land the systemic boot-race fix before
anything else (one `wait_time(5)` between `NAMESPACE_UP_HOOK` and
`SPAWN_APP_KBS` in `robot_common/chains/connection.lua`, then
rebuild both robots' IRs). Without this, every fresh-DB deploy will
silently drop initial data. ~10 minutes; smoke-verify by wiping
`var/persistence.db` and confirming all leaves land on the first
boot of each robot.

Then container packaging, decision #12. Open questions to align
on up-front:

1. **Per-process or per-controller image?** Five processes; ship
   one image per process (5 images) or one image that runs them
   all under a supervisor? Operationally I lean per-process —
   matches the decision-#13 "five layers, five processes" framing,
   gives per-layer restart and per-layer logs, and a supervisor
   is one more thing to maintain. Open to "one image per
   controller" if deploy-time simplicity wins.

2. **Compose vs systemd vs k8s for v1?** The target is **Pi Zero 2
   bare process** per decision #28, so a real production deploy is
   actually bare LuaJIT + systemd unit per process — no container
   runtime on a Pi Zero 2. Containers are for dev / staging / fleet
   controller (the not-Pi-side). So we probably want BOTH: a
   docker-compose for the laptop/Mac dev experience, and systemd
   unit files for the Pi.

3. **Image base?** Likely `debian:bookworm-slim` or
   `ubuntu:24.04` — we need LuaJIT + LuaSocket + LuaSec + SQLite +
   curl. Alpine adds musl-vs-glibc friction with the zenoh-pico
   binding's prebuilt `.so` (currently aarch64 GNU/Linux), so
   probably not Alpine v1.

4. **Where does `zenohd` live in the picture?** Decision #16:
   `zenohd is NOT platform infrastructure — it ships inside this
   container; serves only the robots under this controller.` That
   means each controller deployment includes its own zenohd; not
   shared. Easy with compose; with systemd it's one more unit.

5. **Secrets handling at deploy.** Today secrets live in
   `farm_soil/secrets/ttn.env` and
   `server/notification_service/secrets/discord.env`. For
   containers we need either env-var injection at `docker run`
   time, or bind-mounted `secrets/` dirs. For Pi systemd, the
   `secrets/*.env` files persist in `/etc/fleet_design/secrets/`
   and units `EnvironmentFile=` them. No vault yet.

**Held / lower-priority** (don't pick these up before packaging):
- v2 Discord severity routing (waits for Track-2 alert listener).
- Track-2 anomaly listener (reads rancho's `LeakDetected` /
  `ExceededFlowThreshold` flags from persistence, pushes CRITICAL).
- Track-3 dashboard items (time-proportional X-axis, "show more"
  pagination, 0.0.0.0 bind, live-update SSE channel). Move into
  follow-up once deploy works.
- Gateway heap-corruption chase (needs sanitizer-built zenoh-pico).
- Decommissioning tool. zenoh-pico upgrade.

## Plan archive (2026-05-25 — Track 3, or first real-use feedback)

Tracks 1 and 2 both landed 2026-05-24. The natural next thing is
**Track-3 (HTTP / dashboard beef-up)**, but it should be pre-empted by
either of these if they surface:

1. **First real-use feedback from the Discord pushes.** Two messages
   land in Glenn's Discord daily (farm_soil digest + rancho_water
   report). After 24–48 h of real use, expect operator feedback on
   format / signal-to-noise / what's missing. That feedback drives
   higher-priority work than Track-3 polish.

2. **v2 of Track-1 or Track-2** if real-use indicates need:
   - Track-1 v2 candidates: severity routing (multi-channel),
     fingerprint dedup, retry-on-429, persist `last_published_date`
     across reboots.
   - Track-2 v2 candidates: alert when `LeakDetected` /
     `ExceededFlowThreshold` is true (in-process listener that
     publishes to a CRITICAL channel — needs Track-1 v2 severity
     routing first), historical chart on the dashboard fed by the
     persistence `usage/sample` stream.

If Track-3 wins, the inventory from
`application-gateway-dashboard-2026-05-23` and
`next-tracks-2026-05-24` stand: time-proportional X-axis, "show more"
pagination, 0.0.0.0 bind, curated default columns, optional
live-update SSE channel.

## Plan archive (2026-05-25 — Track 2: Rancho water — DONE 2026-05-24)

Track-1 (Discord push) is done — see Resume here (2026-05-24). The
next session opens Track-2: the **Rancho water daily-usage skill**.
This is the first real-user validation of the push framework
(motivation: Glenn lost ~$1000 to a bad pump that ran undetected;
this skill exists to make that not happen again).

**Don't start coding until the data-source conversation happens.**
Four questions to put to the user up front:

1. **Data source for the water-meter reading.** City API? On-premise
   meter with a pulse counter / Modbus / TTN-LoRaWAN bridge? Picks
   the schema, the polling cadence, the skill's identity.
2. **Anomaly rule.** Trailing-7-day-mean delta? Hard upper threshold
   (leak)? Hard lower threshold during a scheduled pump-cycle window
   (pump failure)? If usage data from the $1000 incident exists, use
   it to validate the rule choice before committing to one.
3. **Skill shape.** Separate `rancho_water` robot (parallel to
   `farm_soil`, different identity, different cadence, different
   source) OR a skill-KB inside an existing robot? Separate is the
   second-robot test of the "framework for all robots" thesis.
4. **Severity routing.** v1 push is one webhook, one channel — fine
   for the daily-summary digest. The pump-failure alert needs
   *some* distinction (severity prefix in the body for v1? promote
   to v2 routing?). Decide which v1 lever to use before coding.

Track-3 (HTTP/dashboard beef-up) stays queued behind Track-2 unless
Track-2 surfaces a real-time-visualization need that promotes the
live-update SSE channel into Track-2.5.

**First action 2026-05-25**: read this section, read
`next-tracks-2026-05-24` + `discord-push-done-2026-05-24` memories,
then put the four Track-2 questions above to the user. No code
before alignment.

## Plan archive (2026-05-24 — three tracks, Discord first; TRACK 1 DONE)

Framing: **fleet_design is a framework for all robot controllers, not
just farm_soil.** Three parallel tracks emerged from this wrap; do
them in order, but each one EXERCISES or DEPENDS on the prior. Be
willing to revise after each — the user's framing: *feel our way
through, not lock-step.*

### Track 1 — Discord integration (DO THIS FIRST)

The aligned architectural pattern (see
`discord-integration-architecture-2026-05-23` memory) is:

- **Robot owns content, service owns transport.** Robot publishes the
  *finished message body* on a Zenoh event topic; the new
  `server/notification_service/` does only topic → webhook POST. No
  schema knowledge in the service, no Discord knowledge in the robot.
- **LuaJIT in-tree, not Python sidecar.** Port the 109-line
  `~/robot_person/skills/discord/main.py` + `webhook_client.py` to
  ~80 lines of LuaJIT using `socket.http` + LuaSec for HTTPS. Reuses
  the existing single-runtime container; no Python/venv added.
- **Push-only v1.** Bot/pull (slash commands, ack buttons) is real
  scope and waits until push has a week of real use.
- **One webhook, one channel.** Severity routing is config-only and
  ships in v2 when a CRITICAL event actually exists to route.

**Concrete v1 steps:**
1. `server/notification_service/main.lua` + `lib/discord_webhook.lua`
   (LuaJIT port — handle 2000-char truncation, 204 success, the
   Cloudflare-friendly `User-Agent` gotcha, no retry on 429 yet).
2. Subscribe to one well-known token `fleet/notify/digest/daily`
   (same well-known-channel workaround as
   `fleet/admin/persistence_topology_announce` —
   per-class/per-instance subscription would need token-per-key + a
   discovery channel; defer until needed).
3. Add a chain_tree leaf in `farm_soil/chains/` that on a 24-h timer
   reads the moisture + CIMIS streams the robot already publishes,
   formats a text body (port `~/robot_person/robots/farm_soil/format.py`
   — pure Lua, ~60 lines, engine-free), and publishes on the digest
   topic.
4. Hardcode the webhook URL in `server/notification_service/secrets/discord.env`
   (gitignored). Document in continue.md and the new memory.
5. Smoke: kill stack cleanly, restart, wait for the daily timer to
   fire (or trigger via a one-shot test publisher), confirm phone
   gets the message.

**Locked (2026-05-23 evening)**: digest fires from an **internal
chain_tree timer** (24-h `tick_delay` inside the robot), NOT an
external `systemd.timer` + Zenoh RPC. Keeps the controller container
self-contained. Don't mirror the Python demo's external-trigger
pattern. No remaining open Track-1 questions — proceed straight to
step 1 on resume.

### Track 2 — Rancho water daily usage skill (FIRST CONCRETE USER)

**Motivation (locked, personally important):** Glenn lost $1000 to a
bad pump that went undetected. The Rancho water skill exists to
**make that not happen again**. It is the first end-to-end real-user
validation of the Discord framework. Track-2 cannot start until
Track-1 push lands.

Open work needed for Track-2 design (next session, after Discord
v1):

- **Data source**: where does the daily water-meter reading come
  from? City API? On-premise meter with pulse counter / Modbus?
  TTN / LoRaWAN? Needs a discovery conversation with the user before
  any code. Drives schema, polling cadence, identity.
- **Anomaly detection**: simple rule (today's usage vs trailing 7-day
  mean, alert on > N% delta), OR threshold-based (>X gal/day = leak;
  <Y gal/day during scheduled pump cycle = pump failure). Pick the
  one that catches the $1000 incident in retro — if data exists from
  that period.
- **Output**: piggybacks Track-1. Daily summary → digest channel
  (push v1 surface); pump-failure alert → eventually CRITICAL
  channel (push v2). For v1, both go to the single channel with
  clear severity prefix in the text body.
- **Skill shape**: separate `rancho_water` robot (parallel to
  `farm_soil`)? Or a skill-KB inside farm_soil? Probably separate
  robot — different data source, different cadence, different
  identity. Validates fleet_design's "framework for all robots"
  thesis.

### Track 3 — HTTP / dashboard beef-up (QUEUED, do last)

Listed in priority order, all small (gateway/dashboard memory has
the full inventory):
- Drop noisy `entry` / `units` / `schema` columns from the pivoted
  stream-rows table by default; "raw" toggle to expand.
- Time-proportional X-axis (currently evenly-spaced index).
- "Show more" button to walk pagination cursors in-browser.
- Bind `0.0.0.0` (not 127.0.0.1) so the dashboard is reachable from
  the phone on the same Wi-Fi.
- Live-update push channel: persistence republishes
  `fleet/persistence/<kb>/<path>/latest` on every write; gateway
  forwards via Server-Sent Events to the browser. Real-time graphs.
  Mid-size: probably one session.

After Track-3, **container packaging** (still deferred) becomes the
natural next thing — at that point all four server processes
(`fleet_manager`, `persistence`, `application_gateway`,
`notification_service`) are stable and benefit from being baked into
images.

### Held / lower-priority

- Decommissioning tool (operator action to retire a removed
  `(class, instance)` — trim DB rows + kb_info).
- zenoh-pico upgrade (re-test the `fleet/admin/persistence_query`
  poison key; drop rename workaround if fixed).
- Second robot class beyond `farm_soil` + `rancho_water` (e.g. MCU
  class per decision #25).

**First action 2026-05-24**: read this file + the
`discord-integration-architecture-2026-05-23` and
`next-tracks-2026-05-24` memories, then begin Track-1 step 1
(`server/notification_service/` skeleton). The timer question is
locked — internal `tick_delay`, no systemd trigger.

**Reference paths (dev-machine orientation only — NOT used at runtime):**
The runtime uses `fleet_design/vendor/lua/` exclusively (see `vendor/PROVENANCE.md`).

- chain_tree DSL (build-time): `~/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/chain_tree_luajit/lua_dsl/`
- chain_tree runtime (`vendor/lua/ct_*.lua` source): `…/chain_tree_luajit/runtime_dict/`
- chain_tree test corpus: `…/chain_tree_luajit/dsl_tests/incremental_binary/`
- Zenoh bindings (`vendor/lua/zenoh_*.lua` + bench `.so` source): `~/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh/`

## What NOT to do

- Don't redesign the namespace structure — locked (#1–#10, #31).
- Don't introduce a central schema file — firmware is the schema (#9, #20).
- Don't expose Zenoh to external apps — that's the encapsulation boundary (#1).
- Don't reach for ROS / VDA 5050 patterns — wrong reference model.
- Don't muddle s_engine and chain_tree — distinct engines (s_engine = ARM dongles; chain_tree = fleet_design).
- Don't re-add Zenoh commissioning round-trips — #23 rescinded by #27; identity is env+file.
- The real controller is `server/fleet_manager/`; `bench_manager/` was retired 2026-05-21.
- Don't propose chain_tree DSL from API primitives — study `dsl_tests/` + the `chain_tree_dsl_runtime_model.md` memo first.
- Don't publish multi-KB Zenoh values — zenoh-pico silently drops them. Publish per-sample (small messages); serve bulk data by RPC, one small reply per request.
- Don't put SQLite-style persistent files in bare `/tmp` on WSL2 — `construct_kb`'s stream pre-allocation crashes with `SQLITE_IOERR_WRITE` (ext 5898). Use `<repo>/var/` for bench artifacts; containers exempt. See `feedback-no-tmp-for-persistent-files`.
- Don't use `fleet/admin/persistence_query` (or restore the rename without re-testing) — this exact string deterministically breaks zenoh-pico reply routing in commit `88e0ba3`. Other `fleet/admin/*` topics route fine; only this one is poisoned. See `server/persistence/QUERY_API.md` for the repro + provenance.
