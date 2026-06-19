#!/usr/bin/env bash
# run.sh — launcher for the fleet_design irrigation_analytics robot.
#
# Required env:   ROBOT_CLASS, ROBOT_INSTANCE
# Optional env:   IDENTITY_DIR (default ./identity), ZENOH_LOCATOR
#                 (default tcp/127.0.0.1:7447), IRRIGATION_ANALYTICS_TICK_HZ
#                 (default 10), IRRIGATION_CONTROLLER_HOST (default
#                 pi@irrigation), IRRIGATION_POLL_S (default 30)
#
# Sources secrets/discord.env if present (DISCORD_WEBHOOK_URL). Falls back
# to farm_soil/secrets/ttn.env so a single bench can run multiple robots
# without duplicating Discord creds. Both files are gitignored.
#
# Mirrors rancho_water/run.sh. Runs side-by-side with the existing bare
# LuaJIT robot at irrigation_analytics/robot/main.lua during the migration —
# they use different Zenoh namespaces (this one has identity, that one
# doesn't) and different controller-poll cadences, so no contention.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VENDOR_LUA=$REPO_ROOT/vendor/lua

# Secrets — robot-local first, then farm_soil fallback.
for env_file in \
    "$SCRIPT_DIR/secrets/discord.env" \
    "$REPO_ROOT/farm_soil/secrets/ttn.env" \
    "$REPO_ROOT/server/notification_service/secrets/discord.env" \
    ; do
    if [ -f "$env_file" ]; then
        set -a
        . "$env_file"
        set +a
    fi
done

# LuaJIT-compatible cjson must beat any Lua 5.4 luarocks copy.
# Force-set (don't preserve caller's wrong LUA_CPATH if any).
export LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;"

export LUA_PATH="$VENDOR_LUA/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;$SCRIPT_DIR/chains/?.lua;$REPO_ROOT/robot_common/lib/?.lua;$REPO_ROOT/robot_common/chains/?.lua;;"

if [ -z "${LD_LIBRARY_PATH:-}" ]; then
    DEFAULT_ZENOH_LIB=$HOME/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/knowledge_base/zenoh
    DEFAULT_PICO_LIB=$HOME/src/zenoh-pico/lib-combined
    export LD_LIBRARY_PATH="$DEFAULT_ZENOH_LIB:$DEFAULT_PICO_LIB"
fi

exec luajit "$SCRIPT_DIR/main.lua" "$@"
