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
