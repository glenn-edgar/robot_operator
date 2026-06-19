#!/usr/bin/env bash
# run.sh — launcher for the farm_soil robot.
#
# Required env:   ROBOT_CLASS, ROBOT_INSTANCE
# Optional env:   IDENTITY_DIR (default ./identity), ZENOH_LOCATOR
#                 (default tcp/127.0.0.1:7447), FARM_SOIL_TICK_HZ (default 10)
#
# Sources secrets/ttn.env (gitignored) into the environment if present —
# that is where TTN_BEARER_TOKEN lives. The KB0-only boot does not need it;
# the moisture skill-KB will.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

# Secrets — sourced if present (never committed; see secrets/ttn.env.example).
if [ -f "$SCRIPT_DIR/secrets/ttn.env" ]; then
    set -a
    . "$SCRIPT_DIR/secrets/ttn.env"
    set +a
fi

# LuaJIT-compatible cjson (system /usr/local/lib/lua/5.1) — must come before
# the user's ~/.luarocks (Lua-5.4-ABI cjson).
: "${LUA_CPATH:=/usr/local/lib/lua/5.1/?.so;;}"
export LUA_CPATH

# Repo-relative LUA_PATH: this robot's lib/chains, shared robot_common/, vendor.
export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;$SCRIPT_DIR/chains/?.lua;$REPO_ROOT/robot_common/lib/?.lua;$REPO_ROOT/robot_common/chains/?.lua;;"

# TODO Pi/container deploy: replace bench LD_LIBRARY_PATH with vendor/lib-*.
if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/main.lua" "$@"
