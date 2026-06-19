#!/bin/bash
# /app/start.sh — single-container fleet supervisor for irrigation_analytics.
#
# Adapted from packaging/container/start.sh. Same shape: tini's child (PID 2),
# launches procs in staggered phases, exits on first crash for whole-container
# restart, logs JSON crash events to a bind-mounted file.
#
# Difference vs fleet-mcfarland: launches the irrigation_analytics robot
# instead of farm_soil + rancho_water.

set -u

APP_DIR="${APP_DIR:-/app}"
FLEET_DATA_DIR="${FLEET_DATA_DIR:-/var/fleet}"
FLEET_LOG_DIR="${FLEET_LOG_DIR:-$FLEET_DATA_DIR/logs}"
FLEET_SECRETS_DIR="${FLEET_SECRETS_DIR:-/secrets}"
EVENT_LOG="$FLEET_LOG_DIR/supervisor.log"
ROTATE_AT_LINES="${ROTATE_AT_LINES:-100}"
DEDUP_WINDOW_S="${DEDUP_WINDOW_S:-300}"

mkdir -p "$FLEET_LOG_DIR"

# KB4 SQLite directory — written by kb4_clog chain at first tick; pre-create
# here so failures are caught at boot, not silently during fault analysis.
mkdir -p "$FLEET_DATA_DIR/kb4"

# KB2 SQLite directory — written by kb2_resistance chain.
mkdir -p "$FLEET_DATA_DIR/kb2"

# KB2-within-run SQLite directory — separate to avoid lock contention with kb2.
mkdir -p "$FLEET_DATA_DIR/kb2_wr"

# KB1 SQLite directory — written by kb1_overcurrent chain.
mkdir -p "$FLEET_DATA_DIR/kb1"

# KB3 SQLite directory — written by kb3_sustained chain (Glenn 2026-06-09 redesign).
mkdir -p "$FLEET_DATA_DIR/kb3"

# KB4 v2 SQLite directory — PLC-based flow baseline (Glenn 2026-06-09 PM).
mkdir -p "$FLEET_DATA_DIR/kb4v2"

# Notifications log — the robot's "past actions" (KB1/KB3 alerts + daily
# digest); read by application_gateway for /irrigation/alerts (Glenn 2026-06-10).
mkdir -p "$FLEET_DATA_DIR/notify"

# Stage SSH key/config from the read-only secrets bind mount into /root/.ssh
# so the openssh client accepts them (strict-perm check requires
# owner=root + mode 600). Required by controller_client.lua's
# `ssh pi@irrigation ...` call against the LaCima controller.
if [ -d "$FLEET_SECRETS_DIR/ssh" ]; then
    mkdir -p /root/.ssh
    cp -r "$FLEET_SECRETS_DIR/ssh/." /root/.ssh/ 2>/dev/null || true
    chown -R root:root /root/.ssh
    chmod 700 /root/.ssh
    find /root/.ssh -type f ! -name '*.pub' ! -name 'known_hosts' ! -name 'config' \
        -exec chmod 600 {} \; 2>/dev/null
    find /root/.ssh -type f \( -name '*.pub' -o -name 'known_hosts' -o -name 'config' \) \
        -exec chmod 644 {} \; 2>/dev/null
fi

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/usr/local/lib}"

# Sweep all .env files in the secrets bind mount into the env.
if [ -d "$FLEET_SECRETS_DIR" ]; then
    for f in "$FLEET_SECRETS_DIR"/*.env; do
        [ -f "$f" ] || continue
        set -a
        # shellcheck disable=SC1090
        . "$f"
        set +a
    done
fi

export PERSISTENCE_DB="${PERSISTENCE_DB:-$FLEET_DATA_DIR/persistence.db}"
IDENTITY_DIR_ROOT="${IDENTITY_DIR_ROOT:-$FLEET_DATA_DIR/identity}"
mkdir -p "$IDENTITY_DIR_ROOT"

log_event() {
    local level="$1" event="$2" proc="${3:-supervisor}" pid="${4:-null}" rc="${5:-null}"

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
                        return
                    fi
                fi
            fi
        fi
    fi

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

launch() {
    local name="$1"; shift
    "$@" &
    local pid=$!
    PROC_NAMES[$pid]="$name"
    log_event INFO start "$name" "$pid"
}

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

trap 'log_event INFO sigterm; trap - TERM INT; kill 0 2>/dev/null; exit 0' TERM INT

log_event INFO container_boot

# ----------------------------------------------------------------------------
# Staggered launch — same boot-race-avoidance pattern as fleet-mcfarland.
# Total cold-boot ~1m 45s.
# ----------------------------------------------------------------------------

# Phase 1: zenohd (router). 60 s settle.
launch zenohd zenohd -c /etc/zenohd.json5
sleep 60

# Phase 2: fleet_manager (controller). 15 s.
launch fleet_manager bash "$APP_DIR/server/fleet_manager/run.sh"
sleep 15

# Phase 3: back-office services (persistence/gateway/notification). 30 s
# settle so persistence's discovery sub propagates before the robot publishes.
launch persistence  bash "$APP_DIR/server/persistence/run.sh"
launch gateway      bash "$APP_DIR/server/application_gateway/run.sh"
launch notification bash "$APP_DIR/server/notification_service/run.sh"
sleep 30

# Phase 4: irrigation_analytics robot. 105 s after boot — KB0 ack lands cleanly.
launch_robot irrigation_analytics \
    "${IRRIGATION_ANALYTICS_INSTANCE:-lacima}" \
    "$APP_DIR/irrigation_analytics/run.sh"

# Wait for the first child to exit.
wait -n -p CRASHED_PID
CRASHED_RC=$?
CRASHED_NAME="${PROC_NAMES[$CRASHED_PID]:-unknown}"

log_event ERROR crash "$CRASHED_NAME" "$CRASHED_PID" "$CRASHED_RC"

trap - TERM INT
kill 0 2>/dev/null
sleep 1

exit "$CRASHED_RC"
