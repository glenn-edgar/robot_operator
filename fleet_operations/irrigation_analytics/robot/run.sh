#!/usr/bin/env bash
# run.sh — launcher for KB1 shadow robot.
#
# Sources secrets/discord.env if present. Sets POLL_INTERVAL_S to 30 by default.
# Logs land in ./var/kb1.log + ./var/kb1_events.log.
#
# Env overrides:
#   POLL_INTERVAL_S        default 30  (controller updates current ~1/min;
#                                       30 s lets the TIME_STAMP-gated sample
#                                       window catch new readings promptly)
#   MANUAL_SUSPEND=1       force SUSPENDED(MANUAL) for testing
#   KB1_THRESHOLDS_JSON    override per-bin KB1 (current) curve file
#   BASELINES_JSON         override per-bin KB3/KB4 (flow) baselines file
#                          default = ../explore/baseline_state/baselines.json
#   DISCORD_WEBHOOK_URL    omit → log-only (no network)

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)

# Pull DISCORD_WEBHOOK_URL from local secrets if present (gitignored).
if [ -f "$SCRIPT_DIR/secrets/discord.env" ]; then
    set -a
    . "$SCRIPT_DIR/secrets/discord.env"
    set +a
elif [ -f "$REPO_ROOT/fleet_design/server/notification_service/secrets/discord.env" ]; then
    set -a
    . "$REPO_ROOT/fleet_design/server/notification_service/secrets/discord.env"
    set +a
fi

# LuaJIT cjson — force the LuaJIT-ABI .so ahead of any luarocks 5.4 copy.
export LUA_CPATH="/usr/local/lib/lua/5.1/?.so;;"
export LUA_PATH="$REPO_ROOT/fleet_design/vendor/lua/?.lua;$SCRIPT_DIR/lib/?.lua;$SCRIPT_DIR/?.lua;;"

exec luajit "$SCRIPT_DIR/main.lua" "$@"
