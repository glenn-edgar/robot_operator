#!/usr/bin/env bash
# tests/post_test_digest.sh — wire smoke for the notification service.
#
# Publishes one synthetic digest payload on fleet/notify/digest/daily. Pair
# with a running notification_service to verify the receive + POST path.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

# Force LuaJIT-compatible cjson — must come first so the user's Lua-5.4-ABI
# luarocks cjson.so is not picked up.
export LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;"

export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/?.lua;;"

if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/post_test_digest.lua" "$@"
