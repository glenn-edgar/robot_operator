# Build from source

Everything builds offline from vendored sources — no `~/src`, no
`~/knowledge_base_assembly`, no network.

## 1. Native libraries

```bash
./build_libs.sh          # build everything
./build_libs.sh clean    # wipe build dirs first, then build
```

`build_libs.sh` compiles, in dependency order, and stages the results into
`fleet_operations/packaging/build_assets/lib/`:

| Step | Source | Output |
|---|---|---|
| 1 | `third_party/zenoh-pico` (CMake) | `libzenohpico.so` |
| 2 | `third_party/zenoh_libs/c/token` | `libzenoh_token.so` |
| 3 | `third_party/zenoh_libs/c/pub_sub` | `libzenoh_pubsub.so` |
| 4 | `third_party/zenoh_libs/c/rpc` (→ token) | `libzenoh_rpc.so` |

`ltree.so` is **not** built here — it is compiled inside the container from
`vendor/c/ltree` (see the Dockerfile).

The 4 `.so` are also **committed as vendored binaries**, so the image build
works even without running `build_libs.sh` first. Re-run it to regenerate them
from source after a zenoh-pico bump, an arch change, or a shim fix. The build is
reproducible: a fresh build produces binaries byte-identical to the committed
ones.

## 2. Container image

```bash
IMAGE_TAG=nanodatacenter/irrigation-analytics:<tag> \
  fleet_operations/packaging_irrigation_analytics/build.sh
```

`build.sh` stages the `.so` (using the committed/freshly-built ones if present),
regenerates the chain IR (`luajit chains/build.lua chains/connection.json`) so
the baked IR can't go stale, then runs `docker build`. The result is a
~356 MB `linux/arm64` image.

## Architecture parity (load-bearing)

!!! warning "The build host must match the Pi's architecture"
    The whole offline, vendored-`.so` scheme works because the dev host and the
    Pi 4 are both **arm64** — the image and the committed `.so` ship to the Pi
    unchanged, with no cross-compile and no `buildx`.

    If the build ever moves to an **x86** machine, the committed `.so` and the
    image will not run on the Pi until `buildx` (or an arm64 builder) is added.
    Nothing in the repo enforces this today.

Verify what you built:

```bash
file fleet_operations/packaging/build_assets/lib/libzenohpico.so   # → ARM aarch64
docker image inspect <image> --format '{{.Os}}/{{.Architecture}}'  # → linux/arm64
```
