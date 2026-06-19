#!/usr/bin/env bash
# run.sh — launcher for the fleet_design application gateway.
#
# Optional env: ZENOH_LOCATOR (default tcp/127.0.0.1:7447)
#               GATEWAY_HOST  (default 127.0.0.1)
#               GATEWAY_PORT  (default 8080)
#
# Open http://<host>:<port>/ in a browser to see the dashboard.
# JSON endpoints under /api/ — see main.lua for the route list.

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
