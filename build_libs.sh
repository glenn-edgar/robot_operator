#!/bin/bash
# build_libs.sh — build ALL native .so from vendored source, fully offline.
#
# This is what makes ~/robot_operator totally independent: it compiles the
# zenoh transport stack from source (no ~/src, no ~/knowledge_base_assembly)
# and stages the results where the image build (packaging_irrigation_analytics/
# build.sh) expects them.
#
# Build order (dependency-driven):
#   1. zenoh-pico (upstream, CMake)         -> libzenohpico.so  (+ generated headers)
#   2. zenoh_libs/c/token  (shim)           -> libzenoh_token.so
#   3. zenoh_libs/c/pub_sub (shim)          -> libzenoh_pubsub.so
#   4. zenoh_libs/c/rpc    (shim, ->token)  -> libzenoh_rpc.so
#   (ltree.so is built INSIDE the container from vendor/c/ltree — see Dockerfile)
#
# Output: fleet_operations/packaging/build_assets/lib/*.so  (the 4 staged libs).
# Re-run any time to regenerate the vendored binaries from source.
#
# Usage:  ./build_libs.sh           # build everything
#         ./build_libs.sh clean     # wipe build dirs first
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICO="$ROOT/third_party/zenoh-pico"
SHIM="$ROOT/third_party/zenoh_libs/c"
STAGE="$ROOT/fleet_operations/packaging/build_assets/lib"
JOBS="$(nproc 2>/dev/null || echo 4)"

if [ "${1:-}" = "clean" ]; then
    echo "==> clean: wiping build dirs"
    rm -rf "$PICO/build" "$SHIM"/{token,pub_sub,rpc}/build
fi

# --- 1. zenoh-pico (CMake, shared lib) ------------------------------------
echo "==> [1/4] building zenoh-pico (CMake) ..."
cmake -S "$PICO" -B "$PICO/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON >/dev/null
cmake --build "$PICO/build" -j "$JOBS" >/dev/null
# Populate lib-combined (the layout the shim Makefiles expect via ZENOH_PICO_LIB).
mkdir -p "$PICO/lib-combined"
PICO_SO="$(find "$PICO/build" -name 'libzenohpico*.so' | head -1)"
PICO_A="$(find "$PICO/build" -name 'libzenohpico*.a'  | head -1)"
[ -n "$PICO_SO" ] || { echo "ERROR: libzenohpico.so not produced" >&2; exit 1; }
cp -f "$PICO_SO" "$PICO/lib-combined/libzenohpico.so"
[ -n "$PICO_A" ] && cp -f "$PICO_A" "$PICO/lib-combined/libzenohpico.a"
echo "    zenoh-pico OK: $(basename "$PICO_SO")"

# --- 2-4. shims (Makefiles), token first ----------------------------------
export ZENOH_PICO_HOME="$PICO"
for mod in token pub_sub rpc; do
    echo "==> building shim: $mod ..."
    make -C "$SHIM/$mod" libs ZENOH_PICO_HOME="$PICO" >/dev/null
done

# --- stage the 4 .so into build_assets/lib --------------------------------
echo "==> staging .so -> $STAGE"
mkdir -p "$STAGE"
cp -f "$PICO/lib-combined/libzenohpico.so" "$STAGE/libzenohpico.so"
cp -f "$SHIM/token/build/libzenoh_token.so"    "$STAGE/libzenoh_token.so"
cp -f "$SHIM/pub_sub/build/libzenoh_pubsub.so" "$STAGE/libzenoh_pubsub.so"
cp -f "$SHIM/rpc/build/libzenoh_rpc.so"        "$STAGE/libzenoh_rpc.so"

echo "==> done. staged libs:"
ls -la "$STAGE"/*.so | awk '{print "    "$NF" "$5"B"}'
