#!/usr/bin/env bash
# test_query_client.sh — smoke client for the persistence query RPC.
#
# Same env shape as run.sh; just invokes the test client instead of main.lua.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

: "${LUA_CPATH:=/usr/local/lib/lua/5.1/?.so;;}"
export LUA_CPATH
export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;;"

if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/test_query_client.lua" "$@"
