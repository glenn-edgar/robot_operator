#!/usr/bin/env bash
# run.sh — launcher for the rancho_water robot.
#
# Required env:   ROBOT_CLASS, ROBOT_INSTANCE
# Optional env:   IDENTITY_DIR (default ./identity), ZENOH_LOCATOR
#                 (default tcp/127.0.0.1:7447), RANCHO_WATER_TICK_HZ
#                 (default 10), RANCHO_WATER_ACCOUNT_NUMBER
#
# Sources rancho_water/secrets/rancho.env if present (RANCHO_WATER_ACCOUNT
# + _PASSWORD); falls back to farm_soil/secrets/ttn.env so we can run today
# without duplicating credentials. Both files are gitignored.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

# Secrets — try the robot-local file first, then fall back to farm_soil's.
for env_file in \
    "$SCRIPT_DIR/secrets/rancho.env" \
    "$REPO_ROOT/farm_soil/secrets/ttn.env" \
    ; do
    if [ -f "$env_file" ]; then
        set -a
        . "$env_file"
        set +a
    fi
done

# LuaJIT-compatible cjson — must come before the user's Lua-5.4-ABI luarocks.
: "${LUA_CPATH:=/usr/local/lib/lua/5.1/?.so;;}"
export LUA_CPATH

export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;$SCRIPT_DIR/chains/?.lua;$REPO_ROOT/robot_common/lib/?.lua;$REPO_ROOT/robot_common/chains/?.lua;;"

# TODO Pi/container deploy: replace bench LD_LIBRARY_PATH with vendor/lib-*.
if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/main.lua" "$@"
