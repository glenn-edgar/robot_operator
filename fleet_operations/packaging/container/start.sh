#!/bin/bash
# /app/start.sh — single-container fleet supervisor.
#
# Runs as tini's child (PID 2). Launches the 5 procs side-by-side, exits on
# the first crash, logs structured JSON crash events to a bind-mounted file
# so external maintenance programs can scan for badly-functioning systems.
#
# Restart model: whole-container restart on any crash (docker daemon's
# --restart=unless-stopped brings it back). Per-process self-heal was
# considered and rejected in favor of supervisor-script simplicity.
#
# Log file: ${FLEET_LOG_DIR}/supervisor.log (bind-mounted so it survives).
#   * One JSON object per line (trivially scannable by jq / grep / python).
#   * Rotated at ROTATE_AT_LINES (default 100) by mv .log -> .log.1.
#   * Dedup: a crash event identical to the last recorded crash (same proc
#     + same exit code) is SUPPRESSED — keeps disk writes minimal during
#     crash loops. A different signature breaks dedup and gets logged.

set -u

# ----------------------------------------------------------------------------
# Config (all env-driven so the same image works WSL / Pi / field box)
# ----------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/app}"
FLEET_DATA_DIR="${FLEET_DATA_DIR:-/var/fleet}"
FLEET_LOG_DIR="${FLEET_LOG_DIR:-$FLEET_DATA_DIR/logs}"
FLEET_SECRETS_DIR="${FLEET_SECRETS_DIR:-/secrets}"
EVENT_LOG="$FLEET_LOG_DIR/supervisor.log"
ROTATE_AT_LINES="${ROTATE_AT_LINES:-100}"
# Dedup window: crash events with identical (proc, rc) within this many
# seconds of the prior one are suppressed (burst storms compress to one
# entry). Crashes spread further apart each land in the log, so the
# maintenance program sees the real cadence in the log gaps. Default 5 min.
DEDUP_WINDOW_S="${DEDUP_WINDOW_S:-300}"

mkdir -p "$FLEET_LOG_DIR"

# zenoh client libs live in /usr/local/lib via ldconfig (see Dockerfile).
# Set LD_LIBRARY_PATH non-empty so the per-service run.sh fallback (which
# points at bench host paths that DON'T exist in the container) is skipped.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/usr/local/lib}"

