# robot_operator

Standalone, self-contained home for the **operational robot fleet** — extracted
from the `motioncore-prototype` monorepo so it carries none of the unrelated
firmware/hardware projects (ra4m1, cfl_avr, linux, samd21, …).

This repository is **totally independent**: it vendors the native zenoh
transport sources and builds every `.so` from source, with no `~/src`, no
`~/knowledge_base_assembly`, and no network access required.

## What's here

| Area | Path | What it is |
|---|---|---|
| Fleet framework + robots | `fleet_operations/` | The running robots and the `chain_tree` LuaJIT framework they share. |
| Native transport sources | `third_party/zenoh-pico` | Upstream zenoh-pico (CMake) → `libzenohpico.so`. |
| Zenoh binding shims | `third_party/zenoh_libs` | LuaJIT C shims (token / pub_sub / rpc). |
| Offline lib build | `build_libs.sh` | Compiles **all** native `.so` from vendored source. |

## The robots

| Robot class | Role |
|---|---|
| `irrigation_analytics` | LaCima irrigation monitor (KB0..KB4 `chain_tree` robot) — the production fleet. |
| `farm_soil` | TTN soil-moisture + CIMIS ETo robot. |
| `rancho_water` | Customer-portal water-usage robot. |

All robots run the same KB0 + app-KB supervisor pattern on the
`chain_tree_luajit` engine, share one local Zenoh fabric, persist to SQLite,
and ship in a single Docker container with their peers. The framework itself is
documented under **[Fleet framework](fleet/index.md)**.

## Read next

- **[Build from source](build-from-source.md)** — compile the native libs and
  the container image, fully offline.
- **[Deploy to the Pi](deploy-to-pi.md)** — ship the image to the production
  Raspberry Pi and bring the stack up.
- **[Fleet framework → Architecture](fleet/architecture.md)** — how the
  `chain_tree` engine, KBs, and wire shapes fit together.
- **[Operations](fleet/operations.md)** — running-fleet procedures.

## License

MIT — see [`LICENSE`](https://github.com/glenn-edgar/robot_operator/blob/main/LICENSE).
