#!/usr/bin/env bash
# run.sh — launcher for the fleet_manager layer of the robot controller.
#
# Optional env: ZENOH_LOCATOR (default tcp/127.0.0.1:7447),
#               CONTROLLER_ID (default fleet-manager-1)
#
# Mirrors fake_robot/run.sh: repo-relative LUA_PATH out of vendor/lua, system
# LuaJIT-ABI cjson on LUA_CPATH, bench-only LD_LIBRARY_PATH for the native
# zenoh .so files (swapped for vendor/lib-aarch64/ at Pi deploy).

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

# LuaJIT-compatible cjson — must precede the user's Lua-5.4-ABI luarocks copy.
: "${LUA_CPATH:=/usr/local/lib/lua/5.1/?.so;;}"
export LUA_CPATH

export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;;"

# TODO Pi/container deploy: replace bench LD_LIBRARY_PATH with vendor/lib-*.
if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/main.lua" "$@"
