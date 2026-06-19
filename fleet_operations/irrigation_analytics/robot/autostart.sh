#!/usr/bin/env bash
# autostart.sh — idempotent launcher for the irrigation_analytics WSL robot.
#
# Behavior:
#   - If a process is already running this robot (matched by cmdline), exit 0.
#   - Otherwise, launch via run.sh under nohup, redirecting stdout+stderr to
#     var/robot.stdout / var/robot.stderr (appended).
#
# Designed to be called from ~/.bashrc — safe to invoke on every shell open.
# Also serves as the manual restart entry point:
#     pkill -f 'luajit .*/irrigation_analytics/robot/main.lua'
#     bash <this script>
#
# When we move to Pi tomorrow this same script becomes the ExecStart of the
# systemd unit (drop the cmdline-match self-check, let systemd dedup).
#
# Env vars are sourced inside run.sh (secrets/discord.env). Override
# SKIP_LIVE / POLL_INTERVAL_S in your environment before calling if needed.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MAIN_LUA="$SCRIPT_DIR/main.lua"
VAR_DIR="$SCRIPT_DIR/var"
mkdir -p "$VAR_DIR"

# Match the running robot. `pgrep -x luajit` matches by exact executable
# name only, then we filter further by main.lua path. Using -x avoids the
# classic "shell whose cmdline contains the path matches itself" trap.
RUNNING_PIDS=""
for pid in $(pgrep -x luajit 2>/dev/null); do
    if grep -qF "$MAIN_LUA" "/proc/$pid/cmdline" 2>/dev/null; then
        RUNNING_PIDS="$RUNNING_PIDS $pid"
    fi
done
if [ -n "$RUNNING_PIDS" ]; then
    # Already running. Bashrc will hit this every shell open — stay quiet.
    exit 0
fi

# Default SKIP_LIVE=1 so the robot actually POSTs SKIP_STATION when KB1/KB3
# fire. Override by exporting SKIP_LIVE=0 before invoking.
export SKIP_LIVE="${SKIP_LIVE:-1}"

# nohup + setsid so the process survives the parent shell's exit.
nohup setsid "$SCRIPT_DIR/run.sh" \
    >>"$VAR_DIR/robot.stdout" 2>>"$VAR_DIR/robot.stderr" </dev/null &
NEW_PID=$!

# Brief sanity check — bail loudly if it died on launch.
sleep 1
if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "irrigation_robot autostart: launch FAILED (see $VAR_DIR/robot.stderr)" >&2
    tail -10 "$VAR_DIR/robot.stderr" >&2 || true
    exit 1
fi

echo "irrigation_robot autostart: launched pid=$NEW_PID (SKIP_LIVE=$SKIP_LIVE)"
