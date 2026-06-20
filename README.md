# robot_operator

Standalone, self-contained home for the **operational robot fleet** — extracted
from the `motioncore-prototype` monorepo so it carries none of the unrelated
firmware/hardware projects (ra4m1, cfl_avr, linux, samd21, …).

The monorepo copy is left in place untouched; this repo is an independent copy
with fresh git history.

## Layout

```
fleet_operations/        the running robots + the framework they share
  irrigation_analytics/    LaCima irrigation monitor (KB0..KB4 chain_tree robot)
                           + .claude/skills/irrigation-ops  (the operator skill)
  farm_soil/               TTN soil-moisture + ETo robot
  rancho_water/            customer-portal water-usage robot
  robot_common/            shared chain_tree engine, clock, heartbeat
  server/                  persistence, notification, gateway, fleet_manager
  vendor/  identity/       vendored Lua + C, fleet identity
  packaging/               shared build_assets (incl. the committed .so)
  packaging_irrigation_analytics/   Dockerfile + build.sh + start.sh

third_party/             vendored native sources (so we can build the .so offline)
  zenoh-pico/              upstream zenoh-pico (CMake)            -> libzenohpico.so
  zenoh_libs/              the LuaJIT zenoh C shim (token/pubsub/rpc)

build_libs.sh            build ALL native .so from vendored source (offline)
```

## Totally independent — build everything from source

No `~/src`, no `~/knowledge_base_assembly`, no network needed.

```bash
./build_libs.sh                 # compile zenoh-pico + the 3 shims from source,
                                # stage into fleet_operations/packaging/build_assets/lib
```

The 4 `.so` are also **committed as vendored binaries**, so the image build
works even without running `build_libs.sh` first — run it to regenerate them
from source (after a zenoh-pico bump, an arch change, or a shim fix).

## Build + deploy the irrigation image

```bash
IMAGE_TAG=nanodatacenter/irrigation-analytics:<tag> \
  fleet_operations/packaging_irrigation_analytics/build.sh      # regens IR + docker build
docker save <image> | ssh robot docker load
ssh robot 'sed -i "s#^IMAGE_TAG=.*#IMAGE_TAG=<image>#" /home/pi/farm/irrigation_analytics/fleet.env'
ssh robot 'cd /home/pi/farm/irrigation_analytics && bash start.sh'
```

Production runs on the Pi (`ssh robot` = pi@192.168.1.66); the controller is
`ssh pi@irrigation`. Operating runbook + procedures live in
`fleet_operations/irrigation_analytics/.claude/skills/irrigation-ops/`.

## Residual note (bench-mode only)

A few `run.sh` (non-container bench runs) still reference `~/knowledge_base_assembly`
for shared Lua building-blocks via `LUA_PATH`. The **container build + deploy is
fully self-contained**; only running a robot *outside* Docker from a bare clone
would need those Lua modules vendored too. Deferred until needed.

## Appendix: Alexa smart-plug auto power-on (farm_soil)

The irrigation Pi (`ssh pi@irrigation`, 192.168.1.146) is powered by an **Amazon
Basics smart plug** — Alexa-only, with no LAN API. After a power outage,
`farm_soil`'s `irrigation_watchdog` powers it back on automatically through
**Voice Monkey** (a free Alexa skill exposing an HTTPS trigger webhook).
`farm_soil` runs on the always-on Mcfarland Pi, so it can drive the plug even
while the irrigation Pi is dark — the robot that recovers the box is never the
box being recovered.

**Data path:** watchdog finds the Pi unreachable → `farm_soil/lib/plug_client.lua`
fires the Voice Monkey v3 trigger → Alexa runs a Routine that turns the plug
**On** → watchdog re-probes. After `recover_max_attempts` it falls back to the
Discord "reset the Alexa plug" nag. A single "turn On" is idempotent (it won't
cut power to a running Pi); a non-power outage is a harmless no-op.

### One-time Alexa app setup

1. Enable the **Voice Monkey** skill in the Alexa app and link your account.
2. At `app.voicemonkey.io/routines`, create a **Routine Trigger** device and copy
   its generated id (e.g. `irrigation-pi-power-3f7k2-d4ukm` — Voice Monkey appends
   a random suffix; the API matches on the exact id).
3. Alexa app → **Routines → +**:
   - **When:** Smart Home → device `Alexa Voice Monkey v3` → your trigger event.
   - **Action:** Smart Home → the irrigation plug → **Power → On**. Save and enable.
     (A **group** containing only the plug works if the plug isn't individually listed.)
4. Get an API token at `app.voicemonkey.io/tokens`.

### Wiring

| Piece | Where |
| --- | --- |
| API token (secret) | `VOICEMONKEY_TOKEN` in the Pi's `secrets/ttn.env` (sourced into the container; never committed) |
| Trigger device id | `M.plug.device` in `fleet_operations/farm_soil/class_spec.lua` |
| Recovery tunables | `M.irrigation_watchdog.recover_{after_s,cooldown_s,max_attempts}` |
| Disable | set `M.plug.enabled = false` or blank the token → reverts to the manual Discord nag |

Smoke test (turns the plug on now):

```sh
curl "https://api-v3.voicemonkey.io/trigger?token=$VOICEMONKEY_TOKEN&device=<trigger-id>"
# -> {"success":true,"data":"OK"}
```