# ----------------------------------------------------------------------------
# Source all .env files in the secrets bind mount.
# Each .env is plain KEY=VALUE pairs; every robot/service reads what it needs
# via os.getenv. One sweep here means run.sh per-service sourcing is a no-op.
# ----------------------------------------------------------------------------
if [ -d "$FLEET_SECRETS_DIR" ]; then
    for f in "$FLEET_SECRETS_DIR"/*.env; do
        [ -f "$f" ] || continue
        set -a
        # shellcheck disable=SC1090
        . "$f"
        set +a
    done
fi

# ----------------------------------------------------------------------------
# Persistence defaults — DB and identity dirs land in the bind-mounted var/.
# ----------------------------------------------------------------------------
export PERSISTENCE_DB="${PERSISTENCE_DB:-$FLEET_DATA_DIR/persistence.db}"
IDENTITY_DIR_ROOT="${IDENTITY_DIR_ROOT:-$FLEET_DATA_DIR/identity}"
mkdir -p "$IDENTITY_DIR_ROOT"

# ----------------------------------------------------------------------------
# Structured event log
# ----------------------------------------------------------------------------
log_event() {
    local level="$1" event="$2" proc="${3:-supervisor}" pid="${4:-null}" rc="${5:-null}"

    # Dedup: suppress crash events identical to the last recorded crash
    # ONLY IF that prior crash was within DEDUP_WINDOW_S seconds. Burst
    # storms compress; recurrent same-signature crashes hours apart each
    # land in the log so the operator sees the real cadence.
    if [ "$event" = "crash" ] && [ -f "$EVENT_LOG" ]; then
        local last_crash last_proc last_rc last_ts last_epoch now_epoch age
        last_crash=$(grep '"event":"crash"' "$EVENT_LOG" 2>/dev/null | tail -1)
        if [ -n "$last_crash" ]; then
            last_proc=$(echo "$last_crash" | grep -oE '"proc":"[^"]*"' | cut -d'"' -f4)
            last_rc=$(echo "$last_crash"   | grep -oE '"rc":-?[0-9]+'  | cut -d: -f2)
            if [ "$last_proc" = "$proc" ] && [ "$last_rc" = "$rc" ]; then
                last_ts=$(echo "$last_crash" | grep -oE '"ts":"[^"]*"' | cut -d'"' -f4)
                last_epoch=$(date -u -d "$last_ts" +%s 2>/dev/null || echo "")
                now_epoch=$(date -u +%s)
                if [ -n "$last_epoch" ]; then
                    age=$(( now_epoch - last_epoch ))
                    if [ "$age" -lt "$DEDUP_WINDOW_S" ]; then
                        return    # within window — burst storm dedup
                    fi
                fi
            fi
        fi
    fi

    # Rotate at threshold.
    if [ -f "$EVENT_LOG" ] && [ "$(wc -l < "$EVENT_LOG")" -ge "$ROTATE_AT_LINES" ]; then
        mv "$EVENT_LOG" "$EVENT_LOG.1"
    fi

    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local line
    line=$(printf '{"ts":"%s","level":"%s","event":"%s","proc":"%s","pid":%s,"rc":%s,"host":"%s"}' \
        "$ts" "$level" "$event" "$proc" "$pid" "$rc" "$(hostname)")
    echo "$line" >> "$EVENT_LOG"
    echo "[supervisor] $line" >&2
}

declare -A PROC_NAMES

# Generic launcher — backgrounds a command and records its PID->name.
launch() {
    local name="$1"; shift
    "$@" &
    local pid=$!
    PROC_NAMES[$pid]="$name"
    log_event INFO start "$name" "$pid"
}

# A robot launcher — sets ROBOT_CLASS/INSTANCE/IDENTITY_DIR in a subshell so
# multiple robots can coexist without their env bleeding into each other.
launch_robot() {
    local name="$1" instance="$2" run_sh="$3"
    (
        export ROBOT_CLASS="$name"
        export ROBOT_INSTANCE="$instance"
        export IDENTITY_DIR="$IDENTITY_DIR_ROOT/$name"
        mkdir -p "$IDENTITY_DIR"
        exec bash "$run_sh"
    ) &
    local pid=$!
    PROC_NAMES[$pid]="$name"
    log_event INFO start "$name" "$pid"
}

# SIGTERM from `docker stop` -> kill the whole process group so zenohd + all
# luajit children exit cleanly. `kill 0` signals every PID in the same group
# INCLUDING ourselves, which would re-trigger this trap — so we disarm it
# first with `trap - TERM INT`.
trap 'log_event INFO sigterm; trap - TERM INT; kill 0 2>/dev/null; exit 0' TERM INT

log_event INFO container_boot

# ----------------------------------------------------------------------------
# Launch sequence — STAGGERED to recreate the bench's manual launch cadence.
#
# Boot-time races (in particular the zenoh-pico late-binding race where a
# subscriber declares ~hundreds of ms AFTER a fire-and-forget publish lands
# at the router, losing the message) were silently dodged on the bench by
# the human-typing latency between launching each `bash run.sh`. Containers
# parallel-launch in tens of milliseconds, exposing those races.
#
# Total cold-boot ≈ 1m 45s; paid once per container start. SIGTERM
# interrupts any in-progress `sleep` so `docker stop` still exits promptly.
# ----------------------------------------------------------------------------

# Phase 1: zenohd (router). 60 s settle: huge headroom — the router is
# actually ready in milliseconds, but generous slack covers any first-boot
# OS / disk I/O delays without anyone caring.
launch zenohd zenohd -c /etc/zenohd.json5
sleep 60

# Phase 2: fleet_manager (the controller — serves register RPC, publishes
# the 1 Hz heartbeat that KB0 verifies). 15 s for it to fully come up
# before back-office services try to peer with it.
launch fleet_manager bash "$APP_DIR/server/fleet_manager/run.sh"
sleep 15

# Phase 3: back-office services. persistence's discovery sub on
# `fleet/admin/persistence_topology_announce` MUST be up and propagated
# back to zenohd BEFORE any robot publishes its topology — otherwise the
# topology message is dropped (no subscriber at delivery time) and
# persistence won't open the per-leaf data subs until the next robot
# republish (30 s later, by which time all the one-shot data publishes
# have already gone into the void). 30 s settle covers the worst case
# (fresh-DB schema bootstrap inside persistence).
launch persistence  bash "$APP_DIR/server/persistence/run.sh"
launch gateway      bash "$APP_DIR/server/application_gateway/run.sh"
launch notification bash "$APP_DIR/server/notification_service/run.sh"
sleep 30

# Phase 4: robot processes. By now zenohd has been up 105 s, fleet_manager
# 45 s, back-office 30 s. The robots' KB0 connect dance can land cleanly.
launch_robot farm_soil    "${FARM_SOIL_INSTANCE:-lacima01}"  "$APP_DIR/farm_soil/run.sh"
launch_robot rancho_water "${RANCHO_WATER_INSTANCE:-main}"   "$APP_DIR/rancho_water/run.sh"

# ----------------------------------------------------------------------------
# Wait for the first child to exit. Log which one + its exit code, then exit
# ourselves with the same rc so docker sees the container as failed and
# restarts the whole thing (per --restart=unless-stopped on `docker run`).
# ----------------------------------------------------------------------------
wait -n -p CRASHED_PID
CRASHED_RC=$?
CRASHED_NAME="${PROC_NAMES[$CRASHED_PID]:-unknown}"

log_event ERROR crash "$CRASHED_NAME" "$CRASHED_PID" "$CRASHED_RC"

# Best-effort: signal the rest so docker stop / restart isn't waiting on
# orphaned children. Disarm our own trap first — `kill 0` hits us too and
# we don't want to recurse into the SIGTERM handler.
trap - TERM INT
kill 0 2>/dev/null
sleep 1

exit "$CRASHED_RC"
